//
//  TelemetryIndexStore.swift
//  ACInspector
//
//  Created by Codex on 13.04.26.
//

import Foundation
import SQLite3

actor TelemetryIndexStore {
    private let telemetryStore: TelemetryStore
    private let databaseURL: URL

    init(telemetryStore: TelemetryStore = .shared) {
        self.telemetryStore = telemetryStore
        self.databaseURL = TelemetryPaths.inspectorSupportURL()
            .appendingPathComponent("index.sqlite")
    }

    func refresh() async throws {
        let sessions = await telemetryStore.listSessions()

        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: nil
        )

        let db = try openDatabase()
        defer { sqlite3_close(db) }
        try prepareSchema(in: db)

        try execute("BEGIN IMMEDIATE TRANSACTION;", db: db)
        try execute("DELETE FROM sessions;", db: db)
        try execute("DELETE FROM episodes;", db: db)
        try execute("DELETE FROM events;", db: db)

        for session in sessions {
            try insertSession(session, db: db)
            let events = await telemetryStore.loadEvents(sessionID: session.id)
            try await index(events: events, sessionID: session.id, db: db)
        }

        try execute("COMMIT;", db: db)
    }

    func loadEpisodes() throws -> [IndexedEpisode] {
        let db = try openDatabase()
        defer { sqlite3_close(db) }
        try prepareSchema(in: db)

        let sql = """
        SELECT id, session_id, app_name, window_title, started_at, ended_at, status, end_reason, pinned, labels_json, note, screenshot_path, rendered_prompt_path, prompt_payload_path, model_output_json, reaction_summary, algorithm_id, algorithm_version, prompt_profile_id, experiment_arm
        FROM episodes
        ORDER BY started_at DESC;
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw SQLiteError.prepareFailed(message: currentErrorMessage(db))
        }
        defer { sqlite3_finalize(statement) }

        var results: [IndexedEpisode] = []
        let decoder = JSONDecoder()

        while sqlite3_step(statement) == SQLITE_ROW {
            let labelsJSON = string(at: 9, statement: statement) ?? "[]"
            let labelsData = Data(labelsJSON.utf8)
            let labels = (try? decoder.decode([EpisodeAnnotationLabel].self, from: labelsData)) ?? []

            let startedAt = parseTimestamp(string(at: 4, statement: statement)) ?? Date.distantPast
            let endedAt = parseTimestamp(string(at: 5, statement: statement))
            let status = EpisodeStatus(rawValue: string(at: 6, statement: statement) ?? "active") ?? .active
            let endReason = EpisodeEndReason(rawValue: string(at: 7, statement: statement) ?? "")

            results.append(
                IndexedEpisode(
                    id: string(at: 0, statement: statement) ?? UUID().uuidString,
                    sessionID: string(at: 1, statement: statement) ?? "",
                    appName: string(at: 2, statement: statement) ?? "Unknown App",
                    windowTitle: string(at: 3, statement: statement),
                    startedAt: startedAt,
                    endedAt: endedAt,
                    status: status,
                    endReason: endReason,
                    pinned: int(at: 8, statement: statement) == 1,
                    labels: labels,
                    note: string(at: 10, statement: statement) ?? "",
                    screenshotPath: string(at: 11, statement: statement),
                    renderedPromptPath: string(at: 12, statement: statement),
                    promptPayloadPath: string(at: 13, statement: statement),
                    modelOutputJSON: string(at: 14, statement: statement),
                    reactionSummary: string(at: 15, statement: statement),
                    algorithmID: string(at: 16, statement: statement),
                    algorithmVersion: string(at: 17, statement: statement),
                    promptProfileID: string(at: 18, statement: statement),
                    experimentArm: string(at: 19, statement: statement)
                )
            )
        }

        return results
    }

    func loadEvents(for episodeID: String) throws -> [IndexedEvent] {
        let db = try openDatabase()
        defer { sqlite3_close(db) }
        try prepareSchema(in: db)

        let sql = """
        SELECT id, session_id, episode_id, kind, timestamp, summary, raw_json
        FROM events
        WHERE episode_id = ?
        ORDER BY timestamp ASC;
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw SQLiteError.prepareFailed(message: currentErrorMessage(db))
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, episodeID, -1, sqliteTransient())

        var results: [IndexedEvent] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            results.append(
                IndexedEvent(
                    id: string(at: 0, statement: statement) ?? UUID().uuidString,
                    sessionID: string(at: 1, statement: statement) ?? "",
                    episodeID: string(at: 2, statement: statement),
                    kind: string(at: 3, statement: statement) ?? "",
                    timestamp: parseTimestamp(string(at: 4, statement: statement)) ?? Date.distantPast,
                    summary: string(at: 5, statement: statement) ?? "",
                    rawJSON: string(at: 6, statement: statement) ?? "{}"
                )
            )
        }

        return results
    }

    private func index(events: [TelemetryEvent], sessionID: String, db: OpaquePointer?) async throws {
        struct EpisodeAccumulator {
            var episode: EpisodeRecord
            var labels: Set<EpisodeAnnotationLabel> = []
            var notes: [String] = []
            var screenshotPath: String?
            var renderedPromptPath: String?
            var promptPayloadPath: String?
            var modelOutputJSON: String?
            var reactions: [String] = []
            var strategy: MonitoringExecutionMetadataRecord?
        }

        var accumulators: [String: EpisodeAccumulator] = [:]
        var evaluationEpisodeIDs: [String: String] = [:]

        for event in events {
            let resolvedEpisodeID = resolveEpisodeID(for: event, evaluationEpisodeIDs: evaluationEpisodeIDs)
            if let evaluationID = event.evaluation?.evaluationID,
               let resolvedEpisodeID {
                evaluationEpisodeIDs[evaluationID] = resolvedEpisodeID
            }

            let rawJSON = try await prettyJSONString(for: event)
            let summary = summarize(event)
            try insertEvent(
                IndexedEvent(
                    id: event.id,
                    sessionID: sessionID,
                    episodeID: resolvedEpisodeID,
                    kind: event.kind.rawValue,
                    timestamp: event.timestamp,
                    summary: summary,
                    rawJSON: rawJSON
                ),
                db: db
            )

            guard let episodeID = resolvedEpisodeID else {
                continue
            }

            if let eventEpisode = event.episode ?? accumulators[episodeID]?.episode {
                accumulators[episodeID, default: EpisodeAccumulator(episode: eventEpisode)].episode = eventEpisode
            }

            guard var accumulator = accumulators[episodeID] else {
                continue
            }

            if let annotation = event.annotation {
                accumulator.labels.formUnion(annotation.labels)
                if !annotation.note.isEmpty {
                    accumulator.notes.append(annotation.note)
                }
                if annotation.pinned {
                    accumulator.episode.pinned = true
                }
            }

            if let modelInput = event.modelInput {
                if let screenshot = modelInput.screenshot {
                    accumulator.screenshotPath = await telemetryStore.absoluteArtifactURL(
                        for: screenshot,
                        sessionID: sessionID
                    ).path
                }
                if let renderedPromptArtifact = modelInput.renderedPromptArtifact {
                    accumulator.renderedPromptPath = await telemetryStore.absoluteArtifactURL(
                        for: renderedPromptArtifact,
                        sessionID: sessionID
                    ).path
                }
                if let promptPayloadArtifact = modelInput.promptPayloadArtifact {
                    accumulator.promptPayloadPath = await telemetryStore.absoluteArtifactURL(
                        for: promptPayloadArtifact,
                        sessionID: sessionID
                    ).path
                }
            }

            if let parsedOutput = event.parsedOutput,
               let data = try? await Self.encodeJSON(parsedOutput),
               let json = String(data: data, encoding: .utf8) {
                accumulator.modelOutputJSON = json
            } else if let policy = event.policy,
                      let data = try? await Self.encodeJSON(policy.model),
                      let json = String(data: data, encoding: .utf8) {
                accumulator.modelOutputJSON = json
            }

            if let reaction = event.reaction {
                accumulator.reactions.append(reaction.kind.rawValue)
            }

            if let strategy = event.evaluation?.strategy ??
                event.policy?.strategy ??
                event.action?.strategy {
                accumulator.strategy = strategy
            }

            accumulators[episodeID] = accumulator
        }

        for accumulator in accumulators.values {
            let episode = accumulator.episode
            let note = accumulator.notes.joined(separator: "\n\n")
            let labels = Array(accumulator.labels).sorted { $0.rawValue < $1.rawValue }
            try insertEpisode(
                IndexedEpisode(
                    id: episode.id,
                    sessionID: episode.sessionID,
                    appName: episode.appName,
                    windowTitle: episode.windowTitle,
                    startedAt: episode.startedAt,
                    endedAt: episode.endedAt,
                    status: episode.status,
                    endReason: episode.endReason,
                    pinned: episode.pinned,
                    labels: labels,
                    note: note,
                    screenshotPath: accumulator.screenshotPath,
                    renderedPromptPath: accumulator.renderedPromptPath,
                    promptPayloadPath: accumulator.promptPayloadPath,
                    modelOutputJSON: accumulator.modelOutputJSON,
                    reactionSummary: accumulator.reactions.joined(separator: ", "),
                    algorithmID: accumulator.strategy?.algorithmID,
                    algorithmVersion: accumulator.strategy?.algorithmVersion,
                    promptProfileID: accumulator.strategy?.promptProfileID,
                    experimentArm: accumulator.strategy?.experimentArm
                ),
                db: db
            )
        }
    }

    private func resolveEpisodeID(
        for event: TelemetryEvent,
        evaluationEpisodeIDs: [String: String]
    ) -> String? {
        if let episodeID = event.episodeID {
            return episodeID
        }
        if let episodeID = event.episode?.id {
            return episodeID
        }

        let evaluationID =
            event.evaluation?.evaluationID ??
            event.modelInput?.evaluationID ??
            event.modelOutput?.evaluationID ??
            event.policy?.evaluationID ??
            event.action?.evaluationID ??
            event.failure?.evaluationID

        guard let evaluationID else {
            return nil
        }
        return evaluationEpisodeIDs[evaluationID]
    }

    private func prettyJSONString<T: Encodable & Sendable>(for value: T) async throws -> String {
        let data = try await Self.encodeJSON(value)
        return String(decoding: data, as: UTF8.self)
    }

    private func summarize(_ event: TelemetryEvent) -> String {
        switch event.kind {
        case .sessionStarted:
            return "Session started"
        case .observation:
            return event.observation?.context.appName ?? "Observation"
        case .evaluationRequested:
            if let strategy = event.evaluation?.strategy {
                return "Evaluation requested (\(strategy.algorithmID), \(strategy.promptProfileID))"
            }
            return "Evaluation requested"
        case .modelInputSaved:
            return "Model input saved"
        case .modelOutputReceived:
            return "Model output received"
        case .modelOutputParsed:
            return event.parsedOutput?.assessment.rawValue ?? "Parsed output"
        case .policyDecided:
            if let policy = event.policy,
               let strategy = policy.strategy {
                return "\(policy.finalAction.kind.rawValue) (\(strategy.algorithmID))"
            }
            return event.policy?.finalAction.kind.rawValue ?? "Policy decided"
        case .actionExecuted:
            if let action = event.action,
               let strategy = action.strategy {
                return "\(action.action.kind.rawValue) (\(strategy.algorithmID))"
            }
            return event.action?.action.kind.rawValue ?? "Action executed"
        case .userReaction:
            return event.reaction?.kind.rawValue ?? "Reaction"
        case .annotationSaved:
            return event.annotation?.labels.map(\.rawValue).joined(separator: ", ") ?? "Annotation saved"
        case .sessionEnded:
            return "Session ended"
        case .failure:
            return event.failure?.message ?? "Failure"
        }
    }

    private func openDatabase() throws -> OpaquePointer? {
        var db: OpaquePointer?
        guard sqlite3_open(databaseURL.path, &db) == SQLITE_OK else {
            throw SQLiteError.openFailed(message: currentErrorMessage(db))
        }
        return db
    }

    private func prepareSchema(in db: OpaquePointer?) throws {
        try createTables(in: db)
        try migrateSchema(in: db)
    }

    private func createTables(in db: OpaquePointer?) throws {
        try execute(
            """
            CREATE TABLE IF NOT EXISTS sessions (
                id TEXT PRIMARY KEY,
                started_at TEXT NOT NULL,
                ended_at TEXT,
                path TEXT NOT NULL
            );
            """,
            db: db
        )
        try execute(
            """
            CREATE TABLE IF NOT EXISTS episodes (
                id TEXT PRIMARY KEY,
                session_id TEXT NOT NULL,
                app_name TEXT NOT NULL,
                window_title TEXT,
                started_at TEXT NOT NULL,
                ended_at TEXT,
                status TEXT NOT NULL,
                end_reason TEXT,
                pinned INTEGER NOT NULL,
                labels_json TEXT NOT NULL,
                note TEXT NOT NULL,
                screenshot_path TEXT,
                rendered_prompt_path TEXT,
                prompt_payload_path TEXT,
                model_output_json TEXT,
                reaction_summary TEXT,
                algorithm_id TEXT,
                algorithm_version TEXT,
                prompt_profile_id TEXT,
                experiment_arm TEXT
            );
            """,
            db: db
        )
        try execute(
            """
            CREATE TABLE IF NOT EXISTS events (
                id TEXT PRIMARY KEY,
                session_id TEXT NOT NULL,
                episode_id TEXT,
                kind TEXT NOT NULL,
                timestamp TEXT NOT NULL,
                summary TEXT NOT NULL,
                raw_json TEXT NOT NULL
            );
            """,
            db: db
        )
    }

    private func migrateSchema(in db: OpaquePointer?) throws {
        try ensureColumns(
            in: db,
            table: "episodes",
            columns: [
                ("algorithm_id", "TEXT"),
                ("algorithm_version", "TEXT"),
                ("prompt_profile_id", "TEXT"),
                ("experiment_arm", "TEXT"),
            ]
        )
    }

    private func ensureColumns(
        in db: OpaquePointer?,
        table: String,
        columns: [(name: String, definition: String)]
    ) throws {
        let existingColumns = try columnNames(in: db, table: table)
        for column in columns where existingColumns.contains(column.name) == false {
            try execute(
                "ALTER TABLE \(table) ADD COLUMN \(column.name) \(column.definition);",
                db: db
            )
        }
    }

    private func columnNames(in db: OpaquePointer?, table: String) throws -> Set<String> {
        var statement: OpaquePointer?
        let sql = "PRAGMA table_info(\(table));"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw SQLiteError.prepareFailed(message: currentErrorMessage(db))
        }
        defer { sqlite3_finalize(statement) }

        var names = Set<String>()
        while sqlite3_step(statement) == SQLITE_ROW {
            if let name = string(at: 1, statement: statement) {
                names.insert(name)
            }
        }
        return names
    }

    private func insertSession(_ session: TelemetrySessionDescriptor, db: OpaquePointer?) throws {
        let sql = "INSERT INTO sessions (id, started_at, ended_at, path) VALUES (?, ?, ?, ?);"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw SQLiteError.prepareFailed(message: currentErrorMessage(db))
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, session.id, -1, sqliteTransient())
        sqlite3_bind_text(statement, 2, formatTimestamp(session.startedAt), -1, sqliteTransient())
        sqlite3_bind_text(statement, 3, formatTimestamp(session.endedAt), -1, sqliteTransient())
        sqlite3_bind_text(statement, 4, session.id, -1, sqliteTransient())

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw SQLiteError.stepFailed(message: currentErrorMessage(db))
        }
    }

    private func insertEpisode(_ episode: IndexedEpisode, db: OpaquePointer?) throws {
        let sql = """
        INSERT INTO episodes (id, session_id, app_name, window_title, started_at, ended_at, status, end_reason, pinned, labels_json, note, screenshot_path, rendered_prompt_path, prompt_payload_path, model_output_json, reaction_summary, algorithm_id, algorithm_version, prompt_profile_id, experiment_arm)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw SQLiteError.prepareFailed(message: currentErrorMessage(db))
        }
        defer { sqlite3_finalize(statement) }

        let labelsJSON = String(
            decoding: (try? JSONEncoder().encode(episode.labels)) ?? Data("[]".utf8),
            as: UTF8.self
        )

        sqlite3_bind_text(statement, 1, episode.id, -1, sqliteTransient())
        sqlite3_bind_text(statement, 2, episode.sessionID, -1, sqliteTransient())
        sqlite3_bind_text(statement, 3, episode.appName, -1, sqliteTransient())
        sqlite3_bind_text(statement, 4, episode.windowTitle ?? "", -1, sqliteTransient())
        sqlite3_bind_text(statement, 5, formatTimestamp(episode.startedAt), -1, sqliteTransient())
        sqlite3_bind_text(statement, 6, formatTimestamp(episode.endedAt), -1, sqliteTransient())
        sqlite3_bind_text(statement, 7, episode.status.rawValue, -1, sqliteTransient())
        sqlite3_bind_text(statement, 8, episode.endReason?.rawValue ?? "", -1, sqliteTransient())
        sqlite3_bind_int(statement, 9, episode.pinned ? 1 : 0)
        sqlite3_bind_text(statement, 10, labelsJSON, -1, sqliteTransient())
        sqlite3_bind_text(statement, 11, episode.note, -1, sqliteTransient())
        if let screenshotPath = episode.screenshotPath {
            sqlite3_bind_text(statement, 12, screenshotPath, -1, sqliteTransient())
        } else {
            sqlite3_bind_null(statement, 12)
        }

        if let renderedPromptPath = episode.renderedPromptPath {
            sqlite3_bind_text(statement, 13, renderedPromptPath, -1, sqliteTransient())
        } else {
            sqlite3_bind_null(statement, 13)
        }

        if let promptPayloadPath = episode.promptPayloadPath {
            sqlite3_bind_text(statement, 14, promptPayloadPath, -1, sqliteTransient())
        } else {
            sqlite3_bind_null(statement, 14)
        }
        sqlite3_bind_text(statement, 15, episode.modelOutputJSON ?? "", -1, sqliteTransient())
        sqlite3_bind_text(statement, 16, episode.reactionSummary ?? "", -1, sqliteTransient())
        sqlite3_bind_text(statement, 17, episode.algorithmID ?? "", -1, sqliteTransient())
        sqlite3_bind_text(statement, 18, episode.algorithmVersion ?? "", -1, sqliteTransient())
        sqlite3_bind_text(statement, 19, episode.promptProfileID ?? "", -1, sqliteTransient())
        sqlite3_bind_text(statement, 20, episode.experimentArm ?? "", -1, sqliteTransient())

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw SQLiteError.stepFailed(message: currentErrorMessage(db))
        }
    }

    private func insertEvent(_ event: IndexedEvent, db: OpaquePointer?) throws {
        let sql = """
        INSERT INTO events (id, session_id, episode_id, kind, timestamp, summary, raw_json)
        VALUES (?, ?, ?, ?, ?, ?, ?);
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw SQLiteError.prepareFailed(message: currentErrorMessage(db))
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, event.id, -1, sqliteTransient())
        sqlite3_bind_text(statement, 2, event.sessionID, -1, sqliteTransient())
        sqlite3_bind_text(statement, 3, event.episodeID ?? "", -1, sqliteTransient())
        sqlite3_bind_text(statement, 4, event.kind, -1, sqliteTransient())
        sqlite3_bind_text(statement, 5, formatTimestamp(event.timestamp), -1, sqliteTransient())
        sqlite3_bind_text(statement, 6, event.summary, -1, sqliteTransient())
        sqlite3_bind_text(statement, 7, event.rawJSON, -1, sqliteTransient())

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw SQLiteError.stepFailed(message: currentErrorMessage(db))
        }
    }

    private func execute(_ sql: String, db: OpaquePointer?) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw SQLiteError.stepFailed(message: currentErrorMessage(db))
        }
    }

    private func currentErrorMessage(_ db: OpaquePointer?) -> String {
        if let db, let cString = sqlite3_errmsg(db) {
            return String(cString: cString)
        }
        return "Unknown SQLite error."
    }

    private func string(at index: Int32, statement: OpaquePointer?) -> String? {
        guard let cString = sqlite3_column_text(statement, index) else {
            return nil
        }
        let value = String(cString: cString)
        return value.isEmpty ? nil : value
    }

    private func int(at index: Int32, statement: OpaquePointer?) -> Int32 {
        sqlite3_column_int(statement, index)
    }

    private func parseTimestamp(_ rawValue: String?) -> Date? {
        TelemetryTimestampCodec.date(from: rawValue)
    }

    private func formatTimestamp(_ value: Date?) -> String {
        guard let value else {
            return ""
        }
        return TelemetryTimestampCodec.string(from: value)
    }

    private func sqliteTransient() -> sqlite3_destructor_type? {
        unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    }

    private static func encodeJSON<T: Encodable & Sendable>(_ value: T) async throws -> Data {
        try await MainActor.run {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            return try encoder.encode(value)
        }
    }
}

enum SQLiteError: LocalizedError {
    case openFailed(message: String)
    case prepareFailed(message: String)
    case stepFailed(message: String)

    var errorDescription: String? {
        switch self {
        case let .openFailed(message),
             let .prepareFailed(message),
             let .stepFailed(message):
            return message
        }
    }
}

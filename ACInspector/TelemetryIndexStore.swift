//
//  TelemetryIndexStore.swift
//  ACInspector
//
//  Created by Codex on 13.04.26.
//

import Foundation
import SQLite3

private struct LLMInteractionStorage: Sendable {
    var interactionID: String
    var sessionID: String
    var kind: IndexedEpisodeKind
    var parentInteractionID: String?
    var startedAt: Date
    var endedAt: Date
    var modelIdentifier: String
    var systemPromptPath: String?
    var renderedPromptPath: String?
    var promptPayloadPath: String?
    var rawStdoutPath: String?
    var rawStderrPath: String?
    var parsedOutputJSON: String?
    var summary: String
    var extractedFields: [String: String]
    var failureMessage: String?
}

actor TelemetryIndexStore {
    private struct SessionSourceState: Equatable {
        var descriptorSignature: String
        var eventsSignature: String
    }

    private let telemetryStore: TelemetryStore
    private let databaseURL: URL
    private let telemetryRootURL: URL

    init(telemetryStore: TelemetryStore = .shared) {
        self.telemetryStore = telemetryStore
        self.databaseURL = TelemetryPaths.inspectorSupportURL()
            .appendingPathComponent("index.sqlite")
        self.telemetryRootURL = TelemetryPaths.telemetryRootURL()
    }

    func refresh(forceRebuild: Bool = false) async throws -> Bool {
        let sessions = await telemetryStore.listSessions()

        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: nil
        )

        let db = try openDatabase()
        defer { sqlite3_close(db) }
        try prepareSchema(in: db)

        let existingSourceStates = try loadSourceStates(db: db)
        let currentSessionIDs = Set(sessions.map(\.id))
        var didChange = forceRebuild

        try execute("BEGIN IMMEDIATE TRANSACTION;", db: db)

        let removedSessionIDs = Set(existingSourceStates.keys).subtracting(currentSessionIDs)
        for sessionID in removedSessionIDs {
            try deleteIndexedSession(sessionID: sessionID, db: db)
            try deleteSourceState(sessionID: sessionID, db: db)
            didChange = true
        }

        for session in sessions {
            let sourceState = makeSourceState(for: session)
            let shouldReindex = forceRebuild || existingSourceStates[session.id] != sourceState
            guard shouldReindex else {
                continue
            }

            try deleteIndexedSession(sessionID: session.id, db: db)
            try insertSession(session, db: db)
            let events = await telemetryStore.loadEvents(sessionID: session.id)
            try await index(events: events, sessionID: session.id, db: db)
            try upsertSourceState(sessionID: session.id, state: sourceState, db: db)
            didChange = true
        }

        try execute("COMMIT;", db: db)
        return didChange
    }

    func loadEpisodes() throws -> [IndexedEpisode] {
        let db = try openDatabase()
        defer { sqlite3_close(db) }
        try prepareSchema(in: db)

        let sql = """
        SELECT id, session_id, app_name, window_title, started_at, ended_at, status, end_reason, pinned, labels_json, note, screenshot_path, rendered_prompt_path, prompt_payload_path, model_output_json, reaction_summary, algorithm_id, algorithm_version, prompt_profile_id, experiment_arm, kind, parent_episode_id, extracted_fields_json, system_prompt_path, raw_stdout_path, raw_stderr_path, summary, model_identifier, failure_message
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

            let kindRaw = string(at: 20, statement: statement) ?? IndexedEpisodeKind.focusDecision.rawValue
            let kind = IndexedEpisodeKind(rawValue: kindRaw) ?? .focusDecision
            let extractedJSON = string(at: 22, statement: statement) ?? "{}"
            let extractedData = Data(extractedJSON.utf8)
            let extractedFields = (try? decoder.decode([String: String].self, from: extractedData)) ?? [:]

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
                    experimentArm: string(at: 19, statement: statement),
                    kind: kind,
                    parentEpisodeID: string(at: 21, statement: statement),
                    extractedFields: extractedFields,
                    systemPromptPath: string(at: 23, statement: statement),
                    rawStdoutPath: string(at: 24, statement: statement),
                    rawStderrPath: string(at: 25, statement: statement),
                    summary: string(at: 26, statement: statement) ?? "",
                    modelIdentifier: string(at: 27, statement: statement),
                    failureMessage: string(at: 28, statement: statement)
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
            var primaryPromptMode: String?
            var renderedPromptPath: String?
            var promptPayloadPath: String?
            var modelOutputJSON: String?
            var reactions: [String] = []
            var strategy: MonitoringExecutionMetadataRecord?
        }

        var accumulators: [String: EpisodeAccumulator] = [:]
        var llmAccumulators: [String: LLMInteractionStorage] = [:]
        var evaluationEpisodeIDs: [String: String] = [:]

        for event in events {
            if event.kind == .llmInteraction, let record = event.llmInteraction {
                await ingest(
                    llm: record,
                    event: event,
                    sessionID: sessionID,
                    accumulators: &llmAccumulators
                )
                let rawJSON = (try? await prettyJSONString(for: event)) ?? "{}"
                try insertEvent(
                    IndexedEvent(
                        id: event.id,
                        sessionID: sessionID,
                        episodeID: record.interactionID,
                        kind: event.kind.rawValue,
                        timestamp: event.timestamp,
                        summary: record.summary.isEmpty ? indexedKind(for: record).displayName : record.summary,
                        rawJSON: rawJSON
                    ),
                    db: db
                )
                continue
            }
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
                if shouldPreferPromptMode(modelInput.promptMode, over: accumulator.primaryPromptMode) {
                    accumulator.primaryPromptMode = modelInput.promptMode
                    if let renderedPromptArtifact = modelInput.renderedPromptArtifact {
                        accumulator.renderedPromptPath = await telemetryStore.absoluteArtifactURL(
                            for: renderedPromptArtifact,
                            sessionID: sessionID
                        ).path
                    } else {
                        accumulator.renderedPromptPath = nil
                    }
                    if let promptPayloadArtifact = modelInput.promptPayloadArtifact {
                        accumulator.promptPayloadPath = await telemetryStore.absoluteArtifactURL(
                            for: promptPayloadArtifact,
                            sessionID: sessionID
                        ).path
                    } else {
                        accumulator.promptPayloadPath = nil
                    }
                } else if accumulator.renderedPromptPath == nil,
                          let renderedPromptArtifact = modelInput.renderedPromptArtifact {
                    accumulator.renderedPromptPath = await telemetryStore.absoluteArtifactURL(
                        for: renderedPromptArtifact,
                        sessionID: sessionID
                    ).path
                } else if accumulator.promptPayloadPath == nil,
                          let promptPayloadArtifact = modelInput.promptPayloadArtifact {
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
                    experimentArm: accumulator.strategy?.experimentArm,
                    kind: .focusDecision
                ),
                db: db
            )
        }

        for acc in llmAccumulators.values {
            try insertEpisode(
                IndexedEpisode(
                    id: acc.interactionID,
                    sessionID: acc.sessionID,
                    appName: acc.kind.displayName,
                    windowTitle: acc.summary.isEmpty ? nil : acc.summary,
                    startedAt: acc.startedAt,
                    endedAt: acc.endedAt,
                    status: .ended,
                    endReason: nil,
                    pinned: false,
                    labels: [],
                    note: "",
                    screenshotPath: nil,
                    renderedPromptPath: acc.renderedPromptPath,
                    promptPayloadPath: acc.promptPayloadPath,
                    modelOutputJSON: acc.parsedOutputJSON,
                    reactionSummary: nil,
                    algorithmID: nil,
                    algorithmVersion: nil,
                    promptProfileID: nil,
                    experimentArm: nil,
                    kind: acc.kind,
                    parentEpisodeID: acc.parentInteractionID,
                    extractedFields: acc.extractedFields,
                    systemPromptPath: acc.systemPromptPath,
                    rawStdoutPath: acc.rawStdoutPath,
                    rawStderrPath: acc.rawStderrPath,
                    summary: acc.summary,
                    modelIdentifier: acc.modelIdentifier,
                    failureMessage: acc.failureMessage
                ),
                db: db
            )
        }
    }

    private func indexedKind(for record: LLMInteractionRecord) -> IndexedEpisodeKind {
        switch record.kind {
        case .chat: return .chat
        case .chatAction: return .chatAction
        case .policyMemory: return .policyMemory
        case .memoryConsolidation: return .memoryConsolidation
        case .monitoringText: return .monitoringText
        case .monitoringVision: return .monitoringVision
        case .safelistAppeal: return .safelistAppeal
        case .localChat: return .localChat
        }
    }

    private func ingest(
        llm record: LLMInteractionRecord,
        event: TelemetryEvent,
        sessionID: String,
        accumulators: inout [String: LLMInteractionStorage]
    ) async {
        // Resolve absolute path helper
        func absolutePath(for ref: ArtifactRef?) async -> String? {
            guard let ref else { return nil }
            return await telemetryStore.absoluteArtifactURL(for: ref, sessionID: sessionID).path
        }

        let kind = indexedKind(for: record)
        let systemPath = await absolutePath(for: record.requestArtifacts.systemPrompt)
        let userPath = await absolutePath(for: record.requestArtifacts.userPrompt)
        let payloadPath = await absolutePath(for: record.requestArtifacts.payload)
        let stdoutPath = await absolutePath(for: record.responseArtifacts.rawStdout)
        let stderrPath = await absolutePath(for: record.responseArtifacts.rawStderr)

        if record.isAnnotation {
            // Merge with existing accumulator if present.
            if var existing = accumulators[record.interactionID] {
                if let parsed = record.parsedOutputJSON { existing.parsedOutputJSON = parsed }
                if !record.summary.isEmpty { existing.summary = record.summary }
                if !record.extractedFields.isEmpty { existing.extractedFields = record.extractedFields }
                if let parent = record.parentInteractionID { existing.parentInteractionID = parent }
                accumulators[record.interactionID] = existing
            } else {
                // Annotation without prior record (out-of-order). Create stub.
                accumulators[record.interactionID] = LLMInteractionStorage(
                    interactionID: record.interactionID,
                    sessionID: sessionID,
                    kind: kind,
                    parentInteractionID: record.parentInteractionID,
                    startedAt: record.startedAt,
                    endedAt: record.endedAt,
                    modelIdentifier: record.modelIdentifier,
                    systemPromptPath: nil,
                    renderedPromptPath: nil,
                    promptPayloadPath: nil,
                    rawStdoutPath: nil,
                    rawStderrPath: nil,
                    parsedOutputJSON: record.parsedOutputJSON,
                    summary: record.summary,
                    extractedFields: record.extractedFields,
                    failureMessage: nil
                )
            }
        } else {
            var storage = accumulators[record.interactionID] ?? LLMInteractionStorage(
                interactionID: record.interactionID,
                sessionID: sessionID,
                kind: kind,
                parentInteractionID: record.parentInteractionID,
                startedAt: record.startedAt,
                endedAt: record.endedAt,
                modelIdentifier: record.modelIdentifier,
                systemPromptPath: systemPath,
                renderedPromptPath: userPath,
                promptPayloadPath: payloadPath,
                rawStdoutPath: stdoutPath,
                rawStderrPath: stderrPath,
                parsedOutputJSON: record.parsedOutputJSON,
                summary: record.summary,
                extractedFields: record.extractedFields,
                failureMessage: record.failure?.message
            )
            // First-write fields (in case annotation arrived first as a stub):
            storage.startedAt = record.startedAt
            storage.endedAt = record.endedAt
            storage.modelIdentifier = record.modelIdentifier
            storage.systemPromptPath = systemPath ?? storage.systemPromptPath
            storage.renderedPromptPath = userPath ?? storage.renderedPromptPath
            storage.promptPayloadPath = payloadPath ?? storage.promptPayloadPath
            storage.rawStdoutPath = stdoutPath ?? storage.rawStdoutPath
            storage.rawStderrPath = stderrPath ?? storage.rawStderrPath
            storage.failureMessage = record.failure?.message ?? storage.failureMessage
            if !record.summary.isEmpty { storage.summary = record.summary }
            accumulators[record.interactionID] = storage
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

    private func shouldPreferPromptMode(_ candidate: String, over current: String?) -> Bool {
        promptModePriority(candidate) > promptModePriority(current)
    }

    private func promptModePriority(_ promptMode: String?) -> Int {
        guard let promptMode else { return Int.min }
        switch promptMode {
        case "decision", "legacy_decision", "decision_fallback", "legacy_decision_fallback":
            return 300
        case "nudge_copy":
            return 200
        case "appeal_review":
            return 150
        case "perception_title", "perception_vision", "legacy_perception_vision":
            return 100
        default:
            return 0
        }
    }

    private func prettyJSONString<T: Encodable & Sendable>(for value: T) async throws -> String {
        let data = try await Self.encodeJSON(value)
        return String(decoding: data, as: UTF8.self)
    }

    private func summarize(_ event: TelemetryEvent) -> String {
        switch event.kind {
        case .sessionStarted:
            return "Session started"
        case .sessionHeartbeat:
            return "Session heartbeat"
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
        case .monitoringMetric:
            if let metric = event.metric {
                let parts = [metric.kind.rawValue, metric.reason]
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                return parts.isEmpty ? "Monitoring metric" : parts.joined(separator: " ")
            }
            return "Monitoring metric"
        case .failure:
            return event.failure?.message ?? "Failure"
        case .llmInteraction:
            return event.llmInteraction?.summary ?? "LLM call"
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
        try execute(
            """
            CREATE TABLE IF NOT EXISTS source_states (
                session_id TEXT PRIMARY KEY,
                descriptor_signature TEXT NOT NULL,
                events_signature TEXT NOT NULL
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
                ("kind", "TEXT"),
                ("parent_episode_id", "TEXT"),
                ("extracted_fields_json", "TEXT"),
                ("system_prompt_path", "TEXT"),
                ("raw_stdout_path", "TEXT"),
                ("raw_stderr_path", "TEXT"),
                ("summary", "TEXT"),
                ("model_identifier", "TEXT"),
                ("failure_message", "TEXT"),
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

    private func loadSourceStates(db: OpaquePointer?) throws -> [String: SessionSourceState] {
        let sql = "SELECT session_id, descriptor_signature, events_signature FROM source_states;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw SQLiteError.prepareFailed(message: currentErrorMessage(db))
        }
        defer { sqlite3_finalize(statement) }

        var states: [String: SessionSourceState] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let sessionID = string(at: 0, statement: statement) else {
                continue
            }
            states[sessionID] = SessionSourceState(
                descriptorSignature: string(at: 1, statement: statement) ?? "",
                eventsSignature: string(at: 2, statement: statement) ?? ""
            )
        }
        return states
    }

    private func upsertSourceState(
        sessionID: String,
        state: SessionSourceState,
        db: OpaquePointer?
    ) throws {
        let sql = """
        INSERT INTO source_states (session_id, descriptor_signature, events_signature)
        VALUES (?, ?, ?)
        ON CONFLICT(session_id) DO UPDATE SET
            descriptor_signature = excluded.descriptor_signature,
            events_signature = excluded.events_signature;
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw SQLiteError.prepareFailed(message: currentErrorMessage(db))
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, sessionID, -1, sqliteTransient())
        sqlite3_bind_text(statement, 2, state.descriptorSignature, -1, sqliteTransient())
        sqlite3_bind_text(statement, 3, state.eventsSignature, -1, sqliteTransient())

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw SQLiteError.stepFailed(message: currentErrorMessage(db))
        }
    }

    private func deleteIndexedSession(sessionID: String, db: OpaquePointer?) throws {
        try deleteRows(in: "events", matching: "session_id", value: sessionID, db: db)
        try deleteRows(in: "episodes", matching: "session_id", value: sessionID, db: db)
        try deleteRows(in: "sessions", matching: "id", value: sessionID, db: db)
    }

    private func deleteSourceState(sessionID: String, db: OpaquePointer?) throws {
        try deleteRows(in: "source_states", matching: "session_id", value: sessionID, db: db)
    }

    private func deleteRows(
        in table: String,
        matching column: String,
        value: String,
        db: OpaquePointer?
    ) throws {
        let sql = "DELETE FROM \(table) WHERE \(column) = ?;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw SQLiteError.prepareFailed(message: currentErrorMessage(db))
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, value, -1, sqliteTransient())

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw SQLiteError.stepFailed(message: currentErrorMessage(db))
        }
    }

    private func insertEpisode(_ episode: IndexedEpisode, db: OpaquePointer?) throws {
        let sql = """
        INSERT OR REPLACE INTO episodes (id, session_id, app_name, window_title, started_at, ended_at, status, end_reason, pinned, labels_json, note, screenshot_path, rendered_prompt_path, prompt_payload_path, model_output_json, reaction_summary, algorithm_id, algorithm_version, prompt_profile_id, experiment_arm, kind, parent_episode_id, extracted_fields_json, system_prompt_path, raw_stdout_path, raw_stderr_path, summary, model_identifier, failure_message)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
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
        sqlite3_bind_text(statement, 21, episode.kind.rawValue, -1, sqliteTransient())
        if let parent = episode.parentEpisodeID {
            sqlite3_bind_text(statement, 22, parent, -1, sqliteTransient())
        } else {
            sqlite3_bind_null(statement, 22)
        }
        let extractedJSON = String(
            decoding: (try? JSONEncoder().encode(episode.extractedFields)) ?? Data("{}".utf8),
            as: UTF8.self
        )
        sqlite3_bind_text(statement, 23, extractedJSON, -1, sqliteTransient())
        if let p = episode.systemPromptPath { sqlite3_bind_text(statement, 24, p, -1, sqliteTransient()) } else { sqlite3_bind_null(statement, 24) }
        if let p = episode.rawStdoutPath { sqlite3_bind_text(statement, 25, p, -1, sqliteTransient()) } else { sqlite3_bind_null(statement, 25) }
        if let p = episode.rawStderrPath { sqlite3_bind_text(statement, 26, p, -1, sqliteTransient()) } else { sqlite3_bind_null(statement, 26) }
        sqlite3_bind_text(statement, 27, episode.summary, -1, sqliteTransient())
        if let m = episode.modelIdentifier { sqlite3_bind_text(statement, 28, m, -1, sqliteTransient()) } else { sqlite3_bind_null(statement, 28) }
        if let f = episode.failureMessage { sqlite3_bind_text(statement, 29, f, -1, sqliteTransient()) } else { sqlite3_bind_null(statement, 29) }

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw SQLiteError.stepFailed(message: currentErrorMessage(db))
        }
    }

    private func insertEvent(_ event: IndexedEvent, db: OpaquePointer?) throws {
        let sql = """
        INSERT OR REPLACE INTO events (id, session_id, episode_id, kind, timestamp, summary, raw_json)
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

    private func makeSourceState(for session: TelemetrySessionDescriptor) -> SessionSourceState {
        SessionSourceState(
            descriptorSignature: [
                TelemetryTimestampCodec.string(from: session.startedAt),
                session.endedAt.map(TelemetryTimestampCodec.string(from:)) ?? ""
            ].joined(separator: "|"),
            eventsSignature: fileSignature(at: eventsFileURL(for: session.id))
        )
    }

    private func eventsFileURL(for sessionID: String) -> URL {
        telemetryRootURL
            .appendingPathComponent(sessionID, isDirectory: true)
            .appendingPathComponent("events.jsonl")
    }

    private func fileSignature(at url: URL) -> String {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            return "missing"
        }

        let size = (attributes[.size] as? NSNumber)?.int64Value ?? -1
        let modifiedAt = (attributes[.modificationDate] as? Date)
            .map(TelemetryTimestampCodec.string(from:))
            ?? "unknown"
        return "\(size)|\(modifiedAt)"
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

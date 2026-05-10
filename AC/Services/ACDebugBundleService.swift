//
//  ACDebugBundleService.swift
//  AC
//
//  Exports a compact, agent-readable snapshot of the current debug state plus
//  the raw telemetry session it summarizes.
//

import Foundation

nonisolated enum ACDebugBundleError: LocalizedError {
    case releaseBuild
    case noTelemetrySession

    var errorDescription: String? {
        switch self {
        case .releaseBuild:
            return "Agent debug bundles are only available in Debug builds."
        case .noTelemetrySession:
            return "No telemetry session is available to export."
        }
    }
}

nonisolated struct ACDebugBundleExportResult: Sendable {
    var bundleURL: URL
    var sessionID: String?
}

nonisolated struct ACDebugBundleSummary: Codable, Sendable {
    var exportedAt: Date
    var appBuild: String
    var sessionID: String?
    var telemetryCopied: Bool
    var eventCounts: [String: Int]
    var llmInteractionCounts: [String: Int]
    var skipReasons: [String: Int]
    var decisionMix: [String: Int]
    var actionCounts: [String: Int]
    var profileMetricCounts: [String: Int]
    var failureCount: Int
    var recentFailures: [ACDebugFailureSummary]
    var recentLLMInteractions: [ACDebugLLMSummary]
    var recentActions: [ACDebugActionSummary]
    var artifactHints: [String]
}

nonisolated struct ACDebugFailureSummary: Codable, Sendable {
    var timestamp: Date
    var kind: String
    var episodeID: String?
    var domain: String?
    var message: String
}

nonisolated struct ACDebugLLMSummary: Codable, Sendable {
    var timestamp: Date
    var interactionID: String
    var kind: String
    var parentInteractionID: String?
    var runtime: String
    var modelIdentifier: String
    var summary: String
    var failure: String?
    var extractedFields: [String: String]
    var artifactPaths: [String: String]
}

nonisolated struct ACDebugActionSummary: Codable, Sendable {
    var timestamp: Date
    var action: String
    var source: String
    var succeeded: Bool
    var evaluationID: String?
}

nonisolated struct ACDebugStateSnapshot: Codable, Sendable {
    nonisolated struct Profile: Codable, Sendable {
        var id: String
        var name: String
        var isDefault: Bool
        var description: String?
        var blocklistCount: Int
        var defaultDurationMin: Int?
        var activatedAt: Date?
        var expiresAt: Date?
        var lastUsedAt: Date
    }

    nonisolated struct Rule: Codable, Sendable {
        var id: String
        var kind: String
        var source: String
        var summaryPreview: String
        var profileID: String?
        var active: Bool
        var isLocked: Bool
        var scope: String
        var expiresAt: Date?
    }

    nonisolated struct Memory: Codable, Sendable {
        var id: String
        var createdAt: Date
        var profileID: String?
        var profileName: String?
        var isLocked: Bool
        var textPreview: String
    }

    nonisolated struct RecentAction: Codable, Sendable {
        var kind: String
        var messagePreview: String?
        var timestamp: Date
        var evaluationID: String?
        var appName: String?
        var windowTitlePreview: String?
    }

    var exportedAt: Date
    var setupStatus: String
    var isPaused: Bool
    var debugMode: Bool
    var minimumLogLevel: String
    var permissions: PermissionsSnapshot
    var activeProfileID: String
    var activeProfileName: String
    var profiles: [Profile]
    var monitoringConfiguration: MonitoringConfiguration
    var goalsPreview: String
    var memoryCount: Int
    var recentMemory: [Memory]
    var policyRuleCount: Int
    var activePolicyRules: [Rule]
    var recentActionCount: Int
    var recentActions: [RecentAction]
    var chatMessageCount: Int
    var scheduledActionCount: Int
    var recurringNudgeCount: Int
    var runtimePathOverridePresent: Bool
    var lastFullScreenCheckAt: Date?
}

nonisolated struct ACDebugInspectorEpisodeSummary: Codable, Sendable {
    var id: String
    var kind: String
    var startedAt: Date
    var endedAt: Date?
    var title: String
    var summary: String
    var failure: String?
    var parentID: String?
    var extractedFields: [String: String]
    var artifactPaths: [String: String]
}

nonisolated struct ACDebugInspectorIndexSummary: Codable, Sendable {
    var sessionID: String
    var generatedAt: Date
    var episodeCount: Int
    var episodes: [ACDebugInspectorEpisodeSummary]
}

actor ACDebugBundleService {
    private let telemetryStore: TelemetryStore
    private let fileManager: FileManager
    private let bundleRootURL: URL
    private let activityLogURLProvider: @Sendable () async -> URL
    private let openRouterHealthURLProvider: @Sendable () async -> URL

    init(
        telemetryStore: TelemetryStore = .shared,
        fileManager: FileManager = .default,
        bundleRootURL: URL = TelemetryPaths.applicationSupportURL().appendingPathComponent("debug-bundles", isDirectory: true),
        activityLogURLProvider: @escaping @Sendable () async -> URL = {
            ActivityLogService.shared.fileURL()
        },
        openRouterHealthURLProvider: @escaping @Sendable () async -> URL = {
            OpenRouterHealthStatsService.shared.snapshotFileURL()
        }
    ) {
        self.telemetryStore = telemetryStore
        self.fileManager = fileManager
        self.bundleRootURL = bundleRootURL
        self.activityLogURLProvider = activityLogURLProvider
        self.openRouterHealthURLProvider = openRouterHealthURLProvider
    }

    func export(state: ACState, now: Date = Date()) async throws -> ACDebugBundleExportResult {
        let isDebug = ACBuild.isDebug
        guard isDebug else {
            throw ACDebugBundleError.releaseBuild
        }

        try fileManager.createDirectory(at: bundleRootURL, withIntermediateDirectories: true)
        let bundleURL = bundleRootURL.appendingPathComponent(Self.bundleName(for: now), isDirectory: true)
        if fileManager.fileExists(atPath: bundleURL.path) {
            try fileManager.removeItem(at: bundleURL)
        }
        try fileManager.createDirectory(at: bundleURL, withIntermediateDirectories: true)

        let session = await selectedSession()
        let events: [TelemetryEvent]
        if let session {
            events = await telemetryStore.loadEvents(sessionID: session.id)
        } else {
            events = []
        }

        try writeREADME(to: bundleURL)
        try writeJSON(makeStateSnapshot(from: state, now: now), to: bundleURL.appendingPathComponent("current_state_redacted.json"))

        let summary = makeSummary(events: events, sessionID: session?.id, now: now, telemetryCopied: session != nil, isDebug: isDebug)
        try writeJSON(summary, to: bundleURL.appendingPathComponent("summary.json"))

        if let session {
            try await copyTelemetrySession(session, to: bundleURL)
            let index = makeInspectorIndexSummary(events: events, sessionID: session.id, now: now)
            try writeJSON(index, to: bundleURL.appendingPathComponent("inspector_index_summary.json"))
        } else {
            try writeJSON(
                ACDebugInspectorIndexSummary(sessionID: "", generatedAt: now, episodeCount: 0, episodes: []),
                to: bundleURL.appendingPathComponent("inspector_index_summary.json")
            )
        }

        let activityLogURL = await activityLogURLProvider()
        if fileManager.fileExists(atPath: activityLogURL.path) {
            try? fileManager.copyItem(
                at: activityLogURL,
                to: bundleURL.appendingPathComponent("activity.log")
            )
        }

        let healthURL = await openRouterHealthURLProvider()
        if fileManager.fileExists(atPath: healthURL.path) {
            try? fileManager.copyItem(
                at: healthURL,
                to: bundleURL.appendingPathComponent("openrouter_health.json")
            )
        }

        return ACDebugBundleExportResult(bundleURL: bundleURL, sessionID: session?.id)
    }

    private func selectedSession() async -> TelemetrySessionDescriptor? {
        if let current = await telemetryStore.currentSessionDescriptor() {
            return current
        }
        return await telemetryStore.listSessions().first
    }

    private func copyTelemetrySession(_ session: TelemetrySessionDescriptor, to bundleURL: URL) async throws {
        let sourceRoot = await telemetryStore.rootDirectoryURL()
        let sourceURL = sourceRoot.appendingPathComponent(session.id, isDirectory: true)
        let destinationURL = bundleURL.appendingPathComponent("telemetry", isDirectory: true)
        guard fileManager.fileExists(atPath: sourceURL.path) else { return }
        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }
        try fileManager.copyItem(at: sourceURL, to: destinationURL)
    }

    private func makeStateSnapshot(from state: ACState, now: Date) -> ACDebugStateSnapshot {
        let activeRules = state.policyMemory.rules
            .filter(\.active)
            .sorted { $0.updatedAt > $1.updatedAt }
            .prefix(40)
            .map { rule in
                ACDebugStateSnapshot.Rule(
                    id: rule.id,
                    kind: rule.kind.rawValue,
                    source: rule.source.rawValue,
                    summaryPreview: Self.preview(rule.summary, limit: 240),
                    profileID: rule.profileID,
                    active: rule.active,
                    isLocked: rule.isLocked,
                    scope: Self.scopeSummary(rule.scope),
                    expiresAt: rule.schedule.expiresAt
                )
            }

        let recentMemory = state.memoryEntries
            .sorted { $0.createdAt > $1.createdAt }
            .prefix(20)
            .map {
                ACDebugStateSnapshot.Memory(
                    id: $0.id.uuidString,
                    createdAt: $0.createdAt,
                    profileID: $0.profileID,
                    profileName: $0.profileName,
                    isLocked: $0.isLocked,
                    textPreview: Self.preview($0.text, limit: 300)
                )
            }

        return ACDebugStateSnapshot(
            exportedAt: now,
            setupStatus: "\(state.setupStatus)",
            isPaused: state.isPaused,
            debugMode: state.debugMode,
            minimumLogLevel: state.minimumLogLevel.rawValue,
            permissions: state.permissions,
            activeProfileID: state.activeProfileID,
            activeProfileName: state.profiles.first(where: { $0.id == state.activeProfileID })?.name ?? "Everyday",
            profiles: state.profiles.map {
                ACDebugStateSnapshot.Profile(
                    id: $0.id,
                    name: $0.name,
                    isDefault: $0.isDefault,
                    description: $0.description,
                    blocklistCount: $0.blocklist.count,
                    defaultDurationMin: $0.defaultDurationMin,
                    activatedAt: $0.activatedAt,
                    expiresAt: $0.expiresAt,
                    lastUsedAt: $0.lastUsedAt
                )
            },
            monitoringConfiguration: state.monitoringConfiguration,
            goalsPreview: Self.preview(state.goalsText, limit: 500),
            memoryCount: state.memoryEntries.count,
            recentMemory: Array(recentMemory),
            policyRuleCount: state.policyMemory.rules.count,
            activePolicyRules: Array(activeRules),
            recentActionCount: state.recentActions.count,
            recentActions: state.recentActions
                .sorted { $0.timestamp > $1.timestamp }
                .prefix(20)
                .map {
                    ACDebugStateSnapshot.RecentAction(
                        kind: $0.kind.rawValue,
                        messagePreview: $0.message.map { Self.preview($0, limit: 240) },
                        timestamp: $0.timestamp,
                        evaluationID: $0.evaluationID,
                        appName: $0.appName,
                        windowTitlePreview: $0.windowTitle.map { Self.preview($0, limit: 240) }
                    )
                },
            chatMessageCount: state.chatHistory.count,
            scheduledActionCount: state.scheduledActions.count,
            recurringNudgeCount: state.recurringNudges.count,
            runtimePathOverridePresent: state.runtimePathOverride != nil,
            lastFullScreenCheckAt: state.lastFullScreenCheckAt
        )
    }

    private func makeSummary(
        events: [TelemetryEvent],
        sessionID: String?,
        now: Date,
        telemetryCopied: Bool,
        isDebug: Bool
    ) -> ACDebugBundleSummary {
        var eventCounts: [String: Int] = [:]
        var llmCounts: [String: Int] = [:]
        var skipReasons: [String: Int] = [:]
        var decisionMix: [String: Int] = [:]
        var actionCounts: [String: Int] = [:]
        var profileMetricCounts: [String: Int] = [:]
        var failures: [ACDebugFailureSummary] = []
        var llms: [ACDebugLLMSummary] = []
        var actions: [ACDebugActionSummary] = []
        var artifactHints = Set<String>()

        for event in events {
            eventCounts[event.kind.rawValue, default: 0] += 1
            if let metric = event.metric {
                if metric.kind == .evaluationSkipped {
                    skipReasons[metric.reason, default: 0] += 1
                }
                if metric.kind == .profileChanged {
                    profileMetricCounts[metric.reason, default: 0] += 1
                }
            }
            if let parsed = event.parsedOutput {
                decisionMix[parsed.assessment.rawValue, default: 0] += 1
            }
            if let policy = event.policy {
                decisionMix[policy.model.assessment.rawValue, default: 0] += 1
                actionCounts[policy.finalAction.kind.rawValue, default: 0] += 1
            }
            if let action = event.action {
                actions.append(ACDebugActionSummary(
                    timestamp: event.timestamp,
                    action: action.action.kind.rawValue,
                    source: action.source,
                    succeeded: action.succeeded,
                    evaluationID: action.evaluationID
                ))
                actionCounts[action.action.kind.rawValue, default: 0] += 1
            }
            if let failure = event.failure {
                failures.append(ACDebugFailureSummary(
                    timestamp: event.timestamp,
                    kind: event.kind.rawValue,
                    episodeID: event.episodeID,
                    domain: failure.domain,
                    message: failure.message
                ))
            }
            if let record = event.llmInteraction, !record.isAnnotation {
                llmCounts[record.kind.rawValue, default: 0] += 1
                let llm = makeLLMSummary(record: record, timestamp: event.timestamp)
                llms.append(llm)
                artifactHints.formUnion(llm.artifactPaths.values)
                if let failure = record.failure {
                    failures.append(ACDebugFailureSummary(
                        timestamp: event.timestamp,
                        kind: "llm_interaction.\(record.kind.rawValue)",
                        episodeID: record.interactionID,
                        domain: failure.domain,
                        message: failure.message
                    ))
                }
            }
        }

        return ACDebugBundleSummary(
            exportedAt: now,
            appBuild: isDebug ? "Debug" : "Release",
            sessionID: sessionID,
            telemetryCopied: telemetryCopied,
            eventCounts: eventCounts,
            llmInteractionCounts: llmCounts,
            skipReasons: skipReasons,
            decisionMix: decisionMix,
            actionCounts: actionCounts,
            profileMetricCounts: profileMetricCounts,
            failureCount: failures.count,
            recentFailures: Array(failures.sorted { $0.timestamp > $1.timestamp }.prefix(12)),
            recentLLMInteractions: Array(llms.sorted { $0.timestamp > $1.timestamp }.prefix(20)),
            recentActions: Array(actions.sorted { $0.timestamp > $1.timestamp }.prefix(20)),
            artifactHints: Array(artifactHints).sorted()
        )
    }

    private func makeInspectorIndexSummary(
        events: [TelemetryEvent],
        sessionID: String,
        now: Date
    ) -> ACDebugInspectorIndexSummary {
        var episodes: [String: ACDebugInspectorEpisodeSummary] = [:]

        for event in events {
            if let record = event.llmInteraction {
                let existing = episodes[record.interactionID]
                let artifactPaths = makeArtifactPaths(record: record)
                let mergedFields = record.extractedFields.isEmpty ? (existing?.extractedFields ?? [:]) : record.extractedFields
                let summary = record.summary.isEmpty ? (existing?.summary ?? record.kind.rawValue) : record.summary
                let failure = record.failure?.message ?? existing?.failure
                episodes[record.interactionID] = ACDebugInspectorEpisodeSummary(
                    id: record.interactionID,
                    kind: record.kind.rawValue,
                    startedAt: record.startedAt,
                    endedAt: record.endedAt,
                    title: record.kind.rawValue,
                    summary: summary,
                    failure: failure,
                    parentID: record.parentInteractionID ?? existing?.parentID,
                    extractedFields: mergedFields,
                    artifactPaths: artifactPaths.isEmpty ? (existing?.artifactPaths ?? [:]) : artifactPaths
                )
                continue
            }

            if let episode = event.episode {
                episodes[episode.id] = ACDebugInspectorEpisodeSummary(
                    id: episode.id,
                    kind: "focus_decision",
                    startedAt: episode.startedAt,
                    endedAt: episode.endedAt,
                    title: [episode.appName, episode.windowTitle].compactMap { $0 }.joined(separator: " - "),
                    summary: episode.windowTitle ?? episode.appName,
                    failure: nil,
                    parentID: nil,
                    extractedFields: [:],
                    artifactPaths: [:]
                )
            }

            guard let episodeID = event.episodeID else { continue }
            var existing = episodes[episodeID] ?? ACDebugInspectorEpisodeSummary(
                id: episodeID,
                kind: "focus_decision",
                startedAt: event.timestamp,
                endedAt: nil,
                title: episodeID,
                summary: "",
                failure: nil,
                parentID: nil,
                extractedFields: [:],
                artifactPaths: [:]
            )
            if let failure = event.failure {
                existing.failure = failure.message
            }
            if let policy = event.policy {
                existing.summary = "\(policy.model.assessment.rawValue) -> \(policy.finalAction.kind.rawValue)"
                existing.extractedFields["assessment"] = policy.model.assessment.rawValue
                existing.extractedFields["finalAction"] = policy.finalAction.kind.rawValue
                existing.extractedFields["blockReason"] = policy.blockReason ?? ""
                existing.extractedFields["activeProfile"] = policy.activeProfileName ?? policy.activeProfileID ?? ""
            }
            if let modelInput = event.modelInput {
                if let prompt = modelInput.renderedPromptArtifact {
                    existing.artifactPaths["renderedPrompt"] = "telemetry/\(prompt.relativePath)"
                }
                if let payload = modelInput.promptPayloadArtifact {
                    existing.artifactPaths["promptPayload"] = "telemetry/\(payload.relativePath)"
                }
                if let screenshot = modelInput.screenshot {
                    existing.artifactPaths["screenshot"] = "telemetry/\(screenshot.relativePath)"
                }
            }
            if let modelOutput = event.modelOutput {
                if let stdout = modelOutput.stdoutArtifact {
                    existing.artifactPaths["stdout"] = "telemetry/\(stdout.relativePath)"
                }
                if let stderr = modelOutput.stderrArtifact {
                    existing.artifactPaths["stderr"] = "telemetry/\(stderr.relativePath)"
                }
            }
            episodes[episodeID] = existing
        }

        let ordered = episodes.values.sorted { $0.startedAt > $1.startedAt }
        return ACDebugInspectorIndexSummary(
            sessionID: sessionID,
            generatedAt: now,
            episodeCount: ordered.count,
            episodes: ordered
        )
    }

    private func makeLLMSummary(record: LLMInteractionRecord, timestamp: Date) -> ACDebugLLMSummary {
        ACDebugLLMSummary(
            timestamp: timestamp,
            interactionID: record.interactionID,
            kind: record.kind.rawValue,
            parentInteractionID: record.parentInteractionID,
            runtime: record.runtime.rawValue,
            modelIdentifier: record.modelIdentifier,
            summary: record.summary,
            failure: record.failure?.message,
            extractedFields: record.extractedFields,
            artifactPaths: makeArtifactPaths(record: record)
        )
    }

    private func makeArtifactPaths(record: LLMInteractionRecord) -> [String: String] {
        var paths: [String: String] = [:]
        if let ref = record.requestArtifacts.systemPrompt {
            paths["systemPrompt"] = "telemetry/\(ref.relativePath)"
        }
        if let ref = record.requestArtifacts.userPrompt {
            paths["userPrompt"] = "telemetry/\(ref.relativePath)"
        }
        if let ref = record.requestArtifacts.payload {
            paths["payload"] = "telemetry/\(ref.relativePath)"
        }
        if let ref = record.responseArtifacts.rawStdout {
            paths["rawStdout"] = "telemetry/\(ref.relativePath)"
        }
        if let ref = record.responseArtifacts.rawStderr {
            paths["rawStderr"] = "telemetry/\(ref.relativePath)"
        }
        return paths
    }

    private func writeREADME(to bundleURL: URL) throws {
        try Self.readmeText.write(
            to: bundleURL.appendingPathComponent("README_FOR_AGENT.md"),
            atomically: true,
            encoding: .utf8
        )
    }

    private func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        try data.write(to: url, options: .atomic)
    }

    private static func bundleName(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "agent-debug-\(formatter.string(from: date))"
    }

    private static func scopeSummary(_ scope: PolicyRuleScope) -> String {
        var parts: [String] = []
        if let bundleIdentifier = scope.bundleIdentifier, !bundleIdentifier.isEmpty {
            parts.append("bundle=\(bundleIdentifier)")
        }
        if let appName = scope.appName, !appName.isEmpty {
            parts.append("app=\(appName)")
        }
        if !scope.titleContains.isEmpty {
            parts.append("titleContains=\(scope.titleContains.joined(separator: ","))")
        }
        return parts.isEmpty ? "global" : parts.joined(separator: " ")
    }

    private static func preview(_ value: String, limit: Int) -> String {
        let collapsed = value
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard collapsed.count > limit else { return collapsed }
        return String(collapsed.prefix(limit)) + "..."
    }

    private static let readmeText = """
    # AC Agent Debug Bundle

    Start here:
    1. Read `summary.json` for recent failures, LLM calls, skip reasons, decisions, and actions.
    2. Read `inspector_index_summary.json` to choose the specific episode or interaction to inspect.
    3. Open files listed under `artifactPaths` only for the relevant episode.
    4. Use `activity.log` for human-readable breadcrumbs, not as the source of truth.
    5. Use `current_state_redacted.json` to verify active profile, monitoring config, rules, memory, and recent actions.

    Common triage:
    - OpenRouter failure: inspect `recentFailures`, `openrouter_health.json`, and the failing `llm_interaction` raw stdout/stderr artifacts.
    - Bad chat reply: inspect the latest `chat` or `local_chat` interaction, then compare prompt, raw output, parsed fields, and memory/profile state.
    - Wrong or missed nudge: inspect the latest `focus_decision` episode, skip metrics, prompt payload, parsed decision, policy block reason, and action event.
    - Safelist/profile/memory issue: inspect `policy_memory`, `memory_consolidation`, `safelist_appeal`, profile metrics, and `current_state_redacted.json`.

    Raw telemetry is copied under `telemetry/`. Avoid loading whole artifacts into context unless a summary points to them.
    """
}

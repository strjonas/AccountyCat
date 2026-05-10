//
//  LLMTelemetryRecorder.swift
//  AC
//
//  Captures every LLM call (chat, chat-action, policy-memory, monitoring,
//  memory consolidation, safelist appeal, local chat) as a `.llmInteraction`
//  event in the current telemetry session. The Inspector renders one
//  episode per interaction with extracted fields + raw I/O.
//
//  Gated by `TelemetryPersistencePolicy.storesVerboseTelemetry(...)`
//  (Debug builds only). Retention rides on the existing per-session JSONL
//  cleanup in `TelemetryStore.cleanupExpiredSessions`.
//

import Foundation

/// Snapshot of a single LLM call ready to be persisted by `LLMTelemetryRecorder`.
struct LLMTelemetryCall: Sendable {
    var kind: LLMInteractionKind
    var parentInteractionID: String?
    var runtime: LLMInteractionRuntime
    var modelIdentifier: String
    var promptMode: String?
    var systemPrompt: String
    var userPrompt: String
    var requestPayloadJSON: String?
    var imagePath: String?
    var startedAt: Date
    var endedAt: Date
    var rawStdout: String?
    var rawStderr: String?
    var tokenUsage: TokenUsage?
    var failure: LLMInteractionFailure?
    var summary: String

    init(
        kind: LLMInteractionKind,
        parentInteractionID: String? = nil,
        runtime: LLMInteractionRuntime,
        modelIdentifier: String,
        promptMode: String? = nil,
        systemPrompt: String,
        userPrompt: String,
        requestPayloadJSON: String? = nil,
        imagePath: String? = nil,
        startedAt: Date,
        endedAt: Date,
        rawStdout: String?,
        rawStderr: String? = nil,
        tokenUsage: TokenUsage? = nil,
        failure: LLMInteractionFailure? = nil,
        summary: String = ""
    ) {
        self.kind = kind
        self.parentInteractionID = parentInteractionID
        self.runtime = runtime
        self.modelIdentifier = modelIdentifier
        self.promptMode = promptMode
        self.systemPrompt = systemPrompt
        self.userPrompt = userPrompt
        self.requestPayloadJSON = requestPayloadJSON
        self.imagePath = imagePath
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.rawStdout = rawStdout
        self.rawStderr = rawStderr
        self.tokenUsage = tokenUsage
        self.failure = failure
        self.summary = summary
    }
}

/// Parsed-domain enrichment for an already-recorded LLM call. Sent via
/// `LLMTelemetryRecorder.annotate(...)` once the caller has parsed the raw
/// response into a structured object.
struct LLMTelemetryAnnotation: Sendable {
    var interactionID: String
    var kind: LLMInteractionKind
    var parentInteractionID: String?
    var parsedOutputJSON: String?
    var summary: String
    var extractedFields: [String: String]

    init(
        interactionID: String,
        kind: LLMInteractionKind,
        parentInteractionID: String? = nil,
        parsedOutputJSON: String? = nil,
        summary: String = "",
        extractedFields: [String: String] = [:]
    ) {
        self.interactionID = interactionID
        self.kind = kind
        self.parentInteractionID = parentInteractionID
        self.parsedOutputJSON = parsedOutputJSON
        self.summary = summary
        self.extractedFields = extractedFields
    }
}

actor LLMTelemetryRecorder {
    static let shared = LLMTelemetryRecorder()

    private let store: TelemetryStore
    private let previewLimit = 4_000

    init(store: TelemetryStore = .shared) {
        self.store = store
    }

    /// Persist a call. Returns the new `interactionID` (a UUID string) on success,
    /// or `nil` if telemetry is disabled or the write failed.
    @discardableResult
    func record(_ call: LLMTelemetryCall) async -> String? {
        guard TelemetryPersistencePolicy.storesVerboseTelemetry(debugMode: ACBuild.isDebug) else {
            return nil
        }
        guard Self.canUseSharedStoreInCurrentProcess() else {
            return nil
        }

        let interactionID = UUID().uuidString
        do {
            let session = try await store.ensureCurrentSession()
            let sessionID = session.id

            let systemArtifact = try? await store.writeTextArtifact(
                call.systemPrompt,
                sessionID: sessionID,
                prefix: "llm-\(call.kind.rawValue)-system",
                kind: .promptTemplate
            )
            let userArtifact = try? await store.writeTextArtifact(
                call.userPrompt,
                sessionID: sessionID,
                prefix: "llm-\(call.kind.rawValue)-user",
                kind: .renderedPrompt
            )
            var payloadArtifact: ArtifactRef? = nil
            if let payloadJSON = call.requestPayloadJSON, !payloadJSON.isEmpty {
                payloadArtifact = try? await store.writeTextArtifact(
                    payloadJSON,
                    sessionID: sessionID,
                    prefix: "llm-\(call.kind.rawValue)-payload",
                    kind: .promptPayload
                )
            }

            var stdoutArtifact: ArtifactRef? = nil
            if let rawStdout = call.rawStdout, !rawStdout.isEmpty {
                stdoutArtifact = try? await store.writeTextArtifact(
                    rawStdout,
                    sessionID: sessionID,
                    prefix: "llm-\(call.kind.rawValue)-stdout",
                    kind: .rawStdout
                )
            }
            var stderrArtifact: ArtifactRef? = nil
            if let rawStderr = call.rawStderr, !rawStderr.isEmpty {
                stderrArtifact = try? await store.writeTextArtifact(
                    rawStderr,
                    sessionID: sessionID,
                    prefix: "llm-\(call.kind.rawValue)-stderr",
                    kind: .rawStderr
                )
            }

            let record = LLMInteractionRecord(
                interactionID: interactionID,
                kind: call.kind,
                parentInteractionID: call.parentInteractionID,
                runtime: call.runtime,
                modelIdentifier: call.modelIdentifier,
                promptMode: call.promptMode,
                startedAt: call.startedAt,
                endedAt: call.endedAt,
                latencyMs: call.endedAt.timeIntervalSince(call.startedAt) * 1000,
                tokenUsage: tokenUsageRecord(from: call.tokenUsage),
                requestArtifacts: LLMInteractionRequestArtifacts(
                    systemPrompt: systemArtifact,
                    userPrompt: userArtifact,
                    payload: payloadArtifact
                ),
                responseArtifacts: LLMInteractionResponseArtifacts(
                    rawStdout: stdoutArtifact,
                    rawStderr: stderrArtifact
                ),
                stdoutPreview: call.rawStdout.map { Self.preview($0, limit: previewLimit) },
                stderrPreview: call.rawStderr.map { Self.preview($0, limit: previewLimit) },
                parsedOutputJSON: nil,
                summary: call.summary,
                extractedFields: [:],
                failure: call.failure,
                isAnnotation: false
            )

            try await store.appendEvent(
                TelemetryEvent(
                    id: UUID().uuidString,
                    kind: .llmInteraction,
                    timestamp: call.endedAt,
                    sessionID: sessionID,
                    episodeID: interactionID,
                    episode: nil,
                    session: nil,
                    observation: nil,
                    evaluation: nil,
                    modelInput: nil,
                    modelOutput: nil,
                    parsedOutput: nil,
                    policy: nil,
                    action: nil,
                    metric: nil,
                    reaction: nil,
                    annotation: nil,
                    failure: nil,
                    llmInteraction: record
                ),
                sessionID: sessionID
            )
            return interactionID
        } catch {
            return nil
        }
    }

    /// Append an annotation event that enriches a previously-recorded interaction
    /// with parsed-domain fields. Indexer merges by `interactionID` (last write wins).
    func annotate(_ annotation: LLMTelemetryAnnotation) async {
        guard TelemetryPersistencePolicy.storesVerboseTelemetry(debugMode: ACBuild.isDebug) else {
            return
        }
        guard Self.canUseSharedStoreInCurrentProcess() else {
            return
        }
        do {
            let session = try await store.ensureCurrentSession()
            let sessionID = session.id
            let now = Date()

            let record = LLMInteractionRecord(
                interactionID: annotation.interactionID,
                kind: annotation.kind,
                parentInteractionID: annotation.parentInteractionID,
                runtime: .openrouter,
                modelIdentifier: "",
                promptMode: nil,
                startedAt: now,
                endedAt: now,
                latencyMs: 0,
                tokenUsage: nil,
                requestArtifacts: LLMInteractionRequestArtifacts(systemPrompt: nil, userPrompt: nil, payload: nil),
                responseArtifacts: LLMInteractionResponseArtifacts(rawStdout: nil, rawStderr: nil),
                stdoutPreview: nil,
                stderrPreview: nil,
                parsedOutputJSON: annotation.parsedOutputJSON,
                summary: annotation.summary,
                extractedFields: annotation.extractedFields,
                failure: nil,
                isAnnotation: true
            )

            try await store.appendEvent(
                TelemetryEvent(
                    id: UUID().uuidString,
                    kind: .llmInteraction,
                    timestamp: now,
                    sessionID: sessionID,
                    episodeID: annotation.interactionID,
                    episode: nil,
                    session: nil,
                    observation: nil,
                    evaluation: nil,
                    modelInput: nil,
                    modelOutput: nil,
                    parsedOutput: nil,
                    policy: nil,
                    action: nil,
                    metric: nil,
                    reaction: nil,
                    annotation: nil,
                    failure: nil,
                    llmInteraction: record
                ),
                sessionID: sessionID
            )
        } catch {
            // best-effort
        }
    }

    private nonisolated func tokenUsageRecord(from usage: TokenUsage?) -> TokenUsageRecord? {
        guard let usage else { return nil }
        return TokenUsageRecord(
            promptTokens: usage.promptTokens,
            completionTokens: usage.completionTokens,
            totalTokens: usage.totalTokens,
            cacheReadTokens: usage.cacheReadTokens,
            imageTokens: usage.imageTokens,
            costUSD: usage.costUSD,
            estimated: usage.estimated,
            includesScreenshot: false
        )
    }

    nonisolated private static func preview(_ s: String, limit: Int) -> String {
        if s.count <= limit { return s }
        return String(s.prefix(limit)) + "…"
    }

    nonisolated private static func canUseSharedStoreInCurrentProcess() -> Bool {
        guard NSClassFromString("XCTest") != nil else {
            return true
        }
        let env = ProcessInfo.processInfo.environment
        return env["AC_TELEMETRY_ROOT"] != nil || env["AC_APPLICATION_SUPPORT_DIR"] != nil
    }
}

extension LLMInteractionKind {
    /// Maps `OnlineModelRequestSource` → `LLMInteractionKind` for online calls.
    init(_ source: OnlineModelRequestSource) {
        switch source {
        case .chat: self = .chat
        case .chatAction: self = .chatAction
        case .policyMemory: self = .policyMemory
        case .memoryConsolidation: self = .memoryConsolidation
        case .monitoringText: self = .monitoringText
        case .monitoringVision: self = .monitoringVision
        case .safelistAppeal: self = .safelistAppeal
        }
    }
}

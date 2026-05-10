//
//  AgentDebugBundleTests.swift
//  ACTests
//

import Foundation
import Testing
@testable import AC

@MainActor
struct AgentDebugBundleTests {

    @Test
    func exportsBundleWithSummariesAndCopiedTelemetry() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ac-debug-bundle-telemetry-\(UUID().uuidString)", isDirectory: true)
        let bundleRootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ac-debug-bundles-\(UUID().uuidString)", isDirectory: true)
        let activityLogURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ac-debug-activity-\(UUID().uuidString).log")
        let healthURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ac-debug-health-\(UUID().uuidString).json")
        try "activity breadcrumb".write(to: activityLogURL, atomically: true, encoding: .utf8)
        try #"{"models":{},"updatedAt":"2026-05-08T12:00:00Z"}"#.write(to: healthURL, atomically: true, encoding: .utf8)

        let store = TelemetryStore(rootURL: rootURL)
        let session = try await store.startSession(reason: "test")
        try await store.appendEvent(
            TelemetryEvent(
                id: "failure-1",
                kind: .failure,
                timestamp: Date(timeIntervalSince1970: 10),
                sessionID: session.id,
                episodeID: "episode-1",
                episode: nil,
                session: nil,
                observation: nil,
                evaluation: nil,
                modelInput: nil,
                modelOutput: nil,
                parsedOutput: nil,
                policy: nil,
                action: nil,
                reaction: nil,
                annotation: nil,
                failure: FailureRecord(domain: "provider", message: "OpenRouter 503", evaluationID: nil)
            ),
            sessionID: session.id
        )

        var state = ACState()
        state.setupStatus = .ready
        state.runtimePathOverride = "/tmp/private-runtime-path"
        state.memoryEntries = [
            MemoryEntry(text: "User prefers short direct nudges.", profileID: "general", profileName: "Everyday")
        ]
        state.policyMemory.rules = [
            PolicyRule(kind: .disallow, summary: "Avoid short-form video during work.", source: .userChat)
        ]

        let service = ACDebugBundleService(
            telemetryStore: store,
            bundleRootURL: bundleRootURL,
            activityLogURLProvider: { activityLogURL },
            openRouterHealthURLProvider: { healthURL }
        )
        let result = try await service.export(state: state, now: Date(timeIntervalSince1970: 100))

        #expect(FileManager.default.fileExists(atPath: result.bundleURL.appendingPathComponent("README_FOR_AGENT.md").path))
        #expect(FileManager.default.fileExists(atPath: result.bundleURL.appendingPathComponent("summary.json").path))
        #expect(FileManager.default.fileExists(atPath: result.bundleURL.appendingPathComponent("current_state_redacted.json").path))
        #expect(FileManager.default.fileExists(atPath: result.bundleURL.appendingPathComponent("inspector_index_summary.json").path))
        #expect(FileManager.default.fileExists(atPath: result.bundleURL.appendingPathComponent("activity.log").path))
        #expect(FileManager.default.fileExists(atPath: result.bundleURL.appendingPathComponent("openrouter_health.json").path))
        #expect(FileManager.default.fileExists(atPath: result.bundleURL.appendingPathComponent("telemetry/events.jsonl").path))

        let stateJSON = try String(contentsOf: result.bundleURL.appendingPathComponent("current_state_redacted.json"), encoding: .utf8)
        #expect(stateJSON.contains("runtimePathOverridePresent"))
        #expect(!stateJSON.contains("/tmp/private-runtime-path"))
        #expect(stateJSON.contains("Avoid short-form video"))

        let summary = try decode(ACDebugBundleSummary.self, from: result.bundleURL.appendingPathComponent("summary.json"))
        #expect(summary.sessionID == session.id)
        #expect(summary.failureCount == 1)
        #expect(summary.recentFailures.first?.message == "OpenRouter 503")
    }

    @Test
    func inspectorSummaryMergesLLMInteractionAnnotations() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ac-debug-bundle-telemetry-\(UUID().uuidString)", isDirectory: true)
        let bundleRootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ac-debug-bundles-\(UUID().uuidString)", isDirectory: true)
        let store = TelemetryStore(rootURL: rootURL)
        let session = try await store.startSession(reason: "test")
        let artifact = try await store.writeTextArtifact(
            #"{"reply":"ok"}"#,
            sessionID: session.id,
            prefix: "chat-stdout",
            kind: .rawStdout
        )

        let base = LLMInteractionRecord(
            interactionID: "interaction-1",
            kind: .chat,
            parentInteractionID: nil,
            runtime: .openrouter,
            modelIdentifier: "openai/test",
            promptMode: "chat",
            startedAt: Date(timeIntervalSince1970: 20),
            endedAt: Date(timeIntervalSince1970: 21),
            latencyMs: 1000,
            tokenUsage: nil,
            requestArtifacts: LLMInteractionRequestArtifacts(systemPrompt: nil, userPrompt: nil, payload: nil),
            responseArtifacts: LLMInteractionResponseArtifacts(rawStdout: artifact, rawStderr: nil),
            stdoutPreview: #"{"reply":"ok"}"#,
            stderrPreview: nil,
            parsedOutputJSON: nil,
            summary: "raw chat call",
            extractedFields: [:],
            failure: nil,
            isAnnotation: false
        )
        let annotation = LLMInteractionRecord(
            interactionID: "interaction-1",
            kind: .chat,
            parentInteractionID: nil,
            runtime: .openrouter,
            modelIdentifier: "",
            promptMode: nil,
            startedAt: Date(timeIntervalSince1970: 22),
            endedAt: Date(timeIntervalSince1970: 22),
            latencyMs: 0,
            tokenUsage: nil,
            requestArtifacts: LLMInteractionRequestArtifacts(systemPrompt: nil, userPrompt: nil, payload: nil),
            responseArtifacts: LLMInteractionResponseArtifacts(rawStdout: nil, rawStderr: nil),
            stdoutPreview: nil,
            stderrPreview: nil,
            parsedOutputJSON: #"{"reply":"ok"}"#,
            summary: "parsed chat reply",
            extractedFields: ["replyPreview": "ok"],
            failure: nil,
            isAnnotation: true
        )

        try await appendLLM(base, session: session, store: store)
        try await appendLLM(annotation, session: session, store: store)

        let service = ACDebugBundleService(
            telemetryStore: store,
            bundleRootURL: bundleRootURL,
            activityLogURLProvider: { FileManager.default.temporaryDirectory.appendingPathComponent("missing.log") },
            openRouterHealthURLProvider: { FileManager.default.temporaryDirectory.appendingPathComponent("missing-health.json") }
        )
        let result = try await service.export(state: ACState(), now: Date(timeIntervalSince1970: 100))
        let index = try decode(ACDebugInspectorIndexSummary.self, from: result.bundleURL.appendingPathComponent("inspector_index_summary.json"))

        let chatEpisodes = index.episodes.filter { $0.id == "interaction-1" }
        #expect(chatEpisodes.count == 1)
        let episode = try #require(chatEpisodes.first)
        #expect(episode.summary == "parsed chat reply")
        #expect(episode.extractedFields["replyPreview"] == "ok")
        #expect(episode.artifactPaths["rawStdout"] == "telemetry/\(artifact.relativePath)")
    }

    private func appendLLM(
        _ record: LLMInteractionRecord,
        session: TelemetrySessionDescriptor,
        store: TelemetryStore
    ) async throws {
        try await store.appendEvent(
            TelemetryEvent(
                id: UUID().uuidString,
                kind: .llmInteraction,
                timestamp: record.endedAt,
                sessionID: session.id,
                episodeID: record.interactionID,
                episode: nil,
                session: nil,
                observation: nil,
                evaluation: nil,
                modelInput: nil,
                modelOutput: nil,
                parsedOutput: nil,
                policy: nil,
                action: nil,
                reaction: nil,
                annotation: nil,
                failure: nil,
                llmInteraction: record
            ),
            sessionID: session.id
        )
    }

    private func decode<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(T.self, from: Data(contentsOf: url))
    }
}

//
//  BrainServiceTelemetryTests.swift
//  ACTests
//
//  Created by Codex on 23.04.26.
//

import Foundation
import Testing
@testable import AC

@MainActor
struct BrainServiceTelemetryTests {

    @Test
    func userReactionDoesNotCreateTelemetrySessionWhenDebugModeIsOff() async throws {
        let store = makeStore()
        let brainService = makeBrainService(store: store)
        var state = ACState()
        state.debugMode = false
        brainService.stateProvider = { state }

        brainService.recordUserReaction(
            UserReactionRecord(
                kind: .nudgeRatedPositive,
                relatedAction: nil,
                positive: true,
                details: "helpful"
            )
        )

        try await Task.sleep(for: .milliseconds(100))
        let sessions = await store.listSessions()
        #expect(sessions.isEmpty)
    }

    @Test
    func userReactionCreatesTelemetrySessionWhenDebugModeIsOn() async throws {
        let store = makeStore()
        let brainService = makeBrainService(store: store)
        var state = ACState()
        state.debugMode = true
        brainService.stateProvider = { state }

        brainService.recordUserReaction(
            UserReactionRecord(
                kind: .nudgeRatedPositive,
                relatedAction: nil,
                positive: true,
                details: "helpful"
            )
        )

        try await Task.sleep(for: .milliseconds(100))
        let sessions = await store.listSessions()
        #expect(sessions.count == 1)

        let session = try #require(sessions.first)
        let events = await store.loadEvents(sessionID: session.id)
        #expect(events.contains { $0.kind == .userReaction })
    }

    @Test
    func visionRetryIsLoggedAsMetricWhenTextOnlyReturnsUnclear() async throws {
        // Fake runtime: low-confidence distracted is suppressed to unclear by the algorithm,
        // which then triggers the one-shot vision retry path in BrainService.
        var outputs = FakeRuntimeOutputSet()
        outputs.decision = """
        {"assessment":"distracted","suggested_action":"nudge","confidence":0.3,"reason_tags":["ambiguous"],"nudge":"Stay focused."}
        """
        let runtimeFixture = try FakeRuntimeFixture(outputs: outputs)

        // Minimal 1×1 PNG so the retry snapshot has a valid screenshotPath.
        let screenshotURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ac-test-screenshot-\(UUID().uuidString).png")
        let tinyPNG = Data([
            0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
            0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
            0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
            0x08, 0x02, 0x00, 0x00, 0x00, 0x90, 0x77, 0x53,
            0xDE, 0x00, 0x00, 0x00, 0x0C, 0x49, 0x44, 0x41,
            0x54, 0x08, 0xD7, 0x63, 0xF8, 0xFF, 0xFF, 0x3F,
            0x00, 0x05, 0xFE, 0x02, 0xFE, 0xA7, 0x35, 0x81,
            0x84, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E,
            0x44, 0xAE, 0x42, 0x60, 0x82
        ])
        try tinyPNG.write(to: screenshotURL)
        defer { try? FileManager.default.removeItem(at: screenshotURL) }

        let store = makeStore()

        // A non-browser context with a long descriptive title triggers the
        // title-length gate (canRelyOnTitleAlone = true), so the initial snapshot
        // has no screenshot — the precondition for the retry path.
        let context = FrontmostContext(
            bundleIdentifier: "com.example.testapp",
            appName: "TestApp",
            windowTitle: "Refactoring the monitoring layer in AccountyCat — branch main"
        )

        // Pre-seed the algorithm state so tick() immediately proceeds to evaluation
        // (context already stable, last assessment set so "scheduled_recheck" fires).
        var preSeeded = AlgorithmStateEnvelope()
        preSeeded.llmPolicy.currentContextKey = context.contextKey
        preSeeded.llmPolicy.currentContextEnteredAt = Date.distantPast
        preSeeded.llmPolicy.distraction = DistractionMetadata(
            contextKey: context.contextKey,
            stableSince: Date.distantPast,
            lastAssessment: .focused,
            consecutiveDistractedCount: 0,
            nextEvaluationAt: nil
        )

        var state = ACState()
        state.setupStatus = .ready
        state.debugMode = true
        state.permissions = PermissionsSnapshot(screenRecording: .granted, accessibility: .granted)
        state.monitoringConfiguration.pipelineProfileID = "vision_split_default"
        state.runtimePathOverride = runtimeFixture.runtimePath
        state.algorithmState = preSeeded

        let brainService = makeBrainService(store: store)
        brainService.stateProvider = { state }
        brainService.contextProvider = { context }
        brainService.idleSecondsProvider = { 0 }
        brainService.screenshotCapture = { screenshotURL }

        await brainService.tick()
        try await Task.sleep(for: .milliseconds(200))

        let sessions = await store.listSessions()
        let session = try #require(sessions.first, "Expected a telemetry session to exist")
        let events = await store.loadEvents(sessionID: session.id)
        #expect(
            events.contains { $0.metric?.kind == .visionRetried },
            "Expected a visionRetried metric event — the one-shot vision retry did not fire"
        )
    }

    private func makeStore() -> TelemetryStore {
        TelemetryStore(
            rootURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("ac-brain-telemetry-tests-\(UUID().uuidString)", isDirectory: true)
        )
    }

    private func makeBrainService(store: TelemetryStore) -> BrainService {
        let runtime = LocalModelRuntime()
        let registry = MonitoringAlgorithmRegistry(
            runtime: runtime,
            onlineModelService: OnlineModelService(),
            policyMemoryService: PolicyMemoryService(
                runtime: runtime,
                onlineModelService: OnlineModelService()
            )
        )
        return BrainService(
            monitoringAlgorithmRegistry: registry,
            executiveArm: ExecutiveArm(
                showNudge: { _ in },
                showOverlay: { _ in },
                hideOverlay: { }
            ),
            storageService: StorageService(),
            telemetryStore: store
        )
    }
}

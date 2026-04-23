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

    private func makeStore() -> TelemetryStore {
        TelemetryStore(
            rootURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("ac-brain-telemetry-tests-\(UUID().uuidString)", isDirectory: true)
        )
    }

    private func makeBrainService(store: TelemetryStore) -> BrainService {
        let runtime = LocalModelRuntime()
        let registry = MonitoringAlgorithmRegistry(
            monitoringLLMClient: MonitoringLLMClient(runtime: runtime),
            screenStateExtractor: ScreenStateExtractorService(runtime: runtime),
            nudgeCopywriter: NudgeCopywriterService(runtime: runtime),
            runtime: runtime,
            policyMemoryService: PolicyMemoryService(runtime: runtime)
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

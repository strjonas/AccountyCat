//
//  BrainServiceConfigurationTests.swift
//  ACTests
//
//  Created by Codex on 15.04.26.
//

import Foundation
import Testing
@testable import AC

@MainActor
struct BrainServiceConfigurationTests {

    @Test
    func configurationChangeResetsSelectedAlgorithmState() {
        let runtime = LocalModelRuntime()
        let registry = MonitoringAlgorithmRegistry(
            runtime: runtime,
            onlineModelService: OnlineModelService(),
            policyMemoryService: PolicyMemoryService(
                runtime: runtime,
                onlineModelService: OnlineModelService()
            )
        )
        let brainService = BrainService(
            monitoringAlgorithmRegistry: registry,
            executiveArm: ExecutiveArm(
                showNudge: { _ in },
                showOverlay: { _ in },
                hideOverlay: { },
                minimizeApp: { _ in }
            ),
            storageService: StorageService.temporary(),
            telemetryStore: TelemetryStore(
                rootURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent("ac-brain-tests-\(UUID().uuidString)", isDirectory: true)
            )
        )
        var state = ACState()
        state.algorithmState.llmPolicy.distraction = DistractionMetadata(
            contextKey: "com.google.Chrome|feed",
            stableSince: Date(timeIntervalSince1970: 1),
            lastAssessment: .distracted,
            consecutiveDistractedCount: 2,
            nextEvaluationAt: Date(timeIntervalSince1970: 2)
        )

        brainService.stateProvider = { state }
        func applyStateUpdate(_: ACState, updatedState: ACState) {
            state = updatedState
        }
        brainService.stateSink = applyStateUpdate

        brainService.handleMonitoringConfigurationChange()

        #expect(state.monitoringConfiguration.algorithmID == MonitoringConfiguration.defaultAlgorithmID)
        #expect(state.algorithmState == AlgorithmStateEnvelope())
    }

    @Test
    func registryRejectsUnknownAlgorithmIDs() {
        let runtime = LocalModelRuntime()
        let registry = MonitoringAlgorithmRegistry(
            runtime: runtime,
            onlineModelService: OnlineModelService(),
            policyMemoryService: PolicyMemoryService(
                runtime: runtime,
                onlineModelService: OnlineModelService()
            )
        )

        #expect(throws: MonitoringAlgorithmResolutionError.self) {
            _ = try registry.descriptor(for: "corrupted_algorithm_id")
        }
    }

    @Test
    func activeWindowModeSkipsInitialFullScreenButUsesPeriodicSafetyNet() {
        let now = Date(timeIntervalSince1970: 10_000)
        let interval: TimeInterval = 1_800

        #expect(BrainService.shouldUsePeriodicFullScreenCapture(
            lastFullScreenCheckAt: nil,
            interval: interval,
            now: now
        ) == false)
        #expect(BrainService.shouldUsePeriodicFullScreenCapture(
            lastFullScreenCheckAt: now.addingTimeInterval(-interval + 1),
            interval: interval,
            now: now
        ) == false)
        #expect(BrainService.shouldUsePeriodicFullScreenCapture(
            lastFullScreenCheckAt: now.addingTimeInterval(-interval),
            interval: interval,
            now: now
        ) == true)
    }

    @Test
    func skipDetailExplainsBrowserStableContextWait() {
        let now = Date(timeIntervalSince1970: 10_000)
        var state = ACState()
        state.algorithmState.llmPolicy.currentContextEnteredAt = now.addingTimeInterval(-3)

        let detail = BrainService.evaluationSkipDetail(
            plan: MonitoringEvaluationPlan(
                shouldEvaluate: false,
                reason: "stable_context",
                visualCheckReason: nil,
                requiresScreenshot: true,
                promptMode: "mode",
                promptVersion: "1.0"
            ),
            state: state,
            context: FrontmostContext(
                bundleIdentifier: "com.google.Chrome",
                appName: "Google Chrome",
                windowTitle: "YouTube - Cat videos"
            ),
            heuristics: TelemetryHeuristicSnapshot(
                clearlyProductive: false,
                browser: true,
                helpfulWindowTitle: true,
                periodicVisualReason: nil
            ),
            now: now
        )

        #expect(detail.contains("browser/tab settle 3s/5s"))
        #expect(detail.contains("YouTube - Cat videos"))
    }

    @Test
    func skipDetailExplainsScheduledRecheckCountdown() {
        let now = Date(timeIntervalSince1970: 20_000)
        var state = ACState()
        state.algorithmState.llmPolicy.distraction.lastAssessment = .focused
        state.algorithmState.llmPolicy.distraction.nextEvaluationAt = now.addingTimeInterval(42)

        let detail = BrainService.evaluationSkipDetail(
            plan: MonitoringEvaluationPlan(
                shouldEvaluate: false,
                reason: "scheduled_recheck",
                visualCheckReason: nil,
                requiresScreenshot: true,
                promptMode: "mode",
                promptVersion: "1.0"
            ),
            state: state,
            context: FrontmostContext(
                bundleIdentifier: "com.apple.TextEdit",
                appName: "TextEdit",
                windowTitle: "Notes"
            ),
            heuristics: TelemetryHeuristicSnapshot(
                clearlyProductive: false,
                browser: false,
                helpfulWindowTitle: true,
                periodicVisualReason: nil
            ),
            now: now
        )

        #expect(detail.contains("next recheck in 42s"))
        #expect(detail.contains("last assessment focused"))
    }
}

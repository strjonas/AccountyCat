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
            monitoringLLMClient: MonitoringLLMClient(runtime: runtime),
            screenStateExtractor: ScreenStateExtractorService(runtime: runtime),
            nudgeCopywriter: NudgeCopywriterService(runtime: runtime)
        )
        let brainService = BrainService(
            monitoringAlgorithmRegistry: registry,
            executiveArm: ExecutiveArm(showNudge: { _ in }, showOverlay: { }, hideOverlay: { }),
            storageService: StorageService(),
            telemetryStore: TelemetryStore(
                rootURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent("ac-brain-tests-\(UUID().uuidString)", isDirectory: true)
            )
        )
        var state = ACState()
        state.monitoringConfiguration.promptProfileID = "focus_default_v2"
        state.algorithmState.llmFocus.distraction = DistractionMetadata(
            contextKey: "com.google.Chrome|feed",
            stableSince: Date(timeIntervalSince1970: 1),
            lastAssessment: .distracted,
            consecutiveDistractedCount: 2,
            nextEvaluationAt: Date(timeIntervalSince1970: 2)
        )

        brainService.stateProvider = { state }
        brainService.stateSink = { state = $0 }

        brainService.handleMonitoringConfigurationChange()

        #expect(state.monitoringConfiguration.algorithmID == MonitoringConfiguration.defaultAlgorithmID)
        #expect(state.monitoringConfiguration.promptProfileID == MonitoringConfiguration.defaultPromptProfileID)
        #expect(state.algorithmState == AlgorithmStateEnvelope())
    }

    @Test
    func registryRejectsUnknownAlgorithmIDs() {
        let runtime = LocalModelRuntime()
        let registry = MonitoringAlgorithmRegistry(
            monitoringLLMClient: MonitoringLLMClient(runtime: runtime),
            screenStateExtractor: ScreenStateExtractorService(runtime: runtime),
            nudgeCopywriter: NudgeCopywriterService(runtime: runtime)
        )

        #expect(throws: MonitoringAlgorithmResolutionError.self) {
            _ = try registry.descriptor(for: "corrupted_algorithm_id")
        }
    }
}

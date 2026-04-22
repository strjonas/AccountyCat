//
//  ACStateResetTests.swift
//  ACTests
//
//  Created by Codex on 15.04.26.
//

import Foundation
import Testing
@testable import AC

@MainActor
struct ACStateResetTests {

    @Test
    func resetAlgorithmProfileClearsModelFacingState() {
        var state = ACState()
        state.monitoringConfiguration = MonitoringConfiguration(
            algorithmID: MonitoringConfiguration.deprecatedLegacyLLMAlgorithmID,
            promptProfileID: "focus_default_v2",
            selectionMode: .fixed,
            experimentArmOverride: "manual:test"
        )
        state.goalsText = "Temporary experiment goal"
        state.recentActions = [
            ActionRecord(kind: .nudge, message: "test", timestamp: Date(timeIntervalSince1970: 1))
        ]
        state.recentSwitches = [
            AppSwitchRecord(fromAppName: "Xcode", toAppName: "Chrome", toWindowTitle: "YouTube", timestamp: Date(timeIntervalSince1970: 2))
        ]
        state.usageByDay = [
            "2026-04-15": ["Google Chrome": 120]
        ]
        state.distraction = DistractionMetadata(
            contextKey: "com.google.Chrome|youtube",
            stableSince: Date(timeIntervalSince1970: 3),
            lastAssessment: .distracted,
            consecutiveDistractedCount: 2,
            nextEvaluationAt: Date(timeIntervalSince1970: 4)
        )
        state.memory = "User disliked YouTube nudges."

        state.resetAlgorithmProfile()

        #expect(state.goalsText == ACState.defaultGoalsText)
        #expect(state.recentActions.isEmpty)
        #expect(state.recentSwitches.isEmpty)
        #expect(state.usageByDay.isEmpty)
        #expect(state.algorithmState == AlgorithmStateEnvelope())
        #expect(state.distraction == DistractionMetadata())
        #expect(state.memory.isEmpty)
        #expect(state.monitoringConfiguration.algorithmID == MonitoringConfiguration.defaultAlgorithmID)
        #expect(state.monitoringConfiguration.promptProfileID == "focus_default_v2")
        #expect(state.monitoringConfiguration.pipelineProfileID == MonitoringConfiguration.defaultPipelineProfileID)
        #expect(state.monitoringConfiguration.runtimeProfileID == MonitoringConfiguration.defaultRuntimeProfileID)
        #expect(state.monitoringConfiguration.experimentArm == "manual:test")
        #expect(state.policyMemory == PolicyMemory())
    }
}

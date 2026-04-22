//
//  MonitoringConfigurationTests.swift
//  ACTests
//
//  Created by Codex on 15.04.26.
//

import Foundation
import Testing
@testable import AC

@MainActor
struct MonitoringConfigurationTests {

    @Test
    func decodesLegacyDistractionIntoAlgorithmEnvelope() throws {
        let data = Data("""
        {
          "distraction": {
            "contextKey": "com.google.Chrome|youtube",
            "consecutiveDistractedCount": 2,
            "lastAssessment": "distracted"
          }
        }
        """.utf8)

        let state = try JSONDecoder().decode(ACState.self, from: data)

        #expect(state.monitoringConfiguration.algorithmID == MonitoringConfiguration.defaultAlgorithmID)
        #expect(state.monitoringConfiguration.promptProfileID == MonitoringConfiguration.defaultPromptProfileID)
        #expect(state.monitoringConfiguration.pipelineProfileID == MonitoringConfiguration.defaultPipelineProfileID)
        #expect(state.monitoringConfiguration.runtimeProfileID == MonitoringConfiguration.defaultRuntimeProfileID)
        #expect(state.algorithmState.llmFocus.distraction.contextKey == "com.google.Chrome|youtube")
        #expect(state.algorithmState.llmFocus.distraction.consecutiveDistractedCount == 2)
        #expect(state.algorithmState.llmFocus.distraction.lastAssessment == .distracted)
    }

    @Test
    func decodesLegacyLLMAlgorithmIDIntoRenamedID() throws {
        let data = Data("""
        {
          "monitoringConfiguration": {
            "algorithmID": "legacy_focus_v1",
            "promptProfileID": "focus_default_v2",
            "selectionMode": "fixed"
          }
        }
        """.utf8)

        let state = try JSONDecoder().decode(ACState.self, from: data)

        #expect(state.monitoringConfiguration.algorithmID == MonitoringConfiguration.legacyLLMFocusAlgorithmID)
        #expect(
            state.monitoringConfiguration.experimentArm
            == [
                "fixed",
                MonitoringConfiguration.legacyLLMFocusAlgorithmID,
                MonitoringConfiguration.defaultPipelineProfileID,
                MonitoringConfiguration.defaultRuntimeProfileID,
                MonitoringConfiguration.defaultPromptProfileID,
            ].joined(separator: ":")
        )
    }

    @Test
    func defaultConfigurationUsesLLMPolicyDefaults() {
        let configuration = MonitoringConfiguration()

        #expect(configuration.algorithmID == MonitoringConfiguration.currentLLMMonitorAlgorithmID)
        #expect(configuration.pipelineProfileID == MonitoringConfiguration.defaultPipelineProfileID)
        #expect(configuration.runtimeProfileID == MonitoringConfiguration.defaultRuntimeProfileID)
    }
}

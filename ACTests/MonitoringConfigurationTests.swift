//
//  MonitoringConfigurationTests.swift
//  ACTests
//
//  Created by Codex on 15.04.26.
//

import Foundation
import Testing
@testable import AC

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
        #expect(state.algorithmState.llmFocus.distraction.contextKey == "com.google.Chrome|youtube")
        #expect(state.algorithmState.llmFocus.distraction.consecutiveDistractedCount == 2)
        #expect(state.algorithmState.llmFocus.distraction.lastAssessment == .distracted)
    }
}

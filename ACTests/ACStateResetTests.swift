//
//  ACStateResetTests.swift
//  ACTests
//
//  Created by Codex on 15.04.26.
//

import Foundation
import Testing
@testable import AC

struct ACStateResetTests {

    @Test
    func resetAlgorithmProfileClearsModelFacingState() {
        var state = ACState()
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
        #expect(state.distraction == DistractionMetadata())
        #expect(state.memory.isEmpty)
    }
}

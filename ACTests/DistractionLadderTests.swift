//
//  DistractionLadderTests.swift
//  ACTests
//
//  Created by Codex on 12.04.26.
//

import Foundation
import Testing
@testable import AC

struct DistractionLadderTests {

    @Test
    func waitsForStableWindowBeforeFirstEvaluation() {
        var ladder = DistractionLadder()
        let start = Date(timeIntervalSince1970: 1_000)

        _ = ladder.noteContext("com.apple.dt.Xcode|editing", at: start)

        #expect(ladder.shouldEvaluate(at: start.addingTimeInterval(19)) == false)
        #expect(ladder.shouldEvaluate(at: start.addingTimeInterval(20)) == true)
    }

    @Test
    func focusedDecisionStopsRepeatChecksUntilContextChanges() {
        var ladder = DistractionLadder()
        let start = Date(timeIntervalSince1970: 1_000)

        _ = ladder.noteContext("com.apple.dt.Xcode|editing", at: start)
        _ = ladder.record(assessment: .focused, at: start.addingTimeInterval(20))

        #expect(ladder.shouldEvaluate(at: start.addingTimeInterval(300)) == false)

        _ = ladder.noteContext("com.apple.Safari|reddit", at: start.addingTimeInterval(301))
        #expect(ladder.shouldEvaluate(at: start.addingTimeInterval(321)) == true)
    }

    @Test
    func distractedLadderEscalatesAtExpectedIntervals() {
        var ladder = DistractionLadder()
        let start = Date(timeIntervalSince1970: 2_000)

        _ = ladder.noteContext("com.apple.Safari|instagram", at: start)

        #expect(ladder.shouldEvaluate(at: start.addingTimeInterval(20)) == true)
        #expect(ladder.record(assessment: .distracted, at: start.addingTimeInterval(20)) == .nudgeEligible(sequence: 1))
        #expect(ladder.shouldEvaluate(at: start.addingTimeInterval(20 + 299)) == false)
        #expect(ladder.shouldEvaluate(at: start.addingTimeInterval(20 + 300)) == true)

        #expect(ladder.record(assessment: .distracted, at: start.addingTimeInterval(20 + 300)) == .nudgeEligible(sequence: 2))
        #expect(ladder.shouldEvaluate(at: start.addingTimeInterval(20 + 300 + 599)) == false)
        #expect(ladder.shouldEvaluate(at: start.addingTimeInterval(20 + 300 + 600)) == true)

        #expect(ladder.record(assessment: .distracted, at: start.addingTimeInterval(20 + 300 + 600)) == .nudgeEligible(sequence: 3))
        #expect(ladder.shouldEvaluate(at: start.addingTimeInterval(20 + 300 + 600 + 1_200)) == true)
        #expect(ladder.record(assessment: .distracted, at: start.addingTimeInterval(20 + 300 + 600 + 1_200)) == .overlayEligible(sequence: 4))
    }

    @Test
    func contextChangeResetsDistractionCount() {
        var ladder = DistractionLadder()
        let start = Date(timeIntervalSince1970: 3_000)

        _ = ladder.noteContext("com.apple.Safari|instagram", at: start)
        _ = ladder.record(assessment: .distracted, at: start.addingTimeInterval(20))
        _ = ladder.noteContext("com.apple.dt.Xcode|project", at: start.addingTimeInterval(40))

        #expect(ladder.metadata.consecutiveDistractedCount == 0)
        #expect(ladder.metadata.lastAssessment == nil)
    }
}

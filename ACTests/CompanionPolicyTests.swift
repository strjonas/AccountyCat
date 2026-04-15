//
//  CompanionPolicyTests.swift
//  ACTests
//
//  Created by Codex on 13.04.26.
//

import Foundation
import Testing
@testable import AC

struct CompanionPolicyTests {

    @Test
    func nudgeRequiresExplicitModelPermission() {
        let before = DistractionMetadata(consecutiveDistractedCount: 1)
        let after = DistractionMetadata(consecutiveDistractedCount: 2)
        let decision = LLMDecision(
            assessment: .distracted,
            suggestedAction: .abstain,
            confidence: 0.9,
            reasonTags: ["scrolling"],
            nudge: "come back",
            abstainReason: nil
        )

        let result = CompanionPolicy.decide(
            evaluationID: "eval-1",
            modelDecision: decision,
            ladderSignal: .nudgeEligible(sequence: 2),
            distractionBefore: before,
            distractionAfter: after
        )

        #expect(result.action == .none)
        #expect(result.record.blockReason == "model_did_not_request_nudge")
    }

    @Test
    func overlayRequiresExplicitOverlaySuggestion() {
        let before = DistractionMetadata(consecutiveDistractedCount: 3)
        let after = DistractionMetadata(consecutiveDistractedCount: 4)
        let decision = LLMDecision(
            assessment: .distracted,
            suggestedAction: .nudge,
            confidence: 0.95,
            reasonTags: ["extended_distraction"],
            nudge: "back to it",
            abstainReason: nil
        )

        let result = CompanionPolicy.decide(
            evaluationID: "eval-2",
            modelDecision: decision,
            ladderSignal: .overlayEligible(sequence: 4),
            distractionBefore: before,
            distractionAfter: after
        )

        #expect(result.action == .none)
        #expect(result.record.allowEscalation == false)
    }
}

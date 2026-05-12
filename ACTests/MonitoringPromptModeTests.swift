//
//  MonitoringPromptModeTests.swift
//  ACTests
//
//  Verifies the everyday/session split inside the monitoring decision prompts:
//  both stages embed two distinct mode-specific instruction blocks, and the
//  shared "rules in policySummary are authoritative" clause appears in both so
//  user-defined disallow/discourage rules still fire in everyday mode.
//

import Foundation
import Testing
@testable import AC

struct MonitoringPromptModeTests {

    private func systemPrompt(for stage: ACPromptStage) -> String {
        ACPromptSets.systemPrompt(for: stage)
    }

    @Test
    func onlineDecisionPromptContainsBothModeBlocks() {
        let prompt = systemPrompt(for: .onlineDecision)
        #expect(prompt.contains("Mode: EVERYDAY"))
        #expect(prompt.contains("Mode: FOCUS SESSION"))
        #expect(prompt.contains("activeProfile.isDefault == true"))
        #expect(prompt.contains("activeProfile.isDefault == false"))
    }

    @Test
    func decisionPromptContainsBothModeBlocks() {
        let prompt = systemPrompt(for: .decision)
        #expect(prompt.contains("Mode: EVERYDAY"))
        #expect(prompt.contains("Mode: FOCUS SESSION"))
    }

    @Test
    func bothModesIncludeAuthoritativeRulesClause() {
        let online = systemPrompt(for: .onlineDecision)
        let decision = systemPrompt(for: .decision)
        // The shared clause is what keeps "Reddit is never okay" working in
        // everyday mode — the model must always honour disallow/discourage.
        #expect(online.contains("authoritative regardless of mode"))
        #expect(decision.contains("authoritative regardless of mode"))
        #expect(online.contains("disallow"))
        #expect(decision.contains("disallow"))
    }

    @Test
    func everydayBlockIsLenientAndSessionBlockIsAttentive() {
        let online = systemPrompt(for: .onlineDecision)
        // Everyday block emphasises ambient life; session block emphasises opt-in checking.
        #expect(online.contains("errands") || online.contains("life admin"))
        #expect(online.contains("opted in to being checked"))
        #expect(online.contains("Prefer `unclear` + `abstain` over `nudge`"))
        #expect(online.contains("`recentlyEndedSession` is NOT active"))
        #expect(online.contains("Never enforce it as a current obligation"))
    }

    @Test
    func onlineDecisionPromptIncludesSessionExpiryExamples() {
        let online = systemPrompt(for: .onlineDecision)
        #expect(online.contains("Everyday after expiry"))
        #expect(online.contains("Sonnencreme Gesicht"))
        #expect(online.contains("session_already_ended"))
        #expect(online.contains("User correction wins"))
    }

    @Test
    func bothModesIncludeTitleRelatesSoftSignalClause() {
        let online = systemPrompt(for: .onlineDecision)
        let decision = systemPrompt(for: .decision)
        #expect(online.contains("titleRelatesToDeclaredFocus"))
        #expect(decision.contains("titleRelatesToDeclaredFocus"))
        // The clause should explicitly call it a soft hint to keep the model from
        // over-trusting the heuristic.
        #expect(online.contains("soft hint"))
    }

    @Test
    func everydayCadenceMultiplierExtendsDelays() {
        let cadence = MonitoringCadenceMode.balanced
        let session = cadence.adjustedDelay(cadence.focusedFollowUp, isDefaultProfile: false)
        let everyday = cadence.adjustedDelay(cadence.focusedFollowUp, isDefaultProfile: true)
        #expect(session == cadence.focusedFollowUp)
        #expect(everyday > session)
        #expect(everyday == cadence.focusedFollowUp * MonitoringCadenceMode.everydayDelayMultiplier)
    }

    @Test
    func everydayCadenceMultiplierAppliesToAllDelayKinds() {
        let cadence = MonitoringCadenceMode.sharp
        // All delay flavours that the algorithm uses should be subject to the multiplier
        // so the everyday-mode lean shows up consistently across the pipeline.
        for base in [cadence.stableContextDelay, cadence.focusedFollowUp, cadence.unclearFollowUp,
                     cadence.distractedFollowUp, cadence.focusedDecisionCacheTTL] {
            let everyday = cadence.adjustedDelay(base, isDefaultProfile: true)
            #expect(everyday == base * MonitoringCadenceMode.everydayDelayMultiplier)
        }
    }
}

//
//  MonitoringPromptModeTests.swift
//  ACTests
//
//  Verifies the everyday/session split inside the monitoring decision prompts:
//  both stages embed two distinct mode-specific instruction blocks, and the
//  shared "rules in matchingRuleSummary are authoritative" clause appears in both so
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
        #expect(online.contains("active structural rules"))
        #expect(decision.contains("active structural rules"))
        #expect(online.contains("disallow"))
        #expect(decision.contains("disallow"))
        #expect(online.contains("matchingRuleSummary"))
        #expect(decision.contains("matchingRuleSummary"))
    }

    @Test
    func everydayBlockIsLenientAndSessionBlockIsAttentive() {
        let online = systemPrompt(for: .onlineDecision)
        // Everyday block emphasises ambient life; session block emphasises opt-in checking.
        #expect(online.contains("errands") || online.contains("life admin"))
        #expect(online.contains("tolerated"))
        #expect(online.contains("toleratedWindowSeconds"))
        #expect(online.contains("opted in to being checked"))
        #expect(online.contains("Prefer `unclear` + `abstain` over `nudge`"))
        #expect(online.contains("expired profile or stale chat context"))
    }

    @Test
    func sessionPromptUsesContentFirstProfileSpecificityAndCalibration() {
        let online = systemPrompt(for: .onlineDecision)
        let decision = systemPrompt(for: .decision)
        for prompt in [online, decision] {
            #expect(prompt.contains("Judge the actual content/task first"))
            #expect(prompt.contains("broad archetypes"))
            #expect(prompt.contains("docs, tutorials"))
            #expect(prompt.contains("activeProfile.activatedAt"))
            #expect(prompt.contains("code writing only"))
        }
    }

    @Test
    func promptsDescribeRecentUserMessagesAsProfileWindowScoped() {
        let online = systemPrompt(for: .onlineDecision)
        let decision = systemPrompt(for: .decision)
        #expect(online.contains("profile-window scoped"))
        #expect(decision.contains("profile-window scoped"))
        #expect(online.contains("including Everyday"))
    }

    @Test
    func decisionPromptsStayUnifiedAcrossOnlineAndLocalStages() {
        let prompt = systemPrompt(for: .decision)
        #expect(systemPrompt(for: .onlineDecision) == prompt)
        #expect(prompt.contains("Decision contract"))
        #expect(prompt.contains("decisionFrame"))
        #expect(prompt.contains("customer is king"))
        #expect(prompt.contains("Start from `recentUserMessages`"))
        #expect(!prompt.contains("userGoals"))
    }

    @Test
    func onlineDecisionPromptIncludesSessionExpiryExamples() {
        let online = systemPrompt(for: .onlineDecision)
        #expect(online.contains("Everyday after expiry"))
        #expect(online.contains("Sonnencreme Gesicht"))
        #expect(online.contains("life_admin_allowed"))
        #expect(online.contains("Everyday short break"))
        #expect(online.contains("Everyday drift"))
        #expect(online.contains("User correction wins"))
        #expect(online.contains("Generic coding profile"))
        #expect(online.contains("Strict coding profile"))
    }

    @Test
    func profileCreationPromptsKeepBroadArchetypesBroad() {
        let policy = ACPromptSets.policyMemorySystemPrompt()
        let executor = ACPromptSets.profileActionExecutorSystemPrompt

        #expect(policy.contains("Coding work, including implementation, debugging, docs, references, and tutorials"))
        #expect(executor.contains("broad non-restrictive descriptions"))
        #expect(executor.contains("unless the user explicitly gives exclusions"))
    }

    @Test
    func profileMatchingPromptsRequireScopeFitNotJustNameOverlap() {
        let policy = ACPromptSets.policyMemorySystemPrompt()
        let executor = ACPromptSets.profileActionExecutorSystemPrompt
        let chat = ACPromptSets.chatSystemPrompt(withPersonality: "", workflow: .staged)

        for prompt in [policy, executor] {
            #expect(prompt.contains("name and description"))
            #expect(prompt.contains("pure essay writing"))
            #expect(prompt.contains("scope mismatch"))
        }
        #expect(chat.contains("name and description both fit"))
        #expect(chat.contains("pure essay writing"))
        #expect(executor.contains("\"intent\":\"create\""))
        #expect(executor.contains("Pure essay drafting only"))
        #expect(!policy.contains("Match generously"))
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
        for base in [cadence.stableContextDelay, cadence.focusedFollowUp, cadence.toleratedFollowUp, cadence.unclearFollowUp,
                     cadence.distractedFollowUp, cadence.focusedDecisionCacheTTL] {
            let everyday = cadence.adjustedDelay(base, isDefaultProfile: true)
            #expect(everyday == base * MonitoringCadenceMode.everydayDelayMultiplier)
        }
    }
}

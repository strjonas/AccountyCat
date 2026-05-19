//
//  PromptCatalogTests.swift
//  ACTests
//
//  Created by Codex on 15.04.26.
//

import Testing
@testable import AC

struct PromptCatalogTests {

    @Test
    func policyDecisionPromptUsesSharedDecisionRules() {
        let systemPrompt = ACPromptSets.systemPrompt(for: .decision)
        let onlineDecisionPrompt = ACPromptSets.systemPrompt(for: .onlineDecision)
        let perceptionPrompt = ACPromptSets.systemPrompt(for: .perceptionVision)
        let runtimeProfile = LLMPolicyCatalog.defaultRuntimeProfile

        #expect(systemPrompt.contains("assessment` and `suggested_action` must agree"))
        #expect(systemPrompt.contains("Prefer silence over a false positive."))
        #expect(systemPrompt.contains("matchingRuleSummary"))
        #expect(systemPrompt.contains("activeProfile"))
        #expect(systemPrompt.contains("decisionFrame"))
        #expect(systemPrompt.contains("review/debugger/inspector/prompt-lab/meta-tool"))
        #expect(onlineDecisionPrompt == systemPrompt)
        #expect(onlineDecisionPrompt.contains("Decision contract"))
        #expect(onlineDecisionPrompt.contains("Trust the current screenshot/frontmost app, perception, and `recentActivityTimeline` more than stale `usage`"))
        #expect(onlineDecisionPrompt.contains("review/debugger/inspector/prompt-lab/meta-tool"))
        #expect(perceptionPrompt.contains("Do not decide whether the activity matches the user's current intent or policy rules yet."))
        #expect(runtimeProfile.options(for: .decision).ctxSize == 3072)
    }

    @Test
    func chatAndNudgePromptsReferenceCharacterVoice() {
        let chatPrompt = ACPromptSets.chatSystemPrompt(withPersonality: ACCharacter.onyx.personalityPrefix)
        let nudgePrompt = ACPromptSets.policyDefaultPromptSet.prompt(for: .nudgeCopy).systemPrompt
        let decisionPrompt = ACPromptSets.policyDefaultPromptSet.prompt(for: .onlineDecision).systemPrompt

        // Chat injects the personality directly into the system prompt.
        #expect(chatPrompt.contains("Character voice"))
        #expect(chatPrompt.contains("sharp and decisive focus co-pilot"))
        #expect(chatPrompt.contains("\"actions\":[]"))
        #expect(chatPrompt.contains("Action kinds:"))

        // Nudge and decision prompts must NOT contain the personality prefix as a
        // payload field reference — it is injected as a system-prompt prefix at
        // call time so weak models cannot echo it verbatim as output.
        #expect(!nudgePrompt.contains("characterPersonalityPrefix"))
        #expect(!decisionPrompt.contains("characterPersonalityPrefix"))
    }

    @Test
    func memoryConsolidationPromptPrefersLatestUserInstruction() {
        let prompt = ACPromptSets.memoryConsolidationSystemPrompt

        #expect(prompt.contains("most recent user interaction"))
        #expect(prompt.contains("source of truth"))
        #expect(prompt.contains("preserve both sides"))
        #expect(prompt.contains("Treat explicit directives in recent user chat messages as fresh ground truth"))
        #expect(prompt.contains("It is fine to return fewer"))
    }
}

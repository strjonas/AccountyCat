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
        let perceptionPrompt = ACPromptSets.systemPrompt(for: .perceptionVision)
        let runtimeProfile = LLMPolicyCatalog.defaultRuntimeProfile

        #expect(systemPrompt.contains("assessment` and `suggested_action` must agree"))
        #expect(systemPrompt.contains("Prefer silence over a false positive."))
        #expect(systemPrompt.contains("policySummary"))
        #expect(systemPrompt.contains("the newest relevant user statement wins"))
        #expect(perceptionPrompt.contains("Do not decide whether the activity matches the user's goals or policy rules yet."))
        #expect(runtimeProfile.options(for: .decision).ctxSize == 4096)
    }

    @Test
    func chatAndNudgePromptsReferenceCharacterVoice() {
        let chatPrompt = ACPromptSets.chatSystemPrompt(withPersonality: ACCharacter.nova.personalityPrefix)
        let nudgePrompt = ACPromptSets.policyDefaultPromptSet.prompt(for: .nudgeCopy).systemPrompt
        let decisionPrompt = ACPromptSets.policyDefaultPromptSet.prompt(for: .onlineDecision).systemPrompt

        // Chat injects the personality directly into the system prompt.
        #expect(chatPrompt.contains("Character voice:"))
        #expect(chatPrompt.contains("sharp-minded, energetic focus co-pilot"))

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

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
    func resolvesDefaultMonitoringPromptProfile() {
        let profile = PromptCatalog.monitoringProfile(id: MonitoringConfiguration.defaultPromptProfileID)
        let fallback = PromptCatalog.monitoringProfile(id: "missing-profile")
        let prompt = PromptCatalog.loadMonitoringPrompt(
            profileID: MonitoringConfiguration.defaultPromptProfileID,
            variant: .visionPrimary
        )

        #expect(profile.descriptor.id == MonitoringConfiguration.defaultPromptProfileID)
        #expect(profile.descriptor.version == "focus_default_v2")
        #expect(fallback.descriptor.id == profile.descriptor.id)
        #expect(prompt.asset.id == "monitoring.focus_default_v2.vision_system")
        #expect(prompt.asset.version == "focus_default_v2")
        #expect(prompt.contents.isEmpty == false)
    }

    @Test
    func policyDecisionPromptUsesSharedDecisionRules() {
        let systemPrompt = PromptCatalog.loadPolicySystemPrompt(stage: .decision)
        let perceptionPrompt = PromptCatalog.loadPolicySystemPrompt(stage: .perceptionVision)
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
        let chatPrompt = PromptCatalog.loadChatSystemPrompt(character: .nova)
        let nudgePrompt = MonitoringPromptTuning.policyDefaultPromptSet.prompt(for: .nudgeCopy).systemPrompt

        #expect(chatPrompt.contains("Character voice:"))
        #expect(chatPrompt.contains("sharp-minded, energetic focus co-pilot"))
        #expect(nudgePrompt.contains("characterPersonalityPrefix"))
    }
}

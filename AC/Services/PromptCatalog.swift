//
//  PromptCatalog.swift
//  AC
//
//  Thin forwarding accessor. All prompt text lives in ACPromptSets (ACShared).
//

import Foundation

enum PromptCatalog {

    // MARK: - Policy stage prompts (forwarded from ACPromptSets)

    nonisolated static func loadPolicySystemPrompt(stage: LLMPolicyStage) -> String {
        let promptStage = sharedPolicyStage(for: stage)
        return ACPromptSets.policyDefaultPromptSet.prompt(for: promptStage).systemPrompt
    }

    nonisolated static func renderPolicyUserPrompt(
        stage: LLMPolicyStage,
        payloadJSON: String
    ) -> String {
        let promptStage = sharedPolicyStage(for: stage)
        let template = ACPromptSets.policyDefaultPromptSet.prompt(for: promptStage).userTemplate
        return template.replacingOccurrences(of: "{{PAYLOAD_JSON}}", with: payloadJSON)
    }

    nonisolated static func loadPolicyMemorySystemPrompt() -> String {
        loadPolicySystemPrompt(stage: .policyMemory)
    }

    nonisolated static func renderPolicyMemoryUserPrompt(payloadJSON: String) -> String {
        renderPolicyUserPrompt(stage: .policyMemory, payloadJSON: payloadJSON)
    }

    // MARK: - Chat prompt (from ACPromptSets, with character voice injected)

    nonisolated static func loadChatSystemPrompt(character: ACCharacter = .mochi) -> String {
        """
        Character voice:
        \(character.personalityPrefix)

        \(ACPromptSets.chatSystemPrompt)
        """
    }

    // MARK: - Memory consolidation prompt (from ACPromptSets)

    nonisolated static func loadMemoryConsolidationSystemPrompt() -> String {
        ACPromptSets.memoryConsolidationSystemPrompt
    }

    // MARK: - Private helpers

    nonisolated private static func sharedPolicyStage(for stage: LLMPolicyStage) -> ACPromptStage {
        switch stage {
        case .perceptionTitle: return .perceptionTitle
        case .perceptionVision: return .perceptionVision
        case .onlineDecision: return .onlineDecision
        case .decision: return .decision
        case .nudgeCopy: return .nudgeCopy
        case .appealReview: return .appealReview
        case .policyMemory: return .policyMemory
        case .safelistAppeal: return .safelistAppeal
        }
    }
}

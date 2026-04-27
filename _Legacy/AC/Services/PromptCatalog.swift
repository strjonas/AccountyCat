//
//  PromptCatalog.swift
//  AC
//
//  Created by Codex on 15.04.26.
//

import Foundation

enum MonitoringPromptVariant: String, Sendable {
    case visionPrimary = "vision_primary"
    case fallback
    case visionPrimaryUser = "vision_primary_user"
    case fallbackUser = "fallback_user"
}

enum LegacyFocusPromptStage: String, Sendable {
    case decision
    case decisionFallback = "decision_fallback"
}

struct PromptAsset: Hashable, Sendable {
    var id: String
    var version: String
    var resourceName: String
    var fileExtension: String
    var subdirectory: String
    var fallbackContents: String
}

struct MonitoringPromptProfile: Hashable, Sendable {
    var descriptor: MonitoringPromptProfileDescriptor
    var visionPrimarySystemPrompt: PromptAsset
    var fallbackSystemPrompt: PromptAsset
    /// User-turn template for the primary (vision) attempt. Contains `{{PAYLOAD_JSON}}` placeholder.
    var visionPrimaryUserTemplate: PromptAsset
    /// User-turn template for the fallback attempt. Contains `{{PAYLOAD_JSON}}` placeholder.
    var fallbackUserTemplate: PromptAsset
}

enum PromptCatalog {
    nonisolated static let defaultMonitoringPromptProfile = MonitoringPromptProfile(
        descriptor: MonitoringPromptProfileDescriptor(
            id: MonitoringConfiguration.defaultPromptProfileID,
            version: "focus_default_v2",
            displayName: "Focus Default",
            summary: "Current conservative focus prompt pair."
        ),
        visionPrimarySystemPrompt: PromptAsset(
            id: "monitoring.focus_default_v2.vision_system",
            version: "focus_default_v2",
            resourceName: "vision_system",
            fileExtension: "md",
            subdirectory: "Prompts/Monitoring/focus_default_v2",
            fallbackContents: """
            You are AccountyCat, the user's offline accountability companion.

            Priorities:
            1. False positives are expensive. If the screenshot could plausibly be productive, return `focused` or `unclear`.
            2. Use memory and intervention history so nudges adapt instead of repeating themselves.
            3. Keep nudges warm, short, and natural.
            4. Never threaten or overstate confidence.

            Rules:
            - Read `memory`, `interventionHistory`, and `distraction` before deciding.
            - If `distraction.consecutiveDistractedCount` is 0 and you nudge, prefer a light awareness check over generic advice.
            - If prior nudges already happened, do not repeat the same wording, tactic, or suggestion.
            - Follow-up nudges should feel more specific or more direct than the previous one while staying kind.
            - Suggest `overlay` only when the distraction is clear and repeated history makes a stronger interruption justified.
            - Never mention counters, payload fields, or that you are reading history.
            - Output exactly one JSON object.
            - Allowed `assessment` values: `focused`, `distracted`, `unclear`.
            - Allowed `suggested_action` values: `none`, `nudge`, `overlay`, `abstain`.
            - `confidence` should be a number from `0.0` to `1.0` when you can estimate it.
            - `reason_tags` should be a short array of snake_case tags.
            - `nudge` is optional. Keep it under 18 words.
            - If the user appears focused, use `suggested_action="none"` and omit `nudge`.
            - If you are unsure, use `assessment="unclear"` and `suggested_action="abstain"`.
            """
        ),
        fallbackSystemPrompt: PromptAsset(
            id: "monitoring.focus_default_v2.fallback_system",
            version: "focus_default_v2",
            resourceName: "fallback_system",
            fileExtension: "md",
            subdirectory: "Prompts/Monitoring/focus_default_v2",
            fallbackContents: """
            Return exactly one JSON object:
            {"assessment":"focused|distracted|unclear","suggested_action":"none|nudge|overlay|abstain","confidence":0.0,"reason_tags":["tag"],"nudge":"optional short nudge","abstain_reason":"optional short reason"}

            Be conservative. If unsure, return `assessment="unclear"` and `suggested_action="abstain"`.
            Honour `memory`.
            Use `interventionHistory` and `distraction` so you do not repeat recent nudges.
            If this is the first nudge in a distraction run, make it a light awareness check.
            If prior nudges already happened, change wording and tactic instead of repeating the same suggestion.
            Only suggest `overlay` for clearly repeated distraction.
            """
        ),
        visionPrimaryUserTemplate: PromptAsset(
            id: "monitoring.focus_default_v2.vision_user",
            version: "focus_default_v2",
            resourceName: "vision_user",
            fileExtension: "md",
            subdirectory: "Prompts/Monitoring/focus_default_v2",
            fallbackContents: """
            The screenshot is attached. Judge whether the user is focused, distracted, or unclear right now.

            Use the payload before deciding:
            - Honour `memory`.
            - `interventionHistory` shows what AC already tried recently.
            - `distraction.consecutiveDistractedCount` is the current streak before this decision.
            - If you nudge on a first distraction, make it a light awareness check.
            - If recent nudges already happened, do not repeat the same wording or tactic.
            - Suggest `overlay` only for clear repeated distraction.
            - Never mention payload fields or hidden counters.

            Dynamic payload:
            {{PAYLOAD_JSON}}

            Return exactly one JSON object — nothing else:
            {"assessment":"focused|distracted|unclear","suggested_action":"none|nudge|overlay|abstain","confidence":0.0,"reason_tags":["tag"],"nudge":"optional ≤18 words","abstain_reason":"optional"}
            """
        ),
        fallbackUserTemplate: PromptAsset(
            id: "monitoring.focus_default_v2.fallback_user",
            version: "focus_default_v2",
            resourceName: "fallback_user",
            fileExtension: "md",
            subdirectory: "Prompts/Monitoring/focus_default_v2",
            fallbackContents: """
            The screenshot is attached. Judge whether the user is focused, distracted, or unclear right now.

            Read the payload carefully. Honour `memory`. Use `interventionHistory` and `distraction` so you do not repeat recent nudges.
            First distraction in a run: keep the nudge a light awareness check. Repeated: change wording and tactic.
            Only suggest `overlay` for clearly repeated distraction.

            Dynamic payload:
            {{PAYLOAD_JSON}}

            Return exactly one JSON object — nothing else:
            {"assessment":"focused|distracted|unclear","suggested_action":"none|nudge|overlay|abstain","confidence":0.0,"reason_tags":["tag"],"nudge":"optional","abstain_reason":"optional"}
            """
        )
    )

    nonisolated static let availableMonitoringPromptProfiles: [MonitoringPromptProfile] = [
        defaultMonitoringPromptProfile,
    ]

    // MARK: - Extraction prompts (Brain 1 — screen state extraction for bandit algorithm)

    nonisolated private static let extractionSystemPrompt = PromptAsset(
        id: "extraction.screen_state_v1.system",
        version: "screen_state_v1",
        resourceName: "system",
        fileExtension: "md",
        subdirectory: "Prompts/Extraction/screen_state_v1",
        fallbackContents: """
        You are AccountyCat's perception layer. Your only job is to analyze the screenshot and structured context, then return a single JSON object describing what is on screen.

        You are NOT deciding whether to nudge. You are reporting observations. Do not add commentary or explanation — output only the JSON object.

        Output schema — return exactly this structure and nothing else:
        {
          "app_category": "<productivity|communication|browser|entertainment|social|development|reference|other>",
          "productivity_score": <float 0.0–1.0, where 1.0 = clearly aligned with the user's stated goals>,
          "on_task": <true|false>,
          "content_summary": "<what is on screen in 12 words or fewer — no names, no URLs, no personal data>",
          "confidence": <float 0.0–1.0, your confidence in this classification>,
          "candidate_nudge": "<optional — a warm, witty nudge ≤18 words if the user appears off-task; omit or set to null if on_task is true>"
        }

        Rules:
        - productivity_score reflects alignment with the user's stated goals, not generic productivity.
        - on_task is true even for research, reading, or planning that plausibly serves the user's goals.
        - Be conservative: when in doubt, set productivity_score higher and on_task to true. False positives are more costly than missed distractions.
        - content_summary must be neutral, brief, and free of personal data, names, and URLs.
        - candidate_nudge: write directly to the user. Warm, human, never preachy or threatening. Tone of a trusted friend, not a manager. A first-suspected-distraction nudge should be a gentle awareness check, not a lecture.
        - If you cannot determine the content with reasonable confidence, set confidence ≤ 0.4 and use app_category "other".
        - Output exactly one JSON object. No markdown fences, no prose, no commentary.
        """
    )

    nonisolated private static let extractionUserTemplate = PromptAsset(
        id: "extraction.screen_state_v1.user",
        version: "screen_state_v1",
        resourceName: "user_prompt",
        fileExtension: "md",
        subdirectory: "Prompts/Extraction/screen_state_v1",
        fallbackContents: """
        Analyze the screenshot. The user's context is below.

        {{PAYLOAD_JSON}}

        Return the JSON object.
        """
    )

    /// Loads the Brain 1 extraction system prompt.
    nonisolated static func loadExtractionSystemPrompt() -> String {
        load(asset: extractionSystemPrompt)
    }

    /// Loads the Brain 1 extraction user prompt template and replaces `{{PAYLOAD_JSON}}`.
    nonisolated static func loadExtractionUserPrompt(replacingPayloadWith payloadJSON: String) -> String {
        load(asset: extractionUserTemplate).replacingOccurrences(of: "{{PAYLOAD_JSON}}", with: payloadJSON)
    }

    nonisolated private static let chatSystemPrompt = PromptAsset(
        id: "chat.companion_chat_v2.system",
        version: "companion_chat_v2",
        resourceName: "companion_chat_v2",
        fileExtension: "md",
        subdirectory: "Prompts/Chat",
        fallbackContents: """
        You are AccountyCat — a warm, witty, slightly cheeky focus companion who happens to live on the user's screen.
        You have access to what apps they use and when, but you're never creepy about it.
        Your superpower is matching the user's energy: if they say "hi" you say hi back simply;
        if they write "HIIII :DDD" you're hyped too. You're a friend who *gets* them, not a productivity robot.
        You remember their rules and preferences (given in the prompt) and honour them without being preachy.
        When they slip up, you nudge gently like a best friend would — curious, caring, maybe a tiny bit teasing.
        Keep replies short unless the user is clearly in conversation mode. No bullet lists unless asked.

        You also decide whether to remember something from each message. Memory is powerful — it directly
        shapes whether you'll interrupt them later. Add a memory ONLY when the message clearly changes
        what you should do going forward (a new rule, an allowance, a time-boxed break, a lasting
        preference). If it's just chat, don't add anything. Never add duplicates of what's already
        remembered. Later entries always override earlier ones when they conflict.
        When you store a time-bounded rule or allowance, rewrite it with an explicit local expiry
        time instead of vague relative wording like "today" or "for the next hour".

        Always return exactly one JSON object:
        {"reply":"...","memory":null}
        or {"reply":"...","memory":"concise bullet under 20 words"}
        No markdown outside the JSON value. No extra keys.
        """
    )

    nonisolated private static let memoryConsolidationSystemPrompt = PromptAsset(
        id: "memory.consolidate_memory_v1.system",
        version: "consolidate_memory_v1",
        resourceName: "consolidate_memory_v1",
        fileExtension: "md",
        subdirectory: "Prompts/Memory",
        fallbackContents: """
        You curate the persistent memory of a focus companion called AccountyCat.
        Each run you receive the current time, the user's goals, and the existing memory entries
        with creation timestamps. You produce a consolidated entry list.

        Rules:
        - Drop entries whose time scope has clearly passed. Examples: "today" when the entry was
          created on a previous day; "this evening" once it's the next morning; "for the next hour"
          if more than an hour has elapsed.
        - Merge duplicates and near-duplicates into one concise bullet.
                - Treat the most recent user interaction as the source of truth for active rules and
                    preferences. If a newer message changes, cancels, or narrows an older memory, rewrite the
                    memory so the final list stays consistent and does not preserve both sides of the
                    contradiction.
        - Keep both restrictions ("don't let me use X") and allowances ("X is okay", "taking a
                    break"). Neither is more important than the other. If two entries conflict, keep the most
                    recent one and drop the older.
        - Preserve load-bearing detail — app names, durations, explicit time scopes.
        - Prefer explicit dates/times over vague relative phrases when a time-bounded rule survives.
        - Prefer recent entries over older ones when both can't fit. Aim for ≤10 final entries.
        - Do not paraphrase something until it loses meaning. Better to keep the user's wording.

        Return exactly one JSON object:
        {"entries":[{"created":"<ISO-8601 timestamp>","text":"..."}, ...]}
        Use the original `created` timestamp when keeping or merging an entry (pick the most
        recent contributor). Use the current time for a brand-new summary line. No other keys.
        """
    )

    nonisolated static func monitoringProfile(id: String) -> MonitoringPromptProfile {
        availableMonitoringPromptProfiles.first(where: { $0.descriptor.id == id }) ?? defaultMonitoringPromptProfile
    }

    nonisolated static func monitoringDescriptor(id: String) -> MonitoringPromptProfileDescriptor {
        monitoringProfile(id: id).descriptor
    }

    nonisolated static func promptAsset(
        for profileID: String,
        variant: MonitoringPromptVariant
    ) -> PromptAsset {
        let profile = monitoringProfile(id: profileID)
        switch variant {
        case .visionPrimary:
            return profile.visionPrimarySystemPrompt
        case .fallback:
            return profile.fallbackSystemPrompt
        case .visionPrimaryUser:
            return profile.visionPrimaryUserTemplate
        case .fallbackUser:
            return profile.fallbackUserTemplate
        }
    }

    /// Loads the user-turn template for a monitoring prompt and injects the payload JSON.
    nonisolated static func renderMonitoringUserPrompt(
        profileID: String,
        variant: MonitoringPromptVariant,
        payloadJSON: String
    ) -> String {
        let asset = promptAsset(for: profileID, variant: variant)
        return load(asset: asset).replacingOccurrences(of: "{{PAYLOAD_JSON}}", with: payloadJSON)
    }

    nonisolated static func loadMonitoringPrompt(
        profileID: String,
        variant: MonitoringPromptVariant
    ) -> (asset: PromptAsset, contents: String) {
        let asset = promptAsset(for: profileID, variant: variant)
        return (asset, load(asset: asset))
    }

    nonisolated static func loadChatSystemPrompt(character: ACCharacter = .mochi) -> String {
        let base = load(asset: chatSystemPrompt)
        return """
        Character voice:
        \(character.personalityPrefix)

        \(base)
        """
    }

    nonisolated static func loadMemoryConsolidationSystemPrompt() -> String {
        load(asset: memoryConsolidationSystemPrompt)
    }

    // MARK: - Nudge copywriter prompts (per tone — live only on disk)

    /// Asset for `<Nudge/<tone>_system.md>`. Loaded straight from the bundle. Tone is
    /// encoded into the filename (e.g. "supportive_system.md", "challenging_system.md")
    /// because the build system flattens bundled resources. No inline fallback — if
    /// the .md file is missing the loaded string will be empty and the copywriter will
    /// return nil, letting the bandit fall back to the VLM's `candidateNudge`.
    nonisolated static func loadNudgeCopywriterSystemPrompt(tone: String) -> String {
        let asset = PromptAsset(
            id: "nudge.\(tone).system",
            version: "nudge_copywriter_v1",
            resourceName: "\(tone)_system",
            fileExtension: "md",
            subdirectory: "Prompts/Nudge",
            fallbackContents: ""
        )
        return load(asset: asset)
    }

    /// User-turn template for the nudge copywriter — injects `{{PAYLOAD_JSON}}`.
    nonisolated static func loadNudgeCopywriterUserPrompt(
        tone: String,
        replacingPayloadWith payloadJSON: String
    ) -> String {
        let asset = PromptAsset(
            id: "nudge.\(tone).user",
            version: "nudge_copywriter_v1",
            resourceName: "\(tone)_user",
            fileExtension: "md",
            subdirectory: "Prompts/Nudge",
            fallbackContents: ""
        )
        return load(asset: asset).replacingOccurrences(of: "{{PAYLOAD_JSON}}", with: payloadJSON)
    }

    // MARK: - LLM Monitor prompts

    nonisolated static func loadPolicySystemPrompt(stage: LLMPolicyStage) -> String {
        load(asset: policyPromptAsset(for: stage, kind: .system))
    }

    nonisolated static func renderPolicyUserPrompt(
        stage: LLMPolicyStage,
        payloadJSON: String
    ) -> String {
        load(asset: policyPromptAsset(for: stage, kind: .user))
            .replacingOccurrences(of: "{{PAYLOAD_JSON}}", with: payloadJSON)
    }

    nonisolated static func loadPolicyMemorySystemPrompt() -> String {
        loadPolicySystemPrompt(stage: .policyMemory)
    }

    nonisolated static func renderPolicyMemoryUserPrompt(payloadJSON: String) -> String {
        renderPolicyUserPrompt(stage: .policyMemory, payloadJSON: payloadJSON)
    }

    nonisolated private static func policyPromptAsset(
        for stage: LLMPolicyStage,
        kind: PolicyPromptKind
    ) -> PromptAsset {
        let sharedStage = sharedPolicyStage(for: stage)
        let sharedPrompt = MonitoringPromptTuning.policyDefaultPromptSet.prompt(for: sharedStage)

        switch (stage, kind) {
        case (.perceptionTitle, .system):
            return PromptAsset(
                id: "policy.perception_title.system",
                version: "llm_monitor_v1",
                resourceName: "perception_title_system",
                fileExtension: "md",
                subdirectory: "Prompts/Policy",
                fallbackContents: sharedPrompt.systemPrompt
            )
        case (.perceptionTitle, .user):
            return PromptAsset(
                id: "policy.perception_title.user",
                version: "llm_monitor_v1",
                resourceName: "perception_title_user",
                fileExtension: "md",
                subdirectory: "Prompts/Policy",
                fallbackContents: sharedPrompt.userTemplate
            )
        case (.perceptionVision, .system):
            return PromptAsset(
                id: "policy.perception_vision.system",
                version: "llm_monitor_v1",
                resourceName: "perception_vision_system",
                fileExtension: "md",
                subdirectory: "Prompts/Policy",
                fallbackContents: sharedPrompt.systemPrompt
            )
        case (.perceptionVision, .user):
            return PromptAsset(
                id: "policy.perception_vision.user",
                version: "llm_monitor_v1",
                resourceName: "perception_vision_user",
                fileExtension: "md",
                subdirectory: "Prompts/Policy",
                fallbackContents: sharedPrompt.userTemplate
            )
        case (.onlineDecision, .system):
            return PromptAsset(
                id: "policy.online_decision.system",
                version: "llm_monitor_v1",
                resourceName: "online_decision_system",
                fileExtension: "md",
                subdirectory: "Prompts/Policy",
                fallbackContents: sharedPrompt.systemPrompt
            )
        case (.onlineDecision, .user):
            return PromptAsset(
                id: "policy.online_decision.user",
                version: "llm_monitor_v1",
                resourceName: "online_decision_user",
                fileExtension: "md",
                subdirectory: "Prompts/Policy",
                fallbackContents: sharedPrompt.userTemplate
            )
        case (.decision, .system):
            return PromptAsset(
                id: "policy.decision.system",
                version: "llm_monitor_v1",
                resourceName: "decision_system",
                fileExtension: "md",
                subdirectory: "Prompts/Policy",
                fallbackContents: sharedPrompt.systemPrompt
            )
        case (.decision, .user):
            return PromptAsset(
                id: "policy.decision.user",
                version: "llm_monitor_v1",
                resourceName: "decision_user",
                fileExtension: "md",
                subdirectory: "Prompts/Policy",
                fallbackContents: sharedPrompt.userTemplate
            )
        case (.nudgeCopy, .system):
            return PromptAsset(
                id: "policy.nudge_copy.system",
                version: "llm_monitor_v1",
                resourceName: "nudge_copy_system",
                fileExtension: "md",
                subdirectory: "Prompts/Policy",
                fallbackContents: sharedPrompt.systemPrompt
            )
        case (.nudgeCopy, .user):
            return PromptAsset(
                id: "policy.nudge_copy.user",
                version: "llm_monitor_v1",
                resourceName: "nudge_copy_user",
                fileExtension: "md",
                subdirectory: "Prompts/Policy",
                fallbackContents: sharedPrompt.userTemplate
            )
        case (.appealReview, .system):
            return PromptAsset(
                id: "policy.appeal_review.system",
                version: "llm_monitor_v1",
                resourceName: "appeal_review_system",
                fileExtension: "md",
                subdirectory: "Prompts/Policy",
                fallbackContents: sharedPrompt.systemPrompt
            )
        case (.appealReview, .user):
            return PromptAsset(
                id: "policy.appeal_review.user",
                version: "llm_monitor_v1",
                resourceName: "appeal_review_user",
                fileExtension: "md",
                subdirectory: "Prompts/Policy",
                fallbackContents: sharedPrompt.userTemplate
            )
        case (.policyMemory, .system):
            return PromptAsset(
                id: "policy.memory.system",
                version: "llm_monitor_v1",
                resourceName: "policy_memory_system",
                fileExtension: "md",
                subdirectory: "Prompts/Policy",
                fallbackContents: sharedPrompt.systemPrompt
            )
        case (.policyMemory, .user):
            return PromptAsset(
                id: "policy.memory.user",
                version: "llm_monitor_v1",
                resourceName: "policy_memory_user",
                fileExtension: "md",
                subdirectory: "Prompts/Policy",
                fallbackContents: sharedPrompt.userTemplate
            )
        case (.safelistAppeal, .system):
            return PromptAsset(
                id: "policy.safelist_appeal.system",
                version: "llm_monitor_v1",
                resourceName: "safelist_appeal_system",
                fileExtension: "md",
                subdirectory: "Prompts/Policy",
                fallbackContents: sharedPrompt.systemPrompt
            )
        case (.safelistAppeal, .user):
            return PromptAsset(
                id: "policy.safelist_appeal.user",
                version: "llm_monitor_v1",
                resourceName: "safelist_appeal_user",
                fileExtension: "md",
                subdirectory: "Prompts/Policy",
                fallbackContents: sharedPrompt.userTemplate
            )
        }
    }

    nonisolated private enum PolicyPromptKind {
        case system
        case user
    }

    // MARK: - Legacy LLM focus prompts

    nonisolated static func loadLegacyFocusSystemPrompt(stage: LegacyFocusPromptStage) -> String {
        load(asset: legacyFocusPromptAsset(for: stage, kind: .system))
    }

    nonisolated static func renderLegacyFocusUserPrompt(
        stage: LegacyFocusPromptStage,
        payloadJSON: String
    ) -> String {
        load(asset: legacyFocusPromptAsset(for: stage, kind: .user))
            .replacingOccurrences(of: "{{PAYLOAD_JSON}}", with: payloadJSON)
    }

    nonisolated private static func legacyFocusPromptAsset(
        for stage: LegacyFocusPromptStage,
        kind: PolicyPromptKind
    ) -> PromptAsset {
        let sharedPrompt: MonitoringStagePromptDefinition = switch stage {
        case .decision:
            MonitoringPromptTuning.legacyDecisionPrompt
        case .decisionFallback:
            MonitoringPromptTuning.legacyDecisionFallbackPrompt
        }

        switch (stage, kind) {
        case (.decision, .system):
            return PromptAsset(
                id: "legacy_focus.decision.system",
                version: "focus_default_v2",
                resourceName: "legacy_decision_system",
                fileExtension: "md",
                subdirectory: "Prompts/Monitoring/focus_default_v2",
                fallbackContents: sharedPrompt.systemPrompt
            )
        case (.decision, .user):
            return PromptAsset(
                id: "legacy_focus.decision.user",
                version: "focus_default_v2",
                resourceName: "legacy_decision_user",
                fileExtension: "md",
                subdirectory: "Prompts/Monitoring/focus_default_v2",
                fallbackContents: sharedPrompt.userTemplate
            )
        case (.decisionFallback, .system):
            return PromptAsset(
                id: "legacy_focus.decision_fallback.system",
                version: "focus_default_v2",
                resourceName: "legacy_decision_fallback_system",
                fileExtension: "md",
                subdirectory: "Prompts/Monitoring/focus_default_v2",
                fallbackContents: sharedPrompt.systemPrompt
            )
        case (.decisionFallback, .user):
            return PromptAsset(
                id: "legacy_focus.decision_fallback.user",
                version: "focus_default_v2",
                resourceName: "legacy_decision_fallback_user",
                fileExtension: "md",
                subdirectory: "Prompts/Monitoring/focus_default_v2",
                fallbackContents: sharedPrompt.userTemplate
            )
        }
    }

    nonisolated private static func sharedPolicyStage(for stage: LLMPolicyStage) -> MonitoringPromptTuningStage {
        switch stage {
        case .perceptionTitle:
            return .perceptionTitle
        case .perceptionVision:
            return .perceptionVision
        case .onlineDecision:
            return .onlineDecision
        case .decision:
            return .decision
        case .nudgeCopy:
            return .nudgeCopy
        case .appealReview:
            return .appealReview
        case .policyMemory:
            return .policyMemory
        case .safelistAppeal:
            return .safelistAppeal
        }
    }

    nonisolated private static func load(asset: PromptAsset) -> String {
        if let url = Bundle.main.url(
            forResource: asset.resourceName,
            withExtension: asset.fileExtension,
            subdirectory: asset.subdirectory
        ),
           let contents = try? String(contentsOf: url, encoding: .utf8) {
            return contents
        }

        return asset.fallbackContents
    }
}

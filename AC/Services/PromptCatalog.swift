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
        id: "chat.companion_chat_v1.system",
        version: "companion_chat_v1",
        resourceName: "companion_chat_v1",
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
        Always return exactly one JSON object: {"reply":"..."}. No markdown outside the JSON value.
        """
    )

    nonisolated private static let memoryExtractionSystemPrompt = PromptAsset(
        id: "memory.extract_memory_v1.system",
        version: "extract_memory_v1",
        resourceName: "extract_memory_v1",
        fileExtension: "md",
        subdirectory: "Prompts/Memory",
        fallbackContents: """
        You are a memory extractor for a focus companion app.
        Decide if the user's message contains a persistent preference, rule, or important context
        that the companion should always remember (e.g. "don't let me use Instagram today",
        "I work best in the mornings", "I'm studying for exams this week").
        If yes, return JSON: {"memory":"concise bullet under 20 words"}
        If no, return JSON: {"memory":"none"}
        Output only JSON, no other text.
        """
    )

    nonisolated private static let memoryCompressionSystemPrompt = PromptAsset(
        id: "memory.compress_memory_v1.system",
        version: "compress_memory_v1",
        resourceName: "compress_memory_v1",
        fileExtension: "md",
        subdirectory: "Prompts/Memory",
        fallbackContents: """
        You are compressing a focus companion's memory log.
        Merge duplicate entries, remove outdated ones, and keep the most relevant rules/preferences.
        Return JSON: {"memory":"compressed multi-line bullet list"}
        Output only JSON, no other text.
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

    nonisolated static func loadChatSystemPrompt() -> String {
        load(asset: chatSystemPrompt)
    }

    nonisolated static func loadMemoryExtractionSystemPrompt() -> String {
        load(asset: memoryExtractionSystemPrompt)
    }

    nonisolated static func loadMemoryCompressionSystemPrompt() -> String {
        load(asset: memoryCompressionSystemPrompt)
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

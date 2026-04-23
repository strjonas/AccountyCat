//
//  MonitoringPromptTuning.swift
//  ACShared
//
//  Created by Codex on 20.04.26.
//

import Foundation

enum MonitoringPromptTuningStage: String, Codable, CaseIterable, Sendable {
    case perceptionTitle = "perception_title"
    case perceptionVision = "perception_vision"
    case decision
    case nudgeCopy = "nudge_copy"
    case appealReview = "appeal_review"
    case policyMemory = "policy_memory"
    case legacyDecision = "legacy_decision"
    case legacyDecisionFallback = "legacy_decision_fallback"
}

struct MonitoringStagePromptDefinition: Codable, Hashable, Identifiable, Sendable {
    var stage: MonitoringPromptTuningStage
    var systemPrompt: String
    var userTemplate: String

    var id: MonitoringPromptTuningStage { stage }
}

struct MonitoringPromptSetDefinition: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var name: String
    var summary: String
    var prompts: [MonitoringStagePromptDefinition]

    nonisolated func prompt(for stage: MonitoringPromptTuningStage) -> MonitoringStagePromptDefinition {
        prompts.first(where: { $0.stage == stage }) ?? MonitoringStagePromptDefinition(
            stage: stage,
            systemPrompt: "",
            userTemplate: "{{PAYLOAD_JSON}}"
        )
    }
}

struct MonitoringPipelineDefinition: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var displayName: String
    var summary: String
    var requiresScreenshot: Bool
    var usesTitlePerception: Bool
    var usesVisionPerception: Bool
    var splitCopyGeneration: Bool
}

struct MonitoringRuntimeOptionsDefinition: Codable, Hashable, Sendable {
    var modelIdentifier: String
    var maxTokens: Int
    var temperature: Double
    var topP: Double
    var topK: Int
    var ctxSize: Int
    var batchSize: Int
    var ubatchSize: Int
    var timeoutSeconds: UInt64
}

struct MonitoringRuntimeStageDefinition: Codable, Hashable, Identifiable, Sendable {
    var stage: MonitoringPromptTuningStage
    var options: MonitoringRuntimeOptionsDefinition

    var id: MonitoringPromptTuningStage { stage }
}

struct MonitoringRuntimeDefinition: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var displayName: String
    var summary: String
    var optionsByStage: [MonitoringRuntimeStageDefinition]

    nonisolated func options(for stage: MonitoringPromptTuningStage) -> MonitoringRuntimeOptionsDefinition? {
        optionsByStage.first(where: { $0.stage == stage })?.options
    }
}

enum MonitoringPromptTuning {
    private static let decisionSchema = """
    {"assessment":"focused|distracted|unclear","suggested_action":"none|nudge|overlay|abstain","confidence":0.0,"reason_tags":["tag"],"nudge":"optional short nudge","abstain_reason":"optional","overlay_headline":"optional","overlay_body":"optional","overlay_prompt":"optional","submit_button_title":"optional","secondary_button_title":"optional"}
    """

    nonisolated static let policyDefaultPromptSet = MonitoringPromptSetDefinition(
        id: "policy_default_v1",
        name: "Policy Default",
        summary: "Shared production prompt set for staged policy evaluation.",
        prompts: [
            MonitoringStagePromptDefinition(
                stage: .perceptionTitle,
                systemPrompt: """
                You are AC's text-only perception stage.
                Infer the user's current activity from app, title, recent switches, and short usage history.
                Do not decide whether the activity matches the user's goals or policy rules yet.
                Return exactly one JSON object:
                {"activity_summary":"<=24 words","focus_guess":"focused|distracted|unclear","reason_tags":["tag"],"notes":["optional short note"]}
                Rules:
                - Name the likely task or content when the title supports it.
                - Prefer concrete activity labels over generic app labels.
                - Research, reading, planning, messaging, and drafting can still be focused.
                - If the title is weak, keep uncertainty inside `activity_summary`.
                - `notes` may be omitted or empty.
                - No markdown or prose outside JSON.
                """
            ,
                userTemplate: """
                Infer the user's current activity from this lightweight context.
                Capture the likely task, page, video topic, conversation, or feed when possible.
                {{PAYLOAD_JSON}}
                Return exactly one JSON object.
                """
            ),
            MonitoringStagePromptDefinition(
                stage: .perceptionVision,
                systemPrompt: """
                You are AC's screenshot perception stage.
                Describe what the user is actually doing on screen, not what AC should do next.
                Do not decide whether the activity matches the user's goals or policy rules yet.
                Return exactly one JSON object:
                {"scene_summary":"<=24 words","focus_guess":"focused|distracted|unclear","reason_tags":["tag"],"notes":["optional short note"]}
                Rules:
                - Name the likely task or content when visible.
                - Distinguish typing or replying from passive scrolling when the screenshot supports it.
                - Research, reading, planning, messaging, and drafting can still be focused.
                - Avoid personal names, private message text, email addresses, and raw URLs.
                - `notes` may be omitted or empty.
                - No markdown or prose outside JSON.
                """
            ,
                userTemplate: """
                The screenshot is attached.
                Use the screenshot and payload together to infer what the user is doing right now.
                Focus on the exact activity and content when visible.
                {{PAYLOAD_JSON}}
                Return exactly one JSON object.
                """
            ),
            MonitoringStagePromptDefinition(
                stage: .decision,
                systemPrompt: """
                You are AC's decision stage.
                Use goals, free-form memory, recent user chat messages, policy memory, distraction state, recent interventions, and perception summaries to choose the next action.
                False positives are expensive, but explicit rules and limits must still be honored.
                Return exactly one JSON object:
                \(decisionSchema)

                Memory priority (READ CAREFULLY — this is the #1 cause of bad decisions):
                - `freeFormMemory` lines and `recentUserMessages` entries are stamped with local wall-clock time in `YYYY-MM-DD HH:MM`.
                - Resolve conflicts before deciding:
                  1. Read `recentUserMessages` from oldest to newest; the newest relevant user statement wins.
                  2. Then read `freeFormMemory`; newer memory overrides older memory when they conflict.
                  3. Use `policySummary` as supporting structured context, but never let it override a newer explicit user statement from chat or free-form memory.
                - `recentUserMessages` is the most recent ground truth even if not yet consolidated into memory. If the user just said "WhatsApp is okay" or "let me watch YouTube for a bit", honour that over category heuristics.
                - An allowance ("X is okay", "I'm taking a break", "let me") is as authoritative as a restriction ("don't let me use X"). Do not override either with vibes about productivity.
                - Use `now` plus the timestamps to resolve temporary rules. If a temporary allowance or restriction has an explicit expiry, respect it until that time.

                Decision rules:
                - If the likely activity supports the goals or is covered by an allowance in memory / recent chat, return `assessment="focused"` and `suggested_action="none"`.
                - If `recentUserMessages` contains a newer explicit allowance for the current app/activity than any competing restriction, return `assessment="focused"` and `suggested_action="none"`.
                - If the activity is still genuinely unclear after using the whole payload, return `assessment="unclear"` and `suggested_action="abstain"`.
                - If the activity conflicts with the goals or an active restriction in memory / recent chat, return `assessment="distracted"` and `suggested_action="nudge"`.
                - Use `suggested_action="overlay"` only for repeated distraction already reflected in the payload.
                - `assessment` and `suggested_action` must agree:
                  focused -> none
                  unclear -> abstain
                  distracted -> nudge or overlay
                - Prefer silence over a false positive.
                - For development tools, editors, terminals, docs, research, reading, planning, and drafting, prefer `focused` unless the payload clearly says otherwise.
                - If you write `nudge`, keep it under 18 words, specific to the current activity, and different from recent nudges.
                - Never mention counters, hidden fields, or that you are using memory or history.
                """
            ,
                userTemplate: """
                Decide AC's next action from this context.
                Trust the perception summaries more than raw usage when they conflict.
                Before deciding, resolve rules in this order: newest `recentUserMessages`, then newer `freeFormMemory`, then `policySummary`.
                Check for anything the user has told you about THIS specific activity or app — those explicit statements override category defaults.
                Use `recentInterventions` only to avoid repeating wording or escalating too fast.
                {{PAYLOAD_JSON}}
                Return exactly one JSON object.
                """
            ),
            MonitoringStagePromptDefinition(
                stage: .nudgeCopy,
                systemPrompt: """
                Write one short nudge for a focus companion.
                Keep it human, specific to the current activity, and different from recent nudges.
                Avoid generic productivity slogans.
                If `freeFormMemory` or `recentUserMessages` names this specific app or activity, reference that context — it will feel more caring and less generic.
                Return exactly one JSON object: {"nudge":"..."}
                """
            ,
                userTemplate: """
                Write the nudge for this situation.
                Mention the actual activity when that helps.
                Do not nudge against something the user just explicitly allowed in `recentUserMessages` or `freeFormMemory`.
                If chat/memory conflict, the newest timestamp wins.
                If the decision stage made a mistake, still produce something neutral-to-supportive rather than scolding the user for an allowed activity.
                {{PAYLOAD_JSON}}
                Return exactly one JSON object.
                """
            ),
            MonitoringStagePromptDefinition(
                stage: .appealReview,
                systemPrompt: """
                Review a user's typed appeal to continue a potentially distracting activity.
                Prefer allow or defer unless the appeal clearly conflicts with stated goals or rules.
                Return exactly one JSON object:
                {"decision":"allow|deny|defer","message":"short explanation"}
                """
            ,
                userTemplate: """
                Review this typed appeal:
                {{PAYLOAD_JSON}}
                Return exactly one JSON object.
                """
            ),
            MonitoringStagePromptDefinition(
                stage: .policyMemory,
                systemPrompt: """
                You update structured policy memory for a focus companion.
                Only return JSON matching this schema:
                {
                  "operations":[
                    {
                      "type":"add_rule|update_rule|remove_rule|expire_rule",
                      "rule":{...optional full rule...},
                      "ruleID":"optional existing id",
                      "patch":{...optional partial patch...},
                      "reason":"short reason"
                    }
                  ]
                }

                Create rules when the event implies a rule that will affect future nudges. Examples:
                - User says "don't let me use Instagram today" → add_rule {kind:"disallow", scope:"app", target:"Instagram", expiresAt: end of local day}
                - User says "WhatsApp is okay for the next hour" → add_rule {kind:"allow", scope:"app", target:"WhatsApp", expiresAt: now+1h}
                - User says "I'm taking a break" → add_rule {kind:"allow", scope:"any", expiresAt: now+30m} (pick a reasonable default if unspecified)
                - User says "you can let me watch YouTube" → add_rule {kind:"allow", scope:"app", target:"YouTube"} (no expiry if none implied)

                The user's most recent statement is authoritative. If it contradicts an existing rule, either expire_rule or update_rule the old one — do NOT leave contradictory rules coexisting.
                Convert relative scopes like "today", "this evening", or "for the next hour" into explicit `expiresAt` values relative to `now`.
                Prefer the user's exact app/site names over generic categories.
                Do not copy assistant phrasing back into policy memory — use the user's intent.

                Prefer updating existing rules over duplicating them. Only emit operations that actually change state.
                """
            ,
                userTemplate: """
                Update structured policy memory from this event:
                {{PAYLOAD_JSON}}
                Return exactly one JSON object.
                """
            ),
        ]
    )

    nonisolated static let policyDirectPromptSet = MonitoringPromptSetDefinition(
        id: "policy_direct_v1",
        name: "Policy Direct",
        summary: "Shorter, stricter experimental prompt set for side-by-side Prompt Lab runs.",
        prompts: [
            MonitoringStagePromptDefinition(
                stage: .perceptionTitle,
                systemPrompt: """
                Infer the user's likely activity from titles, switches, and short usage history.
                Do not decide whether the activity matches goals or rules yet.
                Return one JSON object only:
                {"activity_summary":"<=24 words","focus_guess":"focused|distracted|unclear","reason_tags":["tag"],"notes":["optional short note"]}
                Prefer a concrete activity label. Prefer `unclear` over overclaiming.
                """
            ,
                userTemplate: """
                Summarize this text-only context:
                {{PAYLOAD_JSON}}
                Return exactly one JSON object.
                """
            ),
            MonitoringStagePromptDefinition(
                stage: .perceptionVision,
                systemPrompt: """
                Describe what is happening on screen for a focus coach.
                Do not decide whether the activity matches goals or rules yet.
                Return one JSON object only:
                {"scene_summary":"<=24 words","focus_guess":"focused|distracted|unclear","reason_tags":["tag"],"notes":["optional short note"]}
                Be concrete about the exact activity and content when visible.
                """
            ,
                userTemplate: """
                Use the screenshot and payload together:
                {{PAYLOAD_JSON}}
                Return exactly one JSON object.
                """
            ),
            MonitoringStagePromptDefinition(
                stage: .decision,
                systemPrompt: """
                Decide whether AC should stay silent, nudge, or escalate.
                Return exactly one JSON object:
                \(decisionSchema)
                Rules:
                - focused -> none
                - unclear -> abstain
                - distracted -> nudge or overlay
                - overlay only for repeated off-task behavior already reflected in the payload
                - explicit rules beat weak signals
                - when evidence is mixed, prefer focused or unclear over distracted
                """
            ,
                userTemplate: """
                Decide the best next action from this context:
                {{PAYLOAD_JSON}}
                Return exactly one JSON object.
                """
            ),
            MonitoringStagePromptDefinition(
                stage: .nudgeCopy,
                systemPrompt: """
                Write one specific nudge that feels human and not generic.
                Return exactly one JSON object: {"nudge":"..."}
                """
            ,
                userTemplate: """
                Draft the nudge for this situation:
                {{PAYLOAD_JSON}}
                Return exactly one JSON object.
                """
            ),
            MonitoringStagePromptDefinition(
                stage: .appealReview,
                systemPrompt: """
                Judge whether the user's typed reason justifies continuing a potentially distracting activity.
                Prefer allow or defer unless the reason clearly conflicts with stated goals and rules.
                Return exactly one JSON object:
                {"decision":"allow|deny|defer","message":"short explanation"}
                """
            ,
                userTemplate: """
                Evaluate this typed appeal:
                {{PAYLOAD_JSON}}
                Return exactly one JSON object.
                """
            ),
            MonitoringStagePromptDefinition(
                stage: .policyMemory,
                systemPrompt: policyDefaultPromptSet.prompt(for: .policyMemory).systemPrompt,
                userTemplate: policyDefaultPromptSet.prompt(for: .policyMemory).userTemplate
            ),
        ]
    )

    nonisolated static let legacyDecisionPrompt = MonitoringStagePromptDefinition(
        stage: .legacyDecision,
        systemPrompt: """
        You are AC's legacy decision stage.
        A separate perception step already summarized the current activity.
        Use goals, memory, heuristics, distraction state, and recent interventions to choose the next action.
        False positives are expensive.
        Return exactly one JSON object:
        {"assessment":"focused|distracted|unclear","suggested_action":"none|nudge|overlay|abstain","confidence":0.0,"reason_tags":["tag"],"nudge":"optional short nudge","abstain_reason":"optional"}
        Decision rules:
        - If the activity summary likely supports the goals, return `focused` + `none`.
        - If the activity summary is still genuinely unclear, return `unclear` + `abstain`.
        - If the activity likely conflicts with the goals or an explicit memory rule, return `distracted` + `nudge`.
        - Use `overlay` only for repeated distraction already reflected in the payload.
        - `assessment` and `suggested_action` must agree:
          focused -> none
          unclear -> abstain
          distracted -> nudge or overlay
        - If the frontmost app is a development tool or editor and nothing in the payload points off-task, prefer `focused` + `none`.
        - If you write `nudge`, keep it under 18 words and avoid repeating recent nudges.
        """
    ,
        userTemplate: """
        Decide AC's action from this text-only context.
        Trust the perception summary more than raw usage when they conflict.
        {{PAYLOAD_JSON}}
        Return exactly one JSON object.
        """
    )

    nonisolated static let legacyDecisionFallbackPrompt = MonitoringStagePromptDefinition(
        stage: .legacyDecisionFallback,
        systemPrompt: """
        Return exactly one JSON object:
        {"assessment":"focused|distracted|unclear","suggested_action":"none|nudge|overlay|abstain","confidence":0.0,"reason_tags":["tag"],"nudge":"optional short nudge","abstain_reason":"optional"}
        Rules:
        - focused -> none
        - unclear -> abstain
        - distracted -> nudge or overlay
        - use overlay only for repeated distraction already reflected in the payload
        - if the activity could plausibly support the goals, prefer focused or unclear over distracted
        """
    ,
        userTemplate: """
        Use this context:
        {{PAYLOAD_JSON}}
        Return exactly one JSON object.
        """
    )

    nonisolated static let pipelineDefinitions: [MonitoringPipelineDefinition] = [
        MonitoringPipelineDefinition(
            id: "vision_split_default",
            displayName: "Vision Split Default",
            summary: "Single image-plus-title perception, low-temp decision, separate nudge copy.",
            requiresScreenshot: true,
            usesTitlePerception: false,
            usesVisionPerception: true,
            splitCopyGeneration: true
        ),
        MonitoringPipelineDefinition(
            id: "title_only_default",
            displayName: "Title Only",
            summary: "Title, usage, and memory only. No screenshot required.",
            requiresScreenshot: false,
            usesTitlePerception: true,
            usesVisionPerception: false,
            splitCopyGeneration: true
        ),
        MonitoringPipelineDefinition(
            id: "vision_single_call",
            displayName: "Vision Single Call",
            summary: "Single image-plus-title perception with inline nudge generation.",
            requiresScreenshot: true,
            usesTitlePerception: false,
            usesVisionPerception: true,
            splitCopyGeneration: false
        ),
        MonitoringPipelineDefinition(
            id: "title_split_copy",
            displayName: "Title Split Copy",
            summary: "Title-only perception with separate nudge copy generation.",
            requiresScreenshot: false,
            usesTitlePerception: true,
            usesVisionPerception: false,
            splitCopyGeneration: true
        ),
    ]

    nonisolated static let runtimeDefinitions: [MonitoringRuntimeDefinition] = [
        MonitoringRuntimeDefinition(
            id: "gemma_balanced_v1",
            displayName: "Gemma Balanced",
            summary: "Default Gemma preset for staged policy evaluation.",
            optionsByStage: [
                MonitoringRuntimeStageDefinition(stage: .perceptionTitle, options: MonitoringRuntimeOptionsDefinition(modelIdentifier: "unsloth/gemma-4-E2B-it-GGUF:Q4_0", maxTokens: 180, temperature: 0.15, topP: 0.9, topK: 48, ctxSize: 3072, batchSize: 1024, ubatchSize: 512, timeoutSeconds: 30)),
                MonitoringRuntimeStageDefinition(stage: .perceptionVision, options: MonitoringRuntimeOptionsDefinition(modelIdentifier: "unsloth/gemma-4-E2B-it-GGUF:Q4_0", maxTokens: 180, temperature: 0.15, topP: 0.95, topK: 64, ctxSize: 4096, batchSize: 2048, ubatchSize: 1024, timeoutSeconds: 45)),
                MonitoringRuntimeStageDefinition(stage: .decision, options: MonitoringRuntimeOptionsDefinition(modelIdentifier: "unsloth/gemma-4-E2B-it-GGUF:Q4_0", maxTokens: 220, temperature: 0.08, topP: 0.9, topK: 40, ctxSize: 4096, batchSize: 1024, ubatchSize: 512, timeoutSeconds: 40)),
                MonitoringRuntimeStageDefinition(stage: .legacyDecision, options: MonitoringRuntimeOptionsDefinition(modelIdentifier: "unsloth/gemma-4-E2B-it-GGUF:Q4_0", maxTokens: 220, temperature: 0.08, topP: 0.9, topK: 40, ctxSize: 4096, batchSize: 1024, ubatchSize: 512, timeoutSeconds: 40)),
                MonitoringRuntimeStageDefinition(stage: .legacyDecisionFallback, options: MonitoringRuntimeOptionsDefinition(modelIdentifier: "unsloth/gemma-4-E2B-it-GGUF:Q4_0", maxTokens: 180, temperature: 0.08, topP: 0.9, topK: 32, ctxSize: 4096, batchSize: 1024, ubatchSize: 512, timeoutSeconds: 40)),
                MonitoringRuntimeStageDefinition(stage: .nudgeCopy, options: MonitoringRuntimeOptionsDefinition(modelIdentifier: "unsloth/gemma-4-E2B-it-GGUF:Q4_0", maxTokens: 120, temperature: 0.55, topP: 0.95, topK: 64, ctxSize: 3072, batchSize: 1024, ubatchSize: 512, timeoutSeconds: 30)),
                MonitoringRuntimeStageDefinition(stage: .appealReview, options: MonitoringRuntimeOptionsDefinition(modelIdentifier: "unsloth/gemma-4-E2B-it-GGUF:Q4_0", maxTokens: 180, temperature: 0.15, topP: 0.92, topK: 48, ctxSize: 4096, batchSize: 1024, ubatchSize: 512, timeoutSeconds: 35)),
                MonitoringRuntimeStageDefinition(stage: .policyMemory, options: MonitoringRuntimeOptionsDefinition(modelIdentifier: "unsloth/gemma-4-E2B-it-GGUF:Q4_0", maxTokens: 260, temperature: 0.15, topP: 0.9, topK: 48, ctxSize: 4096, batchSize: 1024, ubatchSize: 512, timeoutSeconds: 35)),
            ]
        ),
        MonitoringRuntimeDefinition(
            id: "gemma_low_ram_v1",
            displayName: "Gemma Low RAM",
            summary: "Lower context and token limits for lighter local tests.",
            optionsByStage: [
                MonitoringRuntimeStageDefinition(stage: .perceptionTitle, options: MonitoringRuntimeOptionsDefinition(modelIdentifier: "unsloth/gemma-4-E2B-it-GGUF:Q4_0", maxTokens: 140, temperature: 0.12, topP: 0.9, topK: 40, ctxSize: 2048, batchSize: 768, ubatchSize: 384, timeoutSeconds: 25)),
                MonitoringRuntimeStageDefinition(stage: .perceptionVision, options: MonitoringRuntimeOptionsDefinition(modelIdentifier: "unsloth/gemma-4-E2B-it-GGUF:Q4_0", maxTokens: 140, temperature: 0.12, topP: 0.92, topK: 48, ctxSize: 1536, batchSize: 1024, ubatchSize: 1024, timeoutSeconds: 35)),
                MonitoringRuntimeStageDefinition(stage: .decision, options: MonitoringRuntimeOptionsDefinition(modelIdentifier: "unsloth/gemma-4-E2B-it-GGUF:Q4_0", maxTokens: 180, temperature: 0.08, topP: 0.9, topK: 32, ctxSize: 3072, batchSize: 768, ubatchSize: 384, timeoutSeconds: 30)),
                MonitoringRuntimeStageDefinition(stage: .legacyDecision, options: MonitoringRuntimeOptionsDefinition(modelIdentifier: "unsloth/gemma-4-E2B-it-GGUF:Q4_0", maxTokens: 180, temperature: 0.08, topP: 0.9, topK: 32, ctxSize: 3072, batchSize: 768, ubatchSize: 384, timeoutSeconds: 30)),
                MonitoringRuntimeStageDefinition(stage: .legacyDecisionFallback, options: MonitoringRuntimeOptionsDefinition(modelIdentifier: "unsloth/gemma-4-E2B-it-GGUF:Q4_0", maxTokens: 150, temperature: 0.08, topP: 0.9, topK: 32, ctxSize: 3072, batchSize: 768, ubatchSize: 384, timeoutSeconds: 25)),
                MonitoringRuntimeStageDefinition(stage: .nudgeCopy, options: MonitoringRuntimeOptionsDefinition(modelIdentifier: "unsloth/gemma-4-E2B-it-GGUF:Q4_0", maxTokens: 90, temperature: 0.45, topP: 0.95, topK: 48, ctxSize: 2048, batchSize: 768, ubatchSize: 384, timeoutSeconds: 20)),
                MonitoringRuntimeStageDefinition(stage: .appealReview, options: MonitoringRuntimeOptionsDefinition(modelIdentifier: "unsloth/gemma-4-E2B-it-GGUF:Q4_0", maxTokens: 140, temperature: 0.12, topP: 0.92, topK: 40, ctxSize: 3072, batchSize: 768, ubatchSize: 384, timeoutSeconds: 25)),
                MonitoringRuntimeStageDefinition(stage: .policyMemory, options: MonitoringRuntimeOptionsDefinition(modelIdentifier: "unsloth/gemma-4-E2B-it-GGUF:Q4_0", maxTokens: 220, temperature: 0.12, topP: 0.9, topK: 40, ctxSize: 3072, batchSize: 768, ubatchSize: 384, timeoutSeconds: 25)),
            ]
        ),
        MonitoringRuntimeDefinition(
            id: "llama_experiment_v1",
            displayName: "Llama Experiment",
            summary: "Llama-family preset for side-by-side comparisons.",
            optionsByStage: [
                MonitoringRuntimeStageDefinition(stage: .perceptionTitle, options: MonitoringRuntimeOptionsDefinition(modelIdentifier: "bartowski/Llama-3.2-3B-Instruct-GGUF:Q4_K_M", maxTokens: 180, temperature: 0.15, topP: 0.9, topK: 48, ctxSize: 4096, batchSize: 1024, ubatchSize: 512, timeoutSeconds: 35)),
                MonitoringRuntimeStageDefinition(stage: .perceptionVision, options: MonitoringRuntimeOptionsDefinition(modelIdentifier: "bartowski/Llama-3.2-3B-Instruct-GGUF:Q4_K_M", maxTokens: 180, temperature: 0.15, topP: 0.95, topK: 64, ctxSize: 4096, batchSize: 2048, ubatchSize: 1024, timeoutSeconds: 45)),
                MonitoringRuntimeStageDefinition(stage: .decision, options: MonitoringRuntimeOptionsDefinition(modelIdentifier: "bartowski/Llama-3.2-3B-Instruct-GGUF:Q4_K_M", maxTokens: 220, temperature: 0.08, topP: 0.9, topK: 40, ctxSize: 6144, batchSize: 1024, ubatchSize: 512, timeoutSeconds: 40)),
                MonitoringRuntimeStageDefinition(stage: .legacyDecision, options: MonitoringRuntimeOptionsDefinition(modelIdentifier: "bartowski/Llama-3.2-3B-Instruct-GGUF:Q4_K_M", maxTokens: 220, temperature: 0.08, topP: 0.9, topK: 40, ctxSize: 6144, batchSize: 1024, ubatchSize: 512, timeoutSeconds: 40)),
                MonitoringRuntimeStageDefinition(stage: .legacyDecisionFallback, options: MonitoringRuntimeOptionsDefinition(modelIdentifier: "bartowski/Llama-3.2-3B-Instruct-GGUF:Q4_K_M", maxTokens: 180, temperature: 0.08, topP: 0.9, topK: 32, ctxSize: 6144, batchSize: 1024, ubatchSize: 512, timeoutSeconds: 35)),
                MonitoringRuntimeStageDefinition(stage: .nudgeCopy, options: MonitoringRuntimeOptionsDefinition(modelIdentifier: "bartowski/Llama-3.2-3B-Instruct-GGUF:Q4_K_M", maxTokens: 120, temperature: 0.6, topP: 0.95, topK: 64, ctxSize: 3072, batchSize: 1024, ubatchSize: 512, timeoutSeconds: 30)),
                MonitoringRuntimeStageDefinition(stage: .appealReview, options: MonitoringRuntimeOptionsDefinition(modelIdentifier: "bartowski/Llama-3.2-3B-Instruct-GGUF:Q4_K_M", maxTokens: 180, temperature: 0.15, topP: 0.92, topK: 48, ctxSize: 4096, batchSize: 1024, ubatchSize: 512, timeoutSeconds: 35)),
                MonitoringRuntimeStageDefinition(stage: .policyMemory, options: MonitoringRuntimeOptionsDefinition(modelIdentifier: "bartowski/Llama-3.2-3B-Instruct-GGUF:Q4_K_M", maxTokens: 240, temperature: 0.15, topP: 0.9, topK: 48, ctxSize: 4096, batchSize: 1024, ubatchSize: 512, timeoutSeconds: 35)),
            ]
        ),
    ]

    nonisolated static let promptSets: [MonitoringPromptSetDefinition] = [
        policyDefaultPromptSet,
        policyDirectPromptSet,
    ]
}

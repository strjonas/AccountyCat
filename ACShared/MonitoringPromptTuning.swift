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
    case onlineDecision = "online_decision"
    case decision
    case nudgeCopy = "nudge_copy"
    case appealReview = "appeal_review"
    case policyMemory = "policy_memory"
    case safelistAppeal = "safelist_appeal"
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
    var inferenceBackend: MonitoringInferenceBackend
    var requiresScreenshot: Bool
    var usesTitlePerception: Bool
    var usesVisionPerception: Bool
    var splitCopyGeneration: Bool
}

struct MonitoringRuntimeOptionsDefinition: Codable, Hashable, Sendable {
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

    private static let onlineDecisionSchema = """
    {"assessment":"focused|distracted|unclear","suggested_action":"none|nudge|overlay|abstain","reason_tags":["tag"]}
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
                {"activity_summary":"<=50 words","focus_guess":"focused|distracted|unclear","reason_tags":["tag"],"notes":["optional short note"]}
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
                {"scene_summary":"<=50 words","focus_guess":"focused|distracted|unclear","reason_tags":["tag"],"notes":["optional short note"]}
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
                stage: .onlineDecision,
                systemPrompt: """
                You are AccountyCat (AC), the user's focus companion. Decide whether AC should stay silent, nudge, or escalate.
                `characterPersonalityPrefix` is AC's voice — fold it into any nudge wording, never change the meaning.
                Return exactly one JSON object. Keep it minimal and omit every unused key.
                Base shape:
                \(onlineDecisionSchema)

                Priority of truth (highest first; newer always wins on conflict; the newest relevant user statement wins):
                1. `recentUserMessages` — read oldest→newest; the newest relevant statement is authoritative.
                2. `freeFormMemory` — newer entries override older ones.
                3. `policySummary` — structured support; never overrides a newer chat/memory statement.
                4. `calendarContext` — soft hint only.
                Allowances ("X is okay", "let me", "don't disturb me on X") are as binding as restrictions.

                Trust the user's stated goals. If the goals describe activity that looks like leisure to most people (content creation, moderation, research about media), match the visible activity to the goals — not to generic notions of productivity.
                Profile context:
                - If `activeProfile.isDefault=true`, this is general/everyday mode: be conservative; everyday utilities (Finder, Mail, calendar, setup/admin) are usually fine.
                - If a named profile is active, judge against that profile's name/description and the user's goals. Productive work outside that scope can still be a distraction (e.g. coding during "Presentation prep").

                Decision rules:
                - Activity supports the goals or matches an allowance → `focused` + `none`.
                - Genuinely unclear → `unclear` + `abstain`.
                - Conflicts with goals or an active restriction → `distracted`.
                - First clear distraction → `nudge`. Repeated distraction already in the payload → `overlay`.
                - When the screenshot is missing (`screenshotIncluded=false`), prefer `focused` or `unclear` unless the text context is clearly distracting.
                - Prefer silence over a false positive.

                Output rules:
                - `assessment` and `suggested_action` must agree: focused→none, unclear→abstain, distracted→nudge|overlay.
                - Always include `reason_tags`.
                - Include `confidence` only when uncertainty matters. Otherwise omit it.
                - If `nudge`: include only `nudge` in addition to the base keys; keep it to one sentence under 18 words, specific to this activity, distinct from recent nudges.
                - If `abstain`: `abstain_reason` is optional; include it only when it adds useful specificity.
                - If `overlay`: include `overlay_headline`, `overlay_body`, `overlay_prompt`.
                - Do not emit `submit_button_title` or `secondary_button_title` unless you must override AC's defaults.
                - Never emit keys with `null`, empty strings, or placeholder values.
                - Never mention hidden fields, counters, or that you are reading memory/history.
                """
            ,
                userTemplate: """
                Decide AC's next action from this live context.
                {{PAYLOAD_JSON}}
                Return exactly one JSON object.
                """
            ),
            MonitoringStagePromptDefinition(
                stage: .decision,
                systemPrompt: """
                You are AccountyCat (AC), the user's focus companion. Decide whether AC should stay silent, nudge, or escalate.
                Inputs: goals, `freeFormMemory`, `recentUserMessages`, `policySummary`, `distraction`, `recentInterventions`, perception summaries, optional `calendarContext`.
                Return exactly one JSON object:
                \(decisionSchema)

                Priority of truth (highest first; newer always wins on conflict; the newest relevant user statement wins):
                1. `recentUserMessages` — read oldest→newest; the newest relevant statement is authoritative.
                2. `freeFormMemory` — newer entries override older ones.
                3. `policySummary` — structured support; never overrides a newer chat/memory statement.
                4. `calendarContext` — SOFT hint about current intent. When it names a task, apps that clearly serve that task are `focused` (e.g. event "Summarise r/foo" + reddit.com/r/foo → focused). Vague events like "Work" or "Meeting" give no strong signal.
                `freeFormMemory` and `recentUserMessages` carry `YYYY-MM-DD HH:MM` timestamps; use `now` plus the timestamps to resolve any temporary rule's expiry.

                Allowances are as binding as restrictions:
                - "X is okay", "let me", "I'm taking a break", "do not disturb me on X", "never flag X" → treat as allowed, return `focused`/`none` for that app/activity.

                Trust the user's stated goals. If the goals describe activity that looks like leisure to most people (content creation, moderation, research about media), match the visible activity to the goals — not to generic notions of productivity.
                Profile context:
                - If `activeProfile.isDefault=true`, this is general/everyday mode: be conservative; everyday utilities (Finder, Mail, calendar, setup/admin) are usually fine.
                - If a named profile is active, judge against that profile's name/description and the user's goals. Productive work outside that scope can still be a distraction (e.g. coding during "Presentation prep").

                Decision rules:
                - Activity supports the goals OR is covered by an allowance in memory/chat → `focused` + `none`.
                - Newer explicit allowance in `recentUserMessages` for the current app/activity → `focused` + `none`.
                - Genuinely unclear after using the full payload → `unclear` + `abstain`.
                - Activity conflicts with goals or an active restriction → `distracted`.
                - First clear distraction → `nudge`.
                - Repeated distraction (`distraction.distractedStreak >= 2` or multiple recent nudges for the same activity, and no newer allowance) → `overlay`.
                - Development tools, editors, terminals, docs, research, reading, planning, and drafting default to `focused` unless the payload clearly says otherwise.
                - Prefer silence over a false positive.

                Output rules:
                - `assessment` and `suggested_action` must agree: focused→none, unclear→abstain, distracted→nudge|overlay.
                - If `nudge`: under 18 words, specific to this activity, distinct from recent nudges.
                - Never mention counters, hidden fields, or that you are reading memory/history.

                Worked example — ambiguous case:
                - Goals: "make a YouTube video about productivity tools".
                - App: "Google Chrome", title: "AI productivity tools - YouTube".
                - Memory: empty. Calendar: empty.
                - Verdict: `focused`/`none`. The goals describe content research; the title supports it. Do not flag because YouTube is "usually" leisure.
                """
            ,
                userTemplate: """
                Decide AC's next action from this context.
                Trust the perception summaries more than raw usage when they conflict.
                Use `recentInterventions` to avoid repeating recent nudges and to escalate only if already warranted.
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
                `characterPersonalityPrefix` is the active AC voice. Fold it into the wording naturally, but do not let it override the user's vibe or the meaning of the nudge.
                If `freeFormMemory` or `recentUserMessages` names this specific app or activity, reference that context — it will feel more caring and less generic.
                `calendarContext` (when present) can make the nudge feel more specific (e.g. reference the current meeting or focus block) — but treat it as a soft hint, not ground truth, and rank it below memory and chat.
                Return exactly one JSON object: {"nudge":"..."}
                """
            ,
                userTemplate: """
                Write the nudge for this situation.
                Mention the actual activity when that helps.
                Do not nudge against something the user just explicitly allowed in `recentUserMessages` or `freeFormMemory`, or clearly implied by `calendarContext`.
                If chat/memory conflict, the newest timestamp wins. Calendar is a tiebreaker only.
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
                stage: .safelistAppeal,
                systemPrompt: """
                You decide whether an app the user keeps returning to is safe to auto-allow without further per-tick LLM checks. This is important to make the app efficient and avoid unnecessary checks.
                You will see the user's stated goals, memory/rules, the app name, the bundle identifier, sample window titles from recent productive sessions, how many focused sessions were observed, and across how many distinct days.

                Return exactly one JSON object:
                {"approve": true|false, "scope_kind": "bundle" | "title_pattern", "title_pattern": "optional substring", "summary": "<=20 words", "reason": "short reason"}

                Approval rules:
                - Approve when the exact app/title combination, and screenshot if present, strongly anchors the activity to the user's goals and is unlikely to drift without the title changing. Do not deny merely because the broad app category can be misused.
                - Deny when the exact title is generic, entertainment/social-coded, or could plausibly drift into unrelated distracting content without the title changing.
                - `requiresTitleScope=true` means the app is ambiguous at the app level. In that case you MUST deny any bundle-level safelist and, if approving, you MUST set `scope_kind="title_pattern"` using the exact current title or another equally narrow title substring from the samples.
                - `isBrowser=true` always implies `requiresTitleScope=true`. Browsers are never safe at the whole-app level.
                - If `screenshotIncluded=true`, use the screenshot as additional evidence. If the screenshot weakens confidence that this exact title is consistently on-task, deny.
                - If `freeFormMemory` says the user removed or distrusts a safelist for this app/title, deny unless the current title is clearly different and safe.
                - Stable tools like IDEs, editors, terminals, doc tools, design tools, and project trackers can be approved at app level only when `requiresTitleScope=false` and the app itself is plausibly always-productive for the user's goals.
                - Media, social, chat, email, and browser surfaces should usually require exact-title scoping, and should be denied whenever the exact title could still hide distracting content.


                Do not invent context. Use only what is in the payload.
                Return the JSON only — no prose, no markdown.
                """
            ,
                userTemplate: """
                Decide whether to add this app to the auto-safelist.
                {{PAYLOAD_JSON}}
                Return exactly one JSON object.
                """
            ),
            MonitoringStagePromptDefinition(
                stage: .policyMemory,
                systemPrompt: """
                You update structured policy memory AND focus profiles for a focus companion.
                Return JSON only:
                {
                  "operations":[
                    {
                      "type":"add_rule|update_rule|remove_rule|expire_rule|activate_profile|create_and_activate_profile|end_active_profile",
                      "rule":{...optional full rule...},
                      "ruleID":"optional existing id",
                      "patch":{...optional partial patch...},
                      "profileID":"optional — for activate_profile",
                      "profileName":"optional — for create_and_activate_profile",
                      "profileDescription":"optional — for create_and_activate_profile",
                      "profileDurationMinutes":"optional integer — overrides 90-min default",
                      "reason":"short reason"
                    }
                  ]
                }

                Rules (add_rule / update_rule / remove_rule / expire_rule):
                - User says "don't let me use Instagram today" → add_rule {kind:"disallow", scope:"app", target:"Instagram", expiresAt: end of local day}
                - User says "WhatsApp is okay for the next hour" → add_rule {kind:"allow", scope:"app", target:"WhatsApp", expiresAt: now+1h}
                - User says "I'm taking a break" → add_rule {kind:"allow", scope:"any", expiresAt: now+30m}
                - User says "you can let me watch YouTube" → add_rule {kind:"allow", scope:"app", target:"YouTube"}
                Convert relative scopes ("today", "this evening", "for the next hour") into explicit `expiresAt` values relative to `now`.
                Prefer updating existing rules over duplicating them. The user's most recent statement is authoritative — expire or update the old rule when it contradicts.
                Do not copy assistant phrasing back into policy memory; use the user's intent.

                Profiles (use the `availableProfiles` and `activeProfile` payload fields):
                - User says "help me focus on coding for an hour":
                  • If `availableProfiles` already has a "Coding"-like profile, emit `activate_profile {profileID:<that id>, profileDurationMinutes:60}`.
                  • Otherwise emit `create_and_activate_profile {profileName:"Coding", profileDescription:"Deep coding work", profileDurationMinutes:60}`.
                - User says "I'll work on the presentation until 5pm" → `create_and_activate_profile` with a duration matching now→17:00 (or activate an existing match).
                - User says "I'm done coding for today" while a coding profile is active → `end_active_profile`.
                - If no duration is specified, omit `profileDurationMinutes` and let the controller pick its 90-min default.
                - Match generously: "deep work", "writing", "research" etc. should reuse a similar existing profile rather than creating a new one each session.
                - Never emit a profile op when the user's message is an everyday remark (vent, status, nudge feedback). Only when the user is explicitly choosing a focus mode.

                Prefer minimal updates. Only emit operations that actually change state.
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
                {"activity_summary":"<=50 words","focus_guess":"focused|distracted|unclear","reason_tags":["tag"],"notes":["optional short note"]}
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
                {"scene_summary":"<=50 words","focus_guess":"focused|distracted|unclear","reason_tags":["tag"],"notes":["optional short note"]}
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
                stage: .safelistAppeal,
                systemPrompt: policyDefaultPromptSet.prompt(for: .safelistAppeal).systemPrompt,
                userTemplate: policyDefaultPromptSet.prompt(for: .safelistAppeal).userTemplate
            ),
            MonitoringStagePromptDefinition(
                stage: .policyMemory,
                systemPrompt: policyDefaultPromptSet.prompt(for: .policyMemory).systemPrompt,
                userTemplate: policyDefaultPromptSet.prompt(for: .policyMemory).userTemplate
            ),
        ]
    )

    nonisolated static let pipelineDefinitions: [MonitoringPipelineDefinition] = [
        MonitoringPipelineDefinition(
            id: "vision_split_default",
            displayName: "Vision Split Default",
            summary: "Single image-plus-title perception, low-temp decision, separate nudge copy.",
            inferenceBackend: .local,
            requiresScreenshot: true,
            usesTitlePerception: false,
            usesVisionPerception: true,
            splitCopyGeneration: true
        ),
        MonitoringPipelineDefinition(
            id: "title_only_default",
            displayName: "Title Only",
            summary: "Title, usage, and memory only. No screenshot required.",
            inferenceBackend: .local,
            requiresScreenshot: false,
            usesTitlePerception: true,
            usesVisionPerception: false,
            splitCopyGeneration: true
        ),
        MonitoringPipelineDefinition(
            id: "vision_single_call",
            displayName: "Vision Single Call",
            summary: "Single image-plus-title perception with inline nudge generation.",
            inferenceBackend: .local,
            requiresScreenshot: true,
            usesTitlePerception: false,
            usesVisionPerception: true,
            splitCopyGeneration: false
        ),
        MonitoringPipelineDefinition(
            id: "title_split_copy",
            displayName: "Title Split Copy",
            summary: "Title-only perception with separate nudge copy generation.",
            inferenceBackend: .local,
            requiresScreenshot: false,
            usesTitlePerception: true,
            usesVisionPerception: false,
            splitCopyGeneration: true
        ),
        MonitoringPipelineDefinition(
            id: "online_single_round_vision",
            displayName: "Online Vision",
            summary: "One OpenRouter call with screenshot upload, decision, and nudge copy together.",
            inferenceBackend: .openRouter,
            requiresScreenshot: true,
            usesTitlePerception: false,
            usesVisionPerception: false,
            splitCopyGeneration: false
        ),
        MonitoringPipelineDefinition(
            id: "online_single_round_text",
            displayName: "Online Context Only",
            summary: "One OpenRouter call without screenshot upload.",
            inferenceBackend: .openRouter,
            requiresScreenshot: false,
            usesTitlePerception: false,
            usesVisionPerception: false,
            splitCopyGeneration: false
        ),
    ]

    nonisolated static let runtimeDefinitions: [MonitoringRuntimeDefinition] = [
        MonitoringRuntimeDefinition(
            id: "gemma_balanced_v1",
            displayName: "Gemma Balanced",
            summary: "Default Gemma preset for staged policy evaluation.",
            optionsByStage: [
                MonitoringRuntimeStageDefinition(stage: .perceptionTitle, options: MonitoringRuntimeOptionsDefinition(maxTokens: 180, temperature: 0.15, topP: 0.9, topK: 48, ctxSize: 3072, batchSize: 1024, ubatchSize: 512, timeoutSeconds: 30)),
                MonitoringRuntimeStageDefinition(stage: .perceptionVision, options: MonitoringRuntimeOptionsDefinition(maxTokens: 180, temperature: 0.15, topP: 0.95, topK: 64, ctxSize: 4096, batchSize: 2048, ubatchSize: 1024, timeoutSeconds: 45)),
                MonitoringRuntimeStageDefinition(stage: .onlineDecision, options: MonitoringRuntimeOptionsDefinition(maxTokens: 120, temperature: 0.05, topP: 0.9, topK: 32, ctxSize: 4096, batchSize: 1024, ubatchSize: 512, timeoutSeconds: 30)),
                MonitoringRuntimeStageDefinition(stage: .decision, options: MonitoringRuntimeOptionsDefinition(maxTokens: 220, temperature: 0.08, topP: 0.9, topK: 40, ctxSize: 4096, batchSize: 1024, ubatchSize: 512, timeoutSeconds: 40)),
                MonitoringRuntimeStageDefinition(stage: .nudgeCopy, options: MonitoringRuntimeOptionsDefinition(maxTokens: 120, temperature: 0.55, topP: 0.95, topK: 64, ctxSize: 3072, batchSize: 1024, ubatchSize: 512, timeoutSeconds: 30)),
                MonitoringRuntimeStageDefinition(stage: .appealReview, options: MonitoringRuntimeOptionsDefinition(maxTokens: 180, temperature: 0.15, topP: 0.92, topK: 48, ctxSize: 4096, batchSize: 1024, ubatchSize: 512, timeoutSeconds: 35)),
                MonitoringRuntimeStageDefinition(stage: .policyMemory, options: MonitoringRuntimeOptionsDefinition(maxTokens: 260, temperature: 0.15, topP: 0.9, topK: 48, ctxSize: 4096, batchSize: 1024, ubatchSize: 512, timeoutSeconds: 35)),
                MonitoringRuntimeStageDefinition(stage: .safelistAppeal, options: MonitoringRuntimeOptionsDefinition(maxTokens: 140, temperature: 0.1, topP: 0.9, topK: 40, ctxSize: 2048, batchSize: 768, ubatchSize: 384, timeoutSeconds: 25)),
            ]
        ),
        MonitoringRuntimeDefinition(
            id: "gemma_low_ram_v1",
            displayName: "Gemma Low RAM",
            summary: "Lower context and token limits for lighter local tests.",
            optionsByStage: [
                MonitoringRuntimeStageDefinition(stage: .perceptionTitle, options: MonitoringRuntimeOptionsDefinition(maxTokens: 140, temperature: 0.12, topP: 0.9, topK: 40, ctxSize: 2048, batchSize: 768, ubatchSize: 384, timeoutSeconds: 25)),
                MonitoringRuntimeStageDefinition(stage: .perceptionVision, options: MonitoringRuntimeOptionsDefinition(maxTokens: 140, temperature: 0.12, topP: 0.92, topK: 48, ctxSize: 1536, batchSize: 1024, ubatchSize: 1024, timeoutSeconds: 35)),
                MonitoringRuntimeStageDefinition(stage: .onlineDecision, options: MonitoringRuntimeOptionsDefinition(maxTokens: 96, temperature: 0.05, topP: 0.9, topK: 32, ctxSize: 3072, batchSize: 768, ubatchSize: 384, timeoutSeconds: 25)),
                MonitoringRuntimeStageDefinition(stage: .decision, options: MonitoringRuntimeOptionsDefinition(maxTokens: 180, temperature: 0.08, topP: 0.9, topK: 32, ctxSize: 3072, batchSize: 768, ubatchSize: 384, timeoutSeconds: 30)),
                MonitoringRuntimeStageDefinition(stage: .nudgeCopy, options: MonitoringRuntimeOptionsDefinition(maxTokens: 90, temperature: 0.45, topP: 0.95, topK: 48, ctxSize: 2048, batchSize: 768, ubatchSize: 384, timeoutSeconds: 20)),
                MonitoringRuntimeStageDefinition(stage: .appealReview, options: MonitoringRuntimeOptionsDefinition(maxTokens: 140, temperature: 0.12, topP: 0.92, topK: 40, ctxSize: 3072, batchSize: 768, ubatchSize: 384, timeoutSeconds: 25)),
                MonitoringRuntimeStageDefinition(stage: .policyMemory, options: MonitoringRuntimeOptionsDefinition(maxTokens: 220, temperature: 0.12, topP: 0.9, topK: 40, ctxSize: 3072, batchSize: 768, ubatchSize: 384, timeoutSeconds: 25)),
                MonitoringRuntimeStageDefinition(stage: .safelistAppeal, options: MonitoringRuntimeOptionsDefinition(maxTokens: 110, temperature: 0.1, topP: 0.9, topK: 32, ctxSize: 1536, batchSize: 512, ubatchSize: 256, timeoutSeconds: 20)),
            ]
        ),
        MonitoringRuntimeDefinition(
            id: "llama_experiment_v1",
            displayName: "Llama Experiment",
            summary: "Llama-family preset for side-by-side comparisons.",
            optionsByStage: [
                MonitoringRuntimeStageDefinition(stage: .perceptionTitle, options: MonitoringRuntimeOptionsDefinition(maxTokens: 180, temperature: 0.15, topP: 0.9, topK: 48, ctxSize: 4096, batchSize: 1024, ubatchSize: 512, timeoutSeconds: 35)),
                MonitoringRuntimeStageDefinition(stage: .perceptionVision, options: MonitoringRuntimeOptionsDefinition(maxTokens: 180, temperature: 0.15, topP: 0.95, topK: 64, ctxSize: 4096, batchSize: 2048, ubatchSize: 1024, timeoutSeconds: 45)),
                MonitoringRuntimeStageDefinition(stage: .onlineDecision, options: MonitoringRuntimeOptionsDefinition(maxTokens: 140, temperature: 0.05, topP: 0.9, topK: 32, ctxSize: 6144, batchSize: 1024, ubatchSize: 512, timeoutSeconds: 35)),
                MonitoringRuntimeStageDefinition(stage: .decision, options: MonitoringRuntimeOptionsDefinition(maxTokens: 220, temperature: 0.08, topP: 0.9, topK: 40, ctxSize: 6144, batchSize: 1024, ubatchSize: 512, timeoutSeconds: 40)),
                MonitoringRuntimeStageDefinition(stage: .nudgeCopy, options: MonitoringRuntimeOptionsDefinition(maxTokens: 120, temperature: 0.6, topP: 0.95, topK: 64, ctxSize: 3072, batchSize: 1024, ubatchSize: 512, timeoutSeconds: 30)),
                MonitoringRuntimeStageDefinition(stage: .appealReview, options: MonitoringRuntimeOptionsDefinition(maxTokens: 180, temperature: 0.15, topP: 0.92, topK: 48, ctxSize: 4096, batchSize: 1024, ubatchSize: 512, timeoutSeconds: 35)),
                MonitoringRuntimeStageDefinition(stage: .policyMemory, options: MonitoringRuntimeOptionsDefinition(maxTokens: 240, temperature: 0.15, topP: 0.9, topK: 48, ctxSize: 4096, batchSize: 1024, ubatchSize: 512, timeoutSeconds: 35)),
                MonitoringRuntimeStageDefinition(stage: .safelistAppeal, options: MonitoringRuntimeOptionsDefinition(maxTokens: 130, temperature: 0.1, topP: 0.9, topK: 32, ctxSize: 2048, batchSize: 768, ubatchSize: 384, timeoutSeconds: 25)),
            ]
        ),
    ]

    nonisolated static let promptSets: [MonitoringPromptSetDefinition] = [
        policyDefaultPromptSet,
        policyDirectPromptSet,
    ]
}

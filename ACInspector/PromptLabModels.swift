//
//  PromptLabModels.swift
//  ACInspector
//

import Foundation

enum InspectorTab: String, CaseIterable, Identifiable {
    case episodes
    case promptLab = "prompt_lab"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .episodes:
            return "Episodes"
        case .promptLab:
            return "Prompt Lab"
        }
    }
}

enum PromptLabScenarioSource: String, Codable, CaseIterable, Identifiable, Sendable {
    case synthetic
    case telemetry

    var id: String { rawValue }
}

enum PromptLabStage: String, Codable, CaseIterable, Identifiable, Sendable {
    case perceptionTitle = "perception_title"
    case perceptionVision = "perception_vision"
    case decision
    case nudgeCopy = "nudge_copy"
    case appealReview = "appeal_review"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .perceptionTitle:
            return "Perception Title"
        case .perceptionVision:
            return "Perception Vision"
        case .decision:
            return "Decision"
        case .nudgeCopy:
            return "Nudge Copy"
        case .appealReview:
            return "Appeal Review"
        }
    }
}

struct PromptLabStagePrompt: Codable, Hashable, Identifiable, Sendable {
    var stage: PromptLabStage
    var systemPrompt: String
    var userTemplate: String

    var id: PromptLabStage { stage }
}

struct PromptLabPromptSet: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var name: String
    var summary: String
    var prompts: [PromptLabStagePrompt]

    nonisolated func prompt(for stage: PromptLabStage) -> PromptLabStagePrompt {
        prompts.first(where: { $0.stage == stage }) ?? PromptLabStagePrompt(
            stage: stage,
            systemPrompt: "",
            userTemplate: "{{PAYLOAD_JSON}}"
        )
    }

    nonisolated mutating func update(stage: PromptLabStage, systemPrompt: String, userTemplate: String) {
        guard let index = prompts.firstIndex(where: { $0.stage == stage }) else { return }
        prompts[index].systemPrompt = systemPrompt
        prompts[index].userTemplate = userTemplate
    }

    static var defaults: [PromptLabPromptSet] {
        [
            PromptLabPromptSet(
                id: "policy_default_v1",
                name: "Policy Default",
                summary: "Matches the current production-style staged policy prompts.",
                prompts: [
                    PromptLabStagePrompt(
                        stage: .perceptionTitle,
                        systemPrompt: """
                        You normalize text-only context for a focus companion.
                        Return exactly one JSON object:
                        {"activity_summary":"...","focus_guess":"focused|distracted|unclear","reason_tags":["tag"],"notes":["optional"]}
                        Be conservative. Use only the structured payload. No markdown.
                        """,
                        userTemplate: """
                        Normalize this title-and-usage context into a short account of what the user is likely doing.
                        {{PAYLOAD_JSON}}
                        Return exactly one JSON object.
                        """
                    ),
                    PromptLabStagePrompt(
                        stage: .perceptionVision,
                        systemPrompt: """
                        You analyze the screenshot for a focus companion.
                        Return exactly one JSON object:
                        {"scene_summary":"...","focus_guess":"focused|distracted|unclear","reason_tags":["tag"],"notes":["optional"]}
                        Avoid personal data and URLs. No markdown.
                        """,
                        userTemplate: """
                        The screenshot is attached. Use it together with the payload:
                        {{PAYLOAD_JSON}}
                        Return exactly one JSON object.
                        """
                    ),
                    PromptLabStagePrompt(
                        stage: .decision,
                        systemPrompt: """
                        You are the policy brain for a focus companion.
                        Honor the user's goals and structured policy memory. False positives are expensive.
                        Return exactly one JSON object:
                        {
                          "assessment":"focused|distracted|unclear",
                          "suggested_action":"none|nudge|overlay|abstain",
                          "confidence":0.0,
                          "reason_tags":["tag"],
                          "nudge":"optional short nudge",
                          "abstain_reason":"optional",
                          "overlay_headline":"optional short headline",
                          "overlay_body":"optional short body",
                          "overlay_prompt":"optional typed appeal prompt",
                          "submit_button_title":"optional",
                          "secondary_button_title":"optional"
                        }
                        Use `overlay` only for clear, repeated distraction. Keep copy short and human.
                        """,
                        userTemplate: """
                        Decide what AC should do with this situation:
                        {{PAYLOAD_JSON}}
                        Return exactly one JSON object.
                        """
                    ),
                    PromptLabStagePrompt(
                        stage: .nudgeCopy,
                        systemPrompt: """
                        Write one short nudge for a focus companion.
                        It should feel human, specific, and non-repetitive.
                        Return exactly one JSON object: {"nudge":"..."}
                        """,
                        userTemplate: """
                        Write the nudge from this decision context:
                        {{PAYLOAD_JSON}}
                        Return exactly one JSON object.
                        """
                    ),
                    PromptLabStagePrompt(
                        stage: .appealReview,
                        systemPrompt: """
                        Review a user's typed appeal to continue a distracting activity.
                        Be conservative with denial and prefer soft guidance.
                        Return exactly one JSON object:
                        {"decision":"allow|deny|defer","message":"short explanation"}
                        """,
                        userTemplate: """
                        Review this appeal:
                        {{PAYLOAD_JSON}}
                        Return exactly one JSON object.
                        """
                    ),
                ]
            ),
            PromptLabPromptSet(
                id: "policy_direct_v1",
                name: "Policy Direct",
                summary: "Stricter reasoning instructions and shorter, more pointed intervention copy.",
                prompts: [
                    PromptLabStagePrompt(
                        stage: .perceptionTitle,
                        systemPrompt: """
                        Infer what the user is doing from titles, usage, and short history.
                        Return one JSON object only:
                        {"activity_summary":"...","focus_guess":"focused|distracted|unclear","reason_tags":["tag"],"notes":["optional"]}
                        Prefer `unclear` over overclaiming.
                        """,
                        userTemplate: """
                        Summarize this text-only context:
                        {{PAYLOAD_JSON}}
                        Return exactly one JSON object.
                        """
                    ),
                    PromptLabStagePrompt(
                        stage: .perceptionVision,
                        systemPrompt: """
                        Describe what is happening on screen for a focus coach.
                        Return one JSON object only:
                        {"scene_summary":"...","focus_guess":"focused|distracted|unclear","reason_tags":["tag"],"notes":["optional"]}
                        Keep it neutral and concise.
                        """,
                        userTemplate: """
                        Use the screenshot and payload together:
                        {{PAYLOAD_JSON}}
                        Return exactly one JSON object.
                        """
                    ),
                    PromptLabStagePrompt(
                        stage: .decision,
                        systemPrompt: """
                        You decide whether a focus coach should stay silent, nudge, or escalate.
                        Respect explicit rules, temporary exceptions, time limits, and user feedback.
                        False positives are expensive, but ignored explicit rules are unacceptable.
                        Return exactly one JSON object:
                        {
                          "assessment":"focused|distracted|unclear",
                          "suggested_action":"none|nudge|overlay|abstain",
                          "confidence":0.0,
                          "reason_tags":["tag"],
                          "nudge":"optional short nudge",
                          "abstain_reason":"optional",
                          "overlay_headline":"optional short headline",
                          "overlay_body":"optional short body",
                          "overlay_prompt":"optional typed appeal prompt",
                          "submit_button_title":"optional",
                          "secondary_button_title":"optional"
                        }
                        Use `overlay` only for repeated off-task behavior after leniency is already represented in the payload.
                        """,
                        userTemplate: """
                        Decide the best next action from this context:
                        {{PAYLOAD_JSON}}
                        Return exactly one JSON object.
                        """
                    ),
                    PromptLabStagePrompt(
                        stage: .nudgeCopy,
                        systemPrompt: """
                        Write a single nudge that is warm, psychologically useful, and not generic.
                        Avoid clichés, moralizing, and repeated phrasing.
                        Return exactly one JSON object: {"nudge":"..."}
                        """,
                        userTemplate: """
                        Draft the nudge for this situation:
                        {{PAYLOAD_JSON}}
                        Return exactly one JSON object.
                        """
                    ),
                    PromptLabStagePrompt(
                        stage: .appealReview,
                        systemPrompt: """
                        Judge whether the user's typed reason justifies continuing a potentially distracting activity.
                        Prefer allow or defer unless the reason clearly conflicts with stated goals and rules.
                        Return exactly one JSON object:
                        {"decision":"allow|deny|defer","message":"short explanation"}
                        """,
                        userTemplate: """
                        Evaluate this typed appeal:
                        {{PAYLOAD_JSON}}
                        Return exactly one JSON object.
                        """
                    ),
                ]
            ),
        ]
    }
}

struct PromptLabPipelineProfile: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var displayName: String
    var summary: String
    var requiresScreenshot: Bool
    var usesTitlePerception: Bool
    var usesVisionPerception: Bool
    var splitCopyGeneration: Bool

    static var defaults: [PromptLabPipelineProfile] {
        [
            PromptLabPipelineProfile(
                id: "vision_split_default",
                displayName: "Vision Split Default",
                summary: "Vision-backed perception, low-temp decision, separate nudge copy.",
                requiresScreenshot: true,
                usesTitlePerception: true,
                usesVisionPerception: true,
                splitCopyGeneration: true
            ),
            PromptLabPipelineProfile(
                id: "title_only_default",
                displayName: "Title Only",
                summary: "Title, usage, and memory only. No screenshot required.",
                requiresScreenshot: false,
                usesTitlePerception: true,
                usesVisionPerception: false,
                splitCopyGeneration: true
            ),
            PromptLabPipelineProfile(
                id: "vision_single_call",
                displayName: "Vision Single Call",
                summary: "Vision-backed decision with inline nudge generation.",
                requiresScreenshot: true,
                usesTitlePerception: true,
                usesVisionPerception: true,
                splitCopyGeneration: false
            ),
            PromptLabPipelineProfile(
                id: "title_split_copy",
                displayName: "Title Split Copy",
                summary: "Title-only perception with separate nudge copy generation.",
                requiresScreenshot: false,
                usesTitlePerception: true,
                usesVisionPerception: false,
                splitCopyGeneration: true
            ),
        ]
    }
}

struct PromptLabRuntimeOptions: Codable, Hashable, Sendable {
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

struct PromptLabRuntimeStageOptions: Codable, Hashable, Identifiable, Sendable {
    var stage: PromptLabStage
    var options: PromptLabRuntimeOptions

    var id: PromptLabStage { stage }
}

struct PromptLabRuntimeProfile: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var displayName: String
    var summary: String
    var optionsByStage: [PromptLabRuntimeStageOptions]

    nonisolated func options(for stage: PromptLabStage) -> PromptLabRuntimeOptions {
        optionsByStage.first(where: { $0.stage == stage })?.options
        ?? PromptLabRuntimeOptions(
            modelIdentifier: "unsloth/gemma-4-E2B-it-GGUF:Q4_0",
            maxTokens: 180,
            temperature: 0.2,
            topP: 0.95,
            topK: 64,
            ctxSize: 4096,
            batchSize: 1024,
            ubatchSize: 512,
            timeoutSeconds: 45
        )
    }

    static var defaults: [PromptLabRuntimeProfile] {
        [
            PromptLabRuntimeProfile(
                id: "gemma_balanced_v1",
                displayName: "Gemma Balanced",
                summary: "Default Gemma preset for staged policy evaluation.",
                optionsByStage: [
                    PromptLabRuntimeStageOptions(stage: .perceptionTitle, options: PromptLabRuntimeOptions(modelIdentifier: "unsloth/gemma-4-E2B-it-GGUF:Q4_0", maxTokens: 180, temperature: 0.15, topP: 0.9, topK: 48, ctxSize: 3072, batchSize: 1024, ubatchSize: 512, timeoutSeconds: 30)),
                    PromptLabRuntimeStageOptions(stage: .perceptionVision, options: PromptLabRuntimeOptions(modelIdentifier: "unsloth/gemma-4-E2B-it-GGUF:Q4_0", maxTokens: 180, temperature: 0.15, topP: 0.95, topK: 64, ctxSize: 2048, batchSize: 2048, ubatchSize: 2048, timeoutSeconds: 45)),
                    PromptLabRuntimeStageOptions(stage: .decision, options: PromptLabRuntimeOptions(modelIdentifier: "unsloth/gemma-4-E2B-it-GGUF:Q4_0", maxTokens: 220, temperature: 0.1, topP: 0.9, topK: 40, ctxSize: 4096, batchSize: 1024, ubatchSize: 512, timeoutSeconds: 40)),
                    PromptLabRuntimeStageOptions(stage: .nudgeCopy, options: PromptLabRuntimeOptions(modelIdentifier: "unsloth/gemma-4-E2B-it-GGUF:Q4_0", maxTokens: 120, temperature: 0.55, topP: 0.95, topK: 64, ctxSize: 3072, batchSize: 1024, ubatchSize: 512, timeoutSeconds: 30)),
                    PromptLabRuntimeStageOptions(stage: .appealReview, options: PromptLabRuntimeOptions(modelIdentifier: "unsloth/gemma-4-E2B-it-GGUF:Q4_0", maxTokens: 180, temperature: 0.15, topP: 0.92, topK: 48, ctxSize: 4096, batchSize: 1024, ubatchSize: 512, timeoutSeconds: 35)),
                ]
            ),
            PromptLabRuntimeProfile(
                id: "gemma_low_ram_v1",
                displayName: "Gemma Low RAM",
                summary: "Lower context and token limits for lighter local tests.",
                optionsByStage: [
                    PromptLabRuntimeStageOptions(stage: .perceptionTitle, options: PromptLabRuntimeOptions(modelIdentifier: "unsloth/gemma-4-E2B-it-GGUF:Q4_0", maxTokens: 140, temperature: 0.12, topP: 0.9, topK: 40, ctxSize: 2048, batchSize: 768, ubatchSize: 384, timeoutSeconds: 25)),
                    PromptLabRuntimeStageOptions(stage: .perceptionVision, options: PromptLabRuntimeOptions(modelIdentifier: "unsloth/gemma-4-E2B-it-GGUF:Q4_0", maxTokens: 140, temperature: 0.12, topP: 0.92, topK: 48, ctxSize: 1536, batchSize: 1024, ubatchSize: 1024, timeoutSeconds: 35)),
                    PromptLabRuntimeStageOptions(stage: .decision, options: PromptLabRuntimeOptions(modelIdentifier: "unsloth/gemma-4-E2B-it-GGUF:Q4_0", maxTokens: 180, temperature: 0.08, topP: 0.9, topK: 32, ctxSize: 3072, batchSize: 768, ubatchSize: 384, timeoutSeconds: 30)),
                    PromptLabRuntimeStageOptions(stage: .nudgeCopy, options: PromptLabRuntimeOptions(modelIdentifier: "unsloth/gemma-4-E2B-it-GGUF:Q4_0", maxTokens: 90, temperature: 0.45, topP: 0.95, topK: 48, ctxSize: 2048, batchSize: 768, ubatchSize: 384, timeoutSeconds: 20)),
                    PromptLabRuntimeStageOptions(stage: .appealReview, options: PromptLabRuntimeOptions(modelIdentifier: "unsloth/gemma-4-E2B-it-GGUF:Q4_0", maxTokens: 140, temperature: 0.12, topP: 0.92, topK: 40, ctxSize: 3072, batchSize: 768, ubatchSize: 384, timeoutSeconds: 25)),
                ]
            ),
            PromptLabRuntimeProfile(
                id: "llama_experiment_v1",
                displayName: "Llama Experiment",
                summary: "Llama-family preset for side-by-side comparisons.",
                optionsByStage: [
                    PromptLabRuntimeStageOptions(stage: .perceptionTitle, options: PromptLabRuntimeOptions(modelIdentifier: "bartowski/Llama-3.2-3B-Instruct-GGUF:Q4_K_M", maxTokens: 180, temperature: 0.15, topP: 0.9, topK: 48, ctxSize: 4096, batchSize: 1024, ubatchSize: 512, timeoutSeconds: 35)),
                    PromptLabRuntimeStageOptions(stage: .perceptionVision, options: PromptLabRuntimeOptions(modelIdentifier: "bartowski/Llama-3.2-3B-Instruct-GGUF:Q4_K_M", maxTokens: 180, temperature: 0.15, topP: 0.95, topK: 64, ctxSize: 2048, batchSize: 2048, ubatchSize: 2048, timeoutSeconds: 45)),
                    PromptLabRuntimeStageOptions(stage: .decision, options: PromptLabRuntimeOptions(modelIdentifier: "bartowski/Llama-3.2-3B-Instruct-GGUF:Q4_K_M", maxTokens: 240, temperature: 0.1, topP: 0.9, topK: 40, ctxSize: 4096, batchSize: 1024, ubatchSize: 512, timeoutSeconds: 40)),
                    PromptLabRuntimeStageOptions(stage: .nudgeCopy, options: PromptLabRuntimeOptions(modelIdentifier: "bartowski/Llama-3.2-3B-Instruct-GGUF:Q4_K_M", maxTokens: 120, temperature: 0.6, topP: 0.95, topK: 64, ctxSize: 3072, batchSize: 1024, ubatchSize: 512, timeoutSeconds: 30)),
                    PromptLabRuntimeStageOptions(stage: .appealReview, options: PromptLabRuntimeOptions(modelIdentifier: "bartowski/Llama-3.2-3B-Instruct-GGUF:Q4_K_M", maxTokens: 180, temperature: 0.15, topP: 0.92, topK: 48, ctxSize: 4096, batchSize: 1024, ubatchSize: 512, timeoutSeconds: 35)),
                ]
            ),
        ]
    }
}

struct PromptLabSwitchRecord: Codable, Hashable, Identifiable, Sendable {
    var id: UUID = UUID()
    var fromAppName: String = ""
    var toAppName: String = ""
    var toWindowTitle: String = ""
    var timestamp: Date = Date()
}

struct PromptLabActionRecord: Codable, Hashable, Identifiable, Sendable {
    var id: UUID = UUID()
    var kind: String = "nudge"
    var message: String = ""
    var timestamp: Date = Date()
}

struct PromptLabUsageRecord: Codable, Hashable, Identifiable, Sendable {
    var id: UUID = UUID()
    var appName: String = ""
    var seconds: Double = 0
}

struct PromptLabHeuristics: Codable, Hashable, Sendable {
    var clearlyProductive: Bool = false
    var browser: Bool = true
    var helpfulWindowTitle: Bool = true
    var periodicVisualReason: String = ""

    var telemetryRecord: TelemetryHeuristicSnapshot {
        TelemetryHeuristicSnapshot(
            clearlyProductive: clearlyProductive,
            browser: browser,
            helpfulWindowTitle: helpfulWindowTitle,
            periodicVisualReason: periodicVisualReason.isEmpty ? nil : periodicVisualReason
        )
    }
}

struct PromptLabDistractionState: Codable, Hashable, Sendable {
    var stableSince: Date?
    var lastAssessment: ModelAssessment?
    var consecutiveDistractedCount: Int = 0
    var nextEvaluationAt: Date?

    var telemetryRecord: TelemetryDistractionState {
        TelemetryDistractionState(
            stableSince: stableSince,
            lastAssessment: lastAssessment,
            consecutiveDistractedCount: consecutiveDistractedCount,
            nextEvaluationAt: nextEvaluationAt
        )
    }
}

struct PromptLabScenario: Codable, Hashable, Identifiable, Sendable {
    var id: UUID = UUID()
    var name: String
    var source: PromptLabScenarioSource
    var sourceEpisodeID: String?
    var appName: String
    var bundleIdentifier: String
    var windowTitle: String
    var timestamp: Date
    var goals: String
    var freeFormMemorySummary: String
    var policyMemorySummary: String
    var policyMemoryJSON: String
    var recentSwitches: [PromptLabSwitchRecord]
    var recentActions: [PromptLabActionRecord]
    var usage: [PromptLabUsageRecord]
    var screenshotPath: String
    var appealText: String
    var heuristics: PromptLabHeuristics
    var distraction: PromptLabDistractionState
    var expectedAssessment: ModelAssessment?
    var expectedAction: ModelSuggestedAction?

    var recentNudgeMessages: [String] {
        Array(
            recentActions
            .filter { $0.kind == "nudge" && !$0.message.cleanedSingleLine.isEmpty }
            .sorted { $0.timestamp > $1.timestamp }
            .map { $0.message.cleanedSingleLine }
            .prefix(3)
        )
    }

    nonisolated func matches(assessment: ModelAssessment?, action: ModelSuggestedAction?) -> Bool? {
        let assessmentMatch: Bool?
        if let expectedAssessment {
            assessmentMatch = expectedAssessment == assessment
        } else {
            assessmentMatch = nil
        }

        let actionMatch: Bool?
        if let expectedAction {
            actionMatch = expectedAction == action
        } else {
            actionMatch = nil
        }

        switch (assessmentMatch, actionMatch) {
        case (nil, nil):
            return nil
        case let (lhs?, nil):
            return lhs
        case let (nil, rhs?):
            return rhs
        case let (lhs?, rhs?):
            return lhs && rhs
        }
    }

    static let syntheticDefault = PromptLabScenario(
        name: "Synthetic YouTube Rule Test",
        source: .synthetic,
        sourceEpisodeID: nil,
        appName: "Google Chrome",
        bundleIdentifier: "com.google.Chrome",
        windowTitle: "YouTube - Building a Swift macOS productivity app",
        timestamp: Date(),
        goals: "Build AC and stay focused on product and engineering work.",
        freeFormMemorySummary: "The user likes direct nudges and dislikes generic productivity quotes.",
        policyMemorySummary: "Disallow scrolling social feeds. YouTube is allowed for programming tutorials up to 60 minutes per day.",
        policyMemoryJSON: """
        {
          "rules": [
            {
              "id": "youtube_tutorial_cap",
              "kind": "allow",
              "scope": {
                "appNames": ["Google Chrome", "YouTube"],
                "titleIncludes": ["Swift", "programming", "tutorial"]
              },
              "dailyLimitMinutes": 60,
              "priority": 90,
              "source": "chat"
            },
            {
              "id": "social_feed_block",
              "kind": "disallow",
              "scope": {
                "titleIncludes": ["Instagram", "Reels", "feed", "Shorts"]
              },
              "priority": 100,
              "source": "chat"
            }
          ]
        }
        """,
        recentSwitches: [
            PromptLabSwitchRecord(fromAppName: "Xcode", toAppName: "Google Chrome", toWindowTitle: "YouTube - Building a Swift macOS productivity app", timestamp: Date().addingTimeInterval(-180))
        ],
        recentActions: [
            PromptLabActionRecord(kind: "nudge", message: "Quick check: is this still moving AC forward?", timestamp: Date().addingTimeInterval(-600))
        ],
        usage: [
            PromptLabUsageRecord(appName: "Google Chrome", seconds: 900),
            PromptLabUsageRecord(appName: "Xcode", seconds: 5400),
        ],
        screenshotPath: "",
        appealText: "This video is directly helping me implement the feature.",
        heuristics: PromptLabHeuristics(clearlyProductive: false, browser: true, helpfulWindowTitle: true, periodicVisualReason: ""),
        distraction: PromptLabDistractionState(stableSince: Date().addingTimeInterval(-420), lastAssessment: .distracted, consecutiveDistractedCount: 1, nextEvaluationAt: Date().addingTimeInterval(60)),
        expectedAssessment: .focused,
        expectedAction: ModelSuggestedAction.none
    )
}

struct PromptLabStageRunResult: Codable, Hashable, Identifiable, Sendable {
    var id: UUID = UUID()
    var stage: PromptLabStage
    var payloadJSON: String
    var renderedPrompt: String
    var rawOutput: String
    var parsedSummary: String
    var latencyMS: Double
    var errorMessage: String?
}

struct PromptLabRunResult: Codable, Hashable, Identifiable, Sendable {
    var id: UUID = UUID()
    var scenarioID: UUID
    var promptSetID: String
    var pipelineProfileID: String
    var runtimeProfileID: String
    var startedAt: Date
    var finishedAt: Date
    var assessment: ModelAssessment?
    var suggestedAction: ModelSuggestedAction?
    var confidence: Double?
    var nudge: String?
    var appealDecision: String?
    var appealMessage: String?
    var stageResults: [PromptLabStageRunResult]
    var pass: Bool?
    var errorSummary: String?
    var annotationLabels: Set<EpisodeAnnotationLabel> = []
    var annotationNote: String = ""

    var durationMS: Double {
        finishedAt.timeIntervalSince(startedAt) * 1000
    }

    var comboLabel: String {
        [promptSetID, pipelineProfileID, runtimeProfileID].joined(separator: " • ")
    }
}

struct PromptLabMatrixSummary: Hashable, Sendable {
    var totalRuns: Int
    var passedRuns: Int
    var failedRuns: Int
    var unmatchedRuns: Int
}

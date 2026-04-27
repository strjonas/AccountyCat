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
        MonitoringPromptTuning.promptSets.map {
            PromptLabPromptSet(
                id: $0.id,
                name: $0.name,
                summary: $0.summary,
                prompts: $0.prompts.compactMap { prompt in
                    guard let stage = PromptLabStage(sharedStage: prompt.stage) else {
                        return nil
                    }
                    return PromptLabStagePrompt(
                        stage: stage,
                        systemPrompt: prompt.systemPrompt,
                        userTemplate: prompt.userTemplate
                    )
                }
            )
        }
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
        MonitoringPromptTuning.pipelineDefinitions.map {
            PromptLabPipelineProfile(
                id: $0.id,
                displayName: $0.displayName,
                summary: $0.summary,
                requiresScreenshot: $0.requiresScreenshot,
                usesTitlePerception: $0.usesTitlePerception,
                usesVisionPerception: $0.usesVisionPerception,
                splitCopyGeneration: $0.splitCopyGeneration
            )
        }
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
            modelIdentifier: DevelopmentModelConfiguration.defaultModelIdentifier,
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
        MonitoringPromptTuning.runtimeDefinitions.map {
            PromptLabRuntimeProfile(
                id: $0.id,
                displayName: $0.displayName,
                summary: $0.summary,
                optionsByStage: $0.optionsByStage.compactMap { stageDefinition in
                    guard let stage = PromptLabStage(sharedStage: stageDefinition.stage) else {
                        return nil
                    }
                    return PromptLabRuntimeStageOptions(
                        stage: stage,
                        options: PromptLabRuntimeOptions(
                            modelIdentifier: stageDefinition.options.modelIdentifier,
                            maxTokens: stageDefinition.options.maxTokens,
                            temperature: stageDefinition.options.temperature,
                            topP: stageDefinition.options.topP,
                            topK: stageDefinition.options.topK,
                            ctxSize: stageDefinition.options.ctxSize,
                            batchSize: stageDefinition.options.batchSize,
                            ubatchSize: stageDefinition.options.ubatchSize,
                            timeoutSeconds: stageDefinition.options.timeoutSeconds
                        )
                    )
                }
            )
        }
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
    var recentUserMessages: [String] = []
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

private extension PromptLabStage {
    init?(sharedStage: MonitoringPromptTuningStage) {
        switch sharedStage {
        case .perceptionTitle:
            self = .perceptionTitle
        case .perceptionVision:
            self = .perceptionVision
        case .decision, .onlineDecision, .legacyDecision, .legacyDecisionFallback:
            self = .decision
        case .nudgeCopy:
            self = .nudgeCopy
        case .appealReview:
            self = .appealReview
        case .policyMemory, .safelistAppeal:
            return nil
        }
    }
}

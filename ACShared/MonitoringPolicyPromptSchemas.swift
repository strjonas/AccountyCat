//
//  MonitoringPolicyPromptSchemas.swift
//  ACShared
//
//  Created by Codex on 20.04.26.
//

import Foundation

enum MonitoringPromptContextBudget {
    nonisolated static let goalCharacters = 180
    nonisolated static let appNameCharacters = 80
    nonisolated static let windowTitleCharacters = 180
    /// Full memory context. AC is the authority on content; these caps only exist to keep
    /// prompt latency predictable. Exceed them via consolidation, not truncation.
    nonisolated static let freeFormMemoryCharacters = 2000
    nonisolated static let freeFormMemoryLines = 15
    nonisolated static let policySummaryCharacters = 420
    nonisolated static let policySummaryLines = 4
    nonisolated static let titlePerceptionSwitchCount = 2
    nonisolated static let titlePerceptionUsageCount = 3
    nonisolated static let decisionSwitchCount = 3
    nonisolated static let decisionUsageCount = 4
    nonisolated static let recentNudgeCount = 3
    /// Last user chat messages passed into decision + nudge stages as a safety net
    /// against memory extraction lag.
    nonisolated static let recentUserChatCount = 3
    nonisolated static let recentUserChatCharacters = 240
}

nonisolated struct MonitoringPromptHeuristicSummary: Codable, Hashable, Sendable {
    var clearlyProductive: Bool
    var browser: Bool
    var helpfulWindowTitle: Bool

    init(heuristics: TelemetryHeuristicSnapshot) {
        clearlyProductive = heuristics.clearlyProductive
        browser = heuristics.browser
        helpfulWindowTitle = heuristics.helpfulWindowTitle
    }
}

nonisolated struct MonitoringPromptDistractionSummary: Codable, Hashable, Sendable {
    var lastAssessment: ModelAssessment?
    var distractedStreak: Int

    init(state: TelemetryDistractionState) {
        lastAssessment = state.lastAssessment
        distractedStreak = state.consecutiveDistractedCount
    }
}

nonisolated struct MonitoringPromptInterventionSummary: Codable, Hashable, Sendable {
    var recentNudges: [String]
    var lastActionKind: String?
    var lastActionMessage: String?
}

nonisolated struct MonitoringPromptSwitchRecord: Codable, Hashable, Sendable {
    var fromAppName: String?
    var toAppName: String
    var toWindowTitle: String?
    var timestamp: Date
}

nonisolated struct MonitoringPromptUsageRecord: Codable, Hashable, Sendable {
    var appName: String
    var seconds: TimeInterval
}

nonisolated struct MonitoringActiveProfilePromptPayload: Codable, Hashable, Sendable {
    var id: String
    var name: String
    var isDefault: Bool
    var description: String?
    var expiresAt: Date?

    nonisolated init(
        id: String = "general",
        name: String = "General",
        isDefault: Bool = true,
        description: String? = nil,
        expiresAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.isDefault = isDefault
        self.description = description
        self.expiresAt = expiresAt
    }
}

nonisolated struct MonitoringTitlePerceptionPromptPayload: Encodable, Sendable {
    var appName: String
    var bundleIdentifier: String?
    var windowTitle: String?
    var recentSwitches: [MonitoringPromptSwitchRecord]
    var usage: [MonitoringPromptUsageRecord]
}

nonisolated struct MonitoringVisionPerceptionPromptPayload: Encodable, Sendable {
    var appName: String
    var windowTitle: String?
}

nonisolated struct MonitoringOnlineDecisionPromptPayload: Encodable, Sendable {
    var now: Date
    var goals: String
    var freeFormMemory: String
    var recentUserMessages: [String]
    var policySummary: String
    var appName: String
    var bundleIdentifier: String?
    var windowTitle: String?
    var recentSwitches: [MonitoringPromptSwitchRecord]
    var usage: [MonitoringPromptUsageRecord]
    var recentInterventions: MonitoringPromptInterventionSummary
    var distraction: MonitoringPromptDistractionSummary
    var heuristics: MonitoringPromptHeuristicSummary
    var calendarContext: String?
    var screenshotIncluded: Bool
    var activeProfile: MonitoringActiveProfilePromptPayload = MonitoringActiveProfilePromptPayload()
}

nonisolated struct MonitoringDecisionPromptPayload: Encodable, Sendable {
    var now: Date
    var goals: String
    var freeFormMemory: String
    var recentUserMessages: [String]
    var policySummary: String
    var appName: String
    var bundleIdentifier: String?
    var windowTitle: String?
    var recentSwitches: [MonitoringPromptSwitchRecord]
    var usage: [MonitoringPromptUsageRecord]
    var recentInterventions: MonitoringPromptInterventionSummary
    var distraction: MonitoringPromptDistractionSummary
    var titlePerception: MonitoringPerceptionEnvelope?
    var visionPerception: MonitoringPerceptionEnvelope?
    /// Current calendar event rendered as a short single-line string, or nil
    /// when the user has Calendar Intelligence off / no event is active.
    /// A soft hint about intent — ranked below `recentUserMessages`,
    /// `freeFormMemory`, and `policySummary`. Calendars can be wrong (plans
    /// change), so the prompt instructs the model to use this as a tiebreaker,
    /// not authority.
    var calendarContext: String?
    var activeProfile: MonitoringActiveProfilePromptPayload = MonitoringActiveProfilePromptPayload()
}

nonisolated struct MonitoringNudgePromptPayload: Encodable, Sendable {
    var goals: String
    var freeFormMemory: String
    var recentUserMessages: [String]
    var policySummary: String
    var appName: String
    var windowTitle: String?
    var titlePerception: String?
    var visionPerception: String?
    var recentNudges: [String]
    /// Mirrors `calendarContext` on the decision payload. The copywriter uses
    /// it to phrase nudges more specifically (e.g. "didn't you block this hour
    /// for writing?") without treating it as ground truth.
    var calendarContext: String?
    /// The name of the currently active profile (e.g. "General", "Paper Writing").
    /// Ground the nudge to what is actually active right now.
    var activeProfileName: String
}

nonisolated struct MonitoringSafelistAppealPromptPayload: Encodable, Sendable {
    var appName: String
    var bundleIdentifier: String?
    var sampleWindowTitles: [String]
    var goals: String
    var freeFormMemory: String
    var focusedCount: Int
    var distinctDays: Int
    var isBrowser: Bool
    var requiresTitleScope: Bool
    var screenshotIncluded: Bool
}

nonisolated enum MonitoringSafelistScopeKind: String, Codable, Sendable {
    case bundle
    case titlePattern = "title_pattern"
}

nonisolated struct MonitoringSafelistAppealEnvelope: Codable, Sendable {
    var approve: Bool
    var scopeKind: MonitoringSafelistScopeKind
    var titlePattern: String?
    var summary: String?
    var reason: String?

    enum CodingKeys: String, CodingKey {
        case approve
        case scopeKind = "scope_kind"
        case titlePattern = "title_pattern"
        case summary
        case reason
    }
}

nonisolated struct MonitoringAppealPromptPayload: Encodable, Sendable {
    var appealText: String
    var goals: String
    var freeFormMemory: String
    var policySummary: String
    var snapshotAppName: String?
    var snapshotWindowTitle: String?
    var assessment: ModelAssessment?
    var suggestedAction: ModelSuggestedAction?
}

nonisolated struct MonitoringPerceptionEnvelope: Codable, Sendable {
    var activitySummary: String
    var focusGuess: ModelAssessment?
    var reasonTags: [String]
    var notes: [String]

    enum CodingKeys: String, CodingKey {
        case activitySummary = "activity_summary"
        case sceneSummary = "scene_summary"
        case focusGuess = "focus_guess"
        case reasonTags = "reason_tags"
        case notes
    }

    init(
        activitySummary: String,
        focusGuess: ModelAssessment?,
        reasonTags: [String],
        notes: [String]
    ) {
        self.activitySummary = activitySummary
        self.focusGuess = focusGuess
        self.reasonTags = reasonTags
        self.notes = notes
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        activitySummary = try container.decodeIfPresent(String.self, forKey: .activitySummary)
            ?? container.decodeIfPresent(String.self, forKey: .sceneSummary)
            ?? ""
        focusGuess = try container.decodeIfPresent(ModelAssessment.self, forKey: .focusGuess)
        reasonTags = try container.decodeIfPresent([String].self, forKey: .reasonTags) ?? []
        if let noteList = try? container.decode([String].self, forKey: .notes) {
            notes = noteList
        } else if let note = try? container.decode(String.self, forKey: .notes) {
            let cleaned = note.cleanedSingleLine
            notes = cleaned.isEmpty ? [] : [cleaned]
        } else {
            notes = []
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(activitySummary, forKey: .activitySummary)
        try container.encodeIfPresent(focusGuess, forKey: .focusGuess)
        try container.encode(reasonTags, forKey: .reasonTags)
        try container.encode(notes, forKey: .notes)
    }
}

nonisolated struct MonitoringDecisionEnvelope: Codable, Sendable {
    var assessment: ModelAssessment
    var suggestedAction: ModelSuggestedAction
    var confidence: Double?
    var reasonTags: [String]
    var nudge: String?
    var abstainReason: String?
    var overlayHeadline: String?
    var overlayBody: String?
    var overlayPrompt: String?
    var submitButtonTitle: String?
    var secondaryButtonTitle: String?

    init(
        assessment: ModelAssessment,
        suggestedAction: ModelSuggestedAction,
        confidence: Double?,
        reasonTags: [String],
        nudge: String?,
        abstainReason: String?,
        overlayHeadline: String?,
        overlayBody: String?,
        overlayPrompt: String?,
        submitButtonTitle: String?,
        secondaryButtonTitle: String?
    ) {
        self.assessment = assessment
        self.suggestedAction = suggestedAction
        self.confidence = confidence
        self.reasonTags = reasonTags
        self.nudge = nudge
        self.abstainReason = abstainReason
        self.overlayHeadline = overlayHeadline
        self.overlayBody = overlayBody
        self.overlayPrompt = overlayPrompt
        self.submitButtonTitle = submitButtonTitle
        self.secondaryButtonTitle = secondaryButtonTitle
    }

    enum CodingKeys: String, CodingKey {
        case assessment
        case suggestedAction = "suggested_action"
        case confidence
        case reasonTags = "reason_tags"
        case nudge
        case abstainReason = "abstain_reason"
        case overlayHeadline = "overlay_headline"
        case overlayBody = "overlay_body"
        case overlayPrompt = "overlay_prompt"
        case submitButtonTitle = "submit_button_title"
        case secondaryButtonTitle = "secondary_button_title"
    }
}

nonisolated struct MonitoringNudgeEnvelope: Codable, Sendable {
    var nudge: String?
}

nonisolated enum MonitoringAppealDecision: String, Codable, Sendable {
    case allow
    case deny
    case deferDecision = "defer"
}

nonisolated struct MonitoringAppealEnvelope: Codable, Sendable {
    var decision: MonitoringAppealDecision
    var message: String
}

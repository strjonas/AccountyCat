//
//  MonitoringPolicyPromptSchemas.swift
//  ACShared
//
//  Created by Codex on 20.04.26.
//

import Foundation

enum MonitoringPromptContextBudget {
    nonisolated static let appNameCharacters = 80
    nonisolated static let windowTitleCharacters = 180
    /// Full memory context. AC is the authority on content; these caps only exist to keep
    /// prompt latency predictable. Exceed them via consolidation, not truncation.
    nonisolated static let freeFormMemoryCharacters = 2000
    nonisolated static let freeFormMemoryLines = 15
    nonisolated static let matchingRuleSummaryCharacters = 520
    nonisolated static let matchingRuleSummaryLines = 6
    nonisolated static let titlePerceptionSwitchCount = 2
    nonisolated static let titlePerceptionUsageCount = 3
    nonisolated static let decisionSwitchCount = 6
    nonisolated static let decisionUsageCount = 4
    nonisolated static let recentNudgeCount = 3
    /// Last user chat messages passed into decision + nudge stages as a safety net
    /// against memory extraction lag.
    nonisolated static let recentUserChatCount = 8
    nonisolated static let recentUserChatCharacters = 320
    nonisolated static let recentUserChatTotalCharacters = 1800
}

nonisolated struct MonitoringPromptHeuristicSummary: Codable, Hashable, Sendable {
    var clearlyProductive: Bool
    var browser: Bool
    var helpfulWindowTitle: Bool
    /// Soft hint: does the visible window title plausibly relate to the user's
    /// declared focus topic (active or recently-ended session)? `nil` when no
    /// goal is available or the title is empty. Never a guarantee — just a
    /// signal to weight against false-positive nudges.
    var titleRelatesToDeclaredFocus: Bool?

    init(heuristics: TelemetryHeuristicSnapshot) {
        clearlyProductive = heuristics.clearlyProductive
        browser = heuristics.browser
        helpfulWindowTitle = heuristics.helpfulWindowTitle
        titleRelatesToDeclaredFocus = heuristics.titleRelatesToDeclaredFocus
    }

    enum CodingKeys: String, CodingKey {
        case clearlyProductive
        case browser
        case helpfulWindowTitle
        case titleRelatesToDeclaredFocus
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(clearlyProductive, forKey: .clearlyProductive)
        try c.encode(browser, forKey: .browser)
        try c.encode(helpfulWindowTitle, forKey: .helpfulWindowTitle)
        try c.encodeIfPresent(titleRelatesToDeclaredFocus, forKey: .titleRelatesToDeclaredFocus)
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
    /// What the duration represents. Today this is always the all-day total for
    /// the app, not the active tab/window/session.
    var scope: String = "today_app_total"
}

/// Compact snapshot of a focus session that just ended within the last ~30 minutes.
/// Carried in the monitoring payload as reference-only context after the active
/// profile drops to Everyday. The model should use it to avoid false positives
/// around adjacent wrap-up work, not to keep enforcing an expired session.
nonisolated struct RecentlyEndedSessionSummary: Codable, Hashable, Sendable {
    var name: String
    var description: String?
    var endedAt: Date
    /// Optional reason/goal text captured at activation (e.g. "Writing essay 'can machines think'").
    var goalSummary: String?

    nonisolated init(
        name: String,
        description: String? = nil,
        endedAt: Date,
        goalSummary: String? = nil
    ) {
        self.name = name
        self.description = description
        self.endedAt = endedAt
        self.goalSummary = goalSummary
    }
}

nonisolated struct MonitoringActiveProfilePromptPayload: Codable, Hashable, Sendable {
    var id: String
    var name: String
    var isDefault: Bool
    var description: String?
    var goalSummary: String?
    var activatedAt: Date?
    var expiresAt: Date?

    nonisolated init(
        id: String = "general",
        name: String = "General",
        isDefault: Bool = true,
        description: String? = nil,
        goalSummary: String? = nil,
        activatedAt: Date? = nil,
        expiresAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.isDefault = isDefault
        self.description = description
        self.goalSummary = goalSummary
        self.activatedAt = activatedAt
        self.expiresAt = expiresAt
    }
}

/// Compact end-of-payload recap for the decision stages. The full payload still
/// carries memory, chat, perception, and telemetry details; this frame repeats
/// the active contract near the end so small/local models and prefix-cached
/// online calls both keep the current "where are they / where should they be"
/// comparison salient.
nonisolated struct MonitoringDecisionFramePromptPayload: Codable, Hashable, Sendable {
    var currentSurface: String
    var newestCurrentSessionUserMessage: String?
    var activeMatchingRules: String
    var expectedFocusContract: String

    nonisolated init(
        currentSurface: String,
        newestCurrentSessionUserMessage: String? = nil,
        activeMatchingRules: String,
        expectedFocusContract: String
    ) {
        self.currentSurface = currentSurface
        self.newestCurrentSessionUserMessage = newestCurrentSessionUserMessage
        self.activeMatchingRules = activeMatchingRules
        self.expectedFocusContract = expectedFocusContract
    }

    nonisolated static func make(
        appName: String,
        windowTitle: String?,
        currentContextSeconds: TimeInterval?,
        matchingRuleSummary: String,
        recentUserMessages: [String],
        activeProfile: MonitoringActiveProfilePromptPayload
    ) -> MonitoringDecisionFramePromptPayload {
        var surface = "Current surface: \(appName.cleanedSingleLine)"
        if let title = windowTitle?.cleanedSingleLine, !title.isEmpty {
            surface += " — \(title)"
        }
        if let currentContextSeconds {
            surface += " — stable for \(Int(currentContextSeconds))s"
        }

        let expected: String
        if activeProfile.isDefault {
            let description = activeProfile.description?.cleanedSingleLine
            let descriptionLine = description?.isEmpty == false ? description : nil
            expected = [
                "Everyday profile is active: no named focus session is running.",
                descriptionLine.map { "Description: \($0)." },
                "Normal life, breaks, errands, and admin are allowed unless active matching rules or fresh user intent say otherwise.",
            ].compactMap { $0 }.joined(separator: " ")
        } else {
            var parts = ["Focus session active: \(activeProfile.name.cleanedSingleLine)."]
            if let goal = activeProfile.goalSummary?.cleanedSingleLine, !goal.isEmpty {
                parts.append("Activation intent: \(goal).")
            }
            if let description = activeProfile.description?.cleanedSingleLine, !description.isEmpty {
                parts.append("Profile description: \(description).")
            }
            if let expiresAt = activeProfile.expiresAt {
                parts.append("Expires at \(PromptTimestampFormatting.absoluteLabel(for: expiresAt)).")
            }
            expected = parts.joined(separator: " ")
        }

        return MonitoringDecisionFramePromptPayload(
            currentSurface: surface.truncatedForPrompt(maxLength: 280),
            newestCurrentSessionUserMessage: recentUserMessages.last?
                .truncatedForPrompt(maxLength: MonitoringPromptContextBudget.recentUserChatCharacters),
            activeMatchingRules: matchingRuleSummary.isEmpty
                ? "(none matching current context)"
                : matchingRuleSummary,
            expectedFocusContract: expected.truncatedForPrompt(maxLength: 520)
        )
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
    var activeProfile: MonitoringActiveProfilePromptPayload
    var matchingRuleSummary: String
    var recentUserMessages: [String]
    var freeFormMemory: String
    var calendarContext: String?
    var now: Date
    var appName: String
    var bundleIdentifier: String?
    var windowTitle: String?
    var recentSwitches: [MonitoringPromptSwitchRecord]
    var recentActivityTimeline: [MonitoringPromptSwitchRecord]
    var usage: [MonitoringPromptUsageRecord]
    var currentContextSeconds: TimeInterval?
    var recentInterventions: MonitoringPromptInterventionSummary
    var distraction: MonitoringPromptDistractionSummary
    var heuristics: MonitoringPromptHeuristicSummary
    var screenshotIncluded: Bool
    var decisionFrame: MonitoringDecisionFramePromptPayload
}

nonisolated struct MonitoringDecisionPromptPayload: Encodable, Sendable {
    var activeProfile: MonitoringActiveProfilePromptPayload
    var matchingRuleSummary: String
    var recentUserMessages: [String]
    var freeFormMemory: String
    /// Current calendar event rendered as a short single-line string, or nil
    /// when the user has Calendar Intelligence off / no event is active.
    /// A soft hint about intent — ranked below the active profile contract,
    /// `matchingRuleSummary`, current-session chat, and `freeFormMemory`.
    /// Calendars can be wrong (plans change), so the prompt instructs the
    /// model to use this as a tiebreaker, not authority.
    var calendarContext: String?
    var now: Date
    var appName: String
    var bundleIdentifier: String?
    var windowTitle: String?
    var recentSwitches: [MonitoringPromptSwitchRecord]
    var recentActivityTimeline: [MonitoringPromptSwitchRecord]
    var usage: [MonitoringPromptUsageRecord]
    var currentContextSeconds: TimeInterval?
    var recentInterventions: MonitoringPromptInterventionSummary
    var distraction: MonitoringPromptDistractionSummary
    var titlePerception: MonitoringPerceptionEnvelope?
    var visionPerception: MonitoringPerceptionEnvelope?
    var decisionFrame: MonitoringDecisionFramePromptPayload
}

nonisolated struct MonitoringNudgePromptPayload: Encodable, Sendable {
    var activeProfile: MonitoringActiveProfilePromptPayload
    var matchingRuleSummary: String
    var recentUserMessages: [String]
    var freeFormMemory: String
    /// Mirrors `calendarContext` on the decision payload. The copywriter uses
    /// it to phrase nudges more specifically (e.g. "didn't you block this hour
    /// for writing?") without treating it as ground truth.
    var calendarContext: String?
    var appName: String
    var windowTitle: String?
    var titlePerception: String?
    var visionPerception: String?
    var recentNudges: [String]
}

nonisolated struct MonitoringSafelistAppealPromptPayload: Encodable, Sendable {
    var appName: String
    var bundleIdentifier: String?
    var sampleWindowTitles: [String]
    var freeFormMemory: String
    var activeProfile: MonitoringActiveProfilePromptPayload
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
    var activeProfile: MonitoringActiveProfilePromptPayload
    var matchingRuleSummary: String
    var recentUserMessages: [String]
    var appealText: String
    var freeFormMemory: String
    var snapshotAppName: String?
    var snapshotWindowTitle: String?
    var assessment: ModelAssessment?
    var suggestedAction: ModelSuggestedAction?
}

private nonisolated struct MonitoringPromptAnyEncodable: Encodable {
    private let encodeValue: (Encoder) throws -> Void

    nonisolated init<T: Encodable>(_ value: T) {
        encodeValue = value.encode(to:)
    }

    nonisolated func encode(to encoder: Encoder) throws {
        try encodeValue(encoder)
    }
}

private nonisolated struct MonitoringPromptOrderedField {
    var name: String
    var value: MonitoringPromptAnyEncodable?
}

nonisolated enum MonitoringPromptPayloadEncoding {
    nonisolated static func encode<T: Encodable>(_ payload: T, prettyPrinted: Bool = false) -> String {
        if let payload = payload as? MonitoringOnlineDecisionPromptPayload {
            return encodeOnlineDecision(payload, prettyPrinted: prettyPrinted)
        }
        if let payload = payload as? MonitoringDecisionPromptPayload {
            return encodeDecision(payload, prettyPrinted: prettyPrinted)
        }
        if let payload = payload as? MonitoringNudgePromptPayload {
            return encodeNudge(payload, prettyPrinted: prettyPrinted)
        }
        if let payload = payload as? MonitoringAppealPromptPayload {
            return encodeAppeal(payload, prettyPrinted: prettyPrinted)
        }
        if let payload = payload as? MonitoringSafelistAppealPromptPayload {
            return encodeSafelistAppeal(payload, prettyPrinted: prettyPrinted)
        }
        return encodeAny(payload, prettyPrinted: prettyPrinted)
    }

    private static func encodeOnlineDecision(
        _ payload: MonitoringOnlineDecisionPromptPayload,
        prettyPrinted: Bool
    ) -> String {
        encodeFields([
            field("activeProfile", payload.activeProfile),
            field("matchingRuleSummary", payload.matchingRuleSummary),
            field("recentUserMessages", payload.recentUserMessages),
            field("freeFormMemory", payload.freeFormMemory),
            optionalField("calendarContext", payload.calendarContext),
            field("now", payload.now),
            field("appName", payload.appName),
            optionalField("bundleIdentifier", payload.bundleIdentifier),
            optionalField("windowTitle", payload.windowTitle),
            field("recentSwitches", payload.recentSwitches),
            field("recentActivityTimeline", payload.recentActivityTimeline),
            field("usage", payload.usage),
            optionalField("currentContextSeconds", payload.currentContextSeconds),
            field("recentInterventions", payload.recentInterventions),
            field("distraction", payload.distraction),
            field("heuristics", payload.heuristics),
            field("screenshotIncluded", payload.screenshotIncluded),
            field("decisionFrame", payload.decisionFrame),
        ], prettyPrinted: prettyPrinted)
    }

    private static func encodeDecision(
        _ payload: MonitoringDecisionPromptPayload,
        prettyPrinted: Bool
    ) -> String {
        encodeFields([
            field("activeProfile", payload.activeProfile),
            field("matchingRuleSummary", payload.matchingRuleSummary),
            field("recentUserMessages", payload.recentUserMessages),
            field("freeFormMemory", payload.freeFormMemory),
            optionalField("calendarContext", payload.calendarContext),
            field("now", payload.now),
            field("appName", payload.appName),
            optionalField("bundleIdentifier", payload.bundleIdentifier),
            optionalField("windowTitle", payload.windowTitle),
            field("recentSwitches", payload.recentSwitches),
            field("recentActivityTimeline", payload.recentActivityTimeline),
            field("usage", payload.usage),
            optionalField("currentContextSeconds", payload.currentContextSeconds),
            field("recentInterventions", payload.recentInterventions),
            field("distraction", payload.distraction),
            optionalField("titlePerception", payload.titlePerception),
            optionalField("visionPerception", payload.visionPerception),
            field("decisionFrame", payload.decisionFrame),
        ], prettyPrinted: prettyPrinted)
    }

    private static func encodeNudge(
        _ payload: MonitoringNudgePromptPayload,
        prettyPrinted: Bool
    ) -> String {
        encodeFields([
            field("activeProfile", payload.activeProfile),
            field("matchingRuleSummary", payload.matchingRuleSummary),
            field("recentUserMessages", payload.recentUserMessages),
            field("freeFormMemory", payload.freeFormMemory),
            optionalField("calendarContext", payload.calendarContext),
            field("appName", payload.appName),
            optionalField("windowTitle", payload.windowTitle),
            optionalField("titlePerception", payload.titlePerception),
            optionalField("visionPerception", payload.visionPerception),
            field("recentNudges", payload.recentNudges),
        ], prettyPrinted: prettyPrinted)
    }

    private static func encodeAppeal(
        _ payload: MonitoringAppealPromptPayload,
        prettyPrinted: Bool
    ) -> String {
        encodeFields([
            field("activeProfile", payload.activeProfile),
            field("matchingRuleSummary", payload.matchingRuleSummary),
            field("recentUserMessages", payload.recentUserMessages),
            field("appealText", payload.appealText),
            field("freeFormMemory", payload.freeFormMemory),
            optionalField("snapshotAppName", payload.snapshotAppName),
            optionalField("snapshotWindowTitle", payload.snapshotWindowTitle),
            optionalField("assessment", payload.assessment),
            optionalField("suggestedAction", payload.suggestedAction),
        ], prettyPrinted: prettyPrinted)
    }

    private static func encodeSafelistAppeal(
        _ payload: MonitoringSafelistAppealPromptPayload,
        prettyPrinted: Bool
    ) -> String {
        encodeFields([
            field("activeProfile", payload.activeProfile),
            field("freeFormMemory", payload.freeFormMemory),
            field("appName", payload.appName),
            optionalField("bundleIdentifier", payload.bundleIdentifier),
            field("sampleWindowTitles", payload.sampleWindowTitles),
            field("focusedCount", payload.focusedCount),
            field("distinctDays", payload.distinctDays),
            field("isBrowser", payload.isBrowser),
            field("requiresTitleScope", payload.requiresTitleScope),
            field("screenshotIncluded", payload.screenshotIncluded),
        ], prettyPrinted: prettyPrinted)
    }

    private static func field<T: Encodable>(_ name: String, _ value: T) -> MonitoringPromptOrderedField {
        MonitoringPromptOrderedField(name: name, value: MonitoringPromptAnyEncodable(value))
    }

    private static func optionalField<T: Encodable>(_ name: String, _ value: T?) -> MonitoringPromptOrderedField {
        MonitoringPromptOrderedField(name: name, value: value.map(MonitoringPromptAnyEncodable.init))
    }

    private static func encodeFields(
        _ fields: [MonitoringPromptOrderedField],
        prettyPrinted: Bool
    ) -> String {
        let parts = fields.compactMap { field -> String? in
            guard let value = field.value else { return nil }
            let key = encodeAny(field.name, prettyPrinted: false)
            let encodedValue = encodeAny(value, prettyPrinted: false)
            return "\(key):\(encodedValue)"
        }
        if prettyPrinted {
            return parts.isEmpty ? "{}" : "{\n  \(parts.joined(separator: ",\n  "))\n}"
        }
        return "{\(parts.joined(separator: ","))}"
    }

    private static func encodeAny<T: Encodable>(_ value: T, prettyPrinted: Bool) -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = prettyPrinted ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
        guard let data = try? encoder.encode(value),
              let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return string
    }
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

//
//  ACEvalModels.swift
//  AC
//

import Foundation

nonisolated enum ACEvalKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case focus
    case chat
    case chatAction = "chat-action"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .focus: return "Focus"
        case .chat: return "Chat"
        case .chatAction: return "Chat Action"
        }
    }
}

nonisolated enum ACEvalImportance: String, Codable, CaseIterable, Identifiable, Sendable {
    case low
    case medium
    case high
    case critical

    var id: String { rawValue }

    var rank: Int {
        switch self {
        case .low: return 0
        case .medium: return 1
        case .high: return 2
        case .critical: return 3
        }
    }
}

nonisolated enum ACEvalRecommendedBackend: String, Codable, CaseIterable, Identifiable, Sendable {
    case local
    case online

    var id: String { rawValue }
}

nonisolated enum ACEvalCategory: String, Codable, CaseIterable, Identifiable, Sendable {
    case falsePositive = "false_positive"
    case falseNegative = "false_negative"
    case goodBehavior = "good_behavior"
    case focusSession = "focus_session"
    case everydayMode = "everyday_mode"
    case browser
    case chatAction = "chat_action"
    case memory
    case profile
    case focusPolicy = "focus_policy"
    case tone
    case regression

    var id: String { rawValue }
}

nonisolated struct ACEvalCase: Codable, Hashable, Identifiable, Sendable {
    var version: Int
    var id: String
    var name: String
    var kind: ACEvalKind
    var importance: ACEvalImportance
    var categories: [String]
    var rationale: String
    var createdAt: Date
    var updatedAt: Date
    var source: ACEvalSource
    var recommendedBackend: ACEvalRecommendedBackend
    var focusInput: ACEvalFocusInput?
    var chatInput: ACEvalChatInput?
    var chatActionInput: ACEvalChatActionInput?
    var expectation: ACEvalExpectation
    var observedOutput: ACEvalObservedOutput?

    init(
        version: Int = 1,
        id: String = UUID().uuidString,
        name: String,
        kind: ACEvalKind,
        importance: ACEvalImportance = .medium,
        categories: [String] = [],
        rationale: String = "",
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        source: ACEvalSource,
        recommendedBackend: ACEvalRecommendedBackend = .local,
        focusInput: ACEvalFocusInput? = nil,
        chatInput: ACEvalChatInput? = nil,
        chatActionInput: ACEvalChatActionInput? = nil,
        expectation: ACEvalExpectation,
        observedOutput: ACEvalObservedOutput? = nil
    ) {
        self.version = version
        self.id = id
        self.name = name
        self.kind = kind
        self.importance = importance
        self.categories = categories
        self.rationale = rationale
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.source = source
        self.recommendedBackend = recommendedBackend
        self.focusInput = focusInput
        self.chatInput = chatInput
        self.chatActionInput = chatActionInput
        self.expectation = expectation
        self.observedOutput = observedOutput
    }

    var expectedOutcomeSummary: String {
        expectation.summary(for: kind)
    }

    var hasScreenshot: Bool {
        guard let path = focusInput?.screenshotPath ?? source.screenshotPath else { return false }
        return !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

nonisolated struct ACEvalSource: Codable, Hashable, Sendable {
    var episodeID: String?
    var sessionID: String?
    var appName: String
    var bundleIdentifier: String?
    var windowTitle: String?
    var timestamp: Date
    var screenshotPath: String?

    init(
        episodeID: String? = nil,
        sessionID: String? = nil,
        appName: String = "",
        bundleIdentifier: String? = nil,
        windowTitle: String? = nil,
        timestamp: Date = Date(),
        screenshotPath: String? = nil
    ) {
        self.episodeID = episodeID
        self.sessionID = sessionID
        self.appName = appName
        self.bundleIdentifier = bundleIdentifier
        self.windowTitle = windowTitle
        self.timestamp = timestamp
        self.screenshotPath = screenshotPath
    }
}

nonisolated struct ACEvalObservedOutput: Codable, Hashable, Sendable {
    var summary: String
    var json: String?
    var modelIdentifier: String?
}

nonisolated struct ACEvalExpectation: Codable, Hashable, Sendable {
    var focus: ACEvalFocusExpectation?
    var chat: ACEvalChatExpectation?
    var chatAction: ACEvalChatActionExpectation?

    func summary(for kind: ACEvalKind) -> String {
        switch kind {
        case .focus:
            return focus?.summary ?? "No focus expectation"
        case .chat:
            return chat?.summary ?? "No chat expectation"
        case .chatAction:
            return chatAction?.summary ?? "No chat-action expectation"
        }
    }
}

nonisolated struct ACEvalFocusExpectation: Codable, Hashable, Sendable {
    var acceptedAssessments: [ModelAssessment]
    var forbiddenAssessments: [ModelAssessment]
    var acceptedActions: [ModelSuggestedAction]
    var forbiddenActions: [ModelSuggestedAction]

    init(
        acceptedAssessments: [ModelAssessment] = [],
        forbiddenAssessments: [ModelAssessment] = [],
        acceptedActions: [ModelSuggestedAction] = [],
        forbiddenActions: [ModelSuggestedAction] = []
    ) {
        self.acceptedAssessments = acceptedAssessments
        self.forbiddenAssessments = forbiddenAssessments
        self.acceptedActions = acceptedActions
        self.forbiddenActions = forbiddenActions
    }

    var summary: String {
        var parts: [String] = []
        if !acceptedAssessments.isEmpty {
            parts.append("assessment in \(acceptedAssessments.map(\.rawValue).joined(separator: ","))")
        }
        if !acceptedActions.isEmpty {
            parts.append("action in \(acceptedActions.map(\.rawValue).joined(separator: ","))")
        }
        if !forbiddenAssessments.isEmpty {
            parts.append("forbid assessment \(forbiddenAssessments.map(\.rawValue).joined(separator: ","))")
        }
        if !forbiddenActions.isEmpty {
            parts.append("forbid action \(forbiddenActions.map(\.rawValue).joined(separator: ","))")
        }
        return parts.isEmpty ? "No focus expectation" : parts.joined(separator: " | ")
    }

    func evaluate(assessment: ModelAssessment?, action: ModelSuggestedAction?) -> ACEvalExpectationMatch {
        guard let assessment, let action else {
            return ACEvalExpectationMatch(pass: false, reason: "missing_focus_output")
        }
        if forbiddenAssessments.contains(assessment) {
            return ACEvalExpectationMatch(pass: false, reason: "forbidden_assessment:\(assessment.rawValue)")
        }
        if forbiddenActions.contains(action) {
            return ACEvalExpectationMatch(pass: false, reason: "forbidden_action:\(action.rawValue)")
        }
        if !acceptedAssessments.isEmpty, !acceptedAssessments.contains(assessment) {
            return ACEvalExpectationMatch(pass: false, reason: "assessment_not_accepted:\(assessment.rawValue)")
        }
        if !acceptedActions.isEmpty, !acceptedActions.contains(action) {
            return ACEvalExpectationMatch(pass: false, reason: "action_not_accepted:\(action.rawValue)")
        }
        return ACEvalExpectationMatch(pass: true, reason: "matched")
    }
}

nonisolated struct ACEvalChatExpectation: Codable, Hashable, Sendable {
    var requiredActionKinds: [CompanionChatActionKind]
    var forbiddenActionKinds: [CompanionChatActionKind]
    var requiredScheduleKind: String?
    var replyMustBeNonEmpty: Bool

    init(
        requiredActionKinds: [CompanionChatActionKind] = [],
        forbiddenActionKinds: [CompanionChatActionKind] = [],
        requiredScheduleKind: String? = nil,
        replyMustBeNonEmpty: Bool = true
    ) {
        self.requiredActionKinds = requiredActionKinds
        self.forbiddenActionKinds = forbiddenActionKinds
        self.requiredScheduleKind = requiredScheduleKind
        self.replyMustBeNonEmpty = replyMustBeNonEmpty
    }

    var summary: String {
        var parts: [String] = []
        if replyMustBeNonEmpty { parts.append("reply_nonempty") }
        if !requiredActionKinds.isEmpty {
            parts.append("requires \(requiredActionKinds.map(\.rawValue).joined(separator: ","))")
        }
        if !forbiddenActionKinds.isEmpty {
            parts.append("forbids \(forbiddenActionKinds.map(\.rawValue).joined(separator: ","))")
        }
        if let requiredScheduleKind, !requiredScheduleKind.isEmpty {
            parts.append("schedule \(requiredScheduleKind)")
        }
        return parts.isEmpty ? "No chat expectation" : parts.joined(separator: " | ")
    }

    func evaluate(reply: String, actions: [CompanionChatAction], scheduleKind: String?) -> ACEvalExpectationMatch {
        if replyMustBeNonEmpty, reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return ACEvalExpectationMatch(pass: false, reason: "empty_reply")
        }
        let actionKinds = Set(actions.map(\.kind))
        for forbidden in forbiddenActionKinds where actionKinds.contains(forbidden) {
            return ACEvalExpectationMatch(pass: false, reason: "forbidden_action_kind:\(forbidden.rawValue)")
        }
        for required in requiredActionKinds where !actionKinds.contains(required) {
            return ACEvalExpectationMatch(pass: false, reason: "missing_action_kind:\(required.rawValue)")
        }
        if let requiredScheduleKind, !requiredScheduleKind.isEmpty,
           scheduleKind != requiredScheduleKind {
            return ACEvalExpectationMatch(pass: false, reason: "schedule_not_matched:\(scheduleKind ?? "none")")
        }
        return ACEvalExpectationMatch(pass: true, reason: "matched")
    }
}

nonisolated struct ACEvalChatActionExpectation: Codable, Hashable, Sendable {
    var kind: CompanionChatActionKind?
    var intent: String?
    var scope: String?
    var targetType: String?
    var targetValue: String?
    var duration: String?
    var profileID: String?
    var profileName: String?
    var profileDescription: String?
    var durationMinutes: Int?
    var textContains: String?
    var locked: Bool?

    var summary: String {
        var parts: [String] = []
        if let kind { parts.append("kind=\(kind.rawValue)") }
        if let intent, !intent.isEmpty { parts.append("intent=\(intent)") }
        if let targetType, !targetType.isEmpty { parts.append("target=\(targetType):\(targetValue ?? "")") }
        if let textContains, !textContains.isEmpty { parts.append("text contains \(textContains)") }
        return parts.isEmpty ? "No chat-action expectation" : parts.joined(separator: " | ")
    }

    func evaluate(action: CompanionChatAction?) -> ACEvalExpectationMatch {
        guard let action else {
            return ACEvalExpectationMatch(pass: false, reason: "missing_chat_action")
        }
        if let kind, action.kind != kind {
            return ACEvalExpectationMatch(pass: false, reason: "kind_not_matched:\(action.kind.rawValue)")
        }
        if let intent, !intent.matchesEvalString(action.intent) {
            return ACEvalExpectationMatch(pass: false, reason: "intent_not_matched:\(action.intent ?? "nil")")
        }
        if let scope, !scope.matchesEvalString(action.scope) {
            return ACEvalExpectationMatch(pass: false, reason: "scope_not_matched:\(action.scope ?? "nil")")
        }
        if let targetType, !targetType.matchesEvalString(action.target?.type) {
            return ACEvalExpectationMatch(pass: false, reason: "target_type_not_matched:\(action.target?.type ?? "nil")")
        }
        if let targetValue, !targetValue.matchesEvalString(action.target?.value) {
            return ACEvalExpectationMatch(pass: false, reason: "target_value_not_matched:\(action.target?.value ?? "nil")")
        }
        if let duration, !duration.matchesEvalString(action.duration) {
            return ACEvalExpectationMatch(pass: false, reason: "duration_not_matched:\(action.duration ?? "nil")")
        }
        if let profileID, !profileID.matchesEvalString(action.profileID) {
            return ACEvalExpectationMatch(pass: false, reason: "profile_id_not_matched:\(action.profileID ?? "nil")")
        }
        if let profileName, !profileName.matchesEvalString(action.profileName) {
            return ACEvalExpectationMatch(pass: false, reason: "profile_name_not_matched:\(action.profileName ?? "nil")")
        }
        if let profileDescription, !profileDescription.matchesEvalString(action.profileDescription) {
            return ACEvalExpectationMatch(pass: false, reason: "profile_description_not_matched")
        }
        if let durationMinutes, action.durationMinutes != durationMinutes {
            return ACEvalExpectationMatch(pass: false, reason: "duration_minutes_not_matched:\(action.durationMinutes.map(String.init) ?? "nil")")
        }
        if let textContains, !textContains.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let text = action.text ?? ""
            if text.range(of: textContains, options: [.caseInsensitive, .diacriticInsensitive]) == nil {
                return ACEvalExpectationMatch(pass: false, reason: "text_missing:\(textContains)")
            }
        }
        if let locked, action.locked != locked {
            return ACEvalExpectationMatch(pass: false, reason: "locked_not_matched:\(action.locked.map(String.init) ?? "nil")")
        }
        return ACEvalExpectationMatch(pass: true, reason: "matched")
    }
}

nonisolated struct ACEvalExpectationMatch: Codable, Hashable, Sendable {
    var pass: Bool
    var reason: String
}

nonisolated struct ACEvalFocusInput: Codable, Hashable, Sendable {
    var timestamp: Date
    var appName: String
    var bundleIdentifier: String?
    var windowTitle: String?
    var screenshotPath: String?
    var goals: String
    var freeFormMemory: String
    var recentUserMessages: [String]
    var policyMemorySummary: String
    var policyMemoryJSON: String
    var recentSwitches: [ACEvalSwitchRecord]
    var recentActions: [ACEvalActionRecord]
    var usage: [ACEvalUsageRecord]
    var heuristics: ACEvalHeuristics
    var distraction: ACEvalDistraction
    var activeProfile: ACEvalActiveProfile
}

nonisolated struct ACEvalChatInput: Codable, Hashable, Sendable {
    var userMessage: String
    var goals: String
    var memory: String
    var policyRules: String
    var context: ACEvalChatContext
    var history: [ACEvalChatMessage]
    var character: String
    var activeProfileContext: String
    var workflow: CompanionChatWorkflow
}

nonisolated struct ACEvalChatActionInput: Codable, Hashable, Sendable {
    var action: CompanionChatAction
    var latestUserMessage: String
    var recentUserMessages: [String]
    var goals: String
    var freeFormMemory: String
    var policyRules: String
    var context: ACEvalFrontmostContext?
    var activeProfile: ACEvalProfileSummary
    var availableProfiles: [ACEvalProfileSummary]
}

nonisolated struct ACEvalSwitchRecord: Codable, Hashable, Identifiable, Sendable {
    var id: UUID
    var fromAppName: String?
    var toAppName: String
    var toWindowTitle: String?
    var timestamp: Date

    init(id: UUID = UUID(), fromAppName: String? = nil, toAppName: String = "", toWindowTitle: String? = nil, timestamp: Date = Date()) {
        self.id = id
        self.fromAppName = fromAppName
        self.toAppName = toAppName
        self.toWindowTitle = toWindowTitle
        self.timestamp = timestamp
    }
}

nonisolated struct ACEvalActionRecord: Codable, Hashable, Identifiable, Sendable {
    var id: UUID
    var kind: String
    var message: String?
    var timestamp: Date

    init(id: UUID = UUID(), kind: String = "", message: String? = nil, timestamp: Date = Date()) {
        self.id = id
        self.kind = kind
        self.message = message
        self.timestamp = timestamp
    }
}

nonisolated struct ACEvalUsageRecord: Codable, Hashable, Identifiable, Sendable {
    var id: UUID
    var appName: String
    var seconds: Double

    init(id: UUID = UUID(), appName: String = "", seconds: Double = 0) {
        self.id = id
        self.appName = appName
        self.seconds = seconds
    }
}

nonisolated struct ACEvalHeuristics: Codable, Hashable, Sendable {
    var clearlyProductive: Bool
    var browser: Bool
    var helpfulWindowTitle: Bool
    var periodicVisualReason: String?
    var titleRelatesToDeclaredFocus: Bool?

    init(
        clearlyProductive: Bool = false,
        browser: Bool = false,
        helpfulWindowTitle: Bool = true,
        periodicVisualReason: String? = nil,
        titleRelatesToDeclaredFocus: Bool? = nil
    ) {
        self.clearlyProductive = clearlyProductive
        self.browser = browser
        self.helpfulWindowTitle = helpfulWindowTitle
        self.periodicVisualReason = periodicVisualReason
        self.titleRelatesToDeclaredFocus = titleRelatesToDeclaredFocus
    }
}

nonisolated struct ACEvalDistraction: Codable, Hashable, Sendable {
    var stableSince: Date?
    var lastAssessment: ModelAssessment?
    var consecutiveDistractedCount: Int
    var nextEvaluationAt: Date?
}

nonisolated struct ACEvalActiveProfile: Codable, Hashable, Sendable {
    var id: String
    var name: String
    var isDefault: Bool
    var description: String?
    var activatedAt: Date?
    var expiresAt: Date?
}

nonisolated struct ACEvalChatContext: Codable, Hashable, Sendable {
    var frontmostAppName: String
    var frontmostWindowTitle: String?
    var idleSeconds: Double
    var timestamp: Date
    var recentSwitches: [ACEvalSwitchRecord]
    var usage: [ACEvalUsageRecord]
}

nonisolated struct ACEvalChatMessage: Codable, Hashable, Identifiable, Sendable {
    var id: UUID
    var role: String
    var text: String
    var timestamp: Date

    init(id: UUID = UUID(), role: String, text: String, timestamp: Date = Date()) {
        self.id = id
        self.role = role
        self.text = text
        self.timestamp = timestamp
    }
}

nonisolated struct ACEvalFrontmostContext: Codable, Hashable, Sendable {
    var bundleIdentifier: String?
    var appName: String
    var windowTitle: String?
}

nonisolated struct ACEvalProfileSummary: Codable, Hashable, Sendable {
    var id: String
    var name: String
    var description: String?
    var isDefault: Bool
}

nonisolated struct ACEvalManifest: Codable, Hashable, Sendable {
    var version: Int
    var generatedAt: Date
    var caseCount: Int
    var cases: [ACEvalManifestEntry]
}

nonisolated struct ACEvalManifestEntry: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var name: String
    var kind: ACEvalKind
    var importance: ACEvalImportance
    var categories: [String]
    var sourceEpisodeID: String?
    var appName: String
    var bundleIdentifier: String?
    var windowTitle: String?
    var hasScreenshot: Bool
    var expectedOutcomeSummary: String
    var recommendedBackend: ACEvalRecommendedBackend
    var updatedAt: Date
}

private extension String {
    nonisolated func matchesEvalString(_ candidate: String?) -> Bool {
        let expected = trimmingCharacters(in: .whitespacesAndNewlines)
        guard !expected.isEmpty else { return true }
        let actual = candidate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return actual.compare(expected, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
    }
}

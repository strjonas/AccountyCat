//
//  ACModels.swift
//  AC
//
//  Created by Codex on 12.04.26.
//

import Foundation

enum PermissionState: String, Codable, Sendable {
    case unknown
    case granted
    case denied
}

struct PermissionsSnapshot: Codable, Sendable {
    var screenRecording: PermissionState = .unknown
    var accessibility: PermissionState = .unknown

    var isReady: Bool {
        screenRecording == .granted && accessibility == .granted
    }
}

enum SetupStatus: String, Codable, Sendable {
    case checking
    case needsPermissions
    case needsRuntime
    case blocked
    case installing
    case ready
    case failed
}

typealias MonitoringVerdict = ModelAssessment

struct LLMDecision: Codable, Sendable, Equatable {
    var assessment: ModelAssessment
    var suggestedAction: ModelSuggestedAction
    var confidence: Double?
    var reasonTags: [String]
    var nudge: String?
    var abstainReason: String?

    var verdict: MonitoringVerdict {
        assessment
    }

    var parsedRecord: ModelOutputParsedRecord {
        ModelOutputParsedRecord(
            assessment: assessment,
            suggestedAction: suggestedAction,
            confidence: confidence,
            reasonTags: reasonTags,
            nudge: nudge,
            abstainReason: abstainReason
        )
    }

    static let unclear = LLMDecision(
        assessment: .unclear,
        suggestedAction: .abstain,
        confidence: nil,
        reasonTags: [],
        nudge: nil,
        abstainReason: "no_usable_decision"
    )
}

enum CompanionAction: Equatable, Sendable {
    case none
    case showNudge(String)
    case showOverlay
}

enum CompanionMood: String, Sendable {
    case setup
    case idle
    case watching
    case nudging
    case escalated
    case paused
}

struct RescueAppTarget: Codable, Sendable {
    var displayName: String
    var bundleIdentifier: String
    var applicationPath: String?

    static let xcode = RescueAppTarget(
        displayName: "Xcode",
        bundleIdentifier: "com.apple.dt.Xcode",
        applicationPath: nil
    )
}

struct AppSwitchRecord: Codable, Hashable, Sendable {
    var fromAppName: String?
    var toAppName: String
    var toWindowTitle: String?
    var timestamp: Date
}

struct AppUsageRecord: Codable, Hashable, Sendable {
    var appName: String
    var seconds: TimeInterval
}

enum ActionKind: String, Codable, Sendable {
    case nudge
    case overlay
    case backToWork
    case dismissOverlay
}

struct ActionRecord: Codable, Hashable, Sendable {
    var kind: ActionKind
    var message: String?
    var timestamp: Date
}

enum ChatRole: String, Codable, Sendable {
    case system
    case user
    case assistant
}

struct ChatMessage: Identifiable, Hashable, Codable, Sendable {
    let id: UUID
    var role: ChatRole
    var text: String
    var timestamp: Date

    init(
        id: UUID = UUID(),
        role: ChatRole,
        text: String,
        timestamp: Date = Date()
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.timestamp = timestamp
    }
}

struct AppSnapshot: Codable, Sendable {
    var bundleIdentifier: String?
    var appName: String
    var windowTitle: String?
    var recentSwitches: [AppSwitchRecord]
    var perAppDurations: [AppUsageRecord]
    var screenshotArtifact: ArtifactRef
    var screenshotThumbnail: ArtifactRef?
    var screenshotPath: String
    var idle: Bool
    var timestamp: Date
}

struct ChatContext: Sendable {
    var frontmostAppName: String
    var frontmostWindowTitle: String?
    var idleSeconds: TimeInterval
    var timestamp: Date
    var recentSwitches: [AppSwitchRecord]
    var perAppDurations: [AppUsageRecord]
}

struct FrontmostContext: Hashable, Sendable {
    var bundleIdentifier: String?
    var appName: String
    var windowTitle: String?

    var contextKey: String {
        [bundleIdentifier ?? "unknown", windowTitle?.normalizedForContextKey ?? ""]
            .joined(separator: "|")
    }
}

struct DistractionMetadata: Codable, Sendable, Equatable {
    var contextKey: String?
    var stableSince: Date?
    var lastAssessment: MonitoringVerdict?
    var consecutiveDistractedCount: Int = 0
    var nextEvaluationAt: Date?

    enum CodingKeys: String, CodingKey {
        case contextKey
        case stableSince
        case lastAssessment
        case lastVerdict
        case consecutiveDistractedCount
        case nextEvaluationAt
    }

    init(
        contextKey: String? = nil,
        stableSince: Date? = nil,
        lastAssessment: MonitoringVerdict? = nil,
        consecutiveDistractedCount: Int = 0,
        nextEvaluationAt: Date? = nil
    ) {
        self.contextKey = contextKey
        self.stableSince = stableSince
        self.lastAssessment = lastAssessment
        self.consecutiveDistractedCount = consecutiveDistractedCount
        self.nextEvaluationAt = nextEvaluationAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        contextKey = try container.decodeIfPresent(String.self, forKey: .contextKey)
        stableSince = try container.decodeIfPresent(Date.self, forKey: .stableSince)
        let decodedAssessment = try container.decodeIfPresent(MonitoringVerdict.self, forKey: .lastAssessment)
        let legacyAssessment = try container.decodeIfPresent(MonitoringVerdict.self, forKey: .lastVerdict)
        lastAssessment = decodedAssessment ?? legacyAssessment
        consecutiveDistractedCount = try container.decodeIfPresent(Int.self, forKey: .consecutiveDistractedCount) ?? 0
        nextEvaluationAt = try container.decodeIfPresent(Date.self, forKey: .nextEvaluationAt)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(contextKey, forKey: .contextKey)
        try container.encodeIfPresent(stableSince, forKey: .stableSince)
        try container.encodeIfPresent(lastAssessment, forKey: .lastAssessment)
        try container.encode(consecutiveDistractedCount, forKey: .consecutiveDistractedCount)
        try container.encodeIfPresent(nextEvaluationAt, forKey: .nextEvaluationAt)
    }
}

struct ACState: Codable, Sendable {
    static let defaultGoalsText = """
    I want to spend most of my time studying, building, and gaining experience. Short social check-ins are okay, but not long scrolling sessions.
    """

    var permissions = PermissionsSnapshot()
    var setupStatus: SetupStatus = .checking
    var isPaused = false
    var debugMode = true
    var goalsText = Self.defaultGoalsText
    var rescueApp = RescueAppTarget.xcode
    var runtimePathOverride: String?
    var monitoringConfiguration = MonitoringConfiguration()
    var algorithmState = AlgorithmStateEnvelope()
    var recentActions: [ActionRecord] = []
    var recentSwitches: [AppSwitchRecord] = []
    var usageByDay: [String: [String: TimeInterval]] = [:]
    /// Persistent memory of user preferences, rules, and important context.
    var memory: String = ""
    /// Persistent chat history excluding the synthetic system opener.
    var chatHistory: [ChatMessage] = []

    enum CodingKeys: String, CodingKey {
        case permissions
        case setupStatus
        case isPaused
        case debugMode
        case goalsText
        case rescueApp
        case runtimePathOverride
        case monitoringConfiguration
        case algorithmState
        case recentActions
        case recentSwitches
        case usageByDay
        case distraction
        case memory
        case chatHistory
    }

    /// Telemetry-friendly accessor for the active algorithm's distraction metadata.
    /// Only the LLM algorithm maintains a DistractionLadder; the bandit returns an
    /// empty record (its anti-spam is timestamp-based, not ladder-based).
    var distraction: DistractionMetadata {
        get {
            switch monitoringConfiguration.algorithmID {
            case MonitoringConfiguration.defaultAlgorithmID:
                return algorithmState.llmFocus.distraction
            case MonitoringConfiguration.banditAlgorithmID:
                return DistractionMetadata()
            default:
                return algorithmState.llmFocus.distraction
            }
        }
        set {
            switch monitoringConfiguration.algorithmID {
            case MonitoringConfiguration.defaultAlgorithmID:
                algorithmState.llmFocus.distraction = newValue
            case MonitoringConfiguration.banditAlgorithmID:
                break
            default:
                algorithmState.llmFocus.distraction = newValue
            }
        }
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        permissions = try container.decodeIfPresent(PermissionsSnapshot.self, forKey: .permissions) ?? PermissionsSnapshot()
        setupStatus = try container.decodeIfPresent(SetupStatus.self, forKey: .setupStatus) ?? .checking
        isPaused = try container.decodeIfPresent(Bool.self, forKey: .isPaused) ?? false
        debugMode = try container.decodeIfPresent(Bool.self, forKey: .debugMode) ?? true
        goalsText = try container.decodeIfPresent(String.self, forKey: .goalsText) ?? Self.defaultGoalsText
        rescueApp = try container.decodeIfPresent(RescueAppTarget.self, forKey: .rescueApp) ?? .xcode
        runtimePathOverride = try container.decodeIfPresent(String.self, forKey: .runtimePathOverride)
        monitoringConfiguration = try container.decodeIfPresent(MonitoringConfiguration.self, forKey: .monitoringConfiguration) ?? MonitoringConfiguration()
        algorithmState = try container.decodeIfPresent(AlgorithmStateEnvelope.self, forKey: .algorithmState) ?? AlgorithmStateEnvelope()
        recentActions = try container.decodeIfPresent([ActionRecord].self, forKey: .recentActions) ?? []
        recentSwitches = try container.decodeIfPresent([AppSwitchRecord].self, forKey: .recentSwitches) ?? []
        usageByDay = try container.decodeIfPresent([String: [String: TimeInterval]].self, forKey: .usageByDay) ?? [:]
        let legacyDistraction = try container.decodeIfPresent(DistractionMetadata.self, forKey: .distraction)
        if algorithmState.llmFocus.distraction == DistractionMetadata(),
           let legacyDistraction {
            algorithmState.llmFocus.distraction = legacyDistraction
        }
        memory = try container.decodeIfPresent(String.self, forKey: .memory) ?? ""
        chatHistory = try container.decodeIfPresent([ChatMessage].self, forKey: .chatHistory) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(permissions, forKey: .permissions)
        try container.encode(setupStatus, forKey: .setupStatus)
        try container.encode(isPaused, forKey: .isPaused)
        try container.encode(debugMode, forKey: .debugMode)
        try container.encode(goalsText, forKey: .goalsText)
        try container.encode(rescueApp, forKey: .rescueApp)
        try container.encodeIfPresent(runtimePathOverride, forKey: .runtimePathOverride)
        try container.encode(monitoringConfiguration, forKey: .monitoringConfiguration)
        try container.encode(algorithmState, forKey: .algorithmState)
        try container.encode(recentActions, forKey: .recentActions)
        try container.encode(recentSwitches, forKey: .recentSwitches)
        try container.encode(usageByDay, forKey: .usageByDay)
        try container.encode(distraction, forKey: .distraction)
        try container.encode(memory, forKey: .memory)
        try container.encode(chatHistory, forKey: .chatHistory)
    }

    mutating func resetAlgorithmProfile() {
        goalsText = Self.defaultGoalsText
        recentActions = []
        recentSwitches = []
        usageByDay = [:]
        algorithmState = AlgorithmStateEnvelope()
        memory = ""
        chatHistory = []
    }
}

struct RuntimeDiagnostics: Sendable {
    var runtimePath: String
    var runtimeDirectory: String
    var runtimePresent: Bool
    var modelCachePath: String
    var modelCachePresent: Bool
    var missingTools: [String]

    var isReady: Bool {
        runtimePresent && modelCachePresent && missingTools.isEmpty
    }

    var canInstall: Bool {
        missingTools.isEmpty
    }
}

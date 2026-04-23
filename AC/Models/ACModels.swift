//
//  ACModels.swift
//  AC
//
//  Created by Codex on 12.04.26.
//

import Foundation

// MARK: - AC Character

/// Selectable companion personality. Stored in ACState and persisted across launches.
/// The character injects a 1–2 sentence style prefix into every system prompt;
/// the companion always identifies itself as "AccountyCat" / "AC" regardless of character.
enum ACCharacter: String, Codable, CaseIterable, Sendable {
    case mochi  // default — warm, cozy
    case nova   // sharp, energetic
    case sage   // calm, minimal

    var displayName: String {
        switch self {
        case .mochi: return "Mochi"
        case .nova:  return "Nova"
        case .sage:  return "Sage"
        }
    }

    var tagline: String {
        switch self {
        case .mochi: return "Your cozy focus buddy"
        case .nova:  return "Your sharp-minded co-pilot"
        case .sage:  return "Your calm inner guide"
        }
    }

    /// 1–2 sentence style prefix prepended to every system prompt.
    /// The companion still calls itself AccountyCat / AC in all conversations.
    nonisolated var personalityPrefix: String {
        switch self {
        case .mochi:
            return "You are AccountyCat (AC), the user's warm and cozy focus companion. Check in gently like a caring friend who's always in their corner."
        case .nova:
            return "You are AccountyCat (AC), the user's sharp-minded, energetic focus co-pilot. Nudge with confident, punchy energy — you believe they can do it."
        case .sage:
            return "You are AccountyCat (AC), the user's calm and grounded focus guide. Use spacious, mindful words that invite reflection without pressure."
        }
    }
}

enum ACBuild {
    /// True for Debug configuration builds; false for Release.
    static let isDebug: Bool = {
        #if DEBUG
        true
        #else
        false
        #endif
    }()
}

enum TelemetryPersistencePolicy {
    static func storesVerboseTelemetry(debugMode: Bool) -> Bool {
        ACBuild.isDebug && debugMode
    }
}

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

    func satisfies(_ requirements: MonitoringPermissionRequirements) -> Bool {
        let accessibilityReady = !requirements.requiresAccessibility || accessibility == .granted
        let screenReady = !requirements.requiresScreenRecording || screenRecording == .granted
        return accessibilityReady && screenReady
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
    case showOverlay(OverlayPresentation)
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

struct OverlayPresentation: Codable, Hashable, Equatable, Sendable {
    var headline: String
    var body: String
    var prompt: String?
    var appName: String
    var evaluationID: String?
    var submitButtonTitle: String
    var secondaryButtonTitle: String
}

enum AppealReviewDecision: String, Codable, Sendable {
    case allow
    case deny
    case deferDecision = "defer"
}

struct AppealReviewResult: Codable, Hashable, Equatable, Sendable {
    var decision: AppealReviewDecision
    var message: String
}

struct MonitoringAppealSession: Codable, Hashable, Equatable, Sendable {
    var evaluationID: String
    var contextKey: String
    var appName: String
    var prompt: String
    var createdAt: Date
    var lastSubmittedAt: Date?
    var lastResult: AppealReviewResult?
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

    nonisolated init(
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

    nonisolated var promptTimestampLabel: String {
        PromptTimestampFormatting.absoluteLabel(for: timestamp)
    }

    nonisolated var promptStampedLine: String? {
        let cleaned = text.cleanedSingleLine
        guard !cleaned.isEmpty else { return nil }
        return "[\(promptTimestampLabel)] \(cleaned)"
    }
}

struct AppSnapshot: Codable, Sendable {
    var bundleIdentifier: String?
    var appName: String
    var windowTitle: String?
    var recentSwitches: [AppSwitchRecord]
    var perAppDurations: [AppUsageRecord]
    var screenshotArtifact: ArtifactRef?
    var screenshotThumbnail: ArtifactRef?
    var screenshotPath: String?
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

struct FrontmostContext: Hashable, Sendable, Codable {
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

    var character: ACCharacter = .mochi
    var permissions = PermissionsSnapshot()
    var setupStatus: SetupStatus = .checking
    var isPaused = false
    var debugMode = ACBuild.isDebug
    var goalsText = Self.defaultGoalsText
    var rescueApp = RescueAppTarget.xcode
    var runtimePathOverride: String?
    var monitoringConfiguration = MonitoringConfiguration()
    var algorithmState = AlgorithmStateEnvelope()
    var hasMigratedPolicyAlgorithmDefault = false
    var recentActions: [ActionRecord] = []
    var recentSwitches: [AppSwitchRecord] = []
    var usageByDay: [String: [String: TimeInterval]] = [:]
    /// Timestamped persistent memory of user preferences, rules, and important context.
    /// The LLM decides what goes in here (via chat-reply memory_update) and consolidates
    /// when the list grows or entries go stale. Code does not filter, score, or rewrite.
    var memoryEntries: [MemoryEntry] = []
    /// Last time the consolidation pass ran, so we can throttle it (at most once/day
    /// unless the list exceeds the soft cap).
    var lastMemoryConsolidationAt: Date?
    /// Structured monitoring rules that the model can update deterministically.
    var policyMemory = PolicyMemory()
    /// Persistent chat history excluding the synthetic system opener.
    var chatHistory: [ChatMessage] = []

    enum CodingKeys: String, CodingKey {
        case character
        case permissions
        case setupStatus
        case isPaused
        case debugMode
        case goalsText
        case rescueApp
        case runtimePathOverride
        case monitoringConfiguration
        case algorithmState
        case hasMigratedPolicyAlgorithmDefault
        case recentActions
        case recentSwitches
        case usageByDay
        case distraction
        case memory
        case memoryEntries
        case lastMemoryConsolidationAt
        case policyMemory
        case chatHistory
    }


    /// Telemetry-friendly accessor for the active algorithm's distraction metadata.
    /// Only the LLM algorithm maintains a DistractionLadder; the bandit returns an
    /// empty record (its anti-spam is timestamp-based, not ladder-based).
    var distraction: DistractionMetadata {
        get {
            switch MonitoringConfiguration.normalizedAlgorithmID(monitoringConfiguration.algorithmID) {
            case MonitoringConfiguration.legacyLLMFocusAlgorithmID:
                return algorithmState.llmFocus.distraction
            case MonitoringConfiguration.currentLLMMonitorAlgorithmID:
                return algorithmState.llmPolicy.distraction
            case MonitoringConfiguration.banditAlgorithmID:
                return DistractionMetadata()
            default:
                return algorithmState.llmPolicy.distraction
            }
        }
        set {
            switch MonitoringConfiguration.normalizedAlgorithmID(monitoringConfiguration.algorithmID) {
            case MonitoringConfiguration.legacyLLMFocusAlgorithmID:
                algorithmState.llmFocus.distraction = newValue
            case MonitoringConfiguration.currentLLMMonitorAlgorithmID:
                algorithmState.llmPolicy.distraction = newValue
            case MonitoringConfiguration.banditAlgorithmID:
                break
            default:
                algorithmState.llmPolicy.distraction = newValue
            }
        }
    }

    init() {}

    init(from decoder: Decoder) throws {
        struct LegacyChatMessage: Decodable {
            var id: UUID
            var role: ChatRole
            var text: String
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        character = try container.decodeIfPresent(ACCharacter.self, forKey: .character) ?? .mochi
        permissions = try container.decodeIfPresent(PermissionsSnapshot.self, forKey: .permissions) ?? PermissionsSnapshot()
        setupStatus = try container.decodeIfPresent(SetupStatus.self, forKey: .setupStatus) ?? .checking
        isPaused = try container.decodeIfPresent(Bool.self, forKey: .isPaused) ?? false
        debugMode = try container.decodeIfPresent(Bool.self, forKey: .debugMode) ?? ACBuild.isDebug
        goalsText = try container.decodeIfPresent(String.self, forKey: .goalsText) ?? Self.defaultGoalsText
        rescueApp = try container.decodeIfPresent(RescueAppTarget.self, forKey: .rescueApp) ?? .xcode
        runtimePathOverride = try container.decodeIfPresent(String.self, forKey: .runtimePathOverride)
        monitoringConfiguration = try container.decodeIfPresent(MonitoringConfiguration.self, forKey: .monitoringConfiguration) ?? MonitoringConfiguration()
        algorithmState = try container.decodeIfPresent(AlgorithmStateEnvelope.self, forKey: .algorithmState) ?? AlgorithmStateEnvelope()
        hasMigratedPolicyAlgorithmDefault = try container.decodeIfPresent(Bool.self, forKey: .hasMigratedPolicyAlgorithmDefault) ?? false
        recentActions = try container.decodeIfPresent([ActionRecord].self, forKey: .recentActions) ?? []
        recentSwitches = try container.decodeIfPresent([AppSwitchRecord].self, forKey: .recentSwitches) ?? []
        usageByDay = try container.decodeIfPresent([String: [String: TimeInterval]].self, forKey: .usageByDay) ?? [:]
        let legacyDistraction = try container.decodeIfPresent(DistractionMetadata.self, forKey: .distraction)
        if algorithmState.llmFocus.distraction == DistractionMetadata(),
           let legacyDistraction {
            algorithmState.llmFocus.distraction = legacyDistraction
        }
        if let decodedEntries = try container.decodeIfPresent([MemoryEntry].self, forKey: .memoryEntries) {
            memoryEntries = decodedEntries
        } else if let legacy = try container.decodeIfPresent(String.self, forKey: .memory), !legacy.isEmpty {
            // Legacy string memory → one entry per non-empty line, backdated 1 minute apart so
            // relative order is preserved. The next consolidation pass will clean up timestamps.
            let now = Date()
            let lines = legacy.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            memoryEntries = lines.enumerated().map { index, text in
                MemoryEntry(
                    createdAt: now.addingTimeInterval(-Double(lines.count - index) * 60),
                    text: text
                )
            }
        } else {
            memoryEntries = []
        }
        lastMemoryConsolidationAt = try container.decodeIfPresent(Date.self, forKey: .lastMemoryConsolidationAt)
        policyMemory = try container.decodeIfPresent(PolicyMemory.self, forKey: .policyMemory) ?? PolicyMemory()
        do {
            chatHistory = try container.decodeIfPresent([ChatMessage].self, forKey: .chatHistory) ?? []
        } catch {
            let legacyHistory = (try? container.decode([LegacyChatMessage].self, forKey: .chatHistory)) ?? []
            if legacyHistory.isEmpty {
                chatHistory = []
            } else {
                let now = Date()
                chatHistory = legacyHistory.enumerated().map { index, message in
                    ChatMessage(
                        id: message.id,
                        role: message.role,
                        text: message.text,
                        timestamp: now.addingTimeInterval(-Double(legacyHistory.count - index) * 60)
                    )
                }
            }
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(character, forKey: .character)
        try container.encode(permissions, forKey: .permissions)
        try container.encode(setupStatus, forKey: .setupStatus)
        try container.encode(isPaused, forKey: .isPaused)
        try container.encode(debugMode, forKey: .debugMode)
        try container.encode(goalsText, forKey: .goalsText)
        try container.encode(rescueApp, forKey: .rescueApp)
        try container.encodeIfPresent(runtimePathOverride, forKey: .runtimePathOverride)
        try container.encode(monitoringConfiguration, forKey: .monitoringConfiguration)
        try container.encode(algorithmState, forKey: .algorithmState)
        try container.encode(hasMigratedPolicyAlgorithmDefault, forKey: .hasMigratedPolicyAlgorithmDefault)
        try container.encode(recentActions, forKey: .recentActions)
        try container.encode(recentSwitches, forKey: .recentSwitches)
        try container.encode(usageByDay, forKey: .usageByDay)
        try container.encode(distraction, forKey: .distraction)
        try container.encode(memoryEntries, forKey: .memoryEntries)
        try container.encodeIfPresent(lastMemoryConsolidationAt, forKey: .lastMemoryConsolidationAt)
        try container.encode(policyMemory, forKey: .policyMemory)
        try container.encode(chatHistory, forKey: .chatHistory)
    }

    mutating func resetAlgorithmProfile() {
        goalsText = Self.defaultGoalsText
        recentActions = []
        recentSwitches = []
        usageByDay = [:]
        monitoringConfiguration.algorithmID = MonitoringConfiguration.defaultAlgorithmID
        monitoringConfiguration.promptProfileID = MonitoringConfiguration.defaultPromptProfileID
        monitoringConfiguration.pipelineProfileID = MonitoringConfiguration.defaultPipelineProfileID
        monitoringConfiguration.runtimeProfileID = MonitoringConfiguration.defaultRuntimeProfileID
        algorithmState = AlgorithmStateEnvelope()
        hasMigratedPolicyAlgorithmDefault = true
        memoryEntries = []
        lastMemoryConsolidationAt = nil
        policyMemory = PolicyMemory()
        chatHistory = []
    }

    // MARK: - Memory helpers

    /// Soft cap: when exceeded, the consolidation pass is scheduled.
    /// The cap is intentionally generous — AC should compress intelligently, not truncate mechanically.
    static let memorySoftLineCap = 15

    /// Render the stored memory for inclusion in an LLM prompt. Most-recent-N entries up to
    /// the byte budget, chronological (oldest first, newest last). Empty string if no memory.
    func memoryForPrompt(
        now: Date = Date(),
        maxLines: Int = MonitoringPromptContextBudget.freeFormMemoryLines,
        maxCharacters: Int = MonitoringPromptContextBudget.freeFormMemoryCharacters
    ) -> String {
        MemoryRendering.renderForPrompt(
            entries: memoryEntries,
            now: now,
            maxLines: maxLines,
            maxCharacters: maxCharacters
        )
    }

    /// Full, human-readable memory for the UI. Newest first.
    func memoryForDisplay(now: Date = Date()) -> String {
        MemoryRendering.renderForDisplay(entries: memoryEntries, now: now)
    }

    /// True when the stored memory has grown past the soft cap and consolidation should run.
    var memoryExceedsSoftCap: Bool {
        memoryEntries.count > Self.memorySoftLineCap
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

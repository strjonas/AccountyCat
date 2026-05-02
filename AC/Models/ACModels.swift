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
            return "You are AC, the user's warm and cozy focus companion. Check in gently like a caring friend who's always in their corner."
        case .nova:
            return "You are AC, the user's sharp-minded, energetic focus co-pilot. Nudge with confident, punchy energy — you believe they can do it."
        case .sage:
            return "You are AC, the user's calm and grounded focus guide. Use spacious, mindful words that invite reflection without pressure."
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

enum LogLevel: String, CaseIterable, Codable {
    case error
    case standard
    case more
    case verbose

    var ordinal: Int {
        switch self {
        case .error: return 0
        case .standard: return 1
        case .more: return 2
        case .verbose: return 3
        }
    }

    var displayName: String {
        switch self {
        case .error: return "Errors Only"
        case .standard: return "Standard"
        case .more: return "More"
        case .verbose: return "Verbose"
        }
    }

    static var defaultForBuild: LogLevel {
        ACBuild.isDebug ? .standard : .error
    }
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
    /// Calendar permission is opt-in and never blocks core monitoring. It's
    /// tracked here only so the Settings UI can mirror the current grant state.
    var calendar: PermissionState = .unknown

    var isReady: Bool {
        screenRecording == .granted && accessibility == .granted
    }

    func satisfies(_ requirements: MonitoringPermissionRequirements) -> Bool {
        let accessibilityReady = !requirements.requiresAccessibility || accessibility == .granted
        let screenReady = !requirements.requiresScreenRecording || screenRecording == .granted
        return accessibilityReady && screenReady
    }

    enum CodingKeys: String, CodingKey {
        case screenRecording
        case accessibility
        case calendar
    }

    init(
        screenRecording: PermissionState = .unknown,
        accessibility: PermissionState = .unknown,
        calendar: PermissionState = .unknown
    ) {
        self.screenRecording = screenRecording
        self.accessibility = accessibility
        self.calendar = calendar
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        screenRecording = try container.decodeIfPresent(PermissionState.self, forKey: .screenRecording) ?? .unknown
        accessibility = try container.decodeIfPresent(PermissionState.self, forKey: .accessibility) ?? .unknown
        // Older persisted snapshots predate calendar support — default to
        // `.unknown` so the UI treats it as "not yet decided" rather than denied.
        calendar = try container.decodeIfPresent(PermissionState.self, forKey: .calendar) ?? .unknown
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
    var isHardEscalation: Bool {
        if case .showOverlay(let p) = self { return p.isHardEscalation }
        return false
    }
}

enum CompanionMood: String, Sendable {
    case setup
    case idle
    case watching
    case nudging
    case escalated
    case escalatedHard
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
    case autoMinimizeApp
    case minimizeApp
}

struct ActionRecord: Codable, Hashable, Sendable {
    var id: String?
    var kind: ActionKind
    var message: String?
    var timestamp: Date
    var evaluationID: String?
    var contextKey: String?
    var appName: String?
    var windowTitle: String?

    init(
        id: String? = nil,
        kind: ActionKind,
        message: String?,
        timestamp: Date,
        evaluationID: String? = nil,
        contextKey: String? = nil,
        appName: String? = nil,
        windowTitle: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.message = message
        self.timestamp = timestamp
        self.evaluationID = evaluationID
        self.contextKey = contextKey
        self.appName = appName
        self.windowTitle = windowTitle
    }
}

enum FocusSegmentAssessment: String, Codable, Sendable {
    case focused
    case distracted
    case unclear
    case idle

    init(distractionAssessment: ModelAssessment?) {
        switch distractionAssessment {
        case .focused:
            self = .focused
        case .distracted:
            self = .distracted
        case .unclear, .none:
            self = .unclear
        }
    }
}

struct FocusTimelineSegment: Codable, Hashable, Identifiable, Sendable {
    var id: UUID
    var startAt: Date
    var endAt: Date
    var appName: String
    var bundleIdentifier: String?
    var windowTitle: String?
    var assessment: FocusSegmentAssessment
    var driftScore: Double?
    var interventionID: String?

    init(
        id: UUID = UUID(),
        startAt: Date,
        endAt: Date,
        appName: String,
        bundleIdentifier: String?,
        windowTitle: String?,
        assessment: FocusSegmentAssessment,
        driftScore: Double? = nil,
        interventionID: String? = nil
    ) {
        self.id = id
        self.startAt = startAt
        self.endAt = endAt
        self.appName = appName
        self.bundleIdentifier = bundleIdentifier
        self.windowTitle = windowTitle
        self.assessment = assessment
        self.driftScore = driftScore
        self.interventionID = interventionID
    }
}

struct OverlayPresentation: Codable, Hashable, Equatable, Sendable {
    var headline: String
    var body: String
    var prompt: String?
    var appName: String
    var evaluationID: String?
    var submitButtonTitle: String
    var secondaryButtonTitle: String
    var isHardEscalation: Bool = false
}

struct ActiveEscalation: Codable, Hashable, Equatable, Sendable {
    var appName: String
    var bundleIdentifier: String?
    var evaluationID: String
    var startedAt: Date
    var timesMinimized: Int = 0
    var lastMinimizedAt: Date?
    var lastAppealText: String?
    var lastAppealResult: AppealReviewDecision?
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

/// Structured payload for a `.suggestion` chat message. Today: profile-switch suggestions
/// from the calendar pipeline.
struct ChatSuggestionData: Codable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable {
        case calendarProfileSuggest = "calendar_profile_suggest"
    }

    var kind: Kind
    /// Profile id to activate (when matching an existing profile). Mutually exclusive with
    /// `proposedProfileName` for create-and-activate suggestions.
    var profileID: String?
    /// Name for a new profile to create. Mutually exclusive with `profileID`.
    var proposedProfileName: String?
    var proposedProfileDescription: String?
    /// Suggested duration in minutes. Optional; AppController picks a default if nil.
    var durationMinutes: Int?
    /// Calendar event id we're acting on, so the same event isn't re-suggested.
    var calendarEventID: String?
    /// True when the user has actioned the suggestion (Accept/Dismiss); UI hides buttons.
    var resolved: Bool = false
    /// Final action chosen by the user, for telemetry.
    var resolution: Resolution?

    enum Resolution: String, Codable, Sendable {
        case accepted
        case dismissed
    }
}

enum ChatMessageStyle: String, Codable, Sendable {
    case standard
    case nudge
    case celebration
    /// Inline calendar/profile suggestion — renders Accept/Dismiss action buttons.
    case suggestion
}

/// Whether a chat message is allowed to surface immediately or should sit quietly until the
/// user comes to it.
enum ChatInterruptionPolicy: String, Codable, Sendable {
    /// Render immediately (default for direct user/assistant exchanges and nudge orb pops).
    case immediate
    /// Queue silently. Marked as unread; revealed when the user opens the popover, becomes
    /// idle, or the active named profile expires.
    case deferred
}

struct ChatMessage: Identifiable, Hashable, Codable, Sendable {
    let id: UUID
    var role: ChatRole
    var text: String
    var timestamp: Date
    var style: ChatMessageStyle
    var interruptionPolicy: ChatInterruptionPolicy
    /// True until the user opens the popover (or otherwise marks it read).
    var isUnread: Bool
    /// Optional structured payload for suggestion messages (e.g. calendar-suggested profile).
    /// Decoded as JSON keys when present, kept opaque to the rest of the system otherwise.
    var suggestionData: ChatSuggestionData?

    enum CodingKeys: String, CodingKey {
        case id
        case role
        case text
        case timestamp
        case style
        case interruptionPolicy
        case isUnread
        case suggestionData
    }

    nonisolated init(
        id: UUID = UUID(),
        role: ChatRole,
        text: String,
        timestamp: Date = Date(),
        style: ChatMessageStyle = .standard,
        interruptionPolicy: ChatInterruptionPolicy = .immediate,
        isUnread: Bool = false,
        suggestionData: ChatSuggestionData? = nil
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.timestamp = timestamp
        self.style = style
        self.interruptionPolicy = interruptionPolicy
        self.isUnread = isUnread || (interruptionPolicy == .deferred && role == .assistant)
        self.suggestionData = suggestionData
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        role = try container.decode(ChatRole.self, forKey: .role)
        text = try container.decode(String.self, forKey: .text)
        timestamp = try container.decodeIfPresent(Date.self, forKey: .timestamp) ?? Date()
        style = try container.decodeIfPresent(ChatMessageStyle.self, forKey: .style) ?? .standard
        interruptionPolicy = try container.decodeIfPresent(ChatInterruptionPolicy.self, forKey: .interruptionPolicy) ?? .immediate
        isUnread = try container.decodeIfPresent(Bool.self, forKey: .isUnread) ?? false
        suggestionData = try container.decodeIfPresent(ChatSuggestionData.self, forKey: .suggestionData)
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

    nonisolated var contextKey: String {
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
    var aiTier: AITier = .balanced
    var permissions = PermissionsSnapshot()
    var setupStatus: SetupStatus = .checking
    var isPaused = false
    var debugMode = ACBuild.isDebug
    var minimumLogLevel = LogLevel.defaultForBuild
    var goalsText = Self.defaultGoalsText
    var rescueApp = RescueAppTarget.xcode
    var runtimePathOverride: String?
    var monitoringConfiguration = MonitoringConfiguration()
    var algorithmState = AlgorithmStateEnvelope()
    var hasMigratedPolicyAlgorithmDefault = false
    var recentActions: [ActionRecord] = []
    var recentSwitches: [AppSwitchRecord] = []
    var usageByDay: [String: [String: TimeInterval]] = [:]
    var focusSegments: [FocusTimelineSegment] = []
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
    /// Hidden-gem feature: when true, AC reads the user's current calendar
    /// event (via EventKit, local-only) and feeds it into the decision + nudge
    /// prompts as a soft hint about intent. Off by default — surfaced in
    /// Settings, not in onboarding. Flipping it on triggers the system
    /// calendar permission prompt (see AppController.setCalendarIntelligence).
    var calendarIntelligenceEnabled: Bool = false
    /// Multi-select of which calendars AC is allowed to read. Empty set means
    /// "all calendars" (the simple default right after opting in). The user
    /// can narrow the list from the picker to exclude noisy shared calendars.
    /// Stored as an array on disk for stable Codable encoding.
    var enabledCalendarIdentifiers: Set<String> = []
    /// Stored focus profiles (default + up to N named). Default is always present.
    /// LRU eviction by `lastUsedAt` enforces `FocusProfile.maximumProfileCount`.
    var profiles: [FocusProfile] = [FocusProfile.makeDefault()]
    /// Id of the currently active profile. Defaults to `general`.
    var activeProfileID: String = PolicyRule.defaultProfileID
    /// Timestamp of the last forced full-screen screenshot (safety net when using active-window mode).
    var lastFullScreenCheckAt: Date?
    /// Active hard escalation: when set, the brain auto-minimizes the named app if the user re-opens it.
    var hardEscalation: ActiveEscalation?

    private static func sanitizeRuntimePathOverride(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let tempPrefix = FileManager.default.temporaryDirectory.path
        if trimmed.hasPrefix(tempPrefix) || trimmed.contains("ac-fake-runtime") {
            return nil
        }
        return trimmed
    }

    enum CodingKeys: String, CodingKey {
        case character
        case aiTier
        case permissions
        case setupStatus
        case isPaused
        case debugMode
        case minimumLogLevel
        case goalsText
        case rescueApp
        case runtimePathOverride
        case monitoringConfiguration
        case algorithmState
        case hasMigratedPolicyAlgorithmDefault
        case recentActions
        case recentSwitches
        case usageByDay
        case focusSegments
        case distraction
        case memory
        case memoryEntries
        case lastMemoryConsolidationAt
        case policyMemory
        case chatHistory
        case calendarIntelligenceEnabled
        case enabledCalendarIdentifiers
        case profiles
        case activeProfileID
        case lastFullScreenCheckAt
        case hardEscalation
    }


    /// Telemetry-friendly accessor for the active monitor's distraction metadata.
    var distraction: DistractionMetadata {
        get {
            algorithmState.llmPolicy.distraction
        }
        set {
            algorithmState.llmPolicy.distraction = newValue
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
        aiTier = try container.decodeIfPresent(AITier.self, forKey: .aiTier) ?? .balanced
        permissions = try container.decodeIfPresent(PermissionsSnapshot.self, forKey: .permissions) ?? PermissionsSnapshot()
        setupStatus = try container.decodeIfPresent(SetupStatus.self, forKey: .setupStatus) ?? .checking
        isPaused = try container.decodeIfPresent(Bool.self, forKey: .isPaused) ?? false
        debugMode = try container.decodeIfPresent(Bool.self, forKey: .debugMode) ?? ACBuild.isDebug
        minimumLogLevel = try container.decodeIfPresent(LogLevel.self, forKey: .minimumLogLevel) ?? LogLevel.defaultForBuild
        goalsText = try container.decodeIfPresent(String.self, forKey: .goalsText) ?? Self.defaultGoalsText
        rescueApp = try container.decodeIfPresent(RescueAppTarget.self, forKey: .rescueApp) ?? .xcode
        let decodedOverride = try container.decodeIfPresent(String.self, forKey: .runtimePathOverride)
        runtimePathOverride = Self.sanitizeRuntimePathOverride(decodedOverride)
        monitoringConfiguration = try container.decodeIfPresent(MonitoringConfiguration.self, forKey: .monitoringConfiguration) ?? MonitoringConfiguration()
        algorithmState = try container.decodeIfPresent(AlgorithmStateEnvelope.self, forKey: .algorithmState) ?? AlgorithmStateEnvelope()
        hasMigratedPolicyAlgorithmDefault = try container.decodeIfPresent(Bool.self, forKey: .hasMigratedPolicyAlgorithmDefault) ?? false
        recentActions = try container.decodeIfPresent([ActionRecord].self, forKey: .recentActions) ?? []
        recentSwitches = try container.decodeIfPresent([AppSwitchRecord].self, forKey: .recentSwitches) ?? []
        usageByDay = try container.decodeIfPresent([String: [String: TimeInterval]].self, forKey: .usageByDay) ?? [:]
        focusSegments = try container.decodeIfPresent([FocusTimelineSegment].self, forKey: .focusSegments) ?? []
        let legacyDistraction = try container.decodeIfPresent(DistractionMetadata.self, forKey: .distraction)
        if algorithmState.llmPolicy.distraction == DistractionMetadata(),
           let legacyDistraction {
            algorithmState.llmPolicy.distraction = legacyDistraction
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
        calendarIntelligenceEnabled = try container.decodeIfPresent(Bool.self, forKey: .calendarIntelligenceEnabled) ?? false
        if let identifiers = try container.decodeIfPresent([String].self, forKey: .enabledCalendarIdentifiers) {
            enabledCalendarIdentifiers = Set(identifiers)
        } else {
            enabledCalendarIdentifiers = []
        }
        profiles = try container.decodeIfPresent([FocusProfile].self, forKey: .profiles) ?? [FocusProfile.makeDefault()]
        activeProfileID = try container.decodeIfPresent(String.self, forKey: .activeProfileID) ?? PolicyRule.defaultProfileID
        // Migration safety: legacy state files have no profiles array. Make sure default is present.
        if !profiles.contains(where: { $0.isDefault }) {
            profiles.insert(FocusProfile.makeDefault(), at: 0)
        }
        if !profiles.contains(where: { $0.id == activeProfileID }) {
            activeProfileID = PolicyRule.defaultProfileID
        }
        lastFullScreenCheckAt = try container.decodeIfPresent(Date.self, forKey: .lastFullScreenCheckAt)
        hardEscalation = try container.decodeIfPresent(ActiveEscalation.self, forKey: .hardEscalation)
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
        try container.encode(aiTier, forKey: .aiTier)
        try container.encode(permissions, forKey: .permissions)
        try container.encode(setupStatus, forKey: .setupStatus)
        try container.encode(isPaused, forKey: .isPaused)
        try container.encode(debugMode, forKey: .debugMode)
        try container.encode(minimumLogLevel, forKey: .minimumLogLevel)
        try container.encode(goalsText, forKey: .goalsText)
        try container.encode(rescueApp, forKey: .rescueApp)
        try container.encodeIfPresent(runtimePathOverride, forKey: .runtimePathOverride)
        try container.encode(monitoringConfiguration, forKey: .monitoringConfiguration)
        try container.encode(algorithmState, forKey: .algorithmState)
        try container.encode(hasMigratedPolicyAlgorithmDefault, forKey: .hasMigratedPolicyAlgorithmDefault)
        try container.encode(recentActions, forKey: .recentActions)
        try container.encode(recentSwitches, forKey: .recentSwitches)
        try container.encode(usageByDay, forKey: .usageByDay)
        try container.encode(focusSegments, forKey: .focusSegments)
        try container.encode(distraction, forKey: .distraction)
        try container.encode(memoryEntries, forKey: .memoryEntries)
        try container.encodeIfPresent(lastMemoryConsolidationAt, forKey: .lastMemoryConsolidationAt)
        try container.encode(policyMemory, forKey: .policyMemory)
        try container.encode(chatHistory, forKey: .chatHistory)
        try container.encode(calendarIntelligenceEnabled, forKey: .calendarIntelligenceEnabled)
        try container.encode(Array(enabledCalendarIdentifiers).sorted(), forKey: .enabledCalendarIdentifiers)
        try container.encode(profiles, forKey: .profiles)
        try container.encode(activeProfileID, forKey: .activeProfileID)
        try container.encodeIfPresent(lastFullScreenCheckAt, forKey: .lastFullScreenCheckAt)
        try container.encodeIfPresent(hardEscalation, forKey: .hardEscalation)
    }

    mutating func resetAlgorithmProfile() {
        goalsText = Self.defaultGoalsText
        aiTier = .balanced
        recentActions = []
        recentSwitches = []
        usageByDay = [:]
        focusSegments = []
        monitoringConfiguration.algorithmID = MonitoringConfiguration.defaultAlgorithmID
        monitoringConfiguration.promptProfileID = MonitoringConfiguration.defaultPromptProfileID
        monitoringConfiguration.pipelineProfileID = MonitoringConfiguration.defaultPipelineProfileID
        monitoringConfiguration.runtimeProfileID = MonitoringConfiguration.defaultRuntimeProfileID
        monitoringConfiguration.cadenceMode = .balanced
        algorithmState = AlgorithmStateEnvelope()
        hasMigratedPolicyAlgorithmDefault = true
        memoryEntries = []
        lastMemoryConsolidationAt = nil
        policyMemory = PolicyMemory()
        chatHistory = []
        profiles = [FocusProfile.makeDefault()]
        activeProfileID = PolicyRule.defaultProfileID
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

    func policyRulesForChatPrompt(
        now: Date = Date(),
        maxLines: Int = 8,
        maxCharacters: Int = 700
    ) -> String {
        policyMemory
            .chatSummary(now: now, limit: maxLines, profileID: activeProfileID)
            .truncatedMultilineForPrompt(
                maxLength: maxCharacters,
                maxLines: maxLines
            )
    }

    /// True when the stored memory has grown past the soft cap and consolidation should run.
    var memoryExceedsSoftCap: Bool {
        memoryEntries.count > Self.memorySoftLineCap
    }

    // MARK: - Focus profiles

    /// Returns the profile with the given id, or `nil` if it doesn't exist.
    func profile(withID id: String) -> FocusProfile? {
        profiles.first(where: { $0.id == id })
    }

    /// The currently active profile. Always returns a non-nil value: if `activeProfileID` no
    /// longer matches a stored profile, the default profile is returned (and it is always present).
    var activeProfile: FocusProfile {
        profile(withID: activeProfileID) ?? FocusProfile.makeDefault()
    }

    /// Ensure the default profile exists. Idempotent. Call on first launch / migration.
    mutating func ensureDefaultProfileExists() {
        if !profiles.contains(where: { $0.isDefault }) {
            profiles.insert(FocusProfile.makeDefault(), at: 0)
        }
        if !profiles.contains(where: { $0.id == activeProfileID }) {
            activeProfileID = PolicyRule.defaultProfileID
        }
    }
}

// MARK: - FocusProfile

/// A named focus context (e.g. "Coding", "Presentation prep") plus an always-present default.
/// Each `PolicyRule.profileID` references one of these. Profiles persist across activations —
/// per-rule expiry handles freshness — but they are evicted LRU once the cap is exceeded.
struct FocusProfile: Codable, Identifiable, Equatable, Hashable, Sendable {
    /// Maximum number of stored profiles (default + named). The oldest unused named profile is
    /// evicted when a new one would exceed this cap.
    static let maximumProfileCount = 8

    /// Display name shown in the menu bar and Brain tab when the default is active.
    /// Picked over "Default" to feel less system-y while staying neutral.
    static let defaultDisplayName = "General"

    let id: String
    var name: String
    var isDefault: Bool
    var description: String?
    let createdAt: Date
    var lastUsedAt: Date
    var activatedAt: Date?
    /// `nil` for default; set on activation, cleared on switch.
    var expiresAt: Date?
    var createdReason: String?

    init(
        id: String = UUID().uuidString,
        name: String,
        isDefault: Bool = false,
        description: String? = nil,
        createdAt: Date = Date(),
        lastUsedAt: Date = Date(),
        activatedAt: Date? = nil,
        expiresAt: Date? = nil,
        createdReason: String? = nil
    ) {
        self.id = id
        self.name = name
        self.isDefault = isDefault
        self.description = description
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
        self.activatedAt = activatedAt
        self.expiresAt = expiresAt
        self.createdReason = createdReason
    }

    static func makeDefault() -> FocusProfile {
        FocusProfile(
            id: PolicyRule.defaultProfileID,
            name: defaultDisplayName,
            isDefault: true,
            description: "Everyday baseline. Active when no named focus session is running.",
            createdReason: "system_default"
        )
    }

    /// Has this profile expired by the given moment?
    func isExpired(at now: Date) -> Bool {
        guard !isDefault, let expiresAt else { return false }
        return expiresAt <= now
    }
}

struct RuntimeDiagnostics: Sendable {
    var runtimePath: String
    var runtimeDirectory: String
    var runtimePresent: Bool
    var modelCachePath: String
    var managedModelCachePath: String
    var modelCachePresent: Bool
    var modelArtifactsPresent: Bool
    var resolvedModelPath: String?
    var resolvedProjectorPath: String?
    var missingTools: [String]

    var isReady: Bool {
        runtimePresent && modelArtifactsPresent && missingTools.isEmpty
    }

    var canInstall: Bool {
        missingTools.isEmpty
    }
}

struct InstalledLocalModel: Identifiable, Sendable, Hashable {
    var id: String { cachePath }
    var modelIdentifier: String
    var repositoryIdentifier: String
    var cachePath: String
    var snapshotPath: String
    var modelPath: String
    var projectorPath: String?
}

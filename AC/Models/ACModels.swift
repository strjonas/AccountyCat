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
///
/// The cat's visual identity (portrait + palette) is paired one-to-one with personality —
/// the character picker is the only place look + tone are chosen, no mix-and-match.
enum ACCharacter: String, CaseIterable, Sendable {
    case mochi  // warm orange tabby — encouraging
    case misty  // soft gray — thoughtful
    case onyx  // sharp black — decisive

    var displayName: String {
        switch self {
        case .mochi: return "Mochi"
        case .misty: return "Misty"
        case .onyx: return "Onyx"
        }
    }

    var tagline: String {
        switch self {
        case .mochi: return "Your cozy focus buddy"
        case .misty: return "Your attentive focus companion"
        case .onyx: return "Your no-nonsense co-pilot"
        }
    }

    /// 1–2 sentence style prefix prepended to every system prompt.
    /// The companion still calls itself AccountyCat / AC in all conversations.
    nonisolated var personalityPrefix: String {
        switch self {
        case .mochi:
            return
                "You are AC, the user's warm and encouraging focus companion. Cheer them on like a close friend who's always rooting for them — kind, playful, never lecturing."
        case .misty:
            return
                "You are AC, the user's thoughtful focus companion. Stay quietly attentive — speak with care, listen for what they actually need, and only step in when it genuinely helps."
        case .onyx:
            return
                "You are AC, the user's sharp and decisive focus co-pilot. Cut through the noise — short, direct, dry-witted. Push them when they need it, drop the chit-chat when they don't."
        }
    }
}

// Codable with legacy-key migration:
//   "nova" → .onyx, "sage" → .misty so existing state files don't reset users.
extension ACCharacter: Codable {
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        switch raw {
        case "nova": self = .onyx
        case "sage": self = .misty
        default:
            self = ACCharacter(rawValue: raw) ?? .mochi
        }
    }
}

/// Glass effect mode for panels, overlays, and nudges.
/// `.auto` honors the macOS "Reduce Transparency" accessibility setting —
/// glass off when the user has asked the system to reduce transparency.
enum ACGlassMode: String, Codable, CaseIterable, Sendable {
    case auto
    case on
    case off

    var displayName: String {
        switch self {
        case .auto: return "auto"
        case .on: return "on"
        case .off: return "off"
        }
    }

    var blurb: String {
        switch self {
        case .auto: return "follows macOS"
        case .on: return "always translucent"
        case .off: return "always solid"
        }
    }
}

enum ACBuild {
    /// True for Debug configuration builds; false for Release.
    nonisolated
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

    nonisolated var ordinal: Int {
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

    nonisolated static var defaultForBuild: LogLevel {
        ACBuild.isDebug ? .standard : .error
    }
}

// MARK: - Display Mode

/// Controls where the AccountyCat UI is visible: floating orb, menu bar chip, or both.
enum ACDisplayMode: String, Codable, CaseIterable, Sendable {
    case orb  // floating companion only
    case menuBar  // menu bar chip only
    case both  // both visible (default)

    var displayName: String {
        switch self {
        case .orb: return "Orb"
        case .menuBar: return "Menu Bar"
        case .both: return "Both"
        }
    }

    var showsOrb: Bool { self == .orb || self == .both }
    var showsMenuBar: Bool { self == .menuBar || self == .both }
}

// MARK: - Status Bar Style

/// Controls what the menu bar status item displays.
enum ACStatusBarStyle: String, Codable, CaseIterable, Sendable {
    case profile  // profile name + remaining timer (default)
    case ac  // compact "AC" label
    case icon  // cat SF Symbol

    var displayName: String {
        switch self {
        case .profile: return "Profile"
        case .ac: return "\"AC\""
        case .icon: return "Cat"
        }
    }
}

enum TelemetryPersistencePolicy {
    nonisolated static func storesVerboseTelemetry(debugMode: Bool) -> Bool {
        ACBuild.isDebug
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
        screenRecording =
            try container.decodeIfPresent(PermissionState.self, forKey: .screenRecording)
            ?? .unknown
        accessibility =
            try container.decodeIfPresent(PermissionState.self, forKey: .accessibility) ?? .unknown
        // Older persisted snapshots predate calendar support — default to
        // `.unknown` so the UI treats it as "not yet decided" rather than denied.
        calendar =
            try container.decodeIfPresent(PermissionState.self, forKey: .calendar) ?? .unknown
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

    var telemetryLabel: String {
        switch self {
        case .none: return "none"
        case .showNudge: return "nudge"
        case .showOverlay(let p): return p.isHardEscalation ? "hard_escalation" : "escalation"
        }
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
    var denialCount: Int = 0
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

nonisolated struct RecurringSchedule: Codable, Hashable, Sendable {
    var hour: Int
    var minute: Int
    /// nil = every day. 1 = Sunday … 7 = Saturday (matches `Calendar.current.component(.weekday, …)`).
    var weekdays: [Int]?

    init(hour: Int, minute: Int, weekdays: [Int]? = nil) {
        self.hour = min(max(hour, 0), 23)
        self.minute = min(max(minute, 0), 59)
        self.weekdays = weekdays.flatMap { $0.isEmpty ? nil : $0 }
    }

    func matches(now: Date, calendar: Calendar = .current) -> Bool {
        let components = calendar.dateComponents([.hour, .minute, .weekday], from: now)
        guard let nowHour = components.hour, let nowMinute = components.minute else { return false }
        let nowTotalMinutes = nowHour * 60 + nowMinute
        let scheduledTotalMinutes = hour * 60 + minute
        guard
            nowTotalMinutes >= scheduledTotalMinutes && nowTotalMinutes <= scheduledTotalMinutes + 2
        else { return false }
        if let weekdays, let weekday = components.weekday {
            return weekdays.contains(weekday)
        }
        return true
    }

    func scheduleDescription() -> String {
        let time = String(format: "%02d:%02d", hour, minute)
        let days: String
        if let weekdays {
            let fmt = DateFormatter()
            fmt.locale = Locale(identifier: "en_US_POSIX")
            let shortNames = weekdays.compactMap { d -> String? in
                guard d >= 1, d <= 7 else { return nil }
                return fmt.shortWeekdaySymbols[d - 1]
            }
            days = shortNames.isEmpty ? "every day" : shortNames.joined(separator: ",")
        } else {
            days = "every day"
        }
        return "\(days) at \(time)"
    }
}

nonisolated struct RecurringNudge: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var hour: Int
    var minute: Int
    var weekdays: [Int]?
    var message: String
    var createdAt: Date
    var enabled: Bool
    var lastFiredAt: Date?

    init(
        id: UUID = UUID(),
        hour: Int,
        minute: Int,
        weekdays: [Int]? = nil,
        message: String,
        createdAt: Date = Date(),
        enabled: Bool = true,
        lastFiredAt: Date? = nil
    ) {
        self.id = id
        self.hour = min(max(hour, 0), 23)
        self.minute = min(max(minute, 0), 59)
        self.weekdays = weekdays.flatMap { $0.isEmpty ? nil : $0 }
        self.message = message
        self.createdAt = createdAt
        self.enabled = enabled
        self.lastFiredAt = lastFiredAt
    }

    func scheduleDescription() -> String {
        let time = String(format: "%02d:%02d", hour, minute)
        let days: String
        if let weekdays {
            let fmt = DateFormatter()
            fmt.locale = Locale(identifier: "en_US_POSIX")
            let shortNames = weekdays.compactMap { d -> String? in
                guard d >= 1, d <= 7 else { return nil }
                return fmt.shortWeekdaySymbols[d - 1]
            }
            days = shortNames.isEmpty ? "every day" : shortNames.joined(separator: ",")
        } else {
            days = "every day"
        }
        return "\(days) at \(time)"
    }

    func matches(now: Date, calendar: Calendar = .current) -> Bool {
        guard enabled else { return false }
        if let lastFiredAt, calendar.isDate(lastFiredAt, inSameDayAs: now) {
            return false
        }

        let components = calendar.dateComponents([.hour, .minute, .weekday], from: now)
        guard let nowHour = components.hour, let nowMinute = components.minute else { return false }
        let nowTotalMinutes = nowHour * 60 + nowMinute
        let scheduledTotalMinutes = hour * 60 + minute
        guard
            nowTotalMinutes >= scheduledTotalMinutes && nowTotalMinutes <= scheduledTotalMinutes + 2
        else { return false }
        if let weekdays, let weekday = components.weekday {
            return weekdays.contains(weekday)
        }
        return true
    }
}

struct ScheduledAction: Identifiable, Codable, Sendable {
    enum ActionType: String, Codable, Sendable {
        case nudge
        case profileActivation
    }

    var id: UUID
    var type: ActionType
    var fireAt: Date
    var message: String?
    var profileName: String?
    var createdAt: Date
    var fired: Bool

    init(
        id: UUID = UUID(),
        type: ActionType,
        fireAt: Date,
        message: String? = nil,
        profileName: String? = nil,
        createdAt: Date = Date(),
        fired: Bool = false
    ) {
        self.id = id
        self.type = type
        self.fireAt = fireAt
        self.message = message
        self.profileName = profileName
        self.createdAt = createdAt
        self.fired = fired
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
        interruptionPolicy =
            try container.decodeIfPresent(ChatInterruptionPolicy.self, forKey: .interruptionPolicy)
            ?? .immediate
        isUnread = try container.decodeIfPresent(Bool.self, forKey: .isUnread) ?? false
        suggestionData = try container.decodeIfPresent(
            ChatSuggestionData.self, forKey: .suggestionData)
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

    nonisolated var contextKey: String {
        [bundleIdentifier ?? "unknown", windowTitle?.normalizedForContextKey ?? ""]
            .joined(separator: "|")
    }
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

struct RecentInteractionAllowance: Codable, Hashable, Sendable {
    var createdAt: Date
    var expiresAt: Date
    var contextKey: String?
    var bundleIdentifier: String?
    var appName: String?
    var windowTitle: String?
    var reason: String

    func isExpired(at now: Date) -> Bool {
        now >= expiresAt
    }

    /// Canonical builder. For browsers we drop `contextKey` and `windowTitle` so the
    /// allowance spans adjacent tabs of the same research session. For everything else
    /// we keep the exact window — distinct windows in a native app usually mean distinct
    /// activities (e.g. two Slack channels, two Notes notes) and shouldn't be conflated.
    static func make(
        bundleIdentifier: String?,
        appName: String?,
        windowTitle: String?,
        contextKey: String?,
        now: Date,
        duration: TimeInterval,
        reason: String
    ) -> RecentInteractionAllowance? {
        let cleanedAppName = appName?.cleanedSingleLine
        guard bundleIdentifier != nil || (cleanedAppName?.isEmpty == false) else {
            return nil
        }
        let browserLike = MonitoringHeuristics.isBrowser(bundleIdentifier: bundleIdentifier)
        return RecentInteractionAllowance(
            createdAt: now,
            expiresAt: now.addingTimeInterval(duration),
            contextKey: browserLike ? nil : contextKey,
            bundleIdentifier: bundleIdentifier,
            appName: cleanedAppName,
            windowTitle: browserLike ? nil : windowTitle?.cleanedSingleLine,
            reason: reason.cleanedSingleLine
        )
    }

    func matches(snapshot: AppSnapshot) -> Bool {
        // A contextKey on the allowance is an exact-activity claim ("this app + this window title").
        // If it's set, it's authoritative — don't fall back to fuzzier app-level checks.
        if let contextKey {
            return contextKey == snapshot.contextKey
        }

        if let bundleIdentifier,
            snapshot.bundleIdentifier?.caseInsensitiveCompare(bundleIdentifier) != .orderedSame
        {
            return false
        }

        if let appName,
            snapshot.appName.cleanedSingleLine.caseInsensitiveCompare(appName.cleanedSingleLine)
                != .orderedSame
        {
            return false
        }

        if let windowTitle {
            guard let snapshotTitle = snapshot.windowTitle?.cleanedSingleLine,
                !snapshotTitle.isEmpty
            else {
                return false
            }
            return snapshotTitle.caseInsensitiveCompare(windowTitle.cleanedSingleLine)
                == .orderedSame
        }

        return bundleIdentifier != nil || appName != nil
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
        let decodedAssessment = try container.decodeIfPresent(
            MonitoringVerdict.self, forKey: .lastAssessment)
        let legacyAssessment = try container.decodeIfPresent(
            MonitoringVerdict.self, forKey: .lastVerdict)
        lastAssessment = decodedAssessment ?? legacyAssessment
        consecutiveDistractedCount =
            try container.decodeIfPresent(Int.self, forKey: .consecutiveDistractedCount) ?? 0
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
    static let usageHistoryRetentionDays = 35

    var character: ACCharacter = .mochi
    /// Glass effect mode for panels/overlays. `.auto` follows the system Reduce
    /// Transparency accessibility setting (glass off when system says reduce).
    var glassMode: ACGlassMode = .auto
    var aiTier: AITier = .balanced
    var permissions = PermissionsSnapshot()
    var setupStatus: SetupStatus = .checking
    var displayMode: ACDisplayMode = .both
    var statusBarStyle: ACStatusBarStyle = .profile
    var isPaused = false
    var autoQuietOnCalls = true
    var debugMode = ACBuild.isDebug
    var minimumLogLevel = LogLevel.defaultForBuild
    var goalsText = Self.defaultGoalsText
    var userName: String = ""
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
    /// Chat may propose memory actions; task-specific action resolution can also create
    /// entries. Consolidation only runs when the list grows or entries go stale.
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
    /// When the profile count reaches cap, creation prompts the user to remove one first (suggesting the LRU candidate) instead of silently evicting.
    var profiles: [FocusProfile] = [FocusProfile.makeDefault()]
    /// Id of the currently active profile. Defaults to `general`.
    var activeProfileID: String = PolicyRule.defaultProfileID
    /// Timestamp of the last forced full-screen screenshot (safety net when using active-window mode).
    var lastFullScreenCheckAt: Date?
    /// Active hard escalation: when set, the brain auto-minimizes the named app if the user re-opens it.
    var hardEscalation: ActiveEscalation?
    /// Scheduled actions (timed nudges, delayed profile activations) created via chat.
    var scheduledActions: [ScheduledAction] = []
    /// Recurring nudges — fire daily (or on specific weekdays) at the configured time.
    var recurringNudges: [RecurringNudge] = []
    /// A focus session that ended within the last ~30 minutes, carried into the
    /// monitoring payload so the model still sees what the user was just doing
    /// after the session expires. Cleared automatically once stale (`endedAt`
    /// older than `RecentlyEndedSession.retentionWindow`) or when a new
    /// non-default profile activates.
    var recentlyEndedSession: RecentlyEndedSession?
    /// Suggestions the LLM emitted via `propose_rule` / `propose_memory` that need explicit
    /// user approval before they land in `policyMemory.rules` / `memoryEntries`. Pruned of
    /// stale entries on access.
    var proposedChanges: [ProposedPolicyChange] = []
    /// Recent behavioral observations (appeal approvals, repeated dismissals, post-nudge
    /// returns to focus) the model uses to decide whether to apply or merely propose a
    /// rule. Bounded to the last 32 entries within a 7-day window.
    var recentBehavioralSignals: [BehavioralSignalSummary] = []

    static let recentBehavioralSignalsCap = 32

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

    private static func migrateUnscopedRulesToDefaultProfile(_ policyMemory: inout PolicyMemory) {
        policyMemory.rules = policyMemory.rules.map { rule in
            guard rule.profileID == nil, rule.kind != .tonePreference else {
                return rule
            }
            var scoped = rule
            scoped.profileID = PolicyRule.defaultProfileID
            return scoped
        }
    }

    enum CodingKeys: String, CodingKey {
        case character
        case glassMode
        // Legacy keys — decoded for migration, never re-encoded:
        case useLiquidGlass
        case selectedSkin
        case accentFollowsCharacter
        case customAccentHex
        case aiTier
        case permissions
        case setupStatus
        case isPaused
        case autoQuietOnCalls
        case displayMode
        case statusBarStyle
        case debugMode
        case minimumLogLevel
        case goalsText
        case userName
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
        case scheduledActions
        case recurringNudges
        case recentlyEndedSession
        case proposedChanges
        case recentBehavioralSignals
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
        // Glass mode migration: prefer the new 3-state key; otherwise inherit
        // from the legacy `useLiquidGlass` Bool (true → .on, false → .off so
        // returning users see no surprise change). Fresh installs default to
        // .auto via the property initializer.
        if let decoded = try container.decodeIfPresent(ACGlassMode.self, forKey: .glassMode) {
            glassMode = decoded
        } else if let legacy = try container.decodeIfPresent(Bool.self, forKey: .useLiquidGlass) {
            glassMode = legacy ? .on : .off
        }
        // Legacy skin/custom-accent keys are intentionally read-and-discard:
        // the visual identity now flows from `character` alone.
        _ = try container.decodeIfPresent(String.self, forKey: .selectedSkin)
        _ = try container.decodeIfPresent(Bool.self, forKey: .accentFollowsCharacter)
        _ = try container.decodeIfPresent(String.self, forKey: .customAccentHex)
        aiTier = try container.decodeIfPresent(AITier.self, forKey: .aiTier) ?? .balanced
        permissions =
            try container.decodeIfPresent(PermissionsSnapshot.self, forKey: .permissions)
            ?? PermissionsSnapshot()
        setupStatus =
            try container.decodeIfPresent(SetupStatus.self, forKey: .setupStatus) ?? .checking
        isPaused = try container.decodeIfPresent(Bool.self, forKey: .isPaused) ?? false
        autoQuietOnCalls =
            try container.decodeIfPresent(Bool.self, forKey: .autoQuietOnCalls) ?? true
        displayMode =
            try container.decodeIfPresent(ACDisplayMode.self, forKey: .displayMode) ?? .both
        statusBarStyle =
            try container.decodeIfPresent(ACStatusBarStyle.self, forKey: .statusBarStyle)
            ?? .profile
        debugMode = try container.decodeIfPresent(Bool.self, forKey: .debugMode) ?? ACBuild.isDebug
        minimumLogLevel =
            try container.decodeIfPresent(LogLevel.self, forKey: .minimumLogLevel)
            ?? LogLevel.defaultForBuild
        goalsText =
            try container.decodeIfPresent(String.self, forKey: .goalsText) ?? Self.defaultGoalsText
        userName = try container.decodeIfPresent(String.self, forKey: .userName) ?? ""
        rescueApp =
            try container.decodeIfPresent(RescueAppTarget.self, forKey: .rescueApp) ?? .xcode
        let decodedOverride = try container.decodeIfPresent(
            String.self, forKey: .runtimePathOverride)
        runtimePathOverride = Self.sanitizeRuntimePathOverride(decodedOverride)
        monitoringConfiguration =
            try container.decodeIfPresent(
                MonitoringConfiguration.self, forKey: .monitoringConfiguration)
            ?? MonitoringConfiguration()
        algorithmState =
            try container.decodeIfPresent(AlgorithmStateEnvelope.self, forKey: .algorithmState)
            ?? AlgorithmStateEnvelope()
        hasMigratedPolicyAlgorithmDefault =
            try container.decodeIfPresent(Bool.self, forKey: .hasMigratedPolicyAlgorithmDefault)
            ?? false
        recentActions =
            try container.decodeIfPresent([ActionRecord].self, forKey: .recentActions) ?? []
        recentSwitches =
            try container.decodeIfPresent([AppSwitchRecord].self, forKey: .recentSwitches) ?? []
        usageByDay =
            try container.decodeIfPresent(
                [String: [String: TimeInterval]].self, forKey: .usageByDay) ?? [:]
        focusSegments =
            try container.decodeIfPresent([FocusTimelineSegment].self, forKey: .focusSegments) ?? []
        let legacyDistraction = try container.decodeIfPresent(
            DistractionMetadata.self, forKey: .distraction)
        if algorithmState.llmPolicy.distraction == DistractionMetadata(),
            let legacyDistraction
        {
            algorithmState.llmPolicy.distraction = legacyDistraction
        }
        if let decodedEntries = try container.decodeIfPresent(
            [MemoryEntry].self, forKey: .memoryEntries)
        {
            memoryEntries = decodedEntries
        } else if let legacy = try container.decodeIfPresent(String.self, forKey: .memory),
            !legacy.isEmpty
        {
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
        lastMemoryConsolidationAt = try container.decodeIfPresent(
            Date.self, forKey: .lastMemoryConsolidationAt)
        policyMemory =
            try container.decodeIfPresent(PolicyMemory.self, forKey: .policyMemory)
            ?? PolicyMemory()
        calendarIntelligenceEnabled =
            try container.decodeIfPresent(Bool.self, forKey: .calendarIntelligenceEnabled) ?? false
        if let identifiers = try container.decodeIfPresent(
            [String].self, forKey: .enabledCalendarIdentifiers)
        {
            enabledCalendarIdentifiers = Set(identifiers)
        } else {
            enabledCalendarIdentifiers = []
        }
        profiles =
            try container.decodeIfPresent([FocusProfile].self, forKey: .profiles) ?? [
                FocusProfile.makeDefault()
            ]
        activeProfileID =
            try container.decodeIfPresent(String.self, forKey: .activeProfileID)
            ?? PolicyRule.defaultProfileID
        // Migration safety: legacy state files have no profiles array. Make sure default is present.
        if !profiles.contains(where: { $0.isDefault }) {
            profiles.insert(FocusProfile.makeDefault(), at: 0)
        }
        if !profiles.contains(where: { $0.id == activeProfileID }) {
            activeProfileID = PolicyRule.defaultProfileID
        }
        Self.migrateUnscopedRulesToDefaultProfile(&policyMemory)
        lastFullScreenCheckAt = try container.decodeIfPresent(
            Date.self, forKey: .lastFullScreenCheckAt)
        hardEscalation = try container.decodeIfPresent(
            ActiveEscalation.self, forKey: .hardEscalation)
        scheduledActions =
            try container.decodeIfPresent([ScheduledAction].self, forKey: .scheduledActions) ?? []
        recurringNudges =
            try container.decodeIfPresent([RecurringNudge].self, forKey: .recurringNudges) ?? []
        if let decoded = try container.decodeIfPresent(
            RecentlyEndedSession.self, forKey: .recentlyEndedSession),
            !decoded.isStale(at: Date())
        {
            recentlyEndedSession = decoded
        } else {
            recentlyEndedSession = nil
        }
        let now = Date()
        proposedChanges =
            (try container.decodeIfPresent([ProposedPolicyChange].self, forKey: .proposedChanges)
            ?? [])
            .filter { !$0.isStale(at: now) }
        recentBehavioralSignals =
            (try container.decodeIfPresent(
                [BehavioralSignalSummary].self, forKey: .recentBehavioralSignals) ?? [])
            .filter { !$0.isStale(at: now) }
            .suffix(Self.recentBehavioralSignalsCap)
            .map { $0 }
        do {
            chatHistory =
                try container.decodeIfPresent([ChatMessage].self, forKey: .chatHistory) ?? []
        } catch {
            let legacyHistory =
                (try? container.decode([LegacyChatMessage].self, forKey: .chatHistory)) ?? []
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
        pruneUsageHistory(now: now)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(character, forKey: .character)
        try container.encode(glassMode, forKey: .glassMode)
        try container.encode(aiTier, forKey: .aiTier)
        try container.encode(permissions, forKey: .permissions)
        try container.encode(setupStatus, forKey: .setupStatus)
        try container.encode(isPaused, forKey: .isPaused)
        try container.encode(autoQuietOnCalls, forKey: .autoQuietOnCalls)
        try container.encode(displayMode, forKey: .displayMode)
        try container.encode(statusBarStyle, forKey: .statusBarStyle)
        try container.encode(debugMode, forKey: .debugMode)
        try container.encode(minimumLogLevel, forKey: .minimumLogLevel)
        try container.encode(goalsText, forKey: .goalsText)
        try container.encode(userName, forKey: .userName)
        try container.encode(rescueApp, forKey: .rescueApp)
        try container.encodeIfPresent(runtimePathOverride, forKey: .runtimePathOverride)
        try container.encode(monitoringConfiguration, forKey: .monitoringConfiguration)
        try container.encode(algorithmState, forKey: .algorithmState)
        try container.encode(
            hasMigratedPolicyAlgorithmDefault, forKey: .hasMigratedPolicyAlgorithmDefault)
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
        try container.encode(
            Array(enabledCalendarIdentifiers).sorted(), forKey: .enabledCalendarIdentifiers)
        try container.encode(profiles, forKey: .profiles)
        try container.encode(activeProfileID, forKey: .activeProfileID)
        try container.encodeIfPresent(lastFullScreenCheckAt, forKey: .lastFullScreenCheckAt)
        try container.encodeIfPresent(hardEscalation, forKey: .hardEscalation)
        try container.encode(scheduledActions, forKey: .scheduledActions)
        try container.encode(recurringNudges, forKey: .recurringNudges)
        try container.encodeIfPresent(recentlyEndedSession, forKey: .recentlyEndedSession)
        try container.encode(proposedChanges, forKey: .proposedChanges)
        try container.encode(recentBehavioralSignals, forKey: .recentBehavioralSignals)
    }

    mutating func resetAlgorithmProfile() {
        goalsText = Self.defaultGoalsText
        userName = ""
        glassMode = .auto
        aiTier = .balanced
        recentActions = []
        recentSwitches = []
        usageByDay = [:]
        focusSegments = []
        monitoringConfiguration.algorithmID = MonitoringConfiguration.defaultAlgorithmID
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
        scheduledActions = []
        recentlyEndedSession = nil
        proposedChanges = []
        recentBehavioralSignals = []
    }

    mutating func pruneUsageHistory(now: Date = Date()) {
        let calendar = Calendar(identifier: .gregorian)
        guard
            let cutoffDate = calendar.date(
                byAdding: .day,
                value: -(Self.usageHistoryRetentionDays - 1),
                to: calendar.startOfDay(for: now)
            )
        else {
            return
        }

        let cutoffKey = cutoffDate.acDayKey
        usageByDay = usageByDay.reduce(into: [:]) { partial, entry in
            guard entry.key >= cutoffKey else { return }
            let positiveUsage = entry.value.filter { $0.value > 0 }
            guard !positiveUsage.isEmpty else { return }
            partial[entry.key] = positiveUsage
        }
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
/// per-rule expiry handles freshness. When the cap is reached, the user is asked to remove one
/// (with an LRU-based suggestion) rather than having one silently evicted.
struct FocusProfile: Codable, Identifiable, Equatable, Hashable, Sendable {
    /// Maximum number of stored profiles (default + named). When this cap is reached,
    /// creation prompts the user to remove a profile first (suggesting the LRU candidate).
    nonisolated static let maximumProfileCount = 7

    /// Display name shown in the menu bar and Brain tab when the default is active.
    /// Picked over "Default" to feel less system-y while staying neutral.
    nonisolated static let defaultDisplayName = "Everyday"

    let id: String
    var name: String
    var isDefault: Bool
    var description: String?
    /// Emoji shown in the profile bar and picker (e.g. "✎").
    var emoji: String
    /// Hex color for the profile (e.g. "#7BA3D9").
    var color: String
    /// Per-profile blocklist — app names or site domains that are always
    /// considered distractions while this profile is active.
    var blocklist: [String]
    /// Default session duration in minutes. `nil` for the default profile.
    var defaultDurationMin: Int?
    let createdAt: Date
    var lastUsedAt: Date
    var activatedAt: Date?
    /// `nil` for default; set on activation, cleared on switch.
    var expiresAt: Date?
    var createdReason: String?
    /// When set, this profile auto-activates at the given time every day (or on specific weekdays).
    /// nil for profiles without a recurring schedule. Omitted from chat prompts when nil.
    var recurringSchedule: RecurringSchedule?
    /// Last time this profile's recurring schedule fired (for same-day dedup).
    var lastScheduleFireDate: Date?
    /// Set when soft-expiry auto-extended the current activation. Cleared on
    /// reactivation. Prevents multiple auto-extensions from chaining together
    /// (the user is meant to confirm via chat after the first one).
    var autoExtendedAt: Date?
    /// Set when the 5-min pre-expiry warning fired for the current activation.
    /// Cleared on reactivation. Ensures a single warning per session.
    var prewarnSentAt: Date?

    init(
        id: String = UUID().uuidString,
        name: String,
        isDefault: Bool = false,
        description: String? = nil,
        emoji: String = "◎",
        color: String = "#9aa1a8",
        blocklist: [String] = [],
        defaultDurationMin: Int? = nil,
        createdAt: Date = Date(),
        lastUsedAt: Date = Date(),
        activatedAt: Date? = nil,
        expiresAt: Date? = nil,
        createdReason: String? = nil,
        recurringSchedule: RecurringSchedule? = nil,
        autoExtendedAt: Date? = nil,
        prewarnSentAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.isDefault = isDefault
        self.description = description
        self.emoji = emoji
        self.color = color
        self.blocklist = blocklist
        self.defaultDurationMin = defaultDurationMin
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
        self.activatedAt = activatedAt
        self.expiresAt = expiresAt
        self.createdReason = createdReason
        self.recurringSchedule = recurringSchedule
        self.lastScheduleFireDate = nil
        self.autoExtendedAt = autoExtendedAt
        self.prewarnSentAt = prewarnSentAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, isDefault, description
        case emoji, color, blocklist, defaultDurationMin
        case createdAt, lastUsedAt, activatedAt, expiresAt, createdReason
        case recurringSchedule, lastScheduleFireDate
        case autoExtendedAt, prewarnSentAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        isDefault = try c.decode(Bool.self, forKey: .isDefault)
        description = try c.decodeIfPresent(String.self, forKey: .description)
        emoji = try c.decodeIfPresent(String.self, forKey: .emoji) ?? "◎"
        color = try c.decodeIfPresent(String.self, forKey: .color) ?? "#9aa1a8"
        blocklist = try c.decodeIfPresent([String].self, forKey: .blocklist) ?? []
        defaultDurationMin = try c.decodeIfPresent(Int.self, forKey: .defaultDurationMin)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        lastUsedAt = try c.decode(Date.self, forKey: .lastUsedAt)
        activatedAt = try c.decodeIfPresent(Date.self, forKey: .activatedAt)
        expiresAt = try c.decodeIfPresent(Date.self, forKey: .expiresAt)
        createdReason = try c.decodeIfPresent(String.self, forKey: .createdReason)
        recurringSchedule = try c.decodeIfPresent(
            RecurringSchedule.self, forKey: .recurringSchedule)
        lastScheduleFireDate = try c.decodeIfPresent(Date.self, forKey: .lastScheduleFireDate)
        autoExtendedAt = try c.decodeIfPresent(Date.self, forKey: .autoExtendedAt)
        prewarnSentAt = try c.decodeIfPresent(Date.self, forKey: .prewarnSentAt)
    }

    static func makeDefault() -> FocusProfile {
        FocusProfile(
            id: PolicyRule.defaultProfileID,
            name: defaultDisplayName,
            isDefault: true,
            description: "Everyday baseline. Active when no named focus session is running.",
            emoji: "◎",
            color: "#9aa1a8",
            blocklist: [],
            defaultDurationMin: nil,
            createdReason: "system_default"
        )
    }

    /// Has this profile expired by the given moment?
    func isExpired(at now: Date) -> Bool {
        guard !isDefault, let expiresAt else { return false }
        return expiresAt <= now
    }

    /// Seconds remaining until expiry. Negative when already expired. `nil` for default
    /// or non-expiring profiles.
    func secondsUntilExpiry(at now: Date) -> TimeInterval? {
        guard !isDefault, let expiresAt else { return nil }
        return expiresAt.timeIntervalSince(now)
    }
}

/// Snapshot of a focus session that just ended. Persisted on `ACState` so it
/// survives across ticks; the monitoring payload reads it for ~30 min so the
/// model retains the "what was the user just doing" anchor after a profile
/// drops back to Everyday.
struct RecentlyEndedSession: Codable, Equatable, Hashable, Sendable {
    /// Window during which the session is still surfaced to the model.
    static let retentionWindow: TimeInterval = 30 * 60

    var name: String
    var description: String?
    var endedAt: Date
    /// Optional reason / goal text from the activation (e.g. `createdReason`).
    var goalSummary: String?

    func isStale(at now: Date) -> Bool {
        now.timeIntervalSince(endedAt) > Self.retentionWindow
    }

    var promptSummary: RecentlyEndedSessionSummary {
        RecentlyEndedSessionSummary(
            name: name,
            description: description,
            endedAt: endedAt,
            goalSummary: goalSummary
        )
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

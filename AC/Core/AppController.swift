//
//  AppController.swift
//  AC
//
//  Created by Codex on 12.04.26.
//

import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers

@MainActor
final class AppController: ObservableObject {
    static let shared = AppController()

    @Published var state: ACState
    @Published var setupDiagnostics: RuntimeDiagnostics
    @Published var setupLog = ""
    @Published var activityLog = ""
    @Published var companionMood: CompanionMood = .setup
    @Published var latestNudge: String?
    @Published var overlayVisible = false
    @Published var activeOverlay: OverlayPresentation?
    @Published var overlayAppealDraft = ""
    @Published var sendingOverlayAppeal = false
    @Published var installingRuntime = false
    @Published var installingDependencies = false
    @Published var setupProgressValue: Double?
    @Published var setupProgressMessage: String?
    @Published var setupErrorMessage: String?
    @Published var pendingLocalModelChange: PendingLocalModelChange?
    @Published var modelDownloadNotice: ModelDownloadNotice?
    @Published var modelDownloadSuccess: ModelDownloadSuccess?
    @Published var dependencyInstallPromptVisible = false
    @Published var deletingManagedModels = false
    @Published var importingModelToOllama = false
    @Published var selectedInstalledModelCachePath: String?
    @Published var localModelStorageMessage: String?
    @Published var localModelStorageError: String?
    @Published var showingOnboardingCompletion = false
    @Published var activityStatusText = "Checking permissions and local runtime."
    @Published var chatMessages: [ChatMessage]
    @Published var sendingChatMessage = false
    /// True when any assistant chat message is still flagged as unread (typically deferred
    /// suggestions like profile-switch announcements or calendar-suggested switches).
    /// Drives the menu bar dot badge.
    @Published var hasUnreadChatMessages: Bool = false
    @Published var consolidatingMemory = false
    @Published var lastUsedModelIdentifier: String?
    @Published var onboardingDismissed = false
    @Published var telemetrySessionID: String?
    @Published var onlineAPIKeyDraft: String
    @Published var directOpenAIAPIKeyDraft: String
    @Published var directOpenAIEnabled: Bool
    @Published var openRouterKeyInfo: OpenRouterKeyInfo?
    @Published var openRouterKeyInfoError: String?
    /// Set by BrainService when repeated API failures suggest a provider-side issue.
    /// Displayed as a gentle banner in the main UI.
    @Published var connectionProblemNotice: String?
    /// True once the user has completed the first-run onboarding wizard. Stored in
    /// UserDefaults (not ACState) so it survives state resets.
    @Published var hasCompletedOnboardingWizard: Bool
    /// Set by WindowCoordinator when the orb is snapped to a screen edge (peek mode).
    @Published var peekingEdge: NSRectEdge? = nil
    /// Populated by `refreshAvailableCalendars()` once Calendar Intelligence is
    /// enabled and permission is granted. Empty while the feature is off so the
    /// Settings UI has nothing to render before the user opts in.
    @Published var availableCalendars: [ACCalendarInfo] = []
    /// Timestamp of the last BrainService tick that reached evaluation (or skip).
    @Published var lastMonitoringCheckAt: Date?
    @Published var agentDebugBundleStatus: String?
    /// Subtle "AC learned: …" toast that appears briefly when a memory entry or rule is
    /// auto-added (source ≠ explicit user statement). Carries an Undo handler. Auto-clears
    /// after `LearnedToast.defaultDuration`.
    @Published var learnedToast: LearnedToast?
    /// Auto-dismiss task for the current `learnedToast`. Cancelled when a new toast lands
    /// or when the user dismisses it manually.
    var learnedToastDismissTask: Task<Void, Never>?

    /// Closure set by AppDelegate to allow UI components to close the main NSPopover.
    var dismissPopover: (() -> Void)?
    /// Closure set by AppDelegate so compact controls can open the full app popover on demand.
    var openMainPopover: (() -> Void)?
    /// Closure set by AppDelegate to resize the main popover (e.g. when stats expand).
    var resizePopover: ((NSSize) -> Void)?

    /// How many recent messages (non-system) are sent to the LLM for context.
    static let chatContextWindow = 8

    let storageService: StorageService
    let telemetryStore = TelemetryStore.shared
    let localModelRuntime: LocalModelRuntime
    let onlineModelService: OnlineModelService
    let companionChatService: CompanionChatService
    let memoryConsolidationService: MemoryConsolidationService
    let policyMemoryService: PolicyMemoryService
    let monitoringAlgorithmRegistry: MonitoringAlgorithmRegistry

    private(set) var executiveArm: ExecutiveArm?
    private(set) var brainService: BrainService?
    private var hasBootstrapped = false
    var hasPerformedInitialRefresh = false
    var onboardingCompletionTask: DispatchWorkItem?
    var lastPromptedDependencySignature: String?
    private var statsSnapshotCache: [StatsWindow: MonitoringStatsSnapshot] = [:]
    var installRuntimeTask: Task<Void, Never>?
    private var telemetryHeartbeatTask: Task<Void, Never>?
    var activeScheduledTimers: [UUID: DispatchWorkItem] = [:]

    private init() {
        self.storageService = StorageService()
        let runtime = LocalModelRuntime()
        let onlineModelService = OnlineModelService()
        let companionChatService = CompanionChatService(
            runtime: runtime,
            onlineModelService: onlineModelService
        )
        let memoryConsolidationService = MemoryConsolidationService(
            runtime: runtime,
            onlineModelService: onlineModelService
        )
        let policyMemoryService = PolicyMemoryService(
            runtime: runtime,
            onlineModelService: onlineModelService
        )
        self.localModelRuntime = runtime
        self.onlineModelService = onlineModelService
        self.companionChatService = companionChatService
        self.memoryConsolidationService = memoryConsolidationService
        self.policyMemoryService = policyMemoryService
        self.monitoringAlgorithmRegistry = MonitoringAlgorithmRegistry(
            runtime: runtime,
            onlineModelService: onlineModelService,
            policyMemoryService: policyMemoryService
        )
        let loadedState = storageService.loadState()
        var state = loadedState
        Self.seedDefaultSafelistIfNeeded(into: &state)
        self.state = state
        self.onlineAPIKeyDraft = OnlineProviderCredentialStore.loadOpenRouterAPIKey() ?? ""
        self.directOpenAIAPIKeyDraft = OnlineProviderCredentialStore.loadDirectOpenAIAPIKey() ?? ""
        self.directOpenAIEnabled = OnlineProviderRoutingStore.loadDirectOpenAIEnabled()
        self.setupDiagnostics = RuntimeSetupService.inspect(
            runtimeOverride: state.runtimePathOverride,
            modelIdentifier: Self.effectiveSetupModelIdentifier(for: state.monitoringConfiguration)
        )
        self.chatMessages = Self.makeChatMessages(from: state.chatHistory)
        self.hasCompletedOnboardingWizard = UserDefaults.standard.bool(forKey: "acOnboardingWizardCompleted")

        Task { @MainActor [weak self] in
            await ActivityLogService.shared.setMinimumLogLevel(state.minimumLogLevel)
            self?.activityLog = await ActivityLogService.shared.loadRecentContents()
        }
    }

    @MainActor
    static func makeForTesting(storageService: StorageService) -> AppController {
        let controller = AppController(storageService: storageService)
        return controller
    }

    @MainActor
    private init(storageService: StorageService) {
        self.storageService = storageService
        let runtime = LocalModelRuntime()
        let onlineModelService = OnlineModelService()
        let companionChatService = CompanionChatService(
            runtime: runtime,
            onlineModelService: onlineModelService
        )
        let memoryConsolidationService = MemoryConsolidationService(
            runtime: runtime,
            onlineModelService: onlineModelService
        )
        let policyMemoryService = PolicyMemoryService(
            runtime: runtime,
            onlineModelService: onlineModelService
        )
        self.localModelRuntime = runtime
        self.onlineModelService = onlineModelService
        self.companionChatService = companionChatService
        self.memoryConsolidationService = memoryConsolidationService
        self.policyMemoryService = policyMemoryService
        self.monitoringAlgorithmRegistry = MonitoringAlgorithmRegistry(
            runtime: runtime,
            onlineModelService: onlineModelService,
            policyMemoryService: policyMemoryService
        )
        let loadedState = storageService.loadState()
        var state = loadedState
        Self.seedDefaultSafelistIfNeeded(into: &state)
        self.state = state
        self.onlineAPIKeyDraft = OnlineProviderCredentialStore.loadOpenRouterAPIKey() ?? ""
        self.directOpenAIAPIKeyDraft = OnlineProviderCredentialStore.loadDirectOpenAIAPIKey() ?? ""
        self.directOpenAIEnabled = OnlineProviderRoutingStore.loadDirectOpenAIEnabled()
        self.setupDiagnostics = RuntimeSetupService.inspect(
            runtimeOverride: state.runtimePathOverride,
            modelIdentifier: Self.effectiveSetupModelIdentifier(for: state.monitoringConfiguration)
        )
        self.chatMessages = Self.makeChatMessages(from: state.chatHistory)
        self.hasCompletedOnboardingWizard = UserDefaults.standard.bool(forKey: "acOnboardingWizardCompleted")

        Task { @MainActor [weak self] in
            await ActivityLogService.shared.setMinimumLogLevel(state.minimumLogLevel)
            self?.activityLog = await ActivityLogService.shared.loadRecentContents()
        }
    }

    func bootstrap() {
        guard !hasBootstrapped else { return }
        hasBootstrapped = true
        logActivity("app", "Bootstrapping AccountyCat")
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard TelemetryPersistencePolicy.storesVerboseTelemetry(debugMode: self.state.debugMode) else {
                self.telemetrySessionID = nil
                return
            }
            if let session = try? await self.telemetryStore.startSession(reason: "app_launch") {
                self.telemetrySessionID = session.id
                await self.telemetryStore.appendSessionHeartbeat(
                    reason: "app_bootstrap",
                    details: [
                        "setupStatus": self.state.setupStatus.rawValue,
                        "debugMode": String(self.state.debugMode),
                    ]
                )
                self.startTelemetryHeartbeat()
            }
        }
        refreshSystemState(persist: false)
        configureBrainIfNeeded()
        restorePendingScheduledActions()
        recomputeTodayStats()
    }

    func shutdown() async {
        persistState()
        telemetryHeartbeatTask?.cancel()
        telemetryHeartbeatTask = nil
        await telemetryStore.appendSessionHeartbeat(reason: "app_shutdown_started")
        await localModelRuntime.shutdown()
        await telemetryStore.endCurrentSession(reason: "app_termination")
    }

    private func startTelemetryHeartbeat() {
        telemetryHeartbeatTask?.cancel()
        telemetryHeartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled, let self else { continue }
                let state = await MainActor.run { self.state }
                await self.telemetryStore.appendSessionHeartbeat(
                    reason: "app_alive",
                    details: [
                        "setupStatus": state.setupStatus.rawValue,
                        "paused": String(state.isPaused),
                        "activeProfileID": state.activeProfileID,
                    ]
                )
            }
        }
    }

    func attachExecutiveArm(_ executiveArm: ExecutiveArm) {
        self.executiveArm = executiveArm
        configureBrainIfNeeded()
    }

    func refreshSystemState(persist: Bool = true) {
        repairInvalidMonitoringConfigurationIfNeeded()

        let previousStatus = state.setupStatus
        state.permissions = PermissionService.currentSnapshot()

        let modelIdentifier = pendingLocalModelChange?.modelIdentifier
            ?? Self.effectiveSetupModelIdentifier(for: state.monitoringConfiguration)
        setupDiagnostics = RuntimeSetupService.inspect(
            runtimeOverride: state.runtimePathOverride,
            modelIdentifier: modelIdentifier
        )
        let permissionRequirements = LLMPolicyCatalog.permissionRequirements(for: state.monitoringConfiguration)
        let usesOnlineInference = state.monitoringConfiguration.usesOnlineInference

        if installingRuntime || installingDependencies {
            if installingRuntime,
               pendingLocalModelChange != nil,
               setupDiagnostics.isReady {
                state.setupStatus = .ready
            } else {
                state.setupStatus = .installing
            }
        } else if !state.permissions.satisfies(permissionRequirements) {
            state.setupStatus = .needsPermissions
        } else if usesOnlineInference {
            state.setupStatus = hasActiveOnlineAPIKeyConfigured ? .ready : .needsRuntime
        } else if setupDiagnostics.isReady {
            state.setupStatus = .ready
        } else if !setupDiagnostics.canInstall {
            state.setupStatus = .blocked
        } else {
            state.setupStatus = .needsRuntime
        }

        updateActivityStatusLine()
        handleSetupStatusTransition(from: previousStatus, to: state.setupStatus)
        maybePromptForMissingDependencies()
        if !installingRuntime {
            _ = applyPendingLocalModelIfReady()
        }

        if persist {
            persistState()
        }
    }

    func persistState() {
        state.chatHistory = persistedChatHistory()
        storageService.saveState(state)
    }

    func updateGoals(_ text: String) {
        state.goalsText = text
        persistState()
    }

    func updateUserName(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        state.userName = trimmed
        persistState()
    }

    func appendMonitoringMetric(
        kind: MonitoringMetricKind,
        reason: String,
        profile: FocusProfile,
        detail: String?
    ) {
        guard TelemetryPersistencePolicy.storesVerboseTelemetry(debugMode: state.debugMode) else {
            return
        }
        Task { [telemetryStore] in
            guard let sessionID = try? await telemetryStore.ensureCurrentSession(reason: "runtime").id else {
                return
            }
            try? await telemetryStore.appendEvent(
                TelemetryEvent(
                    id: UUID().uuidString,
                    kind: .monitoringMetric,
                    timestamp: Date(),
                    sessionID: sessionID,
                    episodeID: nil,
                    episode: nil,
                    session: nil,
                    observation: nil,
                    evaluation: nil,
                    modelInput: nil,
                    modelOutput: nil,
                    parsedOutput: nil,
                    policy: nil,
                    action: nil,
                    metric: MonitoringMetricRecord(
                        kind: kind,
                        reason: reason,
                        activeProfileID: profile.id,
                        activeProfileName: profile.name,
                        detail: detail
                    ),
                    reaction: nil,
                    annotation: nil,
                    failure: nil
                ),
                sessionID: sessionID
            )
        }
    }

    func updateCharacter(_ character: ACCharacter) {
        guard state.character != character else { return }
        state.character = character
        logActivity("app", "Selected character: \(character.displayName)")
        persistState()
    }

    func updateSkin(_ skin: ACSkin) {
        guard state.selectedSkin != skin else { return }
        state.selectedSkin = skin
        logActivity("app", "Selected skin: \(skin.rawValue)")
        persistState()
    }

    func updateLiquidGlass(_ enabled: Bool) {
        guard state.useLiquidGlass != enabled else { return }
        state.useLiquidGlass = enabled
        logActivity("app", "Liquid glass: \(enabled)")
        persistState()
    }

    func updateAutoQuietOnCalls(_ enabled: Bool) {
        guard state.autoQuietOnCalls != enabled else { return }
        state.autoQuietOnCalls = enabled
        logActivity("app", "Auto-quiet on calls: \(enabled)")
        persistState()
    }

    func updateDisplayMode(_ mode: ACDisplayMode) {
        guard state.displayMode != mode else { return }
        state.displayMode = mode
        logActivity("app", "Display mode: \(mode.displayName)")
        persistState()
    }

    func updateStatusBarStyle(_ style: ACStatusBarStyle) {
        guard state.statusBarStyle != style else { return }
        state.statusBarStyle = style
        logActivity("app", "Status bar style: \(style.displayName)")
        persistState()
    }

    func updateAccent(usesDefault: Bool, customHex: String? = nil) {
        let normalizedHex: String? = customHex.flatMap { raw in
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let digits = trimmed.hasPrefix("#") ? String(trimmed.dropFirst()) : trimmed
            guard digits.count == 6, UInt(digits, radix: 16) != nil else { return nil }
            return "#\(digits.uppercased())"
        }
        var changed = false
        if state.accentFollowsCharacter != usesDefault {
            state.accentFollowsCharacter = usesDefault
            changed = true
        }
        if let normalizedHex, state.customAccentHex != normalizedHex {
            state.customAccentHex = normalizedHex
            changed = true
        }
        guard changed else { return }
        logActivity("app", "Updated accent: \(state.accentFollowsCharacter ? "skin default" : state.customAccentHex)")
        persistState()
    }

    func updateRuntimeOverride(_ path: String) {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            state.runtimePathOverride = nil
        } else if trimmed.hasPrefix(NSTemporaryDirectory()) || trimmed.contains("ac-fake-runtime") {
            state.runtimePathOverride = nil
            logActivity("setup", "Ignored runtime override that looks like a test fixture path.")
        } else {
            state.runtimePathOverride = trimmed
        }
        refreshSystemState()
    }

    func updateMonitoringPipelineProfile(_ pipelineProfileID: String) {
        let descriptor = LLMPolicyCatalog.pipelineProfile(id: pipelineProfileID).descriptor
        guard state.monitoringConfiguration.pipelineProfileID != descriptor.id else { return }
        state.monitoringConfiguration.pipelineProfileID = descriptor.id
        brainService?.handleMonitoringConfigurationChange()
        refreshSystemState(persist: false)
        persistState()
        logActivity("monitoring", "Selected pipeline profile: \(descriptor.id)")
    }

    func updateMonitoringRuntimeProfile(_ runtimeProfileID: String) {
        let descriptor = LLMPolicyCatalog.runtimeProfile(id: runtimeProfileID).descriptor
        guard state.monitoringConfiguration.runtimeProfileID != descriptor.id else { return }
        state.monitoringConfiguration.runtimeProfileID = descriptor.id
        brainService?.handleMonitoringConfigurationChange()
        refreshSystemState()
        persistState()
        logActivity("monitoring", "Selected runtime profile: \(descriptor.id)")
    }

    func updateMonitoringCadenceMode(_ cadenceMode: MonitoringCadenceMode) {
        guard state.monitoringConfiguration.cadenceMode != cadenceMode else { return }
        state.monitoringConfiguration.cadenceMode = cadenceMode
        brainService?.handleMonitoringConfigurationChange()
        persistState()
        logActivity("monitoring", "Monitoring cadence: \(cadenceMode.rawValue)")
    }

    func updateTitleLengthForTextOnly(_ value: Int) {
        let clamped = MonitoringConfiguration.clampedTitleLengthForTextOnly(value)
        guard state.monitoringConfiguration.titleLengthForTextOnly != clamped else { return }
        state.monitoringConfiguration.titleLengthForTextOnly = clamped
        brainService?.handleMonitoringConfigurationChange()
        persistState()
        logActivity("monitoring", "Title-only vision gate threshold: \(clamped) chars")
    }

    var visionEnabled: Bool {
        LLMPolicyCatalog.pipelineProfile(id: state.monitoringConfiguration.pipelineProfileID)
            .descriptor
            .requiresScreenshot
    }

    func updateVisionEnabled(_ enabled: Bool) {
        let target: String
        if state.monitoringConfiguration.usesOnlineInference {
            target = enabled
                ? MonitoringConfiguration.defaultOnlineVisionPipelineProfileID
                : MonitoringConfiguration.defaultOnlineTextPipelineProfileID
        } else {
            target = enabled ? MonitoringConfiguration.defaultPipelineProfileID : "title_only_default"
        }
        updateMonitoringPipelineProfile(target)
    }

    var hasOnlineAPIKeyConfigured: Bool {
        !onlineAPIKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var hasDirectOpenAIAPIKeyConfigured: Bool {
        !directOpenAIAPIKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var hasActiveOnlineAPIKeyConfigured: Bool {
        OnlineProviderRouting.hasActiveAPIKeyConfigured(
            openRouterAPIKey: onlineAPIKeyDraft,
            directOpenAIAPIKey: directOpenAIAPIKeyDraft,
            directOpenAIEnabled: directOpenAIEnabled
        )
    }

    var activeOnlineProvider: OnlineModelProvider {
        OnlineProviderRouting.activeProvider(directOpenAIEnabled: directOpenAIEnabled)
    }

    var usingOnlineMonitoring: Bool {
        state.monitoringConfiguration.usesOnlineInference
    }

    func cachedStatsSnapshot(for window: StatsWindow) -> MonitoringStatsSnapshot? {
        statsSnapshotCache[window]
    }

    func storeStatsSnapshot(_ snapshot: MonitoringStatsSnapshot, for window: StatsWindow) {
        statsSnapshotCache[window] = snapshot
    }

    func invalidateStatsSnapshots() {
        statsSnapshotCache.removeAll()
    }

    /// Short human-readable name for the model currently configured, suitable for
    /// compact display in the header or settings footnote.
    func updateThinkingEnabled(_ enabled: Bool) {
        guard state.monitoringConfiguration.thinkingEnabled != enabled else { return }
        state.monitoringConfiguration.thinkingEnabled = enabled
        persistState()
        logActivity("monitoring", "Thinking \(enabled ? "enabled" : "disabled")")
    }

    func togglePause() {
        state.isPaused.toggle()
        logActivity("app", state.isPaused ? "Monitoring paused" : "Monitoring resumed")
        persistState()
        refreshSystemState()
    }

    func resetAlgorithmProfile() {
        state.resetAlgorithmProfile()
        clearChatHistory()
        brainService?.resetAlgorithmProfile()
        persistState()
        updateActivityStatusLine()
        logActivity("memory", "Algorithm profile reset to defaults")
    }

    func requestAccessibilityPermission() {
        logActivity("permissions", "Requested Accessibility permission")
        PermissionService.requestAccessibility()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            self.refreshSystemState()
        }
    }

    func requestScreenRecordingPermission() {
        logActivity("permissions", "Requested Screen Recording permission")
        PermissionService.requestScreenRecording()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            self.refreshSystemState()
        }
    }

    // MARK: - Calendar Intelligence

    /// Flip the Calendar Intelligence toggle. When turning ON we ask for
    /// EventKit permission and, on grant, load the calendar list so the
    /// Settings picker has something to render. When turning OFF we clear
    /// the cache but leave the saved calendar selection in place so it
    /// comes back automatically if the user flips it on again later.
    func setCalendarIntelligence(enabled: Bool) {
        guard state.calendarIntelligenceEnabled != enabled else { return }
        state.calendarIntelligenceEnabled = enabled
        persistState()
        logActivity("calendar", "Calendar Intelligence \(enabled ? "enabled" : "disabled")")

        if enabled {
            Task { [weak self] in
                let granted = await PermissionService.requestCalendarAccess()
                guard let self else { return }
                await MainActor.run {
                    self.refreshSystemState()
                    if granted {
                        self.refreshAvailableCalendars()
                    }
                }
            }
        } else {
            availableCalendars = []
            Task { await CalendarService.shared.invalidateCache() }
        }
    }

    /// Called after the user grants permission, or when opening Settings, to
    /// refresh the pickable calendar list. Safe to call even if permission
    /// is still pending — EventKit just returns an empty list.
    func refreshAvailableCalendars() {
        Task { [weak self] in
            let calendars = await CalendarService.shared.availableCalendars()
            await MainActor.run {
                self?.availableCalendars = calendars
            }
        }
    }

    /// Toggle a specific calendar in the multi-select picker. Empty selection
    /// means "use all calendars" (sensible default right after opt-in), so the
    /// first explicit toggle switches from "all" to a single-calendar selection.
    func toggleCalendarEnabled(_ calendarID: String) {
        // First tap on a fresh install: start from "all selected" so the
        // toggled-off calendar leaves every other one enabled rather than
        // collapsing to just the one the user clicked off.
        if state.enabledCalendarIdentifiers.isEmpty {
            let allIDs = Set(availableCalendars.map(\.id))
            state.enabledCalendarIdentifiers = allIDs
        }
        if state.enabledCalendarIdentifiers.contains(calendarID) {
            state.enabledCalendarIdentifiers.remove(calendarID)
        } else {
            state.enabledCalendarIdentifiers.insert(calendarID)
        }
        persistState()
        Task { await CalendarService.shared.invalidateCache() }
    }

    /// Convenience for the picker — a calendar is treated as enabled when
    /// either the user has explicitly selected it, or the selection set is
    /// empty (meaning "all").
    func isCalendarEnabled(_ calendarID: String) -> Bool {
        state.enabledCalendarIdentifiers.isEmpty ||
            state.enabledCalendarIdentifiers.contains(calendarID)
    }

    // MARK: - Today stats

    struct TodayStats {
        let totalTrackedSeconds: TimeInterval
        let focusedSeconds: TimeInterval
        let longestFocusedBlockSeconds: TimeInterval
        let streakDays: Int
        let topAppName: String?
        let topAppSeconds: TimeInterval
        let nudgeCount: Int
        let rescueCount: Int
        let timelineSegments: [FocusTimelineSegment]
    }

    @Published private(set) var todayStats: TodayStats = TodayStats(
        totalTrackedSeconds: 0,
        focusedSeconds: 0,
        longestFocusedBlockSeconds: 0,
        streakDays: 0,
        topAppName: nil,
        topAppSeconds: 0,
        nudgeCount: 0,
        rescueCount: 0,
        timelineSegments: []
    )

    func recomputeTodayStats(now: Date = Date()) {
        let cal = Calendar.current
        let startOfToday = cal.startOfDay(for: now)
        let dayUsage = state.usageByDay[now.acDayKey] ?? [:]
        let total = dayUsage.values.reduce(0, +)
        let top = dayUsage.max(by: { $0.value < $1.value })
        let todayActions = state.recentActions.filter { cal.isDate($0.timestamp, inSameDayAs: now) }
        let todaySegments = state.focusSegments.filter { segment in
            segment.endAt >= startOfToday && segment.startAt <= now
        }
        let focusedSeconds = todaySegments
            .filter { $0.assessment == .focused }
            .reduce(0) { $0 + clampedDuration($1, start: startOfToday, end: now) }
        todayStats = TodayStats(
            totalTrackedSeconds: total,
            focusedSeconds: focusedSeconds,
            longestFocusedBlockSeconds: longestFocusedBlock(in: todaySegments, dayStart: startOfToday, dayEnd: now),
            streakDays: focusStreakDays(now: now),
            topAppName: top?.key,
            topAppSeconds: top?.value ?? 0,
            nudgeCount: todayActions.filter { $0.kind == .nudge }.count,
            rescueCount: todayActions.filter { $0.kind == .backToWork }.count,
            timelineSegments: todaySegments
        )
    }

    private func clampedDuration(
        _ segment: FocusTimelineSegment,
        start: Date,
        end: Date
    ) -> TimeInterval {
        max(0, min(segment.endAt, end).timeIntervalSince(max(segment.startAt, start)))
    }

    private func longestFocusedBlock(
        in segments: [FocusTimelineSegment],
        dayStart: Date,
        dayEnd: Date
    ) -> TimeInterval {
        var longest: TimeInterval = 0
        var currentStart: Date?
        var currentEnd: Date?

        for segment in segments.sorted(by: { $0.startAt < $1.startAt }) {
            guard segment.assessment == .focused else {
                if let start = currentStart, let end = currentEnd {
                    longest = max(longest, end.timeIntervalSince(start))
                }
                currentStart = nil
                currentEnd = nil
                continue
            }

            let start = max(segment.startAt, dayStart)
            let end = min(segment.endAt, dayEnd)
            if let existingEnd = currentEnd,
               start.timeIntervalSince(existingEnd) <= 120 {
                currentEnd = max(existingEnd, end)
            } else {
                if let currentStart, let currentEnd {
                    longest = max(longest, currentEnd.timeIntervalSince(currentStart))
                }
                currentStart = start
                currentEnd = end
            }
        }

        if let currentStart, let currentEnd {
            longest = max(longest, currentEnd.timeIntervalSince(currentStart))
        }
        return longest
    }

    private func focusStreakDays(now: Date) -> Int {
        let cal = Calendar.current
        var streak = 0
        var cursor = cal.startOfDay(for: now)

        while true {
            let nextDay = cal.date(byAdding: .day, value: 1, to: cursor) ?? cursor.addingTimeInterval(24 * 60 * 60)
            let focusedSeconds = state.focusSegments
                .filter { $0.assessment == .focused && $0.endAt > cursor && $0.startAt < nextDay }
                .reduce(0) { $0 + clampedDuration($1, start: cursor, end: nextDay) }
            guard focusedSeconds >= 20 * 60 else {
                return streak
            }
            streak += 1
            guard let previous = cal.date(byAdding: .day, value: -1, to: cursor) else {
                return streak
            }
            cursor = previous
        }
    }

    var availablePipelineProfiles: [MonitoringPipelineProfileDescriptor] {
        LLMPolicyCatalog.availablePipelineProfiles.map(\.descriptor)
    }

    var availableRuntimeProfiles: [MonitoringRuntimeProfileDescriptor] {
        LLMPolicyCatalog.availableRuntimeProfiles.map(\.descriptor)
    }

    var shouldPresentOnboarding: Bool {
        showingOnboardingCompletion || (state.setupStatus != .ready && !onboardingDismissed)
    }

    var shouldPresentChatAsAvailable: Bool {
        state.setupStatus == .ready
    }

    func dismissOnboarding() {
        onboardingDismissed = true
    }

    func resumeOnboarding() {
        onboardingDismissed = false
    }

    func openActivityLog() {
        Task {
            let logURL = await ActivityLogService.shared.fileURL()
            _ = await MainActor.run {
                NSWorkspace.shared.open(logURL)
            }
        }
    }

    func refreshActivityLog() {
        Task { @MainActor [weak self] in
            self?.activityLog = await ActivityLogService.shared.loadRecentContents()
        }
    }

    func openTelemetryRoot() {
        Task {
            let url = await telemetryStore.rootDirectoryURL()
            _ = await MainActor.run {
                NSWorkspace.shared.open(url)
            }
        }
    }

    func openCurrentTelemetrySession() {
        Task {
            guard let session = await telemetryStore.currentSessionDescriptor() else { return }
            let rootURL = await telemetryStore.rootDirectoryURL()
            let sessionURL = rootURL.appendingPathComponent(session.id, isDirectory: true)
            _ = await MainActor.run {
                NSWorkspace.shared.open(sessionURL)
            }
        }
    }

    func exportAgentDebugBundle() {
        agentDebugBundleStatus = "Exporting agent debug bundle..."
        let snapshot = state
        Task { @MainActor [weak self] in
            do {
                let result = try await ACDebugBundleService(telemetryStore: self?.telemetryStore ?? .shared)
                    .export(state: snapshot)
                self?.agentDebugBundleStatus = "Exported \(result.bundleURL.lastPathComponent)"
                NSWorkspace.shared.open(result.bundleURL)
                await ActivityLogService.shared.append(
                    level: .standard,
                    category: "debug-bundle",
                    message: "Exported agent debug bundle: \(result.bundleURL.path)"
                )
            } catch {
                self?.agentDebugBundleStatus = error.localizedDescription
                await ActivityLogService.shared.append(
                    level: .error,
                    category: "debug-bundle-error",
                    message: error.localizedDescription
                )
            }
        }
    }

    func openOpenRouterHealthStats() {
        Task {
            let url = await OpenRouterHealthStatsService.shared.snapshotFileURL()
            _ = await MainActor.run {
                NSWorkspace.shared.open(url)
            }
        }
    }

    func mergeBrainState(base: ACState, updated: ACState) {
        var merged = state
        merged.permissions = updated.permissions
        merged.algorithmState = updated.algorithmState
        merged.recentSwitches = updated.recentSwitches
        merged.recentActions = updated.recentActions
        merged.usageByDay = updated.usageByDay
        merged.focusSegments = updated.focusSegments
        merged.recurringNudges = updated.recurringNudges
        merged.lastFullScreenCheckAt = updated.lastFullScreenCheckAt
        merged.hardEscalation = updated.hardEscalation
        merged.recentlyEndedSession = updated.recentlyEndedSession
        merged.policyMemory = Self.mergePolicyMemory(
            base: base.policyMemory,
            current: merged.policyMemory,
            updated: updated.policyMemory
        )

        if updated.profiles != base.profiles {
            merged.profiles = updated.profiles
        }
        if updated.activeProfileID != base.activeProfileID {
            merged.activeProfileID = updated.activeProfileID
        }
        if updated.chatHistory != base.chatHistory {
            merged.chatHistory = Self.mergeChatHistory(
                base: base.chatHistory,
                current: merged.chatHistory,
                updated: updated.chatHistory
            )
        }

        merged.ensureDefaultProfileExists()
        state = merged
        syncChatMessagesFromState()
        recomputeTodayStats()
    }

    private static func mergeChatHistory(
        base: [ChatMessage],
        current: [ChatMessage],
        updated: [ChatMessage]
    ) -> [ChatMessage] {
        guard updated != base else { return current }
        guard updated.starts(with: base) else { return updated }

        var merged = current
        for message in updated.dropFirst(base.count) where !merged.contains(where: { $0.id == message.id }) {
            merged.append(message)
        }
        return merged
    }

    private static func mergePolicyMemory(
        base: PolicyMemory,
        current: PolicyMemory,
        updated: PolicyMemory
    ) -> PolicyMemory {
        guard updated != base else { return current }

        let baseRules = Dictionary(uniqueKeysWithValues: base.rules.map { ($0.id, $0) })
        let updatedRules = Dictionary(uniqueKeysWithValues: updated.rules.map { ($0.id, $0) })
        var mergedRules = Dictionary(uniqueKeysWithValues: current.rules.map { ($0.id, $0) })

        for (id, rule) in updatedRules {
            if baseRules[id] != rule || baseRules[id] == nil {
                mergedRules[id] = rule
            }
        }

        let removedIDs = Set(baseRules.keys).subtracting(updatedRules.keys)
        for id in removedIDs where mergedRules[id] == baseRules[id] {
            mergedRules.removeValue(forKey: id)
        }

        var merged = current
        merged.rules = Array(mergedRules.values).sorted {
            if $0.priority == $1.priority {
                return $0.updatedAt > $1.updatedAt
            }
            return $0.priority > $1.priority
        }

        if updated.tonePreference != base.tonePreference {
            merged.tonePreference = updated.tonePreference
        }
        if updated.lastUpdatedAt != base.lastUpdatedAt {
            merged.lastUpdatedAt = max(updated.lastUpdatedAt ?? .distantPast, current.lastUpdatedAt ?? .distantPast)
        }

        return merged
    }

    /// Build a compact, prompt-safe summary of a profile (name, description, top rules).
    func configureBrainIfNeeded() {
        guard let executiveArm else {
            return
        }

        if brainService == nil {
            let brainService = BrainService(
                monitoringAlgorithmRegistry: monitoringAlgorithmRegistry,
                executiveArm: executiveArm,
                storageService: storageService,
                telemetryStore: telemetryStore
            )

            brainService.stateProvider = { [weak self] in
                self?.state ?? ACState()
            }
            brainService.stateSink = { [weak self] baseState, updatedState in
                self?.mergeBrainState(base: baseState, updated: updatedState)
            }
            brainService.moodSink = { [weak self] mood in
                guard self?.companionMood != mood else { return }
                self?.companionMood = mood
            }
            brainService.statusSink = { [weak self] status in
                guard self?.activityStatusText != status else { return }
                self?.activityStatusText = status
            }
            brainService.modelUsageSink = { [weak self] identifier in
                self?.noteUsedModel(identifier)
            }
            brainService.hardEscalationReopenSink = { [weak self] appName in
                self?.showHardEscalationOnReopen(appName: appName)
            }
            brainService.lastCheckSink = { [weak self] date in
                self?.lastMonitoringCheckAt = date
            }
            brainService.connectionProblemSink = { [weak self] notice in
                self?.connectionProblemNotice = notice
            }
            brainService.runtimeStandbySink = { [weak self] in
                guard let self else { return }
                await self.suspendMonitoringRuntime()
            }

            self.brainService = brainService
            brainService.start()
        }

        refreshSystemState()
    }

    static func effectiveSetupModelIdentifier(for configuration: MonitoringConfiguration) -> String {
        if configuration.usesOnlineInference {
            return configuration.onlineModelIdentifierImage
                ?? configuration.onlineModelIdentifierText
                ?? configuration.onlineModelIdentifier
        }
        return configuration.localModelIdentifierImage
            ?? configuration.localModelIdentifierText
            ?? AITier.balanced.localModelIdentifierText
    }

    private func suspendMonitoringRuntime() async {
        await localModelRuntime.shutdown()
    }

    func noteUsedModel(_ identifier: String?) {
        guard let normalized = identifier?.trimmingCharacters(in: .whitespacesAndNewlines),
              !normalized.isEmpty else {
            return
        }
        lastUsedModelIdentifier = normalized
    }



    /// Seeds the Everyday profile with default allow-rules for apps that were previously
    /// hardcoded as "clearly productive". Users can see and delete these in Settings.
    private static func seedDefaultSafelistIfNeeded(into state: inout ACState) {
        let defaultProfileID = PolicyRule.defaultProfileID
        let alreadyHasDefaultSafelist = state.policyMemory.rules.contains {
            $0.kind == .allow && $0.source == .system && $0.profileID == defaultProfileID
        }
        guard !alreadyHasDefaultSafelist else { return }

        let appName = Bundle.main.infoDictionary?["CFBundleName"] as? String ?? "AccountyCat"
        let appBundleID = Bundle.main.bundleIdentifier ?? "unknown"
        let defaults: [(bundleID: String, appName: String)] = [
            ("com.apple.calculator", "Calculator"),
            ("com.apple.finder", "Finder"),
            (appBundleID, appName),
        ]

        for entry in defaults {
            let rule = PolicyRule(
                kind: .allow,
                summary: "Allow \(entry.appName) (default safelist)",
                source: .system,
                priority: 50,
                scope: PolicyRuleScope(bundleIdentifier: entry.bundleID, appName: entry.appName),
                profileID: defaultProfileID
            )
            state.policyMemory.rules.append(rule)
        }
    }

    func logActivity(_ category: String, _ message: String, level: LogLevel = .standard) {
        Task {
            await ActivityLogService.shared.append(level: level, category: category, message: message)
        }
    }

    func setMinimumLogLevel(_ level: LogLevel) {
        state.minimumLogLevel = level
        Task { await ActivityLogService.shared.setMinimumLogLevel(level) }
        logActivity("app", "Log level set to \(level.displayName)", level: .error)
        persistState()
    }
}

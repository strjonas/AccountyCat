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

enum LocalModelWarmupState: Equatable {
    case idle
    case warming
    case startingForRequest
    case ready
}

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
    @Published var composerDraft = ""
    @Published var sendingOverlayAppeal = false
    @Published var installingRuntime = false
    @Published var installingDependencies = false
    @Published var setupProgressValue: Double?
    @Published var setupProgressMessage: String?
    @Published var setupDownloadedBytes: Int64?
    @Published var setupTotalBytes: Int64?
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
    /// Settings tab a deep-link wants shown. Set just before opening Settings; the
    /// SettingsView consumes and clears it on appear. Survives the open even though
    /// SettingsView mounts a beat after the notification fires (a plain notification
    /// would be missed by the not-yet-subscribed view).
    @Published var pendingSettingsTab: SettingsTab?
    @Published var activityStatusText = "Checking permissions and local runtime."
    @Published var chatMessages: [ChatMessage]
    @Published var sendingChatMessage = false
    @Published var resolvingChatActions = false
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
    /// True when local inference is active and Low Power Mode is on.
    @Published var localModelLowPowerNotice = false
    @Published var localModelLowPowerNoticeDismissed = false
    /// Short-lived user-facing state for the first local model load after launch,
    /// backend switch, or idle server shutdown. The model files are persisted, but
    /// the warm in-memory server/cache is not.
    @Published var localModelWarmupState: LocalModelWarmupState = .idle
    /// Worst-case safety net: surfaced when a *custom* partner's description keeps
    /// producing unparseable model output, so the user knows to simplify it rather
    /// than think AC is broken. Should never appear in normal use.
    @Published var characterParseProblemNotice: String?
    private var consecutiveCustomCharacterParseFailures = 0
    /// Bumped whenever a custom partner's portrait files are rewritten in place.
    /// Threaded into the view tree as `\.characterPortraitRevision` so portraits
    /// re-read from disk on an edit — the character itself compares equal by id,
    /// so a same-id image swap wouldn't otherwise invalidate the cached pixels.
    @Published private(set) var portraitRevision = 0
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
    /// Closure set by AppDelegate to keep the popover open across a modal system
    /// panel (e.g. the app picker), so resign-active doesn't tear it down.
    var suppressPopoverAutoClose: ((Bool) -> Void)?

    /// How many recent messages (non-system) are sent to the LLM for context.
    static let chatContextWindow = 8

    let storageService: StorageService
    /// Offline portrait storage for custom accountability partners.
    let characterImageStore: CharacterImageStore
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
    var downloadProgressTask: Task<Void, Never>?
    private var telemetryHeartbeatTask: Task<Void, Never>?
    var prewarmTask: Task<Void, Never>?
    var memoryConsolidationTask: Task<Void, Never>?
    var memoryConsolidationRetryTask: Task<Void, Never>?
    var activeScheduledTimers: [UUID: DispatchWorkItem] = [:]

    private init() {
        self.storageService = StorageService()
        self.characterImageStore = CharacterImageStore()
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
        let migrated = Self.migrateDeprecatedOnlineModelIdentifiers(in: &state)
        let reconciledModels = Self.reconcileAIModelSelection(in: &state)
        let reconciledCadence = Self.reconcileCadenceTitleLength(in: &state)
        self.state = state
        if migrated || reconciledModels || reconciledCadence {
            storageService.saveState(state)
            if migrated {
                Self.clearStaleOpenRouterHealthBans()
            }
        }
        self.onlineAPIKeyDraft = OnlineProviderCredentialStore.loadOpenRouterAPIKey() ?? ""
        self.directOpenAIAPIKeyDraft = OnlineProviderCredentialStore.loadDirectOpenAIAPIKey() ?? ""
        self.directOpenAIEnabled = OnlineProviderRoutingStore.loadDirectOpenAIEnabled()
        self.setupDiagnostics = RuntimeSetupService.inspect(
            runtimeOverride: state.runtimePathOverride,
            modelIdentifier: Self.effectiveSetupModelIdentifier(for: state.monitoringConfiguration)
        )
        self.pendingLocalModelChange = Self.pendingLocalModelChange(from: state)
        self.lastUsedModelIdentifier = nil
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
        // Tests must never write portraits into the real Application Support dir.
        self.characterImageStore = CharacterImageStore.temporary()
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
        let migrated = Self.migrateDeprecatedOnlineModelIdentifiers(in: &state)
        let reconciledModels = Self.reconcileAIModelSelection(in: &state)
        let reconciledCadence = Self.reconcileCadenceTitleLength(in: &state)
        self.state = state
        if migrated || reconciledModels || reconciledCadence {
            storageService.saveState(state)
            if migrated {
                Self.clearStaleOpenRouterHealthBans()
            }
        }
        self.onlineAPIKeyDraft = OnlineProviderCredentialStore.loadOpenRouterAPIKey() ?? ""
        self.directOpenAIAPIKeyDraft = OnlineProviderCredentialStore.loadDirectOpenAIAPIKey() ?? ""
        self.directOpenAIEnabled = OnlineProviderRoutingStore.loadDirectOpenAIEnabled()
        self.setupDiagnostics = RuntimeSetupService.inspect(
            runtimeOverride: state.runtimePathOverride,
            modelIdentifier: Self.effectiveSetupModelIdentifier(for: state.monitoringConfiguration)
        )
        self.pendingLocalModelChange = Self.pendingLocalModelChange(from: state)
        self.lastUsedModelIdentifier = nil
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
        resumePendingLocalModelDownloadIfNeeded()
        configureBrainIfNeeded()
        restorePendingScheduledActions()
        recomputeTodayStats()
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name.NSProcessInfoPowerStateDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated {
                self.updateLocalModelLowPowerNotice()
            }
        }
        schedulePrewarmIfNeeded()
    }

    /// Best-effort: when running locally with the model already installed, warm the
    /// shared llama-server and the stable chat/decision prefixes so the next real
    /// interaction isn't a cold prefill. Fired on launch and whenever the backend
    /// switches to Local (where the first query would otherwise pay the full cold
    /// model-load + prefill). Cheap, cancellable, never blocks the UI; the runtime
    /// schedules its own idle shutdown afterwards.
    func schedulePrewarmIfNeeded() {
        guard state.monitoringConfiguration.inferenceBackend == .local,
              !state.isPaused,
              setupDiagnostics.runtimePresent,
              setupDiagnostics.modelArtifactsPresent else {
            localModelWarmupState = .idle
            return
        }

        let runtimePath = RuntimeSetupService.normalizedRuntimePath(from: state.runtimePathOverride)
        let modelIdentifier = runtimeProfileModelIdentifier()
        let personaPrefix = state.character.personalityPrefix
        let chatPrompt = ACPromptSets.chatSystemPrompt(
            withPersonality: personaPrefix,
            expressivenessDirective: state.character.expressiveness.chatDirective
        )

        prewarmTask?.cancel()
        localModelWarmupState = .warming
        prewarmTask = Task(priority: .utility) { [weak self, localModelRuntime] in
            await localModelRuntime.prewarm(
                runtimePath: runtimePath,
                modelIdentifier: modelIdentifier,
                prompts: [
                    (.chat, chatPrompt),
                ]
            )
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self else { return }
                self.localModelWarmupState = .ready
            }
        }
    }

    func cancelPrewarmForInteractiveChat() {
        guard prewarmTask != nil else { return }
        prewarmTask?.cancel()
        prewarmTask = nil
        if localModelWarmupState == .warming {
            localModelWarmupState = .startingForRequest
        }
    }

    func shutdown() async {
        persistState()
        prewarmTask?.cancel()
        prewarmTask = nil
        memoryConsolidationTask?.cancel()
        memoryConsolidationTask = nil
        memoryConsolidationRetryTask?.cancel()
        memoryConsolidationRetryTask = nil
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

        let modelIdentifier = Self.effectiveSetupModelIdentifier(for: state.monitoringConfiguration)
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
        updateLocalModelLowPowerNotice()

        if persist {
            persistState()
        }
    }

    private func updateLocalModelLowPowerNotice() {
        let active = !state.monitoringConfiguration.usesOnlineInference
            && ProcessInfo.processInfo.isLowPowerModeEnabled
        if !active {
            localModelLowPowerNoticeDismissed = false
        }
        localModelLowPowerNotice = active
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

    func updateAppMonitoringScopeMode(_ mode: AppMonitoringScopeMode) {
        guard state.appMonitoringScopeMode != mode else { return }
        state.appMonitoringScopeMode = mode
        brainService?.handleMonitoringConfigurationChange()
        persistState()
        logActivity("monitoring", "App monitoring scope mode: \(mode.rawValue)")
    }

    func importAppMonitoringSelectionsFromPanel() {
        let panel = NSOpenPanel()
        panel.title = "Choose apps for AccountyCat scope"
        switch state.appMonitoringScopeMode {
        case .allowlist:
            panel.message = "Pick the apps AC should monitor. Everything else is left alone."
        case .blocklist:
            panel.message = "Pick the apps AC should skip. It keeps watching everything else."
        case .disabled:
            panel.message = "Pick apps from Applications to scope AC's monitoring."
        }
        panel.prompt = "Add Apps"
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.application]

        // The system open panel takes key window, which would otherwise trip the
        // resign-active handler and tear the popover down. Hold it open so the user
        // lands back on this exact settings view after picking.
        suppressPopoverAutoClose?(true)
        defer { suppressPopoverAutoClose?(false) }

        guard panel.runModal() == .OK else { return }
        addAppMonitoringSelections(from: panel.urls)
    }

    func addAppMonitoringSelections(from urls: [URL]) {
        let mode = state.appMonitoringScopeMode
        guard mode != .disabled else { return }
        let selections = urls.compactMap(Self.appMonitoringSelection(from:))
        guard !selections.isEmpty else { return }

        var merged = Dictionary(
            uniqueKeysWithValues: state.appMonitoringSelections(for: mode).map { ($0.bundleIdentifier, $0) })
        for entry in selections {
            merged[entry.bundleIdentifier] = entry
        }
        let updated = merged.values.sorted {
            $0.appName.localizedCaseInsensitiveCompare($1.appName) == .orderedAscending
        }
        guard updated != state.appMonitoringSelections(for: mode) else { return }

        state.setAppMonitoringSelections(updated, for: mode)
        brainService?.handleMonitoringConfigurationChange()
        persistState()
        logActivity("monitoring", "App monitoring \(mode.rawValue) updated: \(updated.count) app(s)")
    }

    func removeAppMonitoringSelection(bundleIdentifier: String) {
        let mode = state.appMonitoringScopeMode
        guard mode != .disabled else { return }
        let current = state.appMonitoringSelections(for: mode)
        let filtered = current.filter { $0.bundleIdentifier != bundleIdentifier }
        guard filtered.count != current.count else { return }

        state.setAppMonitoringSelections(filtered, for: mode)
        brainService?.handleMonitoringConfigurationChange()
        persistState()
        logActivity("monitoring", "Removed app from \(mode.rawValue): \(bundleIdentifier)")
    }

    func setSkipPrivateBrowserWindows(_ enabled: Bool) {
        guard state.skipPrivateBrowserWindows != enabled else { return }
        state.skipPrivateBrowserWindows = enabled
        brainService?.handleMonitoringConfigurationChange()
        persistState()
        logActivity("monitoring", "Skip private browser windows: \(enabled)")
    }

    func addBrowserTabMonitoringExclusion(from context: FrontmostContext) {
        guard MonitoringHeuristics.isBrowser(bundleIdentifier: context.bundleIdentifier),
              let title = context.windowTitle?.cleanedSingleLine,
              !title.isEmpty else {
            return
        }
        addBrowserTabMonitoringExclusion(
            bundleIdentifier: context.bundleIdentifier,
            appName: context.appName,
            titleContains: BrowserTitleSignature.derive(from: title) ?? title
        )
    }

    func addBrowserTabMonitoringExclusion(
        bundleIdentifier: String?,
        appName: String,
        titleContains: String
    ) {
        let title = titleContains.cleanedSingleLine
        let appName = appName.cleanedSingleLine
        guard !title.isEmpty, !appName.isEmpty else { return }
        let entry = BrowserTabMonitoringExclusion(
            bundleIdentifier: bundleIdentifier,
            appName: appName,
            titleContains: String(title.prefix(120))
        )
        let entryKey = browserTabMonitoringExclusionKey(entry)
        var updated = state.browserTabMonitoringExclusions
            .filter { browserTabMonitoringExclusionKey($0) != entryKey }
        updated.append(entry)
        updated.sort {
            $0.displayTitle.localizedCaseInsensitiveCompare($1.displayTitle) == .orderedAscending
        }
        state.browserTabMonitoringExclusions = updated
        brainService?.handleMonitoringConfigurationChange()
        persistState()
        logActivity("monitoring", "Browser tab monitoring exclusion added: \(entry.appName) / \(entry.titleContains)")
    }

    func removeBrowserTabMonitoringExclusion(id: String) {
        let current = state.browserTabMonitoringExclusions
        let updated = current.filter { $0.id != id }
        guard updated.count != current.count else { return }
        state.browserTabMonitoringExclusions = updated
        brainService?.handleMonitoringConfigurationChange()
        persistState()
        logActivity("monitoring", "Browser tab monitoring exclusion removed: \(id)")
    }

    private func browserTabMonitoringExclusionKey(_ entry: BrowserTabMonitoringExclusion) -> String {
        [
            entry.bundleIdentifier?.cleanedSingleLine.lowercased()
                ?? entry.appName.cleanedSingleLine.lowercased(),
            entry.titleContains.cleanedSingleLine.lowercased()
        ].joined(separator: "|")
    }

    private static func appMonitoringSelection(from url: URL) -> AppMonitoringSelection? {
        guard url.pathExtension.caseInsensitiveCompare("app") == .orderedSame else { return nil }
        guard let bundle = Bundle(url: url) else { return nil }
        guard let bundleIdentifier = bundle.bundleIdentifier?.cleanedSingleLine, !bundleIdentifier.isEmpty else {
            return nil
        }

        let appName =
            (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)?
            .cleanedSingleLine
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)?.cleanedSingleLine
            ?? url.deletingPathExtension().lastPathComponent.cleanedSingleLine
        guard !appName.isEmpty else { return nil }

        return AppMonitoringSelection(
            bundleIdentifier: bundleIdentifier,
            appName: appName
        )
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
        // A fresh partner gets a clean slate for the parse-trouble heuristic.
        consecutiveCustomCharacterParseFailures = 0
        characterParseProblemNotice = nil
        logActivity("app", "Selected character: \(character.displayName)")
        persistState()
    }

    /// Track whether a chat turn parsed into structured JSON. After several
    /// consecutive failures *while a custom partner is active*, surface a gentle
    /// banner — a confusing description is the likeliest culprit. Resets on any
    /// success. Built-in characters never trip it.
    func noteChatParseOutcome(structured: Bool) {
        guard state.character.origin == .custom else {
            consecutiveCustomCharacterParseFailures = 0
            characterParseProblemNotice = nil
            return
        }
        if structured {
            consecutiveCustomCharacterParseFailures = 0
            characterParseProblemNotice = nil
        } else {
            consecutiveCustomCharacterParseFailures += 1
            if consecutiveCustomCharacterParseFailures >= 3 {
                characterParseProblemNotice =
                    "\(state.character.displayName) seems to be confusing the model. Try simplifying this partner's description in Settings → Look."
            }
        }
    }

    func dismissCharacterParseProblemNotice() {
        characterParseProblemNotice = nil
        consecutiveCustomCharacterParseFailures = 0
    }

    // MARK: - Custom accountability partners

    /// Create or update a custom character. Persists its definition; does not
    /// change the active selection. Use `updateCharacter` to activate it.
    func upsertCustomCharacter(_ character: ACCharacter) {
        guard character.origin == .custom else { return }
        objectWillChange.send()
        if let idx = state.customCharacters.firstIndex(where: { $0.id == character.id }) {
            state.customCharacters[idx] = character
            // The portrait PNGs may have been rewritten in place — same id, same
            // `.files` directory. Characters compare equal by id, so bump this
            // signal to invalidate any cached portrait (see `characterPortraitRevision`).
            portraitRevision &+= 1
            logActivity("app", "Updated custom partner: \(character.displayName)")
        } else {
            state.customCharacters.append(character)
            logActivity("app", "Created custom partner: \(character.displayName)")
        }
        // If this is the active character, keep the resolved copy fresh.
        if state.characterID == character.id {
            state.character = character
        }
        persistState()
    }

    /// Delete a custom character and its stored portraits. If it was active,
    /// fall back to the default cat so the UI never points at nothing.
    func deleteCustomCharacter(id: String) {
        guard state.customCharacters.contains(where: { $0.id == id }) else { return }
        let wasActive = state.characterID == id
        state.customCharacters.removeAll { $0.id == id }
        if wasActive {
            state.character = .mochi
        }
        characterImageStore.removeAll(for: id)
        logActivity("app", "Deleted custom partner: \(id)")
        persistState()
    }

    func updateGlassMode(_ mode: ACGlassMode) {
        guard state.glassMode != mode else { return }
        state.glassMode = mode
        logActivity("app", "Glass mode: \(mode.rawValue)")
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
            streakDays: focusStreakDays(now: now, todayTrackedSeconds: total),
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

    private func focusStreakDays(now: Date, todayTrackedSeconds: TimeInterval) -> Int {
        let cal = Calendar.current
        var streak = 0
        var cursor = cal.startOfDay(for: now)
        var isToday = true

        while true {
            let nextDay = cal.date(byAdding: .day, value: 1, to: cursor) ?? cursor.addingTimeInterval(24 * 60 * 60)
            let focusedSeconds = state.focusSegments
                .filter { $0.assessment == .focused && $0.endAt > cursor && $0.startAt < nextDay }
                .reduce(0) { $0 + clampedDuration($1, start: cursor, end: nextDay) }
            // Today counts with any tracked time; past days require 20 min focused
            let qualifies = isToday ? todayTrackedSeconds > 0 : focusedSeconds >= 20 * 60
            guard qualifies else { return streak }
            streak += 1
            isToday = false
            guard let previous = cal.date(byAdding: .day, value: -1, to: cursor) else { return streak }
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
                runtime: localModelRuntime,
                storageService: storageService,
                telemetryStore: telemetryStore
            )

            brainService.stateProvider = { [weak self] in
                self?.state ?? ACState()
            }
            brainService.overlayActiveProvider = { [weak self] in
                self?.overlayVisible ?? false
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

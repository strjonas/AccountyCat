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
    /// True once the user has completed the first-run onboarding wizard. Stored in
    /// UserDefaults (not ACState) so it survives state resets.
    @Published var hasCompletedOnboardingWizard: Bool
    /// Set by WindowCoordinator when the orb is snapped to a screen edge (peek mode).
    @Published var peekingEdge: NSRectEdge? = nil
    /// Populated by `refreshAvailableCalendars()` once Calendar Intelligence is
    /// enabled and permission is granted. Empty while the feature is off so the
    /// Settings UI has nothing to render before the user opts in.
    @Published var availableCalendars: [ACCalendarInfo] = []

    /// Closure set by AppDelegate to allow UI components (like ContentView's X button)
    /// to close the main NSPopover.
    var dismissPopover: (() -> Void)?
    /// Closure set by AppDelegate so compact controls can open the full app popover on demand.
    var openMainPopover: (() -> Void)?
    /// Closure set by AppDelegate so compact controls can dismiss the menu-bar quick popover.
    var dismissProfilePopover: (() -> Void)?

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
    private var hasPerformedInitialRefresh = false
    private var onboardingCompletionTask: DispatchWorkItem?
    private var lastPromptedDependencySignature: String?
    private var statsSnapshotCache: [StatsWindow: MonitoringStatsSnapshot] = [:]
    private var installRuntimeTask: Task<Void, Never>?
    private var activeScheduledTimers: [UUID: DispatchWorkItem] = [:]

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
        self.state = loadedState
        self.onlineAPIKeyDraft = OnlineModelCredentialStore.loadAPIKey() ?? ""
        self.setupDiagnostics = RuntimeSetupService.inspect(
            runtimeOverride: loadedState.runtimePathOverride,
            modelIdentifier: Self.effectiveSetupModelIdentifier(for: loadedState.monitoringConfiguration)
        )
        self.chatMessages = Self.makeChatMessages(from: loadedState.chatHistory)
        self.hasCompletedOnboardingWizard = UserDefaults.standard.bool(forKey: "acOnboardingWizardCompleted")

        Task { @MainActor [weak self] in
            await ActivityLogService.shared.setMinimumLogLevel(loadedState.minimumLogLevel)
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
        self.state = loadedState
        self.onlineAPIKeyDraft = OnlineModelCredentialStore.loadAPIKey() ?? ""
        self.setupDiagnostics = RuntimeSetupService.inspect(
            runtimeOverride: loadedState.runtimePathOverride,
            modelIdentifier: Self.effectiveSetupModelIdentifier(for: loadedState.monitoringConfiguration)
        )
        self.chatMessages = Self.makeChatMessages(from: loadedState.chatHistory)
        self.hasCompletedOnboardingWizard = UserDefaults.standard.bool(forKey: "acOnboardingWizardCompleted")

        Task { @MainActor [weak self] in
            await ActivityLogService.shared.setMinimumLogLevel(loadedState.minimumLogLevel)
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
            }
        }
        refreshSystemState(persist: false)
        configureBrainIfNeeded()
        restorePendingScheduledActions()
        recomputeTodayStats()
    }

    func shutdown() async {
        persistState()
        await localModelRuntime.shutdown()
        await telemetryStore.endCurrentSession(reason: "app_termination")
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
            state.setupStatus = hasOnlineAPIKeyConfigured ? .ready : .needsRuntime
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

    var selectedLocalModelIdentifier: String {
        pendingLocalModelChange?.modelIdentifier
            ?? state.monitoringConfiguration.localModelIdentifierImage
            ?? state.monitoringConfiguration.localModelIdentifierText
            ?? state.aiTier.localModelIdentifierText
    }

    var localModelDiagnostics: RuntimeDiagnostics {
        RuntimeSetupService.inspect(
            runtimeOverride: state.runtimePathOverride,
            modelIdentifier: selectedLocalModelIdentifier
        )
    }

    var installedManagedModels: [InstalledLocalModel] {
        RuntimeSetupService.managedInstalledModels()
    }

    var selectedInstalledModel: InstalledLocalModel? {
        let installed = installedManagedModels
        guard !installed.isEmpty else { return nil }

        if let selectedInstalledModelCachePath,
           let exact = installed.first(where: { $0.cachePath == selectedInstalledModelCachePath }) {
            return exact
        }

        if let current = installed.first(where: { $0.modelIdentifier == selectedLocalModelIdentifier }) {
            return current
        }

        return installed.first
    }

    func selectInstalledModel(cachePath: String) {
        selectedInstalledModelCachePath = cachePath
    }

    func revealManagedModelLocation() {
        localModelStorageError = nil
        guard let selectedInstalledModel else {
            localModelStorageError = "No AC-downloaded local models were found."
            return
        }
        let targetPath = selectedInstalledModel.modelPath
        let url = URL(fileURLWithPath: targetPath)
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
            return
        }

        let parentURL = url.deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: parentURL.path) else {
            localModelStorageError = "The model folder does not exist yet."
            return
        }

        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: parentURL.path)
    }

    func deleteManagedModels() {
        guard !deletingManagedModels else { return }
        guard let selectedInstalledModel else {
            localModelStorageError = "No AC-downloaded local models were found."
            return
        }

        deletingManagedModels = true
        localModelStorageMessage = nil
        localModelStorageError = nil

        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.localModelRuntime.shutdown()

            do {
                let removed = try RuntimeSetupService.deleteCachesCreatedByAC(
                    for: selectedInstalledModel.modelIdentifier,
                    selectedCachePath: selectedInstalledModel.cachePath,
                    runtimePath: RuntimeSetupService.normalizedRuntimePath(from: self.state.runtimePathOverride)
                )
                self.pendingLocalModelChange = nil
                self.modelDownloadNotice = nil
                self.modelDownloadSuccess = nil
                self.refreshSystemState()
                let remaining = self.installedManagedModels
                self.selectedInstalledModelCachePath = remaining.first?.cachePath
                self.localModelStorageMessage = removed > 0
                    ? "Deleted \(Self.shortModelName(for: selectedInstalledModel.modelIdentifier))."
                    : "That AC-downloaded local model was already gone."
            } catch {
                self.localModelStorageError = error.localizedDescription
            }

            self.deletingManagedModels = false
        }
    }

    func importCurrentModelToOllama() {
        guard !importingModelToOllama else { return }
        guard let selectedInstalledModel else {
            localModelStorageError = "Download a local model first."
            return
        }
        guard let ollamaPath = Self.resolvedExecutablePath("ollama") else {
            localModelStorageError = "Ollama is not installed or not on PATH."
            return
        }

        importingModelToOllama = true
        localModelStorageMessage = nil
        localModelStorageError = nil

        let ollamaModelName = Self.ollamaModelName(for: selectedInstalledModel.modelIdentifier)
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await Self.importModelToOllama(
                    ollamaPath: ollamaPath,
                    modelPath: selectedInstalledModel.modelPath,
                    modelName: ollamaModelName
                )
                self.localModelStorageMessage = "Imported to Ollama as \(ollamaModelName). Ollama stores its own copy; check `ollama list`."
            } catch {
                self.localModelStorageError = error.localizedDescription
            }
            self.importingModelToOllama = false
        }
    }

    func updateGoals(_ text: String) {
        state.goalsText = text
        persistState()
    }

    // MARK: - Brain — rule management

    func addUserRule(
        _ summary: String,
        kind: PolicyRuleKind,
        appName: String? = nil,
        profileID: String? = nil
    ) {
        let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var scope = PolicyRuleScope()
        if let name = appName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            scope.appName = name
        }
        let rule = PolicyRule(
            kind: kind,
            summary: trimmed,
            source: .explicitFeedback,
            priority: 75,
            scope: scope,
            profileID: profileID ?? state.activeProfileID
        )
        state.policyMemory.apply(PolicyMemoryUpdateResponse(operations: [
            PolicyMemoryOperation(type: .addRule, rule: rule)
        ]))
        persistState()
        logActivity("brain", "User added rule: \(trimmed)")
    }

    func deleteRule(id: String) {
        let removedRule = state.policyMemory.rules.first { $0.id == id }
        if let removedRule, removedRule.isAutoSafelistRule {
            let now = Date()
            let scope = removedRule.safelistMemoryScopeDescription
            appendMemoryLine("• Safelist correction: Do not auto-safelist \(scope). User manually removed this safelist rule.")
            for key in Array(state.algorithmState.llmPolicy.focusedObservations.keys) {
                guard state.algorithmState.llmPolicy.focusedObservations[key]?.lastAutoAllowRuleID == id else { continue }
                state.algorithmState.llmPolicy.focusedObservations[key]?.previousAutoAllowOutcome = .revokedByUser
                state.algorithmState.llmPolicy.focusedObservations[key]?.lastAutoAllowRuleID = nil
                state.algorithmState.llmPolicy.focusedObservations[key]?.lastPromotionOutcome = .denied
                state.algorithmState.llmPolicy.focusedObservations[key]?.lastPromotionReason = "User manually removed this safelist rule."
                state.algorithmState.llmPolicy.focusedObservations[key]?.lastPromotionCheckedAt = now
            }
        }
        state.policyMemory.rules.removeAll { $0.id == id }
        state.policyMemory.lastUpdatedAt = Date()
        persistState()
        logActivity("brain", "User deleted rule: \(id)")
    }

    private nonisolated static func importModelToOllama(
        ollamaPath: String,
        modelPath: String,
        modelName: String
    ) async throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AC-Ollama-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let modelfileURL = tempDirectory.appendingPathComponent("Modelfile")
        let modelfileContents = "FROM \(modelPath)\n"
        try modelfileContents.write(to: modelfileURL, atomically: true, encoding: .utf8)

        _ = try await runProcess(
            launchPath: ollamaPath,
            arguments: ["create", modelName, "-f", modelfileURL.path],
            currentDirectory: tempDirectory
        )
    }

    private nonisolated static func ollamaModelName(for modelIdentifier: String) -> String {
        let repository = RuntimeSetupService.repositoryIdentifier(for: modelIdentifier)
        let quant = modelIdentifier.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).dropFirst().first.map(String.init) ?? ""
        let rawName = "ac-\(repository)-\(quant)"
        let lower = rawName.lowercased()
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-._")
        let scalars = lower.unicodeScalars.map { scalar -> Character in
            allowed.contains(scalar) ? Character(scalar) : "-"
        }
        let collapsed = String(scalars)
            .replacingOccurrences(of: "--", with: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return collapsed.isEmpty ? "ac-local-model" : collapsed
    }

    private nonisolated static func resolvedExecutablePath(_ tool: String) -> String? {
        let commonLocations = [
            "/usr/bin/\(tool)",
            "/usr/local/bin/\(tool)",
            "/opt/homebrew/bin/\(tool)",
        ]
        if let match = commonLocations.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return match
        }

        return ProcessInfo.processInfo.environment["PATH"]?
            .split(separator: ":")
            .map(String.init)
            .map { "\($0)/\(tool)" }
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) })
    }

    private nonisolated static func runProcess(
        launchPath: String,
        arguments: [String],
        currentDirectory: URL
    ) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectory

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let stdoutBuffer = ProcessOutputBuffer()
        let stderrBuffer = ProcessOutputBuffer()

        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            stdoutBuffer.append(data)
        }

        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            stderrBuffer.append(data)
        }

        try process.run()
        let status = await withCheckedContinuation { continuation in
            process.terminationHandler = { finishedProcess in
                continuation.resume(returning: finishedProcess.terminationStatus)
            }
        }

        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        let stdout = String(decoding: stdoutBuffer.snapshot(), as: UTF8.self)
        let stderr = String(decoding: stderrBuffer.snapshot(), as: UTF8.self)

        guard status == 0 else {
            throw LocalModelStorageActionError.commandFailed(
                command: ([launchPath] + arguments).joined(separator: " "),
                status: status,
                output: stderr.isEmpty ? stdout : stderr
            )
        }

        return stdout
    }

    func toggleRuleLocked(id: String) {
        guard let i = state.policyMemory.rules.firstIndex(where: { $0.id == id }) else { return }
        state.policyMemory.rules[i].isLocked.toggle()
        state.policyMemory.rules[i].updatedAt = Date()
        persistState()
        logActivity("brain", "Rule \(state.policyMemory.rules[i].isLocked ? "locked" : "unlocked"): \(id)")
    }

    // MARK: - Focus profiles

    /// Activate an existing profile by id with an optional explicit expiry.
    /// When `expiresAt` is nil, AC picks a 90-minute default for named profiles.
    /// No-op for unknown ids; default profile activations always succeed.
    @discardableResult
    func activateProfile(
        id: String,
        expiresAt: Date? = nil,
        reason: String? = nil,
        announce: Bool = false
    ) -> Bool {
        let now = Date()
        state.ensureDefaultProfileExists()
        guard let index = state.profiles.firstIndex(where: { $0.id == id }) else {
            logActivity("profile", "Activate failed — unknown profile id: \(id)")
            return false
        }
        var profile = state.profiles[index]
        profile.activatedAt = now
        profile.lastUsedAt = now
        if profile.isDefault {
            profile.expiresAt = nil
        } else {
            profile.expiresAt = expiresAt ?? now.addingTimeInterval(90 * 60)
        }
        if let reason, !reason.isEmpty {
            profile.createdReason = reason
        }
        state.profiles[index] = profile
        state.activeProfileID = profile.id
        persistState()
        logActivity("profile", "Activated profile '\(profile.name)' until \(profile.expiresAt.map { ISO8601DateFormatter().string(from: $0) } ?? "default-no-expiry")")
        appendMonitoringMetric(kind: .profileChanged, reason: "activated", profile: profile, detail: reason)
        if announce {
            announceProfileSwitch(reason: reason)
        }
        return true
    }

    /// Activate an existing profile for a specific number of minutes from now.
    @discardableResult
    func activateProfile(
        id: String,
        durationMinutes: Int,
        reason: String? = nil,
        announce: Bool = false
    ) -> Bool {
        guard durationMinutes > 0 else { return false }
        let expiresAt = Date().addingTimeInterval(TimeInterval(durationMinutes) * 60)
        return activateProfile(
            id: id,
            expiresAt: expiresAt,
            reason: reason,
            announce: announce
        )
    }

    /// Create and activate a new named profile. Enforces the LRU cap.
    @discardableResult
    func createAndActivateProfile(
        name: String,
        description: String? = nil,
        duration: TimeInterval? = nil,
        reason: String? = nil
    ) -> FocusProfile? {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return nil }
        let now = Date()
        state.ensureDefaultProfileExists()
        let durationToUse = duration ?? 90 * 60
        let profile = FocusProfile(
            name: trimmedName,
            description: description,
            createdAt: now,
            lastUsedAt: now,
            activatedAt: now,
            expiresAt: now.addingTimeInterval(durationToUse),
            createdReason: reason
        )
        state.profiles.append(profile)
        evictLRUIfNeeded()
        state.activeProfileID = profile.id
        persistState()
        logActivity("profile", "Created+activated profile '\(profile.name)' for \(Int(durationToUse / 60))m")
        appendMonitoringMetric(kind: .profileChanged, reason: "created", profile: profile, detail: reason)
        return profile
    }

    /// End the active profile and switch back to default. No-op when default is already active.
    func endActiveProfile(announce: Bool = false) {
        guard state.activeProfileID != PolicyRule.defaultProfileID else { return }
        state.ensureDefaultProfileExists()
        if let i = state.profiles.firstIndex(where: { $0.id == state.activeProfileID }) {
            state.profiles[i].activatedAt = nil
            state.profiles[i].expiresAt = nil
        }
        state.activeProfileID = PolicyRule.defaultProfileID
        persistState()
        logActivity("profile", "Ended active profile, back to default")
        appendMonitoringMetric(kind: .profileChanged, reason: "ended", profile: state.activeProfile, detail: nil)
        if announce {
            announceProfileSwitch(reason: "ended")
        }
    }

    /// Extend the currently active named profile by the given number of minutes.
    @discardableResult
    func extendActiveProfile(
        byMinutes minutes: Int,
        reason: String? = "user_extended",
        announce: Bool = false
    ) -> Bool {
        guard minutes > 0 else { return false }
        let active = state.activeProfile
        guard !active.isDefault else { return false }
        let baseline = max(active.expiresAt ?? Date(), Date())
        let newExpiry = baseline.addingTimeInterval(TimeInterval(minutes) * 60)
        return activateProfile(
            id: active.id,
            expiresAt: newExpiry,
            reason: reason,
            announce: announce
        )
    }

    // MARK: - Scheduled actions

    func scheduleActionTimer(_ action: ScheduledAction) {
        let delay = action.fireAt.timeIntervalSince(Date())
        guard delay > 0 else {
            executeScheduledAction(action)
            return
        }
        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                self?.executeScheduledAction(action)
            }
        }
        activeScheduledTimers[action.id] = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    func executeScheduledAction(_ action: ScheduledAction) {
        guard let index = state.scheduledActions.firstIndex(where: { $0.id == action.id }),
              !state.scheduledActions[index].fired else { return }
        state.scheduledActions[index].fired = true

        switch action.type {
        case .nudge:
            let message = action.message ?? "Reminder from AccountyCat"
            executiveArm?.perform(.showNudge(message))
            recordDisplayedNudge(message)
            logActivity("schedule", "Fired scheduled nudge: \(message)")
        case .profileActivation:
            let name = action.profileName ?? ""
            if let profile = state.profiles.first(where: {
                $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame
            }) {
                activateProfile(id: profile.id)
            } else {
                createAndActivateProfile(name: name, duration: 90 * 60)
            }
            logActivity("schedule", "Fired scheduled profile activation: \(name)")
        }

        activeScheduledTimers.removeValue(forKey: action.id)
        persistState()
    }

    func restorePendingScheduledActions() {
        let now = Date()
        for index in state.scheduledActions.indices where !state.scheduledActions[index].fired {
            if state.scheduledActions[index].fireAt <= now {
                executeScheduledAction(state.scheduledActions[index])
            } else {
                scheduleActionTimer(state.scheduledActions[index])
            }
        }
    }

    /// Called by BrainService at the top of every monitoring tick. If the active profile has
    /// expired, swap to default and persist. Returns true when a swap happened (so the caller
    /// can post a deferred chat note).
    @discardableResult
    func pruneExpiredProfileIfActive(now: Date = Date()) -> FocusProfile? {
        let active = state.activeProfile
        guard !active.isDefault, active.isExpired(at: now) else { return nil }
        let expired = active
        endActiveProfile()
        return expired
    }

    /// Rename a profile. Cannot rename the default profile's id, but its display name is editable.
    func renameProfile(id: String, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let index = state.profiles.firstIndex(where: { $0.id == id }) else { return }
        state.profiles[index].name = trimmed
        persistState()
    }

    /// Update editable profile metadata from the Brain tab.
    func updateProfile(id: String, name: String, description: String?) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty,
              let index = state.profiles.firstIndex(where: { $0.id == id }) else { return }
        let trimmedDescription = description?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        state.profiles[index].name = trimmedName
        state.profiles[index].description = (trimmedDescription?.isEmpty == false)
            ? trimmedDescription
            : nil
        persistState()
        logActivity("profile", "Updated profile metadata: \(id)")
    }

    func lockedRuleCount(forProfileID id: String) -> Int {
        state.policyMemory.rules.filter { $0.profileID == id && $0.isLocked }.count
    }

    func canDeleteProfile(id: String) -> Bool {
        id != PolicyRule.defaultProfileID && lockedRuleCount(forProfileID: id) == 0
    }

    /// Delete a non-default profile. Also deletes any rules scoped to it.
    func deleteProfile(id: String) {
        guard id != PolicyRule.defaultProfileID else { return }
        guard canDeleteProfile(id: id) else {
            logActivity("profile", "Delete blocked — profile \(id) still has locked scoped rules")
            return
        }
        state.profiles.removeAll { $0.id == id }
        state.policyMemory.rules.removeAll { $0.profileID == id && !$0.isLocked }
        if state.activeProfileID == id {
            state.activeProfileID = PolicyRule.defaultProfileID
        }
        persistState()
        logActivity("profile", "Deleted profile: \(id)")
    }

    /// LRU eviction: if profile count > cap, remove the oldest unused non-default profile.
    private func evictLRUIfNeeded() {
        let cap = FocusProfile.maximumProfileCount
        while state.profiles.count > cap {
            let evictable = state.profiles
                .enumerated()
                .filter { !$0.element.isDefault && $0.element.id != state.activeProfileID }
                .min(by: { $0.element.lastUsedAt < $1.element.lastUsedAt })
            guard let (index, profile) = evictable else { break }
            state.profiles.remove(at: index)
            state.policyMemory.rules.removeAll { $0.profileID == profile.id && !$0.isLocked }
            logActivity("profile", "LRU-evicted profile '\(profile.name)' (last used \(profile.lastUsedAt))")
        }
    }

    private func appendMonitoringMetric(
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
    var activeModelShortName: String {
        let config = state.monitoringConfiguration
        
        let textModel: String?
        let imageModel: String?
        
        if config.usesOnlineInference {
            textModel = config.onlineModelIdentifierText
            imageModel = config.onlineModelIdentifierImage
        } else {
            textModel = config.localModelIdentifierText
            imageModel = config.localModelIdentifierImage
        }
        
        if let text = textModel, !text.isEmpty,
           let image = imageModel, !image.isEmpty,
           text != image {
            return "\(Self.veryShortModelName(for: text)) / \(Self.veryShortModelName(for: image))"
        }
        
        let id = lastUsedModelIdentifier ?? Self.effectiveSetupModelIdentifier(for: config)
        return Self.shortModelName(for: id)
    }

    /// Converts a full OpenRouter/local model identifier to a compact display name.
    static func shortModelName(for identifier: String) -> String {
        let raw = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = raw.hasSuffix(":free") ? String(raw.dropLast(5)) : raw

        // Known models → friendly names
        switch base {
        case "google/gemma-4-31b-it":              return "Gemma 4 31B"
        case "google/gemma-4-26b-a4b-it":          return "Gemma 4 26B"
        case "mistralai/mistral-small-3.1-24b-instruct": return "Mistral Small 3.1"
        case "mistralai/mistral-small-24b-instruct-2501": return "Mistral Small"
        case "meta-llama/llama-4-scout":           return "Llama 4 Scout"
        case "meta-llama/llama-4-maverick":        return "Llama 4 Maverick"
        case "anthropic/claude-3.5-haiku":         return "Claude 3.5 Haiku"
        case "anthropic/claude-3.5-sonnet":        return "Claude 3.5 Sonnet"
        case "anthropic/claude-3-haiku":           return "Claude 3 Haiku"
        case "google/gemini-flash-1.5":            return "Gemini Flash 1.5"
        case "google/gemini-2.0-flash-001":        return "Gemini 2 Flash"
        case "google/gemini-2.5-flash":            return "Gemini 2.5 Flash"
        case "google/gemini-2.5-flash-preview":    return "Gemini 2.5 Flash"
        case "google/gemini-3-flash-preview":      return "Gemini 3 Flash"
        case "qwen/qwen2.5-vl-72b-instruct":       return "Qwen 2.5 VL"
        case "qwen/qwen3.5-9b":                    return "Qwen 3.5 9B"
        case "nvidia/nemotron-3-super-120b-a12b":  return "Nemotron 3"
        case "deepseek/deepseek-v4-flash":         return "DeepSeek V4"
        case "unsloth/gemma-4-E2B-it-GGUF:Q4_0":   return "Gemma 4 2B"
        case "unsloth/gemma-4-E4B-it-GGUF:Q4_K_M": return "Gemma 4 4B"
        case "unsloth/Qwen3.5-4B-GGUF:UD-Q4_K_XL": return "Qwen 3.5 4B"
        case "unsloth/Qwen3.5-9B-GGUF:UD-Q4_K_XL": return "Qwen 3.5 9B"
        case "unsloth/Qwen3.6-27B-GGUF:UD-Q4_K_XL": return "Qwen 3.6 27B"

        default: break
        }

        // Generic fallback: strip provider prefix, truncate version noise
        let modelPart = base.components(separatedBy: "/").last ?? base
        let cleaned = modelPart
            .replacingOccurrences(of: "-instruct", with: "")
            .replacingOccurrences(of: "-it", with: "")
        return cleaned
    }

    /// Even more compact version for dual-model display (e.g. "DS V4 / Gema 31B").
    static func veryShortModelName(for identifier: String) -> String {
        let raw = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = raw.hasSuffix(":free") ? String(raw.dropLast(5)) : raw

        // Specific overrides for split view — prioritized over generic replacements
        switch base {
        case "deepseek/deepseek-v4-flash":         return "DS V4"
        case "google/gemma-4-31b-it":              return "Gema 31B"
        case "google/gemma-4-26b-a4b-it":          return "Gema 26B"
        case "google/gemini-3-flash-preview":      return "Gem 3"
        case "google/gemini-2.0-flash-001":        return "Gem 2"
        case "nvidia/nemotron-3-super-120b-a12b":  return "Nemot 3"
        case "qwen/qwen3.5-9b":                    return "Qwen 9B"
        case "unsloth/Qwen3.5-4B-GGUF:UD-Q4_K_XL": return "Qwen 4B"
        case "unsloth/Qwen3.5-9B-GGUF:UD-Q4_K_XL": return "Qwen 9B"
        default: break
        }

        let short = shortModelName(for: identifier)
        // If it's already reasonably short, keep it as is
        if short.count <= 8 { return short }
        
        // Otherwise apply common abbreviations
        return short
            .replacingOccurrences(of: "DeepSeek", with: "DS")
            .replacingOccurrences(of: "Gemini", with: "Gem")
            .replacingOccurrences(of: "Gemma", with: "Gema")
            .replacingOccurrences(of: "Mistral", with: "Mist")
    }

    func updateMonitoringInferenceBackend(_ backend: MonitoringInferenceBackend) {
        guard state.monitoringConfiguration.inferenceBackend != backend else { return }
        state.monitoringConfiguration.inferenceBackend = backend
        state.monitoringConfiguration.pipelineProfileID = backend == .openRouter
            ? (visionEnabled
                ? MonitoringConfiguration.defaultOnlineVisionPipelineProfileID
                : MonitoringConfiguration.defaultOnlineTextPipelineProfileID)
            : (visionEnabled
                ? MonitoringConfiguration.defaultPipelineProfileID
                : "title_only_default")
        // Re-apply the current tier's model for the new backend
        applyTierToActiveBackend()
        updateDisplayedModelIdentifier()
        brainService?.handleMonitoringConfigurationChange()
        refreshSystemState(persist: false)
        persistState()
        logActivity("monitoring", "Inference backend: \(backend.rawValue)")
    }

    func updateOnlineModelIdentifier(_ identifier: String) {
        let normalized = MonitoringConfiguration.normalizedOnlineModelIdentifier(identifier)
        guard state.monitoringConfiguration.onlineModelIdentifier != normalized else { return }
        state.monitoringConfiguration.onlineModelIdentifier = normalized
        if state.monitoringConfiguration.usesOnlineInference {
            lastUsedModelIdentifier = normalized
        }
        brainService?.handleMonitoringConfigurationChange()
        refreshSystemState(persist: false)
        persistState()
        logActivity("monitoring", "Online model: \(normalized)")
    }

    func updateOnlineModelIdentifierText(_ identifier: String?) {
        guard state.monitoringConfiguration.onlineModelIdentifierText != identifier else { return }
        state.monitoringConfiguration.onlineModelIdentifierText = identifier
        brainService?.handleMonitoringConfigurationChange()
        refreshSystemState(persist: false)
        persistState()
        logActivity("monitoring", "Online text model: \(identifier ?? "cleared")")
    }

    func updateOnlineModelIdentifierImage(_ identifier: String?) {
        guard state.monitoringConfiguration.onlineModelIdentifierImage != identifier else { return }
        state.monitoringConfiguration.onlineModelIdentifierImage = identifier
        brainService?.handleMonitoringConfigurationChange()
        refreshSystemState(persist: false)
        persistState()
        logActivity("monitoring", "Online image model: \(identifier ?? "cleared")")
    }

    func updateLocalModelIdentifierText(_ identifier: String?) {
        guard state.monitoringConfiguration.localModelIdentifierText != identifier else { return }
        state.monitoringConfiguration.localModelIdentifierText = identifier
        brainService?.handleMonitoringConfigurationChange()
        refreshSystemState(persist: false)
        persistState()
        logActivity("monitoring", "Local text model: \(identifier ?? "cleared")")
    }

    func updateLocalModelIdentifierImage(_ identifier: String?) {
        guard state.monitoringConfiguration.localModelIdentifierImage != identifier else { return }
        state.monitoringConfiguration.localModelIdentifierImage = identifier
        brainService?.handleMonitoringConfigurationChange()
        refreshSystemState(persist: false)
        persistState()
        logActivity("monitoring", "Local image model: \(identifier ?? "cleared")")
    }

    func updateOnlineAPIKey(_ value: String) {
        onlineAPIKeyDraft = value
        _ = OnlineModelCredentialStore.saveAPIKey(value)
        refreshSystemState()
    }

    // MARK: - Onboarding wizard

    func completeOnboardingWizard() {
        hasCompletedOnboardingWizard = true
        UserDefaults.standard.set(true, forKey: "acOnboardingWizardCompleted")
        refreshSystemState()
    }

    // MARK: - AI tier

    var currentAITier: AITier { state.aiTier }

    func updateAITier(_ tier: AITier) {
        guard state.aiTier != tier else { return }
        state.aiTier = tier
        applyTierToActiveBackend()
        updateDisplayedModelIdentifier()
        brainService?.handleMonitoringConfigurationChange()
        refreshSystemState()
        persistState()
        logActivity("monitoring", "AI tier: \(tier.rawValue)")
    }

    private func applyTierToActiveBackend() {
        switch state.monitoringConfiguration.inferenceBackend {
        case .openRouter:
            state.monitoringConfiguration.onlineModelIdentifier = state.aiTier.byokModelIdentifierImage
            state.monitoringConfiguration.onlineModelIdentifierText = state.aiTier.byokModelIdentifierText
            state.monitoringConfiguration.onlineModelIdentifierImage = state.aiTier.byokModelIdentifierImage
        case .local:
            state.monitoringConfiguration.localModelIdentifierText = state.aiTier.localModelIdentifierText
            state.monitoringConfiguration.localModelIdentifierImage = state.aiTier.localModelIdentifierImage
            if !queueLocalModelDownloadIfNeeded(
                targetModelIdentifier: state.aiTier.localModelIdentifierText,
                fallbackIdentifier: activeLocalModelIdentifier()
            ) {
                pendingLocalModelChange = nil
                modelDownloadNotice = nil
                modelDownloadSuccess = nil
                installRuntimeTask?.cancel()
                installRuntimeTask = nil
                if installingRuntime {
                    installingRuntime = false
                    setupProgressValue = nil
                    setupProgressMessage = nil
                }
                applyLocalModelSelection(
                    textModel: state.aiTier.localModelIdentifierText,
                    imageModel: state.aiTier.localModelIdentifierImage
                )
            }
        }
    }

    private func updateDisplayedModelIdentifier() {
        lastUsedModelIdentifier = Self.effectiveSetupModelIdentifier(for: state.monitoringConfiguration)
    }

    private func runtimeProfileModelIdentifier() -> String {
        state.monitoringConfiguration.localModelIdentifierText ?? state.aiTier.localModelIdentifierText
    }

    private func activeLocalModelIdentifier() -> String {
        if let imageModel = state.monitoringConfiguration.localModelIdentifierImage, !imageModel.isEmpty {
            return imageModel
        }
        if let textModel = state.monitoringConfiguration.localModelIdentifierText, !textModel.isEmpty {
            return textModel
        }
        return runtimeProfileModelIdentifier()
    }

    private func applyLocalModelSelection(textModel: String?, imageModel: String?) {
        state.monitoringConfiguration.localModelIdentifierText = textModel
        state.monitoringConfiguration.localModelIdentifierImage = imageModel ?? textModel
        let effectiveModel = activeLocalModelIdentifier()
        let lowerModel = effectiveModel.lowercased()
        let isTextOnly = lowerModel.contains("phi") && !lowerModel.contains("vision") && !lowerModel.contains("multimodal")
        if isTextOnly && visionEnabled {
            state.monitoringConfiguration.pipelineProfileID = "title_only_default"
        }
    }

    private func applyLocalModelFallback(_ fallbackIdentifier: String) {
        applyLocalModelSelection(textModel: fallbackIdentifier, imageModel: fallbackIdentifier)
    }

    @discardableResult
    private func queueLocalModelDownloadIfNeeded(
        targetModelIdentifier: String,
        fallbackIdentifier: String
    ) -> Bool {
        let diagnostics = RuntimeSetupService.inspect(
            runtimeOverride: state.runtimePathOverride,
            modelIdentifier: targetModelIdentifier
        )
        guard !diagnostics.modelArtifactsPresent else { return false }

        let targetName = Self.shortModelName(for: targetModelIdentifier)
        let fallbackName = Self.shortModelName(for: fallbackIdentifier)
        pendingLocalModelChange = PendingLocalModelChange(
            modelIdentifier: targetModelIdentifier
        )
        modelDownloadNotice = ModelDownloadNotice(
            modelIdentifier: targetModelIdentifier,
            modelDisplayName: targetName,
            fallbackDisplayName: fallbackName
        )
        applyLocalModelFallback(fallbackIdentifier)

        if !installingRuntime {
            installRuntime(modelIdentifier: targetModelIdentifier)
        }
        return true
    }

    @discardableResult
    private func applyPendingLocalModelIfReady() -> Bool {
        guard let pending = pendingLocalModelChange else { return false }
        guard state.monitoringConfiguration.inferenceBackend == .local else {
            pendingLocalModelChange = nil
            return true
        }
        let diagnostics = RuntimeSetupService.inspect(
            runtimeOverride: state.runtimePathOverride,
            modelIdentifier: pending.modelIdentifier
        )
        guard diagnostics.modelArtifactsPresent else { return false }

        applyLocalModelSelection(
            textModel: pending.modelIdentifier,
            imageModel: pending.modelIdentifier
        )
        pendingLocalModelChange = nil
        modelDownloadSuccess = ModelDownloadSuccess(
            modelIdentifier: pending.modelIdentifier,
            modelDisplayName: Self.shortModelName(for: pending.modelIdentifier)
        )
        brainService?.handleMonitoringConfigurationChange()
        persistState()
        return true
    }

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

    func setDebugMode(_ enabled: Bool) {
        state.debugMode = enabled
        logActivity("app", enabled ? "Debug mode enabled" : "Debug mode disabled")
        persistState()
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard TelemetryPersistencePolicy.storesVerboseTelemetry(debugMode: enabled) else {
                await self.telemetryStore.endCurrentSession(reason: "debug_mode_disabled")
                self.telemetrySessionID = nil
                return
            }
            if let session = try? await self.telemetryStore.ensureCurrentSession(reason: "debug_mode_enabled") {
                self.telemetrySessionID = session.id
            }
        }
    }

    func sendTestNudge() {
        let message = "Debug nudge: time to check that the panel is visible."
        let context = SnapshotService.frontmostContext()
        state.recentActions.insert(ActionRecord(
            id: UUID().uuidString,
            kind: .nudge,
            message: message,
            timestamp: Date(),
            contextKey: context?.contextKey,
            appName: context?.appName,
            windowTitle: context?.windowTitle
        ), at: 0)
        state.recentActions = Array(state.recentActions.prefix(12))
        companionMood = .nudging
        logActivity("debug", "Triggered test nudge")
        executiveArm?.perform(.showNudge(message))
        persistState()
    }

    /// Called when the user taps 👍 or 👎 on the nudge speech bubble.
    func rateNudge(positive: Bool, nudgeText: String) {
        let kind: UserReactionKind = positive ? .nudgeRatedPositive : .nudgeRatedNegative
        brainService?.recordUserReaction(
            UserReactionRecord(
                kind: kind,
                relatedAction: TelemetryCompanionActionRecord(kind: .nudge, message: nudgeText),
                positive: positive,
                details: nudgeText.cleanedSingleLine
            )
        )
        // Write to persistent memory so future nudges adapt
        let note = positive
            ? "• User liked nudge: \"\(nudgeText.cleanedSingleLine)\""
            : "• User disliked nudge: \"\(nudgeText.cleanedSingleLine)\""
        appendMemoryLine(note)
        schedulePolicyMemoryUpdate(
            eventSummary: positive
                ? "User explicitly liked this nudge: \(nudgeText.cleanedSingleLine)"
                : "User explicitly disliked this nudge: \(nudgeText.cleanedSingleLine)",
            context: SnapshotService.frontmostContext()
        )
        logActivity("feedback", positive ? "👍 nudge: \(nudgeText)" : "👎 nudge: \(nudgeText)")

        // Dismiss the nudge after rating
        clearTransientUI()
    }

    func clearChatHistory() {
        chatMessages = Self.makeChatMessages(from: [])
        persistState()
        logActivity("chat", "Chat history cleared")
    }

    @discardableResult
    func deleteChatMessage(id: UUID) -> (message: ChatMessage, index: Int)? {
        guard let index = chatMessages.firstIndex(where: { $0.id == id && $0.role != .system }) else {
            return nil
        }
        let removed = chatMessages.remove(at: index)
        persistState()
        logActivity("chat", "Deleted chat message (\(removed.role.rawValue))")
        return (removed, index)
    }

    func restoreChatMessage(_ message: ChatMessage, at index: Int) {
        guard message.role != .system else { return }
        let clampedIndex = min(max(1, index), chatMessages.count)
        chatMessages.insert(message, at: clampedIndex)
        persistState()
        logActivity("chat", "Restored chat message (\(message.role.rawValue))")
    }

    func clearMemory() {
        state.memoryEntries = []
        state.lastMemoryConsolidationAt = nil
        state.policyMemory = PolicyMemory()
        persistState()
        logActivity("memory", "Memory cleared")
    }

    func deleteMemoryEntry(id: UUID) {
        state.memoryEntries.removeAll { $0.id == id }
        persistState()
    }

    var canConsolidateMemory: Bool {
        guard !state.memoryEntries.isEmpty,
              state.setupStatus == .ready,
              !consolidatingMemory else {
            return false
        }
        // Online mode does not need a local runtime to consolidate; the call
        // routes through OpenRouter.
        return state.monitoringConfiguration.usesOnlineInference || setupDiagnostics.runtimePresent
    }

    func consolidateMemoryNow() {
        guard !state.memoryEntries.isEmpty else { return }
        guard state.setupStatus == .ready else {
            setupErrorMessage = "Finish setup before AC can run memory consolidation."
            return
        }
        if !state.monitoringConfiguration.usesOnlineInference, !setupDiagnostics.runtimePresent {
            setupErrorMessage = "Install the local runtime first, or switch to online mode."
            return
        }
        startMemoryConsolidation(now: Date(), reason: "manual")
    }

    func resetAlgorithmProfile() {
        state.resetAlgorithmProfile()
        clearChatHistory()
        brainService?.resetAlgorithmProfile()
        persistState()
        updateActivityStatusLine()
        logActivity("memory", "Algorithm profile reset to defaults")
    }

    func showTestOverlay() {
        let context = SnapshotService.frontmostContext()
        state.recentActions.insert(ActionRecord(
            id: UUID().uuidString,
            kind: .overlay,
            message: "debug",
            timestamp: Date(),
            contextKey: context?.contextKey,
            appName: context?.appName,
            windowTitle: context?.windowTitle
        ), at: 0)
        state.recentActions = Array(state.recentActions.prefix(12))
        activeOverlay = OverlayPresentation(
            headline: "Pause for a second.",
            body: "Debug overlay for \(state.rescueApp.displayName).",
            prompt: "This looks a bit off-track — what's going on?",
            appName: "Debug",
            evaluationID: nil,
            submitButtonTitle: "Submit",
            secondaryButtonTitle: "Back to work"
        )
        overlayVisible = true
        companionMood = .escalated
        logActivity("debug", "Triggered test overlay")
        if let activeOverlay {
            executiveArm?.perform(.showOverlay(activeOverlay))
        }
        persistState()
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

    func installMissingDependencies() {
        guard !installingDependencies else { return }

        let missingTools = setupDiagnostics.missingTools
        guard !missingTools.isEmpty else {
            refreshSystemState()
            return
        }

        dependencyInstallPromptVisible = false
        installingDependencies = true
        setupErrorMessage = nil
        appendSetupLog("Preparing dependency install for: \(missingTools.joined(separator: ", "))")
        logActivity("setup", "Installing missing dependencies: \(missingTools.joined(separator: ", "))")
        refreshSystemState()

        Task {
            do {
                try await DependencyInstallerService.installMissingTools(missingTools) { [weak self] chunk in
                    self?.appendSetupLog(chunk)
                }
                logActivity("setup", "Dependency install finished")
            } catch {
                setupErrorMessage = error.localizedDescription
                logActivity("setup", "Dependency install failed: \(error.localizedDescription)")
            }

            installingDependencies = false
            refreshSystemState()
        }
    }

    func installRuntime(modelIdentifier: String? = nil) {
        guard !installingRuntime else { return }

        refreshSystemState()
        guard setupDiagnostics.canInstall else {
            setupErrorMessage = "Missing tools: \(setupDiagnostics.missingTools.joined(separator: ", "))"
            dependencyInstallPromptVisible = true
            return
        }

        installingRuntime = true
        setupProgressValue = nil
        setupProgressMessage = nil
        setupLog = ""
        setupErrorMessage = nil
        logActivity("setup", "Runtime install started")
        refreshSystemState()

        installRuntimeTask?.cancel()
        let task = Task {
            var cancelledDuringInstall = false
            do {
                let setupModelIdentifier = modelIdentifier ?? Self.effectiveSetupModelIdentifier(for: state.monitoringConfiguration)
                let diagnosticsBeforeInstall = RuntimeSetupService.inspect(
                    runtimeOverride: state.runtimePathOverride,
                    modelIdentifier: setupModelIdentifier
                )
                if diagnosticsBeforeInstall.runtimePresent {
                    appendSetupLog("Runtime already installed. Skipping build and warming selected model.")
                } else {
                    try await RuntimeSetupService.installRuntime { [weak self] chunk in
                        self?.appendSetupLog(chunk)
                    }
                }

                guard !Task.isCancelled else { throw CancellationError() }

                let diagnostics = RuntimeSetupService.inspect(
                    runtimeOverride: state.runtimePathOverride,
                    modelIdentifier: setupModelIdentifier
                )
                try await RuntimeSetupService.warmUpRuntime(
                    runtimePath: diagnostics.runtimePath,
                    modelIdentifier: setupModelIdentifier
                ) { [weak self] chunk in
                    self?.appendSetupLog(chunk)
                }

                guard !Task.isCancelled else { throw CancellationError() }

                // Warm-up can complete slightly before cache metadata settles; poll
                // briefly so setup/chat unlocks without requiring an app restart.
                await waitForRuntimeReadinessAfterWarmUp(
                    modelIdentifier: setupModelIdentifier,
                    timeoutSeconds: 12
                )
                if Task.isCancelled { throw CancellationError() }
                logActivity("setup", "Runtime setup warm-up finished")
            } catch is CancellationError {
                cancelledDuringInstall = true
            } catch {
                setupErrorMessage = error.localizedDescription
                logActivity("setup", "Runtime setup failed: \(error.localizedDescription)")
                pendingLocalModelChange = nil
            }

            if cancelledDuringInstall {
                return
            }
            installingRuntime = false
            setupProgressValue = nil
            setupProgressMessage = nil
            _ = applyPendingLocalModelIfReady()
            refreshSystemState()
        }
        installRuntimeTask = task
    }

    func chooseRescueApp() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false

        if panel.runModal() == .OK, let url = panel.url {
            let bundle = Bundle(url: url)
            state.rescueApp = RescueAppTarget(
                displayName: url.deletingPathExtension().lastPathComponent,
                bundleIdentifier: bundle?.bundleIdentifier ?? state.rescueApp.bundleIdentifier,
                applicationPath: url.path
            )
            logActivity("app", "Selected rescue app: \(state.rescueApp.displayName)")
            persistState()
        }
    }

    func openRescueApp() {
        logActivity("action", "Opened rescue app: \(state.rescueApp.displayName)")
        executiveArm?.openRescueApp(state.rescueApp)
    }

    func handleBackToWork() {
        executiveArm?.dismissOverlay()
        overlayVisible = false
        let overlayMessage = activeOverlay.map { "\($0.headline) — \($0.body)" }
        activeOverlay = nil
        overlayAppealDraft = ""
        state.hardEscalation = nil
        brainService?.recordUserReaction(
            UserReactionRecord(
                kind: .backToWorkSelected,
                relatedAction: TelemetryCompanionActionRecord(kind: .overlay, message: overlayMessage),
                positive: true,
                details: state.rescueApp.displayName
            ),
            endEpisodeReason: .rescueReturn
        )
        openRescueApp()
        let context = SnapshotService.frontmostContext()
        state.recentActions.insert(ActionRecord(
            id: UUID().uuidString,
            kind: .backToWork,
            message: state.rescueApp.displayName,
            timestamp: Date(),
            contextKey: context?.contextKey,
            appName: context?.appName,
            windowTitle: context?.windowTitle
        ), at: 0)
        state.recentActions = Array(state.recentActions.prefix(12))
        logActivity("action", "Back to Work selected")
        persistState()
    }

    func dismissOverlay() {
        // Don't clear hard escalation on dismiss — user must convince AC or go back to work
        let wasHard = activeOverlay?.isHardEscalation == true
        executiveArm?.dismissOverlay()
        overlayVisible = false
        let overlayMessage = activeOverlay.map { "\($0.headline) — \($0.body)" }
        activeOverlay = nil
        overlayAppealDraft = ""
        if !wasHard {
            state.hardEscalation = nil
        }
        brainService?.recordUserReaction(
            UserReactionRecord(
                kind: .overlayDismissed,
                relatedAction: TelemetryCompanionActionRecord(kind: .overlay, message: overlayMessage),
                positive: false,
                details: nil
            )
        )
        let context = SnapshotService.frontmostContext()
        state.recentActions.insert(ActionRecord(
            id: UUID().uuidString,
            kind: .dismissOverlay,
            message: nil,
            timestamp: Date(),
            contextKey: context?.contextKey,
            appName: context?.appName,
            windowTitle: context?.windowTitle
        ), at: 0)
        state.recentActions = Array(state.recentActions.prefix(12))
        logActivity("action", "Overlay dismissed")
        persistState()
    }

    func showHardEscalationOnReopen(appName: String) {
        guard overlayVisible == false else { return }
        let escalation = state.hardEscalation
        activeOverlay = OverlayPresentation(
            headline: "No.",
            body: "I minimized \(appName) because you haven't convinced me it serves your goals. Tell me why you need it.",
            prompt: "Explain why \(appName) is actually helping right now…",
            appName: appName,
            evaluationID: escalation?.evaluationID,
            submitButtonTitle: "Submit",
            secondaryButtonTitle: "I'll get back to work",
            isHardEscalation: true
        )
        overlayVisible = true
        companionMood = .escalatedHard
        executiveArm?.perform(.showOverlay(activeOverlay!))
    }

    func clearTransientUI() {
        latestNudge = nil
        if !overlayVisible {
            companionMood = state.isPaused ? .paused : .watching
        }
    }

    func submitOverlayAppeal() {
        guard !sendingOverlayAppeal,
              let presentation = activeOverlay else { return }

        let trimmedAppeal = overlayAppealDraft.cleanedSingleLine
        guard !trimmedAppeal.isEmpty else { return }

        sendingOverlayAppeal = true

        Task {
            let reviewNow = Date()
            let reviewInput = MonitoringAppealReviewInput(
                now: reviewNow,
                appealText: trimmedAppeal,
                snapshot: nil,
                goals: state.goalsText,
                recentActions: state.recentActions,
                memory: state.memoryForPrompt(now: reviewNow),
                recentUserMessages: BrainService.recentUserMessages(
                    chatHistory: state.chatHistory,
                    limit: MonitoringPromptContextBudget.recentUserChatCount
                ),
                policyMemory: state.policyMemory,
                configuration: state.monitoringConfiguration,
                algorithmState: state.algorithmState,
                runtimeOverride: state.runtimePathOverride
            )

            let output = try? await monitoringAlgorithmRegistry.reviewAppeal(input: reviewInput)

            await MainActor.run {
                self.sendingOverlayAppeal = false

                guard let output else {
                    self.activeOverlay = OverlayPresentation(
                        headline: presentation.headline,
                        body: "I couldn't review that just now. Try again or head back to work.",
                        prompt: presentation.prompt,
                        appName: presentation.appName,
                        evaluationID: presentation.evaluationID,
                        submitButtonTitle: presentation.submitButtonTitle,
                        secondaryButtonTitle: presentation.secondaryButtonTitle,
                        isHardEscalation: presentation.isHardEscalation
                    )
                    return
                }

                self.noteUsedModel(output.evaluation.lastUsedModelIdentifier)
                self.state.policyMemory = output.updatedPolicyMemory
                self.state.algorithmState = output.updatedAlgorithmState

                // Hard escalation deny → minimize the app
                if presentation.isHardEscalation, output.result.decision == .deny {
                    self.state.hardEscalation?.lastAppealText = trimmedAppeal
                    self.state.hardEscalation?.lastAppealResult = output.result.decision
                    // Find and minimize the app
                    if let escalation = self.state.hardEscalation,
                       let bid = escalation.bundleIdentifier ?? SnapshotService.frontmostContext()?.bundleIdentifier {
                        self.executiveArm?.hideApp(bundleIdentifier: bid)
                        self.state.hardEscalation?.timesMinimized += 1
                        self.state.hardEscalation?.lastMinimizedAt = Date()
                        self.state.recentActions.insert(ActionRecord(
                            kind: .minimizeApp,
                            message: "Minimized \(escalation.appName) after unconvincing appeal",
                            timestamp: Date(),
                            appName: escalation.appName
                        ), at: 0)
                        self.state.recentActions = Array(self.state.recentActions.prefix(12))
                    }
                    // Save appeal to memory
                    self.appendMemoryLine("• User appealed hard escalation on \(presentation.appName): \"\(trimmedAppeal)\" — denied")
                    self.schedulePolicyMemoryUpdate(
                        eventSummary: "User appealed hard escalation on \(presentation.appName) saying: \(trimmedAppeal). AC denied the appeal.",
                        context: SnapshotService.frontmostContext()
                    )
                    self.activeOverlay = OverlayPresentation(
                        headline: "I'm not convinced.",
                        body: output.result.message.isEmpty
                            ? "I've minimized \(presentation.appName). If you open it again, I'll minimize it again. Convince me."
                            : output.result.message,
                        prompt: "Try again — why is \(presentation.appName) actually helping right now?",
                        appName: presentation.appName,
                        evaluationID: presentation.evaluationID,
                        submitButtonTitle: "Submit",
                        secondaryButtonTitle: "I'll get back to work",
                        isHardEscalation: true
                    )
                } else if presentation.isHardEscalation, output.result.decision == .allow {
                    // User convinced AC — save to memory, clear hard escalation
                    self.state.hardEscalation = nil
                    self.appendMemoryLine("• User convinced AC to allow \(presentation.appName): \"\(trimmedAppeal)\"")
                    self.schedulePolicyMemoryUpdate(
                        eventSummary: "User convinced AC to allow \(presentation.appName): \(trimmedAppeal). Safe to let them continue.",
                        context: SnapshotService.frontmostContext()
                    )
                    self.activeOverlay = nil
                    self.overlayVisible = false
                    self.executiveArm?.dismissOverlay()
                    self.overlayAppealDraft = ""
                    self.companionMood = .watching
                } else {
                    self.activeOverlay = OverlayPresentation(
                        headline: output.result.decision == .allow ? "Okay." : "Not convinced yet.",
                        body: output.result.message,
                        prompt: output.result.decision == .deferDecision ? presentation.prompt : nil,
                        appName: presentation.appName,
                        evaluationID: presentation.evaluationID,
                        submitButtonTitle: output.result.decision == .deferDecision ? "Submit" : "Back to work",
                        secondaryButtonTitle: "Dismiss",
                        isHardEscalation: presentation.isHardEscalation
                    )
                }
                self.overlayAppealDraft = ""
                self.persistState()
            }

            self.logActivity("appeal", "Overlay appeal reviewed: \(trimmedAppeal)")
        }
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

    func openOpenRouterHealthStats() {
        Task {
            let url = await OpenRouterHealthStatsService.shared.snapshotFileURL()
            _ = await MainActor.run {
                NSWorkspace.shared.open(url)
            }
        }
    }

    func sendChatMessage(_ draft: String) {
        let trimmedDraft = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedDraft.isEmpty, !sendingChatMessage else { return }

        chatMessages.append(ChatMessage(role: .user, text: trimmedDraft))
        persistState()
        sendingChatMessage = true
        logActivity("chat", "User: \(trimmedDraft)")

        if AppControllerChatSupport.looksLikeNegativeChatFeedback(trimmedDraft) {
            brainService?.recordUserReaction(
                UserReactionRecord(
                    kind: .negativeChatFeedback,
                    relatedAction: nil,
                    positive: false,
                    details: trimmedDraft.cleanedSingleLine
                )
            )
        }
        if AppControllerChatSupport.looksLikeDistractionCorrection(trimmedDraft) {
            recordDistractionCorrection(trimmedDraft)
        }

        let cappedDraft = AppControllerChatSupport.cappedChatText(
            trimmedDraft,
            limit: AppControllerChatSupport.maxChatMessageLength
        )

        // Rolling context window: last N non-system messages
        let historyWindow = chatMessages
            .filter { $0.role != .system }
            .suffix(Self.chatContextWindow)
            .dropLast()  // exclude the message we just appended (it's the userMessage arg)
            .map { $0 }
        let cappedHistory = historyWindow.map {
            AppControllerChatSupport.cappedMessageForContext(
                $0,
                limit: AppControllerChatSupport.maxChatMessageLength
            )
        }
        let historyBudget = max(0, AppControllerChatSupport.maxChatContextCharacters - cappedDraft.count)
        let boundedHistory = AppControllerChatSupport.limitMessagesByCharacterBudget(
            cappedHistory,
            budget: historyBudget
        )
        let renderedMemory = state.memoryForPrompt(now: Date())
        let renderedPolicyRules = state.policyRulesForChatPrompt(now: Date())

        let profileContext = AppControllerChatSupport.makeProfileContextForChatPrompt(
            activeProfile: state.activeProfile,
            availableProfiles: state.profiles.filter { $0.id != state.activeProfileID }
        )

        let backend = state.monitoringConfiguration.inferenceBackend
        let onlineModelIdentifier = state.monitoringConfiguration.onlineModelIdentifier
        let onlineTextModelIdentifier = state.monitoringConfiguration.onlineModelIdentifierText
        let localTextModelIdentifier = state.monitoringConfiguration.localModelIdentifierText
        let usingOnline = state.monitoringConfiguration.usesOnlineInference
        let chatReady = state.setupStatus == .ready &&
            (usingOnline || setupDiagnostics.runtimePresent)

        Task {
            let result: CompanionChatResult
            if !chatReady {
                result = CompanionChatResult(
                    reply: usingOnline
                        ? "Add your OpenRouter API key in Settings, then I can chat."
                        : "Finish local setup first, or switch to online mode in Settings.",
                    memoryUpdate: nil,
                    profileAction: nil,
                    schedule: nil
                )
            } else if let response = await companionChatService.chat(
                userMessage: cappedDraft,
                goals: state.goalsText,
                recentActions: state.recentActions,
                context: makeChatContext(),
                history: boundedHistory,
                memory: renderedMemory,
                policyRules: renderedPolicyRules,
                character: state.character,
                activeProfileContext: profileContext,
                runtimeOverride: state.runtimePathOverride,
                inferenceBackend: backend,
                onlineModelIdentifier: onlineModelIdentifier,
                onlineTextModelIdentifier: onlineTextModelIdentifier,
                localTextModelIdentifier: localTextModelIdentifier
            ) {
                result = response
            } else {
                result = CompanionChatResult(
                    reply: usingOnline
                        ? "Couldn't reach OpenRouter. Check the API key, your connection, and the model name."
                        : "I couldn't answer just now. Check the logs and local runtime status.",
                    memoryUpdate: nil,
                    profileAction: nil,
                    schedule: nil
                )
            }

            await MainActor.run {
                self.chatMessages.append(ChatMessage(role: .assistant, text: result.reply))
                self.noteUsedModel(result.usedModelIdentifier)
                if let update = result.memoryUpdate?.cleanedSingleLine, !update.isEmpty {
                    let activeProfile = self.state.activeProfile
                    self.state.memoryEntries.append(MemoryEntry(
                        text: update,
                        profileID: activeProfile.id,
                        profileName: activeProfile.name
                    ))
                    self.logActivity("memory", "Remembered: \(update)")
                }
                if let schedule = result.schedule {
                    let fireAt = Date().addingTimeInterval(Double(schedule.delayMinutes) * 60)
                    let action = ScheduledAction(
                        type: schedule.kind == .nudge ? .nudge : .profileActivation,
                        fireAt: fireAt,
                        message: schedule.message,
                        profileName: schedule.profileName
                    )
                    self.state.scheduledActions.append(action)
                    self.scheduleActionTimer(action)
                    self.logActivity("schedule", "Scheduled \(schedule.kind) in \(schedule.delayMinutes)m")
                }
                self.persistState()
                self.sendingChatMessage = false
            }
            self.logActivity("chat", "Assistant: \(result.reply)")

            // Only call policyMemory when there's meaningful work.
            // Profile actions + memory additions go through the designed policy_memory pipeline
            // (per V1 Phase 5: LLM converts chat intent to structured profile/rule operations).
            // No longer fires after every chat message.
            if let profileAction = result.profileAction?.cleanedSingleLine, !profileAction.isEmpty {
                self.logActivity("chat", "Profile action: \(profileAction)")
                self.schedulePolicyMemoryUpdate(
                    eventSummary: "Profile action: \(profileAction)",
                    context: SnapshotService.frontmostContext()
                )
            } else if let memoryUpdate = result.memoryUpdate?.cleanedSingleLine, !memoryUpdate.isEmpty {
                self.schedulePolicyMemoryUpdate(
                    eventSummary: "Latest user chat message: \(trimmedDraft.cleanedSingleLine)",
                    context: SnapshotService.frontmostContext()
                )
            }
            // Run consolidation lazily so the chat reply never waits for it.
            self.maybeConsolidateMemory()
        }
    }

    private func appendSetupLog(_ chunk: String) {
        let sanitizedChunk = chunk.trimmingCharacters(in: .newlines)
        guard !sanitizedChunk.isEmpty else { return }
        if setupLog.isEmpty {
            setupLog = sanitizedChunk
        } else {
            setupLog += "\n" + sanitizedChunk
        }
        logActivity("setup-output", sanitizedChunk)
        updateSetupProgress(from: sanitizedChunk)
    }

    private func updateSetupProgress(from chunk: String) {
        let line = chunk
            .split(whereSeparator: { $0.isNewline })
            .last
            .map(String.init) ?? chunk
        let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedLine.isEmpty else { return }

        let lowered = trimmedLine.lowercased()
        // Keywords that indicate this line is about download / load progress.
        // We deliberately do NOT treat every `\d+%` as progress — llama.cpp and
        // cmake both log percentages for unrelated things (sampling parameters,
        // build fractions), which made the progress bar jump around.
        let progressKeywords = [
            "download",
            "fetch",
            "pull",
            "resolving",
            "receiving",
            "loading model",
            "loading weights",
            "load_tensors",
            "warming",
            "warm up",
        ]
        let looksLikeProgress = progressKeywords.contains(where: lowered.contains)

        if looksLikeProgress,
           let range = trimmedLine.range(of: #"\b(\d{1,3})%"#, options: .regularExpression) {
            let percentString = String(trimmedLine[range]).replacingOccurrences(of: "%", with: "")
            if let percent = Double(percentString), (0...100).contains(percent) {
                setupProgressValue = max(0, min(1, percent / 100))
                setupProgressMessage = trimmedLine
                return
            }
        }

        if looksLikeProgress {
            setupProgressMessage = trimmedLine
        }
    }

    private func waitForRuntimeReadinessAfterWarmUp(modelIdentifier: String, timeoutSeconds: TimeInterval) async {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            let diagnostics = RuntimeSetupService.inspect(
                runtimeOverride: state.runtimePathOverride,
                modelIdentifier: modelIdentifier
            )
            if diagnostics.isReady {
                return
            }
            try? await Task.sleep(nanoseconds: 400_000_000)
        }
    }

    private func makeChatContext() -> ChatContext {
        AppControllerChatSupport.makeChatContext(from: state)
    }

    private func persistedChatHistory() -> [ChatMessage] {
        AppControllerChatSupport.persistedChatHistory(from: chatMessages)
    }

    private static func makeChatMessages(from persistedHistory: [ChatMessage]) -> [ChatMessage] {
        AppControllerChatSupport.makeChatMessages(from: persistedHistory)
    }

    // MARK: - Memory helpers

    private func appendMemoryLine(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Avoid exact-duplicate entries from noisy call sites (e.g. repeated feedback).
        if state.memoryEntries.contains(where: { $0.text.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            return
        }
        let activeProfile = state.activeProfile
        state.memoryEntries.append(MemoryEntry(
            text: trimmed,
            profileID: activeProfile.id,
            profileName: activeProfile.name
        ))
        persistState()
        maybeConsolidateMemory()
    }

    private func recordDistractionCorrection(_ text: String) {
        let now = Date()
        guard let action = state.recentActions.first(where: {
            ($0.kind == .nudge || $0.kind == .overlay) && now.timeIntervalSince($0.timestamp) <= 30 * 60
        }) else {
            return
        }

        let appName = action.appName ?? SnapshotService.frontmostContext()?.appName ?? "the recent activity"
        let title = action.windowTitle?.cleanedSingleLine
        let scope = title.map { "\(appName) (\($0))" } ?? appName
        appendMemoryLine("• Correction: \(scope) was not a distraction. User said: \(text.cleanedSingleLine)")

        if let actionID = action.id,
           let index = state.focusSegments.lastIndex(where: { $0.interventionID == actionID }) {
            state.focusSegments[index].assessment = .focused
            state.focusSegments[index].driftScore = 0
        } else if let index = state.focusSegments.lastIndex(where: {
            abs($0.endAt.timeIntervalSince(action.timestamp)) <= 10 * 60
        }) {
            state.focusSegments[index].assessment = .focused
            state.focusSegments[index].driftScore = 0
        }

        state.algorithmState.llmPolicy.distraction.lastAssessment = .focused
        state.algorithmState.llmPolicy.distraction.consecutiveDistractedCount = 0
        state.algorithmState.llmPolicy.focusSignal.resetFlow(at: now)
        schedulePolicyMemoryUpdate(
            eventSummary: "User corrected a recent intervention: \(text.cleanedSingleLine)",
            context: SnapshotService.frontmostContext()
        )
        persistState()
    }

    private func schedulePolicyMemoryUpdate(
        eventSummary: String,
        context: FrontmostContext?
    ) {
        let now = Date()
        let request = PolicyMemoryUpdateRequest(
            now: now,
            goals: state.goalsText,
            freeFormMemory: state.memoryForPrompt(now: now),
            policyMemory: state.policyMemory,
            eventSummary: eventSummary,
            recentActions: state.recentActions,
            context: context,
            runtimeProfileID: state.monitoringConfiguration.runtimeProfileID,
            inferenceBackend: state.monitoringConfiguration.inferenceBackend,
            onlineModelIdentifier: state.monitoringConfiguration.onlineModelIdentifier,
            onlineTextModelIdentifier: state.monitoringConfiguration.onlineModelIdentifierText,
            localModelIdentifier: state.monitoringConfiguration.localModelIdentifierText,
            activeProfile: makeProfilePromptSummary(state.activeProfile),
            availableProfiles: state.profiles
                .filter { $0.id != state.activeProfileID }
                .map { makeProfilePromptSummary($0) }
        )

        Task {
            guard let response = await policyMemoryService.deriveUpdate(
                request: request,
                runtimeOverride: state.runtimePathOverride
            ) else { return }

            await MainActor.run {
                // Stamp non-profile rule ops with the active profile id so newly added rules
                // land in the right scope.
                let activeID = self.state.activeProfileID
                var stamped = response
                stamped.operations = stamped.operations.map { op in
                    guard op.type == .addRule, var rule = op.rule else { return op }
                    if rule.profileID.isEmpty || rule.profileID == PolicyRule.defaultProfileID {
                        rule.profileID = activeID
                    }
                    var copy = op
                    copy.rule = rule
                    return copy
                }
                self.state.policyMemory.apply(stamped, now: request.now)
                self.applyProfileOperations(stamped.operations)
                self.persistState()
            }
        }
    }

    /// Mark every chat message read. Called when the popover opens (the user is looking)
    /// and when a deferred suggestion is resolved.
    func markAllChatMessagesRead() {
        guard hasUnreadChatMessages || chatMessages.contains(where: { $0.isUnread })
            || state.chatHistory.contains(where: { $0.isUnread }) else { return }
        for index in chatMessages.indices where chatMessages[index].isUnread {
            chatMessages[index].isUnread = false
        }
        for index in state.chatHistory.indices where state.chatHistory[index].isUnread {
            state.chatHistory[index].isUnread = false
        }
        hasUnreadChatMessages = false
        persistState()
    }

    /// Recompute `hasUnreadChatMessages` after any chat-history mutation.
    private func recomputeUnreadChatBadge() {
        hasUnreadChatMessages = chatMessages.contains(where: { $0.isUnread })
            || state.chatHistory.contains(where: { $0.isUnread })
    }

    private func syncChatMessagesFromState() {
        let rendered = Self.makeChatMessages(from: state.chatHistory)
        if rendered.map(\.id) != chatMessages.map(\.id) {
            chatMessages = rendered
        }
        recomputeUnreadChatBadge()
    }

    /// BrainService works on whole-state snapshots. Merge its result against the original
    /// snapshot so concurrent chat/profile edits are preserved instead of being replaced by
    /// a stale monitoring copy.
    func mergeBrainState(base: ACState, updated: ACState) {
        var merged = state
        merged.algorithmState = updated.algorithmState
        merged.recentSwitches = updated.recentSwitches
        merged.recentActions = updated.recentActions
        merged.usageByDay = updated.usageByDay
        merged.focusSegments = updated.focusSegments
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
    private func makeProfilePromptSummary(_ profile: FocusProfile) -> ProfilePromptSummary {
        let rules = state.policyMemory.rules
            .filter { $0.profileID == profile.id && $0.active }
            .prefix(6)
            .map { rule in
                let kindShort: String
                switch rule.kind {
                case .allow: kindShort = "allow"
                case .disallow: kindShort = "disallow"
                case .discourage: kindShort = "discourage"
                case .limit: kindShort = "limit"
                case .tonePreference: kindShort = "tone"
                }
                let target = rule.scope.appName
                    ?? rule.scope.bundleIdentifier
                    ?? (rule.scope.titleContains.first.map { "title:\($0)" })
                    ?? rule.summary
                return "\(kindShort):\(target)"
            }
        let rulesSummary = rules.isEmpty ? nil : rules.joined(separator: ", ")
        return ProfilePromptSummary(
            id: profile.id,
            name: profile.name,
            isDefault: profile.isDefault,
            description: profile.description,
            rulesSummary: rulesSummary,
            lastUsedAt: profile.lastUsedAt,
            expiresAt: profile.expiresAt
        )
    }

    /// Route profile lifecycle ops emitted by the policy_memory pipeline through the
    /// AppController helpers so persistence, eviction, and announcement happen consistently.
    /// If multiple profile ops appear in one response, only the final effective state is
    /// announced so the user does not get spammed by contradictory deferred messages.
    func applyProfileOperations(_ operations: [PolicyMemoryOperation]) {
        var announcementReason: String?
        var shouldAnnounce = false

        for op in operations {
            switch op.type {
            case .activateProfile:
                guard let profileID = op.profileID else { continue }
                let expiresAt: Date?
                if let mins = op.profileDurationMinutes, mins > 0 {
                    expiresAt = Date().addingTimeInterval(TimeInterval(mins) * 60)
                } else {
                    expiresAt = nil
                }
                if activateProfile(id: profileID, expiresAt: expiresAt, reason: op.reason) {
                    announcementReason = op.reason
                    shouldAnnounce = true
                }

            case .createAndActivateProfile:
                guard let name = op.profileName?.cleanedSingleLine, !name.isEmpty else { continue }
                let duration: TimeInterval? = (op.profileDurationMinutes ?? 0) > 0
                    ? TimeInterval(op.profileDurationMinutes!) * 60
                    : nil
                if createAndActivateProfile(
                    name: name,
                    description: op.profileDescription,
                    duration: duration,
                    reason: op.reason
                ) != nil {
                    announcementReason = op.reason
                    shouldAnnounce = true
                }

            case .endActiveProfile:
                guard state.activeProfileID != PolicyRule.defaultProfileID else { continue }
                endActiveProfile()
                announcementReason = op.reason ?? "ended"
                shouldAnnounce = true

            default:
                continue
            }
        }

        if shouldAnnounce {
            announceProfileSwitch(reason: announcementReason)
        }
    }

    /// Post a deferred chat note announcing a profile change. Non-interrupting: relies on the
    /// existing chat history (the orb is reserved for nudges, not profile announcements).
    private func announceProfileSwitch(reason: String?) {
        let active = state.activeProfile
        let trimmedReason = reason?.cleanedSingleLine ?? ""
        let message: String
        if active.isDefault {
            message = trimmedReason.isEmpty
                ? "Switched back to your General profile."
                : "Switched back to General — \(trimmedReason)"
        } else {
            let untilText: String
            if let exp = active.expiresAt {
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.dateFormat = "HH:mm"
                untilText = " until \(formatter.string(from: exp))"
            } else {
                untilText = ""
            }
            let suffix = trimmedReason.isEmpty ? "" : " — \(trimmedReason)"
            message = "Switching to your \(active.name) profile\(untilText).\(suffix)"
        }
        let chatMessage = ChatMessage(
            role: .assistant,
            text: message,
            timestamp: Date(),
            interruptionPolicy: .deferred
        )
        state.chatHistory.append(chatMessage)
        chatMessages.append(chatMessage)
        recomputeUnreadChatBadge()
        logActivity("profile", "Announced profile switch: \(message)")
    }

    /// Trigger the consolidation pass if the memory exceeds the soft cap, or if a full
    /// day has passed since the last consolidation (stale "today" entries etc. get pruned).
    /// Runs asynchronously; the chat reply never waits for it.
    private func maybeConsolidateMemory(now: Date = Date()) {
        guard state.setupStatus == .ready else { return }
        if !state.monitoringConfiguration.usesOnlineInference, !setupDiagnostics.runtimePresent {
            return
        }
        let overCap = state.memoryExceedsSoftCap
        let staleSinceLastRun: Bool = {
            guard let last = state.lastMemoryConsolidationAt else { return !state.memoryEntries.isEmpty }
            return now.timeIntervalSince(last) >= 24 * 60 * 60
        }()
        guard overCap || staleSinceLastRun else { return }
        startMemoryConsolidation(now: now, reason: overCap ? "overflow" : "stale")
    }

    private func startMemoryConsolidation(now: Date, reason: String) {
        guard state.setupStatus == .ready else { return }
        if !state.monitoringConfiguration.usesOnlineInference, !setupDiagnostics.runtimePresent {
            return
        }
        guard !consolidatingMemory else { return }
        guard !state.memoryEntries.isEmpty else { return }

        consolidatingMemory = true
        let entriesSnapshot = state.memoryEntries
        let goalsSnapshot = state.goalsText
        let recentUserMessagesSnapshot = BrainService.recentUserMessages(
            chatHistory: state.chatHistory,
            limit: max(MonitoringPromptContextBudget.recentUserChatCount, 6)
        )
        let runtimeOverride = state.runtimePathOverride
        let backend = state.monitoringConfiguration.inferenceBackend
        let onlineModelIdentifier = state.monitoringConfiguration.onlineModelIdentifier
        let onlineTextModelIdentifier = state.monitoringConfiguration.onlineModelIdentifierText
        let localTextModelIdentifier = state.monitoringConfiguration.localModelIdentifierText

        Task { [weak self, memoryConsolidationService] in
            let consolidated = await memoryConsolidationService.consolidate(
                entries: entriesSnapshot,
                goals: goalsSnapshot,
                recentUserMessages: recentUserMessagesSnapshot,
                now: now,
                runtimeOverride: runtimeOverride,
                inferenceBackend: backend,
                onlineModelIdentifier: onlineModelIdentifier,
                onlineTextModelIdentifier: onlineTextModelIdentifier,
                localTextModelIdentifier: localTextModelIdentifier
            )
            await MainActor.run {
                guard let self else { return }
                self.consolidatingMemory = false
                self.state.lastMemoryConsolidationAt = now
                if let consolidated {
                    self.state.memoryEntries = consolidated
                    self.persistState()
                    self.logActivity(
                        "memory",
                        "Consolidated \(entriesSnapshot.count) → \(consolidated.count) entries (\(reason))"
                    )
                } else {
                    // Keep whatever is there; just record that we tried, so we back off a day.
                    if reason == "manual" {
                        self.setupErrorMessage = "Memory consolidation did not return a usable result."
                    }
                    self.persistState()
                }
            }
        }
    }

    private func configureBrainIfNeeded() {
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

            self.brainService = brainService
            brainService.start()
        }

        refreshSystemState()
    }

    private static func effectiveSetupModelIdentifier(for configuration: MonitoringConfiguration) -> String {
        if configuration.usesOnlineInference {
            return configuration.onlineModelIdentifierImage
                ?? configuration.onlineModelIdentifierText
                ?? configuration.onlineModelIdentifier
        }
        return configuration.localModelIdentifierImage
            ?? configuration.localModelIdentifierText
            ?? AITier.balanced.localModelIdentifierText
    }

    func noteUsedModel(_ identifier: String?) {
        guard let normalized = identifier?.trimmingCharacters(in: .whitespacesAndNewlines),
              !normalized.isEmpty else {
            return
        }
        lastUsedModelIdentifier = normalized
    }

    func recordDisplayedNudge(_ message: String, timestamp: Date = Date()) {
        latestNudge = message

        let shouldAppend = chatMessages.last.map {
            !($0.role == .assistant && $0.style == .nudge && $0.text == message)
        } ?? true
        guard shouldAppend else { return }

        chatMessages.append(
            ChatMessage(
                role: .assistant,
                text: message,
                timestamp: timestamp,
                style: .nudge
            )
        )
        persistState()
    }

    func maybeCelebrateFocusProgress(now: Date = Date()) {
        guard state.setupStatus == .ready,
              state.isPaused == false,
              state.algorithmState.llmPolicy.distraction.lastAssessment != .distracted else {
            return
        }

        let stats = todayStats
        guard stats.focusedSeconds >= 45 * 60 else { return }
        if let lastCelebrationAt = state.algorithmState.llmPolicy.focusSignal.lastCelebrationAt,
           now.timeIntervalSince(lastCelebrationAt) < 2 * 60 * 60 {
            return
        }

        let message: String
        let focused = formatCompactDuration(stats.focusedSeconds)
        let best = formatCompactDuration(stats.longestFocusedBlockSeconds)
        switch state.character {
        case .mochi:
            message = "You’ve already protected \(focused) of focus today. Best block: \(best). I’m proud of that."
        case .nova:
            message = "\(focused) focused today. Best block: \(best). Strong signal; keep the line."
        case .sage:
            message = "\(focused) of focused work today. Your best block is \(best). Notice the steadiness."
        }

        chatMessages.append(ChatMessage(role: .assistant, text: message, timestamp: now, style: .celebration))
        state.algorithmState.llmPolicy.focusSignal.lastCelebrationAt = now
        persistState()
    }

    private func formatCompactDuration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        let h = total / 3600
        let m = (total % 3600) / 60
        if h > 0, m > 0 { return "\(h)h \(m)m" }
        if h > 0 { return "\(h)h" }
        return "\(m)m"
    }


struct PendingLocalModelChange: Equatable, Sendable {
    let modelIdentifier: String
}

private enum LocalModelStorageActionError: LocalizedError {
    case commandFailed(command: String, status: Int32, output: String)

    var errorDescription: String? {
        switch self {
        case let .commandFailed(command, status, output):
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                return "Command failed (\(status)): \(command)"
            }
            return "Command failed (\(status)): \(trimmed)"
        }
    }
}

private final class ProcessOutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    nonisolated(unsafe) private var data = Data()

    nonisolated init() {}

    nonisolated func append(_ chunk: Data) {
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }

    nonisolated func snapshot() -> Data {
        lock.lock()
        let snapshot = data
        lock.unlock()
        return snapshot
    }
}

struct ModelDownloadNotice: Identifiable, Sendable {
    let id = UUID()
    let modelIdentifier: String
    let modelDisplayName: String
    let fallbackDisplayName: String
}

struct ModelDownloadSuccess: Identifiable, Sendable {
    let id = UUID()
    let modelIdentifier: String
    let modelDisplayName: String
}
    private func repairInvalidMonitoringConfigurationIfNeeded() {
        let algorithmID = state.monitoringConfiguration.algorithmID
        if !state.hasMigratedPolicyAlgorithmDefault,
           MonitoringConfiguration.shouldAutoMigrateDeprecatedDefaultAlgorithm(algorithmID) {
            state.monitoringConfiguration.algorithmID = MonitoringConfiguration.currentLLMMonitorAlgorithmID
            state.algorithmState = AlgorithmStateEnvelope()
            state.hasMigratedPolicyAlgorithmDefault = true
            logActivity("monitoring", "Migrated saved monitoring algorithm from \(algorithmID) to \(MonitoringConfiguration.currentLLMMonitorAlgorithmID)")
        }

        guard !monitoringAlgorithmRegistry.containsAlgorithm(id: algorithmID) else {
            if !LLMPolicyCatalog.availablePipelineProfiles.contains(where: { $0.descriptor.id == state.monitoringConfiguration.pipelineProfileID }) {
                state.monitoringConfiguration.pipelineProfileID = state.monitoringConfiguration.usesOnlineInference
                    ? MonitoringConfiguration.defaultOnlineVisionPipelineProfileID
                    : MonitoringConfiguration.defaultPipelineProfileID
            }
            if let pipeline = LLMPolicyCatalog.availablePipelineProfiles.first(
                where: { $0.descriptor.id == state.monitoringConfiguration.pipelineProfileID }
            ),
               pipeline.inferenceBackend != state.monitoringConfiguration.inferenceBackend {
                state.monitoringConfiguration.pipelineProfileID = state.monitoringConfiguration.usesOnlineInference
                    ? (pipeline.descriptor.requiresScreenshot
                        ? MonitoringConfiguration.defaultOnlineVisionPipelineProfileID
                        : MonitoringConfiguration.defaultOnlineTextPipelineProfileID)
                    : (pipeline.descriptor.requiresScreenshot
                        ? MonitoringConfiguration.defaultPipelineProfileID
                        : "title_only_default")
            }
            if !LLMPolicyCatalog.availableRuntimeProfiles.contains(where: { $0.descriptor.id == state.monitoringConfiguration.runtimeProfileID }) {
                state.monitoringConfiguration.runtimeProfileID = MonitoringConfiguration.defaultRuntimeProfileID
            }
            state.monitoringConfiguration.onlineModelIdentifier = MonitoringConfiguration.normalizedOnlineModelIdentifier(
                state.monitoringConfiguration.onlineModelIdentifier
            )
            state.hasMigratedPolicyAlgorithmDefault = true
            return
        }

        state.monitoringConfiguration.algorithmID = MonitoringConfiguration.defaultAlgorithmID
        state.algorithmState = AlgorithmStateEnvelope()
        state.hasMigratedPolicyAlgorithmDefault = true
        setupErrorMessage = "Saved monitoring algorithm '\(algorithmID)' was invalid. AC reset it to '\(MonitoringConfiguration.defaultAlgorithmID)'."
        logActivity("monitoring", "Reset invalid monitoring algorithm: \(algorithmID)")
    }

    private func handleSetupStatusTransition(from previousStatus: SetupStatus, to newStatus: SetupStatus) {
        defer { hasPerformedInitialRefresh = true }

        guard previousStatus != newStatus else { return }
        logActivity("setup", "Setup state changed: \(previousStatus.rawValue) -> \(newStatus.rawValue)")

        guard hasPerformedInitialRefresh else { return }

        if newStatus == .ready {
            configureBrainIfNeeded()
            onboardingCompletionTask?.cancel()
            onboardingDismissed = false
            showingOnboardingCompletion = true

            let workItem = DispatchWorkItem { [weak self] in
                self?.showingOnboardingCompletion = false
            }
            onboardingCompletionTask = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.0, execute: workItem)
        } else {
            onboardingCompletionTask?.cancel()
            showingOnboardingCompletion = false
            onboardingDismissed = false
        }
    }

    private func maybePromptForMissingDependencies() {
        if state.monitoringConfiguration.usesOnlineInference {
            lastPromptedDependencySignature = nil
            dependencyInstallPromptVisible = false
            return
        }

        let signature = setupDiagnostics.missingTools.sorted().joined(separator: ",")
        if signature.isEmpty {
            lastPromptedDependencySignature = nil
            dependencyInstallPromptVisible = false
            return
        }

        guard state.setupStatus == .blocked, !installingDependencies else { return }
        guard signature != lastPromptedDependencySignature else { return }

        lastPromptedDependencySignature = signature
        dependencyInstallPromptVisible = true
    }

    private func updateActivityStatusLine() {
        activityStatusText = AppControllerSetupSupport.activityStatusText(
            state: state,
            diagnostics: setupDiagnostics,
            installingRuntime: installingRuntime,
            installingDependencies: installingDependencies
        )
    }

    private func logActivity(_ category: String, _ message: String, level: LogLevel = .standard) {
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

private enum AppControllerSetupSupport {
    static func activityStatusText(
        state: ACState,
        diagnostics: RuntimeDiagnostics,
        installingRuntime: Bool,
        installingDependencies: Bool
    ) -> String {
        let requirements = LLMPolicyCatalog.permissionRequirements(for: state.monitoringConfiguration)
        let usesOnlineInference = state.monitoringConfiguration.usesOnlineInference
        let hasOnlineAPIKey = !(OnlineModelCredentialStore.loadAPIKey() ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
        if installingDependencies {
            return "Installing missing dependencies."
        } else if installingRuntime {
            if diagnostics.runtimePresent {
                return "Downloading and warming the selected local model."
            }
            return "Building and warming the local runtime."
        } else if !state.permissions.satisfies(requirements) {
            if requirements.requiresScreenRecording {
                return "Waiting for Screen Recording and Accessibility permissions."
            }
            return "Waiting for Accessibility permission."
        } else if usesOnlineInference && !hasOnlineAPIKey {
            return "Add your OpenRouter API key in Settings before AC can monitor online."
        } else if usesOnlineInference && state.isPaused {
            return "Monitoring is paused."
        } else if usesOnlineInference {
            return requirements.requiresScreenRecording
                ? "Monitoring is active via OpenRouter with screenshot upload."
                : "Monitoring is active via OpenRouter without screenshot upload."
        } else if !diagnostics.missingTools.isEmpty {
            return "Install the missing build tools before AC can finish setup."
        } else if !diagnostics.runtimePresent || !diagnostics.modelCachePresent {
            return "Install and warm up the local runtime before AC can watch or chat."
        } else if !diagnostics.modelArtifactsPresent {
            return "Model files are downloading or warming up. AC will start monitoring automatically when ready."
        } else if state.isPaused {
            return "Monitoring is paused."
        } else {
            return "Monitoring is active."
        }
    }
}

private enum AppControllerChatSupport {
    private static let systemMessage = "Ask me what I am watching, why I nudged, or what to improve."
    static let maxChatMessageLength = 1000
    static let maxChatContextCharacters = 4000

    static func cappedChatText(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit))
    }

    static func cappedMessageForContext(_ message: ChatMessage, limit: Int) -> ChatMessage {
        var trimmed = message
        trimmed.text = cappedChatText(message.text, limit: limit)
        return trimmed
    }

    static func limitMessagesByCharacterBudget(_ messages: [ChatMessage], budget: Int) -> [ChatMessage] {
        guard budget > 0 else { return [] }
        var total = 0
        var kept: [ChatMessage] = []
        for message in messages.reversed() {
            let length = message.text.count
            guard total + length <= budget else { continue }
            kept.append(message)
            total += length
        }
        return kept.reversed()
    }

    static func makeChatMessages(from persistedHistory: [ChatMessage]) -> [ChatMessage] {
        [ChatMessage(role: .system, text: systemMessage)]
            + persistedHistory.filter { $0.role != .system }
    }

    static func persistedChatHistory(from messages: [ChatMessage]) -> [ChatMessage] {
        messages.filter { $0.role != .system }
    }

    // `immediateMemoryLine` and `appendingMemoryLine` are gone. Chat messages now flow
    // through the combined chat-reply prompt, which returns an optional `memory_update`.
    // The LLM decides what — if anything — is worth remembering.

    static func makeChatContext(from state: ACState) -> ChatContext {
        let now = Date()
        let frontmost = SnapshotService.frontmostContext()
        let dayUsage = state.usageByDay[now.acDayKey] ?? [:]
        let perAppDurations = dayUsage
            .map { AppUsageRecord(appName: $0.key, seconds: $0.value) }
            .sorted { $0.seconds > $1.seconds }

        return ChatContext(
            frontmostAppName: frontmost?.appName ?? "Unknown App",
            frontmostWindowTitle: frontmost?.windowTitle,
            idleSeconds: SnapshotService.idleSeconds(),
            timestamp: now,
            recentSwitches: Array(state.recentSwitches.prefix(6)),
            perAppDurations: Array(perAppDurations.prefix(8))
        )
    }

    static func looksLikeNegativeChatFeedback(_ text: String) -> Bool {
        let lowered = text.cleanedSingleLine.lowercased()
        let markers = [
            "annoying",
            "stop nudging",
            "too much",
            "interrupt",
            "leave me alone",
            "not helpful",
            "wrong",
        ]
        return markers.contains { lowered.contains($0) }
    }

    static func looksLikeDistractionCorrection(_ text: String) -> Bool {
        let lowered = text.cleanedSingleLine.lowercased()
        let markers = [
            "wasn't a distraction",
            "was not a distraction",
            "wasnt a distraction",
            "not a distraction",
            "wrong nudge",
            "false positive",
            "that was work",
            "that was focused",
            "actually productive",
        ]
        return markers.contains { lowered.contains($0) }
    }

    static func makeProfileContextForChatPrompt(
        activeProfile: FocusProfile,
        availableProfiles: [FocusProfile]
    ) -> String {
        let expiryLabel: String?
        if let exp = activeProfile.expiresAt {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "HH:mm"
            expiryLabel = formatter.string(from: exp)
        } else {
            expiryLabel = nil
        }

        let availableText = availableProfiles
            .map { profile in
                let desc = profile.description.map { " — \($0)" } ?? ""
                return "- \(profile.name)\(desc)"
            }
            .joined(separator: "\n")

        return ACPromptSets.chatProfileContextSection(
            activeProfileName: activeProfile.name,
            activeProfileDescription: activeProfile.description,
            activeProfileIsDefault: activeProfile.isDefault,
            activeProfileExpiresAtLabel: expiryLabel,
            availableProfiles: availableText
        )
    }
}

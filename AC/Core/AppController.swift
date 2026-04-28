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
    @Published var dependencyInstallPromptVisible = false
    @Published var showingOnboardingCompletion = false
    @Published var activityStatusText = "Checking permissions and local runtime."
    @Published var chatMessages: [ChatMessage]
    @Published var sendingChatMessage = false
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

    /// How many recent messages (non-system) are sent to the LLM for context.
    static let chatContextWindow = 6

    let storageService = StorageService()
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

    private init() {
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
        setupDiagnostics = RuntimeSetupService.inspect(
            runtimeOverride: state.runtimePathOverride,
            modelIdentifier: Self.effectiveSetupModelIdentifier(for: state.monitoringConfiguration)
        )
        let permissionRequirements = LLMPolicyCatalog.permissionRequirements(for: state.monitoringConfiguration)
        let usesOnlineInference = state.monitoringConfiguration.usesOnlineInference

        if installingRuntime || installingDependencies {
            state.setupStatus = .installing
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

    // MARK: - Brain — rule management

    func addUserRule(_ summary: String, kind: PolicyRuleKind, appName: String? = nil) {
        let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var scope = PolicyRuleScope()
        if let name = appName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            scope.appName = name
        }
        let rule = PolicyRule(kind: kind, summary: trimmed, source: .explicitFeedback, priority: 75, scope: scope)
        state.policyMemory.apply(PolicyMemoryUpdateResponse(operations: [
            PolicyMemoryOperation(type: .addRule, rule: rule)
        ]))
        persistState()
        logActivity("brain", "User added rule: \(trimmed)")
    }

    func deleteRule(id: String) {
        state.policyMemory.rules.removeAll { $0.id == id }
        state.policyMemory.lastUpdatedAt = Date()
        persistState()
        logActivity("brain", "User deleted rule: \(id)")
    }

    func toggleRuleLocked(id: String) {
        guard let i = state.policyMemory.rules.firstIndex(where: { $0.id == id }) else { return }
        state.policyMemory.rules[i].isLocked.toggle()
        state.policyMemory.rules[i].updatedAt = Date()
        persistState()
        logActivity("brain", "Rule \(state.policyMemory.rules[i].isLocked ? "locked" : "unlocked"): \(id)")
    }

    func updateCharacter(_ character: ACCharacter) {
        guard state.character != character else { return }
        state.character = character
        logActivity("app", "Selected character: \(character.displayName)")
        persistState()
    }

    func updateRuntimeOverride(_ path: String) {
        state.runtimePathOverride = path.isEmpty ? nil : path
        refreshSystemState()
    }

    func updateMonitoringPromptProfile(_ promptProfileID: String) {
        let descriptor = PromptCatalog.monitoringDescriptor(id: promptProfileID)
        guard state.monitoringConfiguration.promptProfileID != descriptor.id else { return }
        state.monitoringConfiguration.promptProfileID = descriptor.id
        brainService?.handleMonitoringConfigurationChange()
        persistState()
        logActivity("monitoring", "Selected prompt profile: \(descriptor.id)")
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

    /// Short human-readable name for the model currently configured, suitable for
    /// compact display in the header or settings footnote.
    var activeModelShortName: String {
        let id = lastUsedModelIdentifier ?? Self.effectiveSetupModelIdentifier(for: state.monitoringConfiguration)
        return Self.shortModelName(for: id)
    }

    /// Converts a full OpenRouter/local model identifier to a compact display name.
    static func shortModelName(for identifier: String) -> String {
        let raw = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = raw.hasSuffix(":free") ? String(raw.dropLast(5)) : raw

        // Known models → friendly names
        switch base {
        case "google/gemma-4-31b-it":              return "Gemma 4"
        case "google/gemma-4-26b-a4b-it":              return "Gemma 4"
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
        case "google/gemini-3-flash-preview":            return "Gemini 3.1 Flash"
        case "qwen/qwen2.5-vl-72b-instruct":       return "Qwen 2.5 VL"
        default: break
        }

        // Generic fallback: strip provider prefix, truncate version noise
        let modelPart = base.components(separatedBy: "/").last ?? base
        let cleaned = modelPart
            .replacingOccurrences(of: "-instruct", with: "")
            .replacingOccurrences(of: "-it", with: "")
        return cleaned
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
        brainService?.handleMonitoringConfigurationChange()
        refreshSystemState(persist: false)
        persistState()
        logActivity("monitoring", "Inference backend: \(backend.rawValue)")
    }

    func updateModelOverride(_ identifier: String) {
        let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        let newValue: String? = trimmed.isEmpty ? nil : trimmed
        guard state.monitoringConfiguration.modelOverride != newValue else { return }
        state.monitoringConfiguration.modelOverride = newValue
        // Auto-disable vision for text-only models so the screenshot call is skipped entirely
        let effectiveModel = newValue ?? DevelopmentModelConfiguration.fallbackModelIdentifier
        if !DevelopmentModelConfiguration.supportsVision(for: effectiveModel) && visionEnabled {
            state.monitoringConfiguration.pipelineProfileID = "title_only_default"
        }
        brainService?.handleMonitoringConfigurationChange()
        refreshSystemState()
        persistState()
        logActivity("monitoring", "Model override: \(newValue ?? "cleared")")
    }

    func updateOnlineModelIdentifier(_ identifier: String) {
        let normalized = MonitoringConfiguration.normalizedOnlineModelIdentifier(identifier)
        guard state.monitoringConfiguration.onlineModelIdentifier != normalized else { return }
        state.monitoringConfiguration.onlineModelIdentifier = normalized
        brainService?.handleMonitoringConfigurationChange()
        refreshSystemState(persist: false)
        persistState()
        logActivity("monitoring", "Online model: \(normalized)")
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
        brainService?.handleMonitoringConfigurationChange()
        refreshSystemState()
        persistState()
        logActivity("monitoring", "AI tier: \(tier.rawValue)")
    }

    private func applyTierToActiveBackend() {
        switch state.monitoringConfiguration.inferenceBackend {
        case .openRouter:
            state.monitoringConfiguration.onlineModelIdentifier = state.aiTier.byokModelIdentifier
        case .local:
            state.monitoringConfiguration.modelOverride = state.aiTier.localModelOverride
        }
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
        state.recentActions.insert(ActionRecord(kind: .nudge, message: message, timestamp: Date()), at: 0)
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

    func deleteChatMessage(id: UUID) {
        guard let index = chatMessages.firstIndex(where: { $0.id == id && $0.role != .system }) else {
            return
        }
        let removed = chatMessages.remove(at: index)
        persistState()
        logActivity("chat", "Deleted chat message (\(removed.role.rawValue))")
    }

    func clearMemory() {
        state.memoryEntries = []
        state.lastMemoryConsolidationAt = nil
        state.policyMemory = PolicyMemory()
        persistState()
        logActivity("memory", "Memory cleared")
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
        state.recentActions.insert(ActionRecord(kind: .overlay, message: "debug", timestamp: Date()), at: 0)
        state.recentActions = Array(state.recentActions.prefix(12))
        activeOverlay = OverlayPresentation(
            headline: "Pause for a second.",
            body: "Debug overlay for \(state.rescueApp.displayName).",
            prompt: "Why should I let you continue here?",
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

    func installRuntime() {
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

        Task {
            do {
                let setupModelIdentifier = Self.effectiveSetupModelIdentifier(for: state.monitoringConfiguration)
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

                // Warm-up can complete slightly before cache metadata settles; poll
                // briefly so setup/chat unlocks without requiring an app restart.
                await waitForRuntimeReadinessAfterWarmUp(timeoutSeconds: 12)
                logActivity("setup", "Runtime setup warm-up finished")
            } catch {
                setupErrorMessage = error.localizedDescription
                logActivity("setup", "Runtime setup failed: \(error.localizedDescription)")
            }

            installingRuntime = false
            setupProgressValue = nil
            setupProgressMessage = nil
            refreshSystemState()
        }
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
        state.recentActions.insert(ActionRecord(kind: .backToWork, message: state.rescueApp.displayName, timestamp: Date()), at: 0)
        state.recentActions = Array(state.recentActions.prefix(12))
        logActivity("action", "Back to Work selected")
        persistState()
    }

    func dismissOverlay() {
        executiveArm?.dismissOverlay()
        overlayVisible = false
        let overlayMessage = activeOverlay.map { "\($0.headline) — \($0.body)" }
        activeOverlay = nil
        overlayAppealDraft = ""
        brainService?.recordUserReaction(
            UserReactionRecord(
                kind: .overlayDismissed,
                relatedAction: TelemetryCompanionActionRecord(kind: .overlay, message: overlayMessage),
                positive: false,
                details: nil
            )
        )
        state.recentActions.insert(ActionRecord(kind: .dismissOverlay, message: nil, timestamp: Date()), at: 0)
        state.recentActions = Array(state.recentActions.prefix(12))
        logActivity("action", "Overlay dismissed")
        persistState()
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
                        secondaryButtonTitle: presentation.secondaryButtonTitle
                    )
                    return
                }

                self.noteUsedModel(output.evaluation.lastUsedModelIdentifier)
                self.state.policyMemory = output.updatedPolicyMemory
                self.state.algorithmState = output.updatedAlgorithmState
                self.activeOverlay = OverlayPresentation(
                    headline: output.result.decision == .allow ? "Okay." : "Not convinced yet.",
                    body: output.result.message,
                    prompt: output.result.decision == .deferDecision ? presentation.prompt : nil,
                    appName: presentation.appName,
                    evaluationID: presentation.evaluationID,
                    submitButtonTitle: output.result.decision == .deferDecision ? "Submit" : "Back to work",
                    secondaryButtonTitle: "Dismiss"
                )
                self.overlayAppealDraft = ""
                self.persistState()
            }

            self.logActivity("appeal", "Overlay appeal reviewed: \(trimmedAppeal)")
        }
    }

    // MARK: - Today stats

    struct TodayStats {
        let totalTrackedSeconds: TimeInterval
        let topAppName: String?
        let topAppSeconds: TimeInterval
        let nudgeCount: Int
        let backToWorkCount: Int
    }

    var todayStats: TodayStats {
        let now = Date()
        let cal = Calendar.current
        let dayUsage = state.usageByDay[now.acDayKey] ?? [:]
        let total = dayUsage.values.reduce(0, +)
        let top = dayUsage.max(by: { $0.value < $1.value })
        let todayActions = state.recentActions.filter { cal.isDate($0.timestamp, inSameDayAs: now) }
        return TodayStats(
            totalTrackedSeconds: total,
            topAppName: top?.key,
            topAppSeconds: top?.value ?? 0,
            nudgeCount: todayActions.filter { $0.kind == .nudge }.count,
            backToWorkCount: todayActions.filter { $0.kind == .backToWork }.count
        )
    }

    var availableMonitoringPromptProfiles: [MonitoringPromptProfileDescriptor] {
        PromptCatalog.availableMonitoringPromptProfiles.map(\.descriptor)
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

        // Rolling context window: last N non-system messages
        let historyWindow = chatMessages
            .filter { $0.role != .system }
            .suffix(Self.chatContextWindow)
            .dropLast()  // exclude the message we just appended (it's the userMessage arg)
            .map { $0 }
        let renderedMemory = state.memoryForPrompt(now: Date())
        let renderedPolicyRules = state.policyRulesForChatPrompt(now: Date())

        let backend = state.monitoringConfiguration.inferenceBackend
        let onlineModelIdentifier = state.monitoringConfiguration.onlineModelIdentifier
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
                    memoryUpdate: nil
                )
            } else if let response = await companionChatService.chat(
                userMessage: trimmedDraft,
                goals: state.goalsText,
                recentActions: state.recentActions,
                context: makeChatContext(),
                history: Array(historyWindow),
                memory: renderedMemory,
                policyRules: renderedPolicyRules,
                character: state.character,
                runtimeOverride: state.runtimePathOverride,
                inferenceBackend: backend,
                onlineModelIdentifier: onlineModelIdentifier
            ) {
                result = response
            } else {
                result = CompanionChatResult(
                    reply: usingOnline
                        ? "Couldn't reach OpenRouter. Check the API key, your connection, and the model name."
                        : "I couldn't answer just now. Check the logs and local runtime status.",
                    memoryUpdate: nil
                )
            }

            await MainActor.run {
                self.chatMessages.append(ChatMessage(role: .assistant, text: result.reply))
                self.noteUsedModel(result.usedModelIdentifier)
                if let update = result.memoryUpdate?.cleanedSingleLine, !update.isEmpty {
                    self.state.memoryEntries.append(MemoryEntry(text: update))
                    self.logActivity("memory", "Remembered: \(update)")
                }
                self.persistState()
                self.sendingChatMessage = false
            }
            self.logActivity("chat", "Assistant: \(result.reply)")
            self.schedulePolicyMemoryUpdate(
                eventSummary: "Latest user chat message: \(trimmedDraft.cleanedSingleLine)",
                context: SnapshotService.frontmostContext()
            )
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

    private func waitForRuntimeReadinessAfterWarmUp(timeoutSeconds: TimeInterval) async {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            refreshSystemState(persist: false)
            if setupDiagnostics.isReady {
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
        state.memoryEntries.append(MemoryEntry(text: trimmed))
        persistState()
        maybeConsolidateMemory()
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
            onlineModelIdentifier: state.monitoringConfiguration.onlineModelIdentifier
        )

        Task {
            guard let response = await policyMemoryService.deriveUpdate(
                request: request,
                runtimeOverride: state.runtimePathOverride
            ) else { return }

            await MainActor.run {
                self.state.policyMemory.apply(response, now: request.now)
                self.persistState()
            }
        }
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

        Task { [weak self, memoryConsolidationService] in
            let consolidated = await memoryConsolidationService.consolidate(
                entries: entriesSnapshot,
                goals: goalsSnapshot,
                recentUserMessages: recentUserMessagesSnapshot,
                now: now,
                runtimeOverride: runtimeOverride,
                inferenceBackend: backend,
                onlineModelIdentifier: onlineModelIdentifier
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
            brainService.stateSink = { [weak self] updatedState in
                self?.state = updatedState
            }
            brainService.moodSink = { [weak self] mood in
                self?.companionMood = mood
            }
            brainService.statusSink = { [weak self] status in
                self?.activityStatusText = status
            }
            brainService.modelUsageSink = { [weak self] identifier in
                self?.noteUsedModel(identifier)
            }

            self.brainService = brainService
            brainService.start()
        }

        refreshSystemState()
    }

    private static func effectiveSetupModelIdentifier(for configuration: MonitoringConfiguration) -> String {
        if configuration.usesOnlineInference {
            return configuration.onlineModelIdentifier
        }

        let override = configuration.modelOverride?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let override, !override.isEmpty {
            return override
        }

        return LLMPolicyCatalog.runtimeProfile(id: configuration.runtimeProfileID).descriptor.modelIdentifier
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

    private func logActivity(_ category: String, _ message: String) {
        Task {
            await ActivityLogService.shared.append(category: category, message: message)
        }
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
}

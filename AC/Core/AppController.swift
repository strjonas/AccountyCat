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
    @Published var setupErrorMessage: String?
    @Published var dependencyInstallPromptVisible = false
    @Published var showingOnboardingCompletion = false
    @Published var activityStatusText = "Checking permissions and local runtime."
    @Published var chatMessages: [ChatMessage]
    @Published var sendingChatMessage = false
    @Published var onboardingDismissed = false
    @Published var telemetrySessionID: String?
    /// Set by WindowCoordinator when the orb is snapped to a screen edge (peek mode).
    @Published var peekingEdge: NSRectEdge? = nil

    /// How many recent messages (non-system) are sent to the LLM for context.
    static let chatContextWindow = 6
    /// Compress memory when it exceeds this character count.
    static let memoryCompressionThreshold = 1000

    let storageService = StorageService()
    let telemetryStore = TelemetryStore.shared
    let localModelRuntime: LocalModelRuntime
    let monitoringLLMClient: MonitoringLLMClient
    let companionChatService: CompanionChatService
    let memoryService: MemoryService
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
        let monitoringLLMClient = MonitoringLLMClient(runtime: runtime)
        let companionChatService = CompanionChatService(runtime: runtime)
        let memoryService = MemoryService(runtime: runtime)
        let policyMemoryService = PolicyMemoryService(runtime: runtime)
        self.localModelRuntime = runtime
        self.monitoringLLMClient = monitoringLLMClient
        self.companionChatService = companionChatService
        self.memoryService = memoryService
        self.policyMemoryService = policyMemoryService
        self.monitoringAlgorithmRegistry = MonitoringAlgorithmRegistry(
            monitoringLLMClient: monitoringLLMClient,
            screenStateExtractor: ScreenStateExtractorService(runtime: runtime),
            nudgeCopywriter: NudgeCopywriterService(runtime: runtime),
            runtime: runtime,
            policyMemoryService: policyMemoryService
        )
        let loadedState = storageService.loadState()
        self.state = loadedState
        self.setupDiagnostics = RuntimeSetupService.inspect(runtimeOverride: loadedState.runtimePathOverride)
        self.chatMessages = Self.makeChatMessages(from: loadedState.chatHistory)

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
            if let session = try? await self.telemetryStore.startSession(reason: "app_launch") {
                self.telemetrySessionID = session.id
            }
        }
        refreshSystemState(persist: false)
        configureBrainIfNeeded()
    }

    func shutdown() {
        persistState()
        Task { @MainActor [weak self] in
            await self?.localModelRuntime.shutdown()
            await self?.telemetryStore.endCurrentSession(reason: "app_termination")
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
        setupDiagnostics = RuntimeSetupService.inspect(runtimeOverride: state.runtimePathOverride)
        let permissionRequirements = LLMPolicyCatalog.permissionRequirements(for: state.monitoringConfiguration)

        if installingRuntime || installingDependencies {
            state.setupStatus = .installing
        } else if !state.permissions.satisfies(permissionRequirements) {
            state.setupStatus = .needsPermissions
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

    func updateRuntimeOverride(_ path: String) {
        state.runtimePathOverride = path.isEmpty ? nil : path
        refreshSystemState()
    }

    func updateMonitoringAlgorithm(_ algorithmID: String) {
        guard let descriptor = try? monitoringAlgorithmRegistry.descriptor(for: algorithmID) else {
            setupErrorMessage = "Unknown monitoring algorithm: \(algorithmID)"
            logActivity("monitoring", "Rejected unknown algorithm: \(algorithmID)")
            return
        }
        guard state.monitoringConfiguration.algorithmID != descriptor.id else { return }
        state.monitoringConfiguration.algorithmID = descriptor.id
        brainService?.handleMonitoringConfigurationChange()
        persistState()
        logActivity("monitoring", "Selected algorithm: \(descriptor.id)")
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
        persistState()
        logActivity("monitoring", "Selected runtime profile: \(descriptor.id)")
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
    }

    func sendTestNudge() {
        let message = "Debug nudge: time to check that the panel is visible."
        state.recentActions.insert(ActionRecord(kind: .nudge, message: message, timestamp: Date()), at: 0)
        state.recentActions = Array(state.recentActions.prefix(12))
        latestNudge = message
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

    func clearMemory() {
        state.memory = ""
        state.policyMemory = PolicyMemory()
        persistState()
        logActivity("memory", "Memory cleared")
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
        setupLog = ""
        setupErrorMessage = nil
        logActivity("setup", "Runtime install started")
        refreshSystemState()

        Task {
            do {
                try await RuntimeSetupService.installRuntime { [weak self] chunk in
                    self?.appendSetupLog(chunk)
                }

                let diagnostics = RuntimeSetupService.inspect(runtimeOverride: state.runtimePathOverride)
                try await RuntimeSetupService.warmUpRuntime(runtimePath: diagnostics.runtimePath) { [weak self] chunk in
                    self?.appendSetupLog(chunk)
                }
                logActivity("setup", "Runtime install and warm-up finished")
            } catch {
                setupErrorMessage = error.localizedDescription
                logActivity("setup", "Runtime install failed: \(error.localizedDescription)")
            }

            installingRuntime = false
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
            let reviewInput = MonitoringAppealReviewInput(
                now: Date(),
                appealText: trimmedAppeal,
                snapshot: nil,
                goals: state.goalsText,
                recentActions: state.recentActions,
                memory: state.memory,
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

    var availableMonitoringAlgorithms: [MonitoringAlgorithmDescriptor] {
        monitoringAlgorithmRegistry.availableAlgorithms
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

        if let immediateMemoryLine = AppControllerChatSupport.immediateMemoryLine(from: trimmedDraft) {
            appendMemoryLine(immediateMemoryLine)
            logActivity("memory", "Captured immediately: \(immediateMemoryLine)")
        }

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
        let currentMemory = state.memory

        Task {
            let reply: String
            if state.setupStatus != .ready || !setupDiagnostics.runtimePresent {
                reply = "Finish setup first, then I can answer from the local runtime."
            } else if let response = await companionChatService.chat(
                userMessage: trimmedDraft,
                goals: state.goalsText,
                recentActions: state.recentActions,
                context: makeChatContext(),
                history: Array(historyWindow),
                memory: currentMemory,
                runtimeOverride: state.runtimePathOverride
            ) {
                reply = response
            } else {
                reply = "I couldn't answer just now. Check the logs and local runtime status."
            }

            await MainActor.run {
                self.chatMessages.append(ChatMessage(role: .assistant, text: reply))
                self.persistState()
                self.sendingChatMessage = false
            }
            self.logActivity("chat", "Assistant: \(reply)")
            self.schedulePolicyMemoryUpdate(
                eventSummary: "User chat feedback: \(trimmedDraft.cleanedSingleLine)\nAssistant reply: \(reply.cleanedSingleLine)",
                context: SnapshotService.frontmostContext()
            )

            // Async memory extraction — non-blocking, runs after reply is shown
            await self.extractAndUpdateMemory(userMessage: trimmedDraft, reply: reply)
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
        state.memory = AppControllerChatSupport.appendingMemoryLine(line, to: state.memory)
        persistState()
    }

    private func schedulePolicyMemoryUpdate(
        eventSummary: String,
        context: FrontmostContext?
    ) {
        let request = PolicyMemoryUpdateRequest(
            now: Date(),
            goals: state.goalsText,
            freeFormMemory: state.memory,
            policyMemory: state.policyMemory,
            eventSummary: eventSummary,
            recentActions: state.recentActions,
            context: context,
            runtimeProfileID: state.monitoringConfiguration.runtimeProfileID
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

    /// Runs after each chat exchange to extract memorable rules/preferences.
    /// Compresses only when memory exceeds the threshold.
    private func extractAndUpdateMemory(userMessage: String, reply: String) async {
        guard state.setupStatus == .ready, setupDiagnostics.runtimePresent else { return }

        if let bullet = await memoryService.extractMemoryUpdate(
            userMessage: userMessage,
            reply: reply,
            currentMemory: state.memory,
            runtimeOverride: state.runtimePathOverride
        ) {
            await MainActor.run {
                self.appendMemoryLine(bullet)
                self.logActivity("memory", "Extracted: \(bullet)")
            }
        }

        // Compress only when over threshold
        guard state.memory.count > Self.memoryCompressionThreshold else { return }
        if let compressed = await memoryService.compressMemory(
            memory: state.memory,
            runtimeOverride: state.runtimePathOverride
        ) {
            await MainActor.run {
                self.state.memory = compressed
                self.persistState()
                self.logActivity("memory", "Compressed memory to \(compressed.count) chars")
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

            self.brainService = brainService
            brainService.start()
        }

        refreshSystemState()
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
                state.monitoringConfiguration.pipelineProfileID = MonitoringConfiguration.defaultPipelineProfileID
            }
            if !LLMPolicyCatalog.availableRuntimeProfiles.contains(where: { $0.descriptor.id == state.monitoringConfiguration.runtimeProfileID }) {
                state.monitoringConfiguration.runtimeProfileID = MonitoringConfiguration.defaultRuntimeProfileID
            }
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
            onboardingCompletionTask?.cancel()
            onboardingDismissed = false
            showingOnboardingCompletion = true

            let workItem = DispatchWorkItem { [weak self] in
                self?.showingOnboardingCompletion = false
            }
            onboardingCompletionTask = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.8, execute: workItem)
        } else {
            onboardingCompletionTask?.cancel()
            showingOnboardingCompletion = false
            onboardingDismissed = false
        }
    }

    private func maybePromptForMissingDependencies() {
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
        if installingDependencies {
            return "Installing missing dependencies."
        } else if installingRuntime {
            return "Building and warming the local runtime."
        } else if !state.permissions.satisfies(requirements) {
            if requirements.requiresScreenRecording {
                return "Waiting for Screen Recording and Accessibility permissions."
            }
            return "Waiting for Accessibility permission."
        } else if !diagnostics.missingTools.isEmpty {
            return "Install the missing build tools before AC can finish setup."
        } else if !diagnostics.runtimePresent || !diagnostics.modelCachePresent {
            return "Install and warm up the local runtime before AC can watch or chat."
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

    static func appendingMemoryLine(_ line: String, to memory: String) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return memory }
        let normalizedTrimmed = trimmed.lowercased()
        let existingLines = memory
            .components(separatedBy: .newlines)
            .map { $0.cleanedSingleLine.lowercased() }
        if existingLines.contains(normalizedTrimmed) {
            return memory
        }
        guard !memory.isEmpty else { return trimmed }
        return memory + "\n" + trimmed
    }

    static func immediateMemoryLine(from text: String) -> String? {
        let cleaned = text.cleanedSingleLine
        guard !cleaned.isEmpty else { return nil }

        let lowered = cleaned.lowercased()
        let explicitRuleMarkers = [
            "don't let me",
            "do not let me",
            "keep me off",
            "block ",
        ]
        guard explicitRuleMarkers.contains(where: { lowered.contains($0) }) else {
            return nil
        }

        let timeMarkers = [
            "today",
            "tonight",
            "tomorrow",
            "this week",
            "this evening",
            "this afternoon",
            "for now",
        ]
        let matchedTimeMarker = timeMarkers.first(where: { lowered.contains($0) })

        let pattern = #"(?i)(?:don't let me|do not let me|keep me off|block)\s+(?:go on|use|open|visit|browse)?\s*([A-Za-z0-9._-]+(?:\.[A-Za-z0-9._-]+)?)\s+(today|tonight|tomorrow|this week|this evening|this afternoon|for now)"#
        if let match = firstMatch(pattern: pattern, in: cleaned),
           match.numberOfRanges >= 3,
           let targetRange = Range(match.range(at: 1), in: cleaned),
           let timeRange = Range(match.range(at: 2), in: cleaned) {
            let target = String(cleaned[targetRange])
            let timeMarker = String(cleaned[timeRange]).lowercased()
            return "Do not allow use of \(displayName(forBlockedTarget: target)) \(timeMarker)."
        }

        guard let matchedTimeMarker else { return nil }
        return "Do not allow this activity \(matchedTimeMarker)."
    }

    private static func firstMatch(pattern: String, in text: String) -> NSTextCheckingResult? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.firstMatch(in: text, range: range)
    }

    private static func displayName(forBlockedTarget target: String) -> String {
        let trimmed = target.trimmingCharacters(in: .punctuationCharacters.union(.whitespacesAndNewlines))
        switch trimmed.lowercased() {
        case "x.com":
            return "X.com"
        default:
            return trimmed
        }
    }

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

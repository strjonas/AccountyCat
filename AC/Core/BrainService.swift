//
//  BrainService.swift
//  AC
//
//  Created by Codex on 12.04.26.
//

import AppKit
import Foundation

@MainActor
final class BrainService: NSObject {
    var stateProvider: (() -> ACState)?
    /// Applies BrainService output on top of the original state snapshot used for the work.
    /// This lets AppController merge monitoring changes without wiping unrelated concurrent edits.
    var stateSink: ((ACState, ACState) -> Void)?
    var moodSink: ((CompanionMood) -> Void)?
    var statusSink: ((String) -> Void)?
    var modelUsageSink: ((String) -> Void)?

    /// Override for testing: substitute a real `SnapshotService.frontmostContext()` call.
    var contextProvider: (() -> FrontmostContext?)?
    /// Override for testing: substitute a real `SnapshotService.captureScreenshot()` call.
    var screenshotCapture: (() async throws -> URL?)?
    /// Override for testing: substitute a real `SnapshotService.idleSeconds()` call.
    var idleSecondsProvider: (() -> TimeInterval)?

    private let monitoringAlgorithmRegistry: MonitoringAlgorithmRegistry
    private let executiveArm: ExecutiveArm
    private let storageService: StorageService
    private let telemetryStore: TelemetryStore
    private let pollingInterval: TimeInterval = 10
    private let contextChangeProbeInterval: TimeInterval = 2

    private var timer: Timer?
    private var contextProbeTimer: Timer?
    private var isTickScheduled = false
    private var isEvaluating = false
    private var evaluationStartedAt: Date?
    private var watchdogTimer: Timer?
    private var activeEvaluationTask: Task<MonitoringDecisionResult, Error>?
    private var isSessionAvailable = true
    private var lastObservedContext: FrontmostContext?
    private var lastObservedAt = Date()
    private var recentSwitches: [AppSwitchRecord] = []
    private var lastPersistAt = Date.distantPast
    private var activeEpisode: EpisodeRecord?
    private var pendingReactionsByEvaluationID: [String: PendingReaction] = [:]

    private struct PendingReaction: Sendable {
        var episodeID: String
        var evaluationID: String
        var action: CompanionAction
        var issuedAt: Date
        var sourceContextKey: String
    }

    /// Maps a user reaction kind to a normalized reward value.
    /// Returns nil for reactions unrelated to nudge quality (e.g. negativeChatFeedback).
    private static func rewardValue(for kind: UserReactionKind) -> Double? {
        switch kind {
        case .nudgeRatedPositive:    return +1.0
        case .nudgeRatedNegative:    return -0.8
        case .postNudgeAppSwitch:    return +0.6
        case .postNudgeRescueReturn: return +0.6
        case .backToWorkSelected:    return +0.6
        case .nudgeIgnored:          return -0.3
        case .overlayDismissed:      return -1.5
        case .negativeChatFeedback:  return nil
        }
    }

    /// Pull the last `limit` user chat messages (oldest→newest) from the stored history.
    /// Safety net so fresh intent reaches the decision stage even if memory extraction lags.
    static func recentUserMessages(chatHistory: [ChatMessage], limit: Int) -> [String] {
        let userMessages = chatHistory
            .filter { $0.role == .user }
            .suffix(limit)
            .compactMap(\.promptStampedLine)
        return Array(userMessages)
    }

    init(
        monitoringAlgorithmRegistry: MonitoringAlgorithmRegistry,
        executiveArm: ExecutiveArm,
        storageService: StorageService,
        telemetryStore: TelemetryStore
    ) {
        self.monitoringAlgorithmRegistry = monitoringAlgorithmRegistry
        self.executiveArm = executiveArm
        self.storageService = storageService
        self.telemetryStore = telemetryStore
    }

    private func shouldPersistVerboseTelemetry(state: ACState? = nil) -> Bool {
        let resolvedState = state ?? stateProvider?()
        guard let resolvedState else {
            return false
        }
        return TelemetryPersistencePolicy.storesVerboseTelemetry(debugMode: resolvedState.debugMode)
    }

    private func ensureTelemetrySessionIfNeeded(for state: ACState) async -> TelemetrySessionDescriptor? {
        guard shouldPersistVerboseTelemetry(state: state) else {
            return nil
        }
        return try? await telemetryStore.ensureCurrentSession(reason: "runtime")
    }

    private func cleanupEphemeralScreenshotIfNeeded(_ snapshot: AppSnapshot) {
        guard let screenshotPath = snapshot.screenshotPath,
              !screenshotPath.isEmpty else {
            return
        }

        let screenshotURL = URL(fileURLWithPath: screenshotPath).standardizedFileURL
        let temporaryRoot = FileManager.default.temporaryDirectory.standardizedFileURL.path
        guard screenshotURL.path.hasPrefix(temporaryRoot) else {
            return
        }

        try? FileManager.default.removeItem(at: screenshotURL)
    }

    func start() {
        guard timer == nil, contextProbeTimer == nil else { return }

        let notificationCenter = NSWorkspace.shared.notificationCenter
        notificationCenter.addObserver(self, selector: #selector(handleWillSleep), name: NSWorkspace.willSleepNotification, object: nil)
        notificationCenter.addObserver(self, selector: #selector(handleDidWake), name: NSWorkspace.didWakeNotification, object: nil)
        notificationCenter.addObserver(self, selector: #selector(handleSessionInactive), name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        notificationCenter.addObserver(self, selector: #selector(handleSessionActive), name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)

        timer = Timer.scheduledTimer(withTimeInterval: pollingInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.scheduleTickIfNeeded()
            }
        }
        contextProbeTimer = Timer.scheduledTimer(withTimeInterval: contextChangeProbeInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.probeForContextChange()
            }
        }
        watchdogTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.checkEvaluationHealth() }
        }
        RunLoop.main.add(timer!, forMode: .common)
        RunLoop.main.add(contextProbeTimer!, forMode: .common)
        RunLoop.main.add(watchdogTimer!, forMode: .common)
    }

    func stop() {
        cancelActiveEvaluationIfNeeded(reason: "monitoring_stop")
        timer?.invalidate()
        timer = nil
        contextProbeTimer?.invalidate()
        contextProbeTimer = nil
        watchdogTimer?.invalidate()
        watchdogTimer = nil
        isTickScheduled = false
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    func resetDistractionState() {
        guard let baseState = stateProvider?() else { return }
        var state = baseState
        do {
            try monitoringAlgorithmRegistry.resetSelectedAlgorithmTransientState(
                configuration: state.monitoringConfiguration,
                state: &state.algorithmState
            )
        } catch {
            handleMonitoringConfigurationError(error)
        }
        stateSink?(baseState, state)
    }

    func resetAlgorithmProfile() {
        cancelActiveEvaluationIfNeeded(reason: "reset_algorithm_profile")
        recentSwitches = []
        resetRuntimeContext()
        resetDistractionState()
    }

    func handleMonitoringConfigurationChange() {
        cancelActiveEvaluationIfNeeded(reason: "monitoring_configuration_changed")
        guard let baseState = stateProvider?() else { return }
        var state = baseState
        state.algorithmState = AlgorithmStateEnvelope()
        stateSink?(baseState, state)
        resetRuntimeContext()
    }

    func recordUserReaction(_ reaction: UserReactionRecord, endEpisodeReason: EpisodeEndReason? = nil) {
        if shouldPersistVerboseTelemetry() {
            Task {
                let sessionID = (try? await telemetryStore.ensureCurrentSession(reason: "runtime").id)
                if let sessionID {
                    try? await telemetryStore.appendEvent(
                        TelemetryEvent(
                            id: UUID().uuidString,
                            kind: .userReaction,
                            timestamp: Date(),
                            sessionID: sessionID,
                            episodeID: activeEpisode?.id,
                            episode: activeEpisode,
                            session: nil,
                            observation: nil,
                            evaluation: nil,
                            modelInput: nil,
                            modelOutput: nil,
                            parsedOutput: nil,
                            policy: nil,
                            action: nil,
                            reaction: reaction,
                            annotation: nil,
                            failure: nil
                        ),
                        sessionID: sessionID
                    )
                }
            }
        }

        // Feed reward signal to the active algorithm. The current LLM monitor ignores it,
        // but the seam remains in place if learning-based variants return later.
        if let reward = Self.rewardValue(for: reaction.kind),
           let captured = matchingPendingReaction(for: reaction),
           let baseState = stateProvider?() {
            var state = baseState
            let signal = MonitoringRewardSignal(
                evaluationID: captured.evaluationID,
                kind: reaction.kind,
                value: reward
            )
            do {
                try monitoringAlgorithmRegistry.observeReward(
                    signal,
                    configuration: state.monitoringConfiguration,
                    state: &state.algorithmState
                )
            } catch {
                handleMonitoringConfigurationError(error)
            }
            stateSink?(baseState, state)
            maybePersist(base: baseState, updated: state, at: Date(), force: true)
            pendingReactionsByEvaluationID.removeValue(forKey: captured.evaluationID)
        }

        guard let endEpisodeReason else {
            return
        }

        Task { @MainActor in
            guard let state = self.stateProvider?() else { return }
            await self.endActiveEpisode(
                reason: endEpisodeReason,
                context: self.lastObservedContext,
                state: state,
                idleSeconds: SnapshotService.idleSeconds(),
                at: Date()
            )
        }
    }

    @objc private func handleWillSleep() {
        cancelActiveEvaluationIfNeeded(reason: "system_sleep")
        isSessionAvailable = false
        Task {
            await ActivityLogService.shared.append(category: "app", message: "System will sleep. Monitoring is standing by.")
        }
        Task { @MainActor in
            guard let state = self.stateProvider?() else { return }
            await self.endActiveEpisode(
                reason: .sessionInactive,
                context: self.lastObservedContext,
                state: state,
                idleSeconds: SnapshotService.idleSeconds(),
                at: Date()
            )
        }
        resetDistractionState()
        moodSink?(.idle)
    }

    @objc private func handleDidWake() {
        isSessionAvailable = true
        Task {
            await ActivityLogService.shared.append(category: "app", message: "System woke up. Monitoring resumed.")
        }
        scheduleTickIfNeeded()
    }

    @objc private func handleSessionInactive() {
        cancelActiveEvaluationIfNeeded(reason: "session_inactive")
        isSessionAvailable = false
        Task {
            await ActivityLogService.shared.append(category: "app", message: "User session became inactive. Monitoring is standing by.")
        }
        Task { @MainActor in
            guard let state = self.stateProvider?() else { return }
            await self.endActiveEpisode(
                reason: .sessionInactive,
                context: self.lastObservedContext,
                state: state,
                idleSeconds: SnapshotService.idleSeconds(),
                at: Date()
            )
        }
        resetDistractionState()
        moodSink?(.idle)
    }

    @objc private func handleSessionActive() {
        isSessionAvailable = true
        Task {
            await ActivityLogService.shared.append(category: "app", message: "User session became active. Monitoring resumed.")
        }
        scheduleTickIfNeeded()
    }

    private func scheduleTickIfNeeded() {
        guard isTickScheduled == false else { return }
        isTickScheduled = true

        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isTickScheduled = false }
            await self.tick()
        }
    }

    private func probeForContextChange() {
        guard isEvaluating == false,
              let state = stateProvider?(),
              state.setupStatus == .ready,
              state.isPaused == false,
              isSessionAvailable else {
            return
        }

        guard let context = SnapshotService.frontmostContext() else {
            return
        }

        if context.contextKey != lastObservedContext?.contextKey {
            scheduleTickIfNeeded()
        }
    }

    func tick() async {
        guard let stateProvider, let baseState = Optional(stateProvider()) else {
            return
        }
        var state = baseState

        if state.setupStatus != .ready {
            moodSink?(.setup)
            statusSink?("Waiting for setup to finish.")
            return
        }

        if state.isPaused {
            cancelActiveEvaluationIfNeeded(reason: "monitoring_paused")
            await endActiveEpisode(
                reason: .paused,
                context: lastObservedContext,
                state: state,
                idleSeconds: SnapshotService.idleSeconds(),
                at: Date()
            )
            moodSink?(.paused)
            statusSink?("Monitoring paused.")
            return
        }

        if !state.permissions.satisfies(LLMPolicyCatalog.permissionRequirements(for: state.monitoringConfiguration)) {
            cancelActiveEvaluationIfNeeded(reason: "permissions_missing")
            moodSink?(.setup)
            statusSink?("Required permissions are still missing.")
            return
        }

        if !isSessionAvailable {
            cancelActiveEvaluationIfNeeded(reason: "session_unavailable")
            moodSink?(.idle)
            statusSink?("Session inactive. AC is standing by.")
            return
        }

        let now = Date()

        // Profile expiry check (clock-driven, no separate scheduler). If the active named
        // profile expired, swap to default before this tick runs so the rule scope is correct.
        let activeProfile = state.activeProfile
        if !activeProfile.isDefault, activeProfile.isExpired(at: now) {
            if let i = state.profiles.firstIndex(where: { $0.id == activeProfile.id }) {
                state.profiles[i].activatedAt = nil
                state.profiles[i].expiresAt = nil
            }
            state.activeProfileID = PolicyRule.defaultProfileID
            state.chatHistory.append(ChatMessage(
                role: .assistant,
                text: "\(activeProfile.name) ended. Switched back to General.",
                timestamp: now,
                interruptionPolicy: .deferred
            ))
            stateSink?(baseState, state)
            await appendMonitoringMetric(
                kind: .profileChanged,
                reason: "profile_expired",
                state: state,
                detail: activeProfile.id
            )
        }

        let idleSeconds = idleSecondsProvider?() ?? SnapshotService.idleSeconds()
        if idleSeconds >= 60 {
            cancelActiveEvaluationIfNeeded(reason: "idle_reset")
            await endActiveEpisode(
                reason: .idleReset,
                context: lastObservedContext,
                state: state,
                idleSeconds: idleSeconds,
                at: now
            )
            do {
                try monitoringAlgorithmRegistry.resetSelectedAlgorithmTransientState(
                    configuration: state.monitoringConfiguration,
                    state: &state.algorithmState
                )
            } catch {
                handleMonitoringConfigurationError(error)
                return
            }
            await appendMonitoringMetric(
                kind: .evaluationSkipped,
                reason: "idle",
                state: state,
                detail: "\(Int(idleSeconds))s"
            )
            stateSink?(baseState, state)
            moodSink?(.idle)
            statusSink?("You look idle, so AC backed off.")
            lastObservedAt = now
            return
        }

        guard let context = contextProvider?() ?? SnapshotService.frontmostContext() else {
            moodSink?(.idle)
            statusSink?("Could not read the active app yet.")
            return
        }

        updateUsageDurations(state: &state, with: context, now: now)

        let didChangeContext: Bool
        do {
            didChangeContext = try monitoringAlgorithmRegistry.noteContext(
                configuration: state.monitoringConfiguration,
                contextKey: context.contextKey,
                at: now,
                state: &state.algorithmState
            )
        } catch {
            handleMonitoringConfigurationError(error)
            return
        }
        if didChangeContext {
            await handleContextChange(
                from: lastObservedContext,
                to: context,
                state: state,
                idleSeconds: idleSeconds,
                now: now
            )
            recentSwitches.insert(
                AppSwitchRecord(
                    fromAppName: lastObservedContext?.appName,
                    toAppName: context.appName,
                    toWindowTitle: context.windowTitle,
                    timestamp: now
                ),
                at: 0
            )
            recentSwitches = Array(recentSwitches.prefix(6))
        }

        lastObservedContext = context
        state.recentSwitches = recentSwitches
        maybePersist(base: baseState, updated: state, at: now)

        await resolvePendingReactionIfNeeded(now: now, context: context)

        let heuristics = MonitoringHeuristics.telemetrySnapshot(for: context)

        guard !isEvaluating else {
            moodSink?(.watching)
            statusSink?("Watching \(context.appName) quietly.")
            stateSink?(baseState, state)
            return
        }

        // Profile-scope the policy memory the algorithm sees: only rules belonging to the
        // currently active profile apply. Default profile is the everyday baseline; a named
        // profile (e.g. "Coding") makes its safelist the only one in effect.
        let activeProfileID = state.activeProfileID
        var scopedPolicyMemory = state.policyMemory
        scopedPolicyMemory.rules = scopedPolicyMemory.rules.filter { $0.profileID == activeProfileID }

        let evaluationPlan: MonitoringEvaluationPlan
        do {
            evaluationPlan = try monitoringAlgorithmRegistry.evaluationPlan(
                configuration: state.monitoringConfiguration,
                context: context,
                heuristics: heuristics,
                policyMemory: scopedPolicyMemory,
                now: now,
                state: &state.algorithmState
            )
        } catch {
            handleMonitoringConfigurationError(error)
            return
        }

        guard evaluationPlan.shouldEvaluate else {
            await appendMonitoringMetric(
                kind: .evaluationSkipped,
                reason: evaluationPlan.reason ?? "not_due",
                state: state,
                detail: context.appName
            )
            moodSink?(.watching)
            statusSink?("Watching \(context.appName) quietly.")
            stateSink?(baseState, state)
            return
        }

        isEvaluating = true
        evaluationStartedAt = Date()
        defer {
            isEvaluating = false
            evaluationStartedAt = nil
        }

        if let visualCheckReason = evaluationPlan.visualCheckReason {
            statusSink?("Running periodic visual check for \(context.appName).")
            await appendObservationEvent(
                context: context,
                state: state,
                idleSeconds: idleSeconds,
                heuristics: heuristics,
                shouldEvaluateNow: true,
                transition: activeEpisode?.contextKey == context.contextKey ? .continuedObserving : .started,
                endReason: nil
            )
            await appendFailureIfNeeded(
                domain: "decision",
                message: "periodic_visual_reason=\(visualCheckReason)",
                evaluationID: nil
            )
        } else {
            statusSink?(evaluationPlan.requiresScreenshot
                ? "Evaluating \(context.appName) with a local snapshot."
                : "Evaluating \(context.appName) from title and usage context.")
        }

        let session = await ensureTelemetrySessionIfNeeded(for: state)
        let episodeTransition = ensureEpisode(for: context, sessionID: session?.id ?? "unknown", at: now)
        let evaluationEpisode = activeEpisode
        let algorithmDescriptor: MonitoringAlgorithmDescriptor
        do {
            algorithmDescriptor = try monitoringAlgorithmRegistry.descriptor(for: state.monitoringConfiguration.algorithmID)
        } catch {
            handleMonitoringConfigurationError(error)
            return
        }
        let executionMetadata = MonitoringExecutionMetadata(
            algorithmID: algorithmDescriptor.id,
            algorithmVersion: algorithmDescriptor.version,
            promptProfileID: state.monitoringConfiguration.promptProfileID,
            pipelineProfileID: state.monitoringConfiguration.pipelineProfileID,
            runtimeProfileID: state.monitoringConfiguration.runtimeProfileID,
            experimentArm: state.monitoringConfiguration.experimentArm
        )

        await appendObservationEvent(
            context: context,
            state: state,
            idleSeconds: idleSeconds,
            heuristics: heuristics,
            shouldEvaluateNow: true,
            transition: episodeTransition,
            endReason: nil
        )

        let evaluationID = UUID().uuidString
        let inferBackend = state.monitoringConfiguration.inferenceBackend.rawValue
        let reason = evaluationPlan.reason ?? "stable_context"
        await ActivityLogService.shared.append(level: .more,
            category: "eval",
            message: "tick #\(evaluationID.prefix(8)) · reason: \(reason) · backend: \(inferBackend) · profile: \(state.activeProfileID)"
        )
        await appendEvaluationRequestedEvent(
            sessionID: session?.id,
            evaluationID: evaluationID,
            episode: evaluationEpisode,
            reason: evaluationPlan.reason ?? "stable_context",
            promptMode: evaluationPlan.promptMode,
            promptVersion: evaluationPlan.promptVersion,
            execution: executionMetadata,
            activeProfile: state.activeProfile
        )

        let snapshot: AppSnapshot
        do {
            snapshot = try await buildSnapshot(
                from: context,
                state: &state,
                idle: false,
                now: now,
                sessionID: session?.id,
                evaluationID: evaluationID,
                requiresScreenshot: evaluationPlan.requiresScreenshot
            )
        } catch {
            statusSink?("Snapshot capture failed. Trying again later.")
            stateSink?(baseState, state)
            await ActivityLogService.shared.append(category: "snapshot-error", message: error.localizedDescription)
            await appendFailureIfNeeded(
                domain: "snapshot",
                message: error.localizedDescription,
                evaluationID: evaluationID,
                episode: evaluationEpisode
            )
            return
        }
        defer {
            cleanupEphemeralScreenshotIfNeeded(snapshot)
        }

        let preEvaluationDistraction = currentDistractionMetadata(from: state)

        // Calendar Intelligence: fetch the current event before kicking off the
        // evaluation task. Opt-in, never blocks — any failure (permission
        // denied, no event, EventKit hiccup) simply yields nil and the prompt
        // falls back to memory + chat as before.
        let calendarContext: String?
        if state.calendarIntelligenceEnabled,
           state.permissions.calendar == .granted {
            calendarContext = await CalendarService.shared.currentEventContext(
                now: now,
                enabledCalendarIdentifiers: state.enabledCalendarIdentifiers
            )
        } else {
            calendarContext = nil
        }

        // Re-read activeProfile here in case the expiry check earlier in this tick swapped it.
        let currentProfile = state.activeProfile
        let evaluationTask = Task { [monitoringAlgorithmRegistry, scopedPolicyMemory, currentProfile] in
            try await monitoringAlgorithmRegistry.evaluate(
                input: MonitoringDecisionInput(
                    now: now,
                    evaluationID: evaluationID,
                    snapshot: snapshot,
                    goals: state.goalsText,
                    recentActions: state.recentActions,
                heuristics: heuristics,
                memory: state.memoryForPrompt(now: now),
                recentUserMessages: Self.recentUserMessages(
                    chatHistory: state.chatHistory,
                    limit: MonitoringPromptContextBudget.recentUserChatCount
                ),
                policyMemory: scopedPolicyMemory,
                runtimeOverride: state.runtimePathOverride,
                configuration: state.monitoringConfiguration,
                algorithmState: state.algorithmState,
                characterPersonalityPrefix: state.character.personalityPrefix,
                calendarContext: calendarContext,
                activeProfileID: currentProfile.id,
                activeProfileName: currentProfile.name,
                activeProfileDescription: currentProfile.description,
                activeProfileExpiresAt: currentProfile.expiresAt
                )
            )
        }
        activeEvaluationTask = evaluationTask
        defer {
            activeEvaluationTask = nil
        }

        var decisionResult: MonitoringDecisionResult
        do {
            decisionResult = try await evaluationTask.value
            let attemptsSummary = decisionResult.evaluation.attempts
                .map { "\($0.promptMode):\($0.parsedDecision?.assessment.rawValue ?? "?")" }
                .joined(separator: ", ")
            await ActivityLogService.shared.append(level: .more,
                category: "eval",
                message: "verdict: \(decisionResult.decision.assessment.rawValue) · attempts: [\(attemptsSummary)]"
            )
        } catch is CancellationError {
            moodSink?(.watching)
            statusSink?("Context changed during evaluation — cancelled.")
            stateSink?(baseState, state)
            return
        } catch {
            handleMonitoringConfigurationError(error)
            return
        }

        // One-shot vision escalation: if text-only returned `unclear` and the pipeline supports
        // a screenshot, capture one and retry. Bound to a single retry per tick.
        let pipelineSupportsScreenshot = LLMPolicyCatalog
            .pipelineProfile(id: state.monitoringConfiguration.pipelineProfileID)
            .descriptor
            .requiresScreenshot
        if decisionResult.decision.assessment == .unclear,
           snapshot.screenshotPath == nil,
           pipelineSupportsScreenshot {
            do {
                let escalatedSnapshot = try await buildSnapshot(
                    from: context,
                    state: &state,
                    idle: false,
                    now: now,
                    sessionID: session?.id,
                    evaluationID: evaluationID,
                    requiresScreenshot: true
                )
                defer {
                    cleanupEphemeralScreenshotIfNeeded(escalatedSnapshot)
                }
                if escalatedSnapshot.screenshotPath != nil {
                    let retryInput = MonitoringDecisionInput(
                        now: Date(),
                        evaluationID: evaluationID,
                        snapshot: escalatedSnapshot,
                        goals: state.goalsText,
                        recentActions: state.recentActions,
                        heuristics: heuristics,
                        memory: state.memoryForPrompt(now: now),
                        recentUserMessages: Self.recentUserMessages(
                            chatHistory: state.chatHistory,
                            limit: MonitoringPromptContextBudget.recentUserChatCount
                        ),
                        policyMemory: scopedPolicyMemory,
                        runtimeOverride: state.runtimePathOverride,
                        configuration: state.monitoringConfiguration,
                        algorithmState: state.algorithmState,
                        characterPersonalityPrefix: state.character.personalityPrefix,
                        calendarContext: calendarContext,
                        activeProfileID: currentProfile.id,
                        activeProfileName: currentProfile.name,
                        activeProfileDescription: currentProfile.description,
                        activeProfileExpiresAt: currentProfile.expiresAt
                    )
                    let retried = try await monitoringAlgorithmRegistry.evaluate(input: retryInput)
                    decisionResult = retried
                    await ActivityLogService.shared.append(
                        category: "vision-retry",
                        message: "Text-only returned unclear; retried with screenshot. New verdict: \(retried.decision.assessment.rawValue)"
                    )
                    await appendMonitoringMetric(
                        kind: .visionRetried,
                        reason: retried.decision.assessment.rawValue,
                        state: state,
                        detail: context.appName
                    )
                }
            } catch is CancellationError {
                moodSink?(.watching)
                statusSink?("Context changed during retry — cancelled.")
                stateSink?(baseState, state)
                return
            } catch {
                // Retry failure: keep the original unclear verdict, log, and continue.
                await ActivityLogService.shared.append(
                    category: "vision-retry-error",
                    message: error.localizedDescription
                )
            }
        }

        await appendEvaluationArtifacts(
            decisionResult.evaluation,
            evaluationID: evaluationID,
            sessionID: session?.id,
            episode: evaluationEpisode,
            snapshot: snapshot,
            state: state,
            heuristics: heuristics,
            distraction: preEvaluationDistraction
        )

        state.algorithmState = decisionResult.updatedAlgorithmState

        if let policyMemoryUpdate = decisionResult.policyMemoryUpdate,
           !policyMemoryUpdate.operations.isEmpty {
            // Stamp newly-added rules with the currently active profile id so promotion
            // (e.g. safelist_appeal) and chat-driven additions land in the right scope.
            var stamped = policyMemoryUpdate
            stamped.operations = stamped.operations.map { op in
                guard op.type == .addRule, var rule = op.rule else { return op }
                if rule.profileID.isEmpty || rule.profileID == PolicyRule.defaultProfileID {
                    rule.profileID = activeProfileID
                }
                var copy = op
                copy.rule = rule
                return copy
            }
            state.policyMemory.apply(stamped, now: now)
        }

        await appendPolicyDecisionEvent(
            sessionID: session?.id,
            episode: evaluationEpisode,
            policy: decisionResult.policy.record
        )

        guard lastObservedContext?.contextKey == context.contextKey else {
            moodSink?(.watching)
            statusSink?("Context changed during evaluation — action discarded.")
            stateSink?(baseState, state)
            await appendFailureIfNeeded(
                domain: "policy",
                message: "stale_context: evaluation started in \(context.appName) but user has since moved away",
                evaluationID: evaluationID,
                episode: evaluationEpisode
            )
            await appendActionExecutedEvent(
                sessionID: session?.id,
                episode: evaluationEpisode,
                evaluationID: evaluationID,
                action: .none,
                execution: decisionResult.execution
            )
            maybePersist(base: baseState, updated: state, at: now, force: true)
            return
        }

        switch decisionResult.policy.action {
        case let .showNudge(message):
            modelUsageSink?(decisionResult.evaluation.lastUsedModelIdentifier)
            let actionID = UUID().uuidString
            state.recentActions.insert(ActionRecord(
                id: actionID,
                kind: .nudge,
                message: message,
                timestamp: now,
                evaluationID: evaluationID,
                contextKey: context.contextKey,
                appName: context.appName,
                windowTitle: context.windowTitle
            ), at: 0)
            state.recentActions = Array(state.recentActions.prefix(12))
            attachIntervention(actionID, toLatestSegmentIn: &state)
            stateSink?(baseState, state)
            moodSink?(.nudging)
            statusSink?("Nudged while you were in \(context.appName).")
            executiveArm.perform(.showNudge(message))
            pendingReactionsByEvaluationID[evaluationID] = PendingReaction(
                episodeID: evaluationEpisode?.id ?? activeEpisode?.id ?? "",
                evaluationID: evaluationID,
                action: .showNudge(message),
                issuedAt: now,
                sourceContextKey: context.contextKey
            )

        case let .showOverlay(presentation):
            modelUsageSink?(decisionResult.evaluation.lastUsedModelIdentifier)
            let actionID = UUID().uuidString
            state.recentActions.insert(ActionRecord(
                id: actionID,
                kind: .overlay,
                message: [presentation.headline, presentation.body].joined(separator: " — "),
                timestamp: now,
                evaluationID: evaluationID,
                contextKey: context.contextKey,
                appName: context.appName,
                windowTitle: context.windowTitle
            ), at: 0)
            state.recentActions = Array(state.recentActions.prefix(12))
            attachIntervention(actionID, toLatestSegmentIn: &state)
            stateSink?(baseState, state)
            moodSink?(.escalated)
            statusSink?("Escalated after repeated distraction signals.")
            executiveArm.perform(.showOverlay(presentation))
            pendingReactionsByEvaluationID[evaluationID] = PendingReaction(
                episodeID: evaluationEpisode?.id ?? activeEpisode?.id ?? "",
                evaluationID: evaluationID,
                action: .showOverlay(presentation),
                issuedAt: now,
                sourceContextKey: context.contextKey
            )

        case .none:
            moodSink?(.watching)
            statusSink?("No action needed in \(context.appName).")
            stateSink?(baseState, state)
        }

        await appendActionExecutedEvent(
            sessionID: session?.id,
            episode: evaluationEpisode,
            evaluationID: evaluationID,
            action: decisionResult.policy.action,
            execution: decisionResult.execution
        )

        maybePersist(base: baseState, updated: state, at: now, force: true)
    }

    private func buildSnapshot(
        from context: FrontmostContext,
        state: inout ACState,
        idle: Bool,
        now: Date,
        sessionID: String?,
        evaluationID: String,
        requiresScreenshot: Bool
    ) async throws -> AppSnapshot {
        let persistVerboseTelemetry = shouldPersistVerboseTelemetry(state: state)
        let screenshotURL: URL?
        if requiresScreenshot {
            if let overrideCapture = screenshotCapture {
                screenshotURL = try await overrideCapture()
            } else {
                switch state.monitoringConfiguration.screenshotCaptureMode {
                case .activeWindow:
                    let interval = state.monitoringConfiguration.periodicFullScreenInterval
                    let needsFullScreen: Bool
                    if let lastCheck = state.lastFullScreenCheckAt {
                        needsFullScreen = now.timeIntervalSince(lastCheck) >= interval
                    } else {
                        needsFullScreen = true // first check should be full screen
                    }
                    if needsFullScreen {
                        screenshotURL = try await SnapshotService.captureScreenshot()
                        state.lastFullScreenCheckAt = now
                    } else {
                        screenshotURL = try await SnapshotService.captureActiveWindowScreenshot()
                    }
                case .fullScreen:
                    screenshotURL = try await SnapshotService.captureScreenshot()
                }
            }
        } else {
            screenshotURL = nil
        }

        let dayUsage = state.usageByDay[now.acDayKey] ?? [:]
        let perAppDurations = dayUsage
            .map { AppUsageRecord(appName: $0.key, seconds: $0.value) }
            .sorted { $0.seconds > $1.seconds }

        let screenshotArtifacts: StoredImageArtifacts?
        if persistVerboseTelemetry, let sessionID, let screenshotURL {
            screenshotArtifacts = try? await telemetryStore.writeScreenshotArtifacts(
                from: screenshotURL,
                sessionID: sessionID,
                stem: "eval-\(evaluationID)-screenshot"
            )
        } else {
            screenshotArtifacts = nil
        }

        let fallbackArtifact: ArtifactRef?
        if persistVerboseTelemetry, let screenshotURL {
            fallbackArtifact = ArtifactRef(
                id: UUID().uuidString,
                kind: .screenshotOriginal,
                relativePath: screenshotArtifacts?.absoluteOriginalURL.path ?? screenshotURL.path,
                sha256: nil,
                byteCount: (try? Data(contentsOf: screenshotURL).count) ?? 0,
                width: nil,
                height: nil,
                createdAt: now
            )
        } else {
            fallbackArtifact = nil
        }

        return AppSnapshot(
            bundleIdentifier: context.bundleIdentifier,
            appName: context.appName,
            windowTitle: context.windowTitle,
            recentSwitches: recentSwitches,
            perAppDurations: perAppDurations,
            screenshotArtifact: screenshotArtifacts?.original ?? fallbackArtifact,
            screenshotThumbnail: screenshotArtifacts?.thumbnail,
            screenshotPath: screenshotArtifacts?.absoluteOriginalURL.path ?? screenshotURL?.path,
            idle: idle,
            timestamp: now
        )
    }

    private func updateUsageDurations(state: inout ACState, with context: FrontmostContext, now: Date) {
        let delta = now.timeIntervalSince(lastObservedAt)
        defer { lastObservedAt = now }

        guard delta > 0, let previousContext = lastObservedContext else {
            return
        }

        var usageForDay = state.usageByDay[now.acDayKey] ?? [:]
        usageForDay[previousContext.appName, default: 0] += delta
        state.usageByDay[now.acDayKey] = usageForDay

        appendFocusSegment(
            state: &state,
            context: previousContext,
            start: lastObservedAt,
            end: now
        )
    }

    private func appendFocusSegment(
        state: inout ACState,
        context: FrontmostContext,
        start: Date,
        end: Date
    ) {
        guard end.timeIntervalSince(start) >= 1 else { return }

        let assessment = focusAssessment(for: context, state: state)
        let driftScore = state.algorithmState.llmPolicy.focusSignal.clampedDrift

        if var last = state.focusSegments.last,
           last.assessment == assessment,
           last.appName == context.appName,
           last.bundleIdentifier == context.bundleIdentifier,
           last.windowTitle == context.windowTitle,
           start.timeIntervalSince(last.endAt) <= 5 {
            last.endAt = end
            last.driftScore = driftScore
            state.focusSegments[state.focusSegments.count - 1] = last
        } else {
            state.focusSegments.append(FocusTimelineSegment(
                startAt: start,
                endAt: end,
                appName: context.appName,
                bundleIdentifier: context.bundleIdentifier,
                windowTitle: context.windowTitle,
                assessment: assessment,
                driftScore: driftScore
            ))
        }

        pruneFocusSegments(state: &state, now: end)
    }

    private func focusAssessment(
        for context: FrontmostContext,
        state: ACState
    ) -> FocusSegmentAssessment {
        let distraction = currentDistractionMetadata(from: state)
        if let lastAssessment = distraction.lastAssessment {
            return FocusSegmentAssessment(distractionAssessment: lastAssessment)
        }

        if MonitoringHeuristics.isClearlyProductive(
            bundleIdentifier: context.bundleIdentifier,
            appName: context.appName
        ) {
            return .focused
        }

        return .unclear
    }

    private func attachIntervention(_ actionID: String, toLatestSegmentIn state: inout ACState) {
        guard !state.focusSegments.isEmpty else { return }
        state.focusSegments[state.focusSegments.count - 1].interventionID = actionID
    }

    private func pruneFocusSegments(state: inout ACState, now: Date) {
        let retentionStart = now.addingTimeInterval(-(14 * 24 * 60 * 60))
        state.focusSegments.removeAll { $0.endAt < retentionStart }
        if state.focusSegments.count > 700 {
            state.focusSegments = Array(state.focusSegments.suffix(700))
        }
    }

    private func maybePersist(base: ACState, updated: ACState, at now: Date, force: Bool = false) {
        guard force || now.timeIntervalSince(lastPersistAt) >= 30 else {
            return
        }

        stateSink?(base, updated)
        storageService.saveState(stateProvider?() ?? updated)
        lastPersistAt = now
    }

    private func ensureEpisode(for context: FrontmostContext, sessionID: String, at now: Date) -> ObservationTransition {
        if let activeEpisode, activeEpisode.contextKey == context.contextKey {
            return .continuedObserving
        }

        activeEpisode = EpisodeRecord(
            id: UUID().uuidString,
            sessionID: sessionID,
            contextKey: context.contextKey,
            appName: context.appName,
            windowTitle: context.windowTitle,
            startedAt: now,
            endedAt: nil,
            status: .active,
            endReason: nil,
            pinned: false
        )
        return .started
    }

    private func handleContextChange(
        from previousContext: FrontmostContext?,
        to context: FrontmostContext,
        state: ACState,
        idleSeconds: TimeInterval,
        now: Date
    ) async {
        cancelActiveEvaluationIfNeeded(reason: "context_changed")

        let endReason: EpisodeEndReason
        if let pendingReaction = mostRecentPendingReaction(
            where: { pending in
                pending.episodeID == activeEpisode?.id
                && now.timeIntervalSince(pending.issuedAt) <= 150
                && context.bundleIdentifier == state.rescueApp.bundleIdentifier
            }
        ) {
            await recordImplicitReaction(
                UserReactionRecord(
                    kind: .postNudgeRescueReturn,
                    relatedAction: CompanionPolicy.telemetryActionRecord(for: pendingReaction.action),
                    positive: true,
                    details: context.appName
                ),
                at: now
            )
            endReason = .rescueReturn
            pendingReactionsByEvaluationID.removeValue(forKey: pendingReaction.evaluationID)
        } else if let pendingReaction = mostRecentPendingReaction(
            where: { pending in
                pending.episodeID == activeEpisode?.id
                && now.timeIntervalSince(pending.issuedAt) <= 150
                && MonitoringHeuristics.isClearlyProductive(
                    bundleIdentifier: context.bundleIdentifier,
                    appName: context.appName
                )
            }
        ) {
            await recordImplicitReaction(
                UserReactionRecord(
                    kind: .postNudgeAppSwitch,
                    relatedAction: CompanionPolicy.telemetryActionRecord(for: pendingReaction.action),
                    positive: true,
                    details: context.appName
                ),
                at: now
            )
            endReason = .contextChange
        } else {
            endReason = .contextChange
        }

        await endActiveEpisode(
            reason: endReason,
            context: previousContext,
            state: state,
            idleSeconds: idleSeconds,
            at: now
        )
    }

    private func endActiveEpisode(
        reason: EpisodeEndReason,
        context: FrontmostContext?,
        state: ACState,
        idleSeconds: TimeInterval,
        at now: Date
    ) async {
        guard var episode = activeEpisode else {
            return
        }

        episode.status = .ended
        episode.endedAt = now
        episode.endReason = reason
        activeEpisode = nil

        guard shouldPersistVerboseTelemetry(state: state) else {
            return
        }

        if let context {
            let heuristics = MonitoringHeuristics.telemetrySnapshot(for: context)
            let observation = ObservationRecord(
                context: context.telemetryContext(
                    idleSeconds: idleSeconds,
                    recentSwitches: recentSwitches,
                    perAppDurations: currentUsageRecords(from: state, now: now),
                    recentActions: state.recentActions,
                    timestamp: now
                ),
                heuristics: heuristics,
                distraction: currentDistractionMetadata(from: state).telemetryState,
                visualCheckReason: heuristics.periodicVisualReason,
                shouldEvaluateNow: false,
                transition: .ended,
                endReason: reason
            )
            let sessionID = (try? await telemetryStore.ensureCurrentSession(reason: "runtime").id) ?? episode.sessionID
            try? await telemetryStore.appendEvent(
                TelemetryEvent(
                    id: UUID().uuidString,
                    kind: .observation,
                    timestamp: now,
                    sessionID: sessionID,
                    episodeID: episode.id,
                    episode: episode,
                    session: nil,
                    observation: observation,
                    evaluation: nil,
                    modelInput: nil,
                    modelOutput: nil,
                    parsedOutput: nil,
                    policy: nil,
                    action: nil,
                    reaction: nil,
                    annotation: nil,
                    failure: nil
                ),
                sessionID: sessionID
            )
        }
    }

    private func appendObservationEvent(
        context: FrontmostContext,
        state: ACState,
        idleSeconds: TimeInterval,
        heuristics: TelemetryHeuristicSnapshot,
        shouldEvaluateNow: Bool,
        transition: ObservationTransition,
        endReason: EpisodeEndReason?
    ) async {
        guard shouldPersistVerboseTelemetry(state: state) else {
            return
        }
        guard let sessionID = try? await telemetryStore.ensureCurrentSession(reason: "runtime").id else {
            return
        }

        let event = TelemetryEvent(
            id: UUID().uuidString,
            kind: .observation,
            timestamp: Date(),
            sessionID: sessionID,
            episodeID: activeEpisode?.id,
            episode: activeEpisode,
            session: nil,
            observation: ObservationRecord(
                context: context.telemetryContext(
                    idleSeconds: idleSeconds,
                    recentSwitches: recentSwitches,
                    perAppDurations: currentUsageRecords(from: state, now: Date()),
                    recentActions: state.recentActions,
                    timestamp: Date()
                ),
                heuristics: heuristics,
                distraction: currentDistractionMetadata(from: state).telemetryState,
                visualCheckReason: heuristics.periodicVisualReason,
                shouldEvaluateNow: shouldEvaluateNow,
                transition: transition,
                endReason: endReason
            ),
            evaluation: nil,
            modelInput: nil,
            modelOutput: nil,
            parsedOutput: nil,
            policy: nil,
            action: nil,
            reaction: nil,
            annotation: nil,
            failure: nil
        )

        try? await telemetryStore.appendEvent(event, sessionID: sessionID)
    }

    private func appendEvaluationRequestedEvent(
        sessionID: String?,
        evaluationID: String,
        episode: EpisodeRecord?,
        reason: String,
        promptMode: String,
        promptVersion: String,
        execution: MonitoringExecutionMetadata,
        activeProfile: FocusProfile
    ) async {
        guard shouldPersistVerboseTelemetry() else { return }
        guard let sessionID else { return }
        try? await telemetryStore.appendEvent(
            TelemetryEvent(
                id: UUID().uuidString,
                kind: .evaluationRequested,
                timestamp: Date(),
                sessionID: sessionID,
                episodeID: episode?.id,
                episode: episode,
                session: nil,
                observation: nil,
                evaluation: EvaluationRequestRecord(
                    evaluationID: evaluationID,
                    reason: reason,
                    promptMode: promptMode,
                    promptVersion: promptVersion,
                    strategy: execution.telemetryRecord,
                    activeProfileID: activeProfile.id,
                    activeProfileName: activeProfile.name
                ),
                modelInput: nil,
                modelOutput: nil,
                parsedOutput: nil,
                policy: nil,
                action: nil,
                reaction: nil,
                annotation: nil,
                failure: nil
            ),
            sessionID: sessionID
        )
    }

    private func appendEvaluationArtifacts(
        _ evaluation: LLMEvaluationResult,
        evaluationID: String,
        sessionID: String?,
        episode: EpisodeRecord?,
        snapshot: AppSnapshot,
        state: ACState,
        heuristics: TelemetryHeuristicSnapshot,
        distraction: DistractionMetadata
    ) async {
        guard shouldPersistVerboseTelemetry(state: state) else { return }
        guard let sessionID else { return }

        let contextRecord = TelemetryContextRecord(
            bundleIdentifier: snapshot.bundleIdentifier,
            appName: snapshot.appName,
            windowTitle: snapshot.windowTitle,
            contextKey: [snapshot.bundleIdentifier ?? "unknown", snapshot.windowTitle?.normalizedForContextKey ?? ""].joined(separator: "|"),
            idleSeconds: SnapshotService.idleSeconds(),
            recentSwitches: snapshot.recentSwitches.map(\.telemetryRecord),
            perAppDurations: snapshot.perAppDurations.map(\.telemetryRecord),
            recentActions: state.recentActions.map(\.telemetrySummary),
            timestamp: snapshot.timestamp
        )

        for attempt in evaluation.attempts {
            let templateArtifact = try? await telemetryStore.writePromptTemplateArtifact(
                contents: attempt.templateContents,
                sessionID: sessionID,
                template: attempt.template
            )
            let payloadArtifact = try? await telemetryStore.writeTextArtifact(
                attempt.payloadJSON,
                sessionID: sessionID,
                prefix: "eval-\(evaluationID)-payload-\(attempt.promptMode)",
                kind: .promptPayload
            )
            let renderedPromptArtifact = try? await telemetryStore.writeTextArtifact(
                attempt.renderedPrompt,
                sessionID: sessionID,
                prefix: "eval-\(evaluationID)-prompt-\(attempt.promptMode)",
                kind: .renderedPrompt
            )

            try? await telemetryStore.appendEvent(
                TelemetryEvent(
                    id: UUID().uuidString,
                    kind: .modelInputSaved,
                    timestamp: Date(),
                    sessionID: sessionID,
                    episodeID: episode?.id,
                    episode: episode,
                    session: nil,
                    observation: nil,
                    evaluation: nil,
                    modelInput: ModelInputRecord(
                        evaluationID: evaluationID,
                        goalsSummary: state.goalsText.cleanedSingleLine,
                        screenshot: snapshot.screenshotArtifact,
                        screenshotThumbnail: snapshot.screenshotThumbnail,
                        promptMode: attempt.promptMode,
                        promptTemplate: attempt.template,
                        promptTemplateArtifact: templateArtifact,
                        promptPayloadArtifact: payloadArtifact,
                        renderedPromptArtifact: renderedPromptArtifact,
                        context: contextRecord,
                        heuristics: heuristics,
                        distraction: distraction.telemetryState
                    ),
                    modelOutput: nil,
                    parsedOutput: nil,
                    policy: nil,
                    action: nil,
                    reaction: nil,
                    annotation: nil,
                    failure: nil
                ),
                sessionID: sessionID
            )

            if let output = attempt.runtimeOutput {
                let stdoutArtifact = output.stdout.isEmpty ? nil : try? await telemetryStore.writeTextArtifact(
                    output.stdout,
                    sessionID: sessionID,
                    prefix: "eval-\(evaluationID)-stdout-\(attempt.promptMode)",
                    kind: .rawStdout
                )
                let stderrArtifact = output.stderr.isEmpty ? nil : try? await telemetryStore.writeTextArtifact(
                    output.stderr,
                    sessionID: sessionID,
                    prefix: "eval-\(evaluationID)-stderr-\(attempt.promptMode)",
                    kind: .rawStderr
                )

                try? await telemetryStore.appendEvent(
                    TelemetryEvent(
                        id: UUID().uuidString,
                        kind: .modelOutputReceived,
                        timestamp: Date(),
                        sessionID: sessionID,
                        episodeID: episode?.id,
                        episode: episode,
                        session: nil,
                        observation: nil,
                        evaluation: nil,
                        modelInput: nil,
                        modelOutput: ModelOutputRecord(
                            evaluationID: evaluationID,
                            runtimePath: evaluation.runtimePath,
                            modelIdentifier: evaluation.modelIdentifier,
                            promptMode: attempt.promptMode,
                            runtimeOptions: attempt.runtimeOptions,
                            stdoutArtifact: stdoutArtifact,
                            stderrArtifact: stderrArtifact,
                            stdoutPreview: output.stdout.cleanedSingleLine.prefix(220).description,
                            stderrPreview: output.stderr.cleanedSingleLine.prefix(220).description,
                            tokenUsage: output.tokenUsage.map { usage in
                                TokenUsageRecord(
                                    promptTokens: usage.promptTokens,
                                    completionTokens: usage.completionTokens,
                                    totalTokens: usage.totalTokens,
                                    cacheReadTokens: usage.cacheReadTokens,
                                    imageTokens: usage.imageTokens,
                                    costUSD: usage.costUSD,
                                    estimated: usage.estimated,
                                    includesScreenshot: snapshot.screenshotArtifact != nil
                                )
                            }
                        ),
                        parsedOutput: nil,
                        policy: nil,
                        action: nil,
                        reaction: nil,
                        annotation: nil,
                        failure: nil
                    ),
                    sessionID: sessionID
                )
            }

            if let parsedDecision = attempt.parsedDecision {
                try? await telemetryStore.appendEvent(
                    TelemetryEvent(
                        id: UUID().uuidString,
                        kind: .modelOutputParsed,
                        timestamp: Date(),
                        sessionID: sessionID,
                        episodeID: episode?.id,
                        episode: episode,
                        session: nil,
                        observation: nil,
                        evaluation: nil,
                        modelInput: nil,
                        modelOutput: nil,
                        parsedOutput: parsedDecision.parsedRecord,
                        policy: nil,
                        action: nil,
                        reaction: nil,
                        annotation: nil,
                        failure: nil
                    ),
                    sessionID: sessionID
                )
            }
        }

        if let failureMessage = evaluation.failureMessage {
            await appendFailureIfNeeded(
                domain: "llm",
                message: failureMessage,
                evaluationID: evaluationID,
                episode: episode
            )
        }
    }

    private func appendPolicyDecisionEvent(
        sessionID: String?,
        episode: EpisodeRecord?,
        policy: PolicyDecisionRecord
    ) async {
        guard shouldPersistVerboseTelemetry() else { return }
        guard let sessionID else { return }
        try? await telemetryStore.appendEvent(
            TelemetryEvent(
                id: UUID().uuidString,
                kind: .policyDecided,
                timestamp: Date(),
                sessionID: sessionID,
                episodeID: episode?.id,
                episode: episode,
                session: nil,
                observation: nil,
                evaluation: nil,
                modelInput: nil,
                modelOutput: nil,
                parsedOutput: nil,
                policy: policy,
                action: nil,
                reaction: nil,
                annotation: nil,
                failure: nil
            ),
            sessionID: sessionID
        )
    }

    private func appendActionExecutedEvent(
        sessionID: String?,
        episode: EpisodeRecord?,
        evaluationID: String,
        action: CompanionAction,
        execution: MonitoringExecutionMetadata
    ) async {
        guard shouldPersistVerboseTelemetry() else { return }
        guard let sessionID else { return }
        guard action != .none else { return }
        try? await telemetryStore.appendEvent(
            TelemetryEvent(
                id: UUID().uuidString,
                kind: .actionExecuted,
                timestamp: Date(),
                sessionID: sessionID,
                episodeID: episode?.id,
                episode: episode,
                session: nil,
                observation: nil,
                evaluation: nil,
                modelInput: nil,
                modelOutput: nil,
                parsedOutput: nil,
                policy: nil,
                action: ActionExecutionRecord(
                    evaluationID: evaluationID,
                    strategy: execution.telemetryRecord,
                    action: CompanionPolicy.telemetryActionRecord(for: action),
                    source: "policy",
                    succeeded: true
                ),
                reaction: nil,
                annotation: nil,
                failure: nil
            ),
            sessionID: sessionID
        )
    }

    private func recordImplicitReaction(_ reaction: UserReactionRecord, at now: Date) async {
        guard shouldPersistVerboseTelemetry() else {
            return
        }
        guard let sessionID = try? await telemetryStore.ensureCurrentSession(reason: "runtime").id else {
            return
        }

        try? await telemetryStore.appendEvent(
            TelemetryEvent(
                id: UUID().uuidString,
                kind: .userReaction,
                timestamp: now,
                sessionID: sessionID,
                episodeID: activeEpisode?.id,
                episode: activeEpisode,
                session: nil,
                observation: nil,
                evaluation: nil,
                modelInput: nil,
                modelOutput: nil,
                parsedOutput: nil,
                policy: nil,
                action: nil,
                reaction: reaction,
                annotation: nil,
                failure: nil
            ),
            sessionID: sessionID
        )
    }

    private func resolvePendingReactionIfNeeded(now: Date, context: FrontmostContext) async {
        let expiredReactions = pendingReactionsByEvaluationID.values
            .filter {
                now.timeIntervalSince($0.issuedAt) > 150
                && context.contextKey == $0.sourceContextKey
            }
            .sorted { $0.issuedAt < $1.issuedAt }

        for pendingReaction in expiredReactions {
            await recordImplicitReaction(
                UserReactionRecord(
                    kind: .nudgeIgnored,
                    relatedAction: CompanionPolicy.telemetryActionRecord(for: pendingReaction.action),
                    positive: false,
                    details: context.appName
                ),
                at: now
            )
            pendingReactionsByEvaluationID.removeValue(forKey: pendingReaction.evaluationID)
        }
    }

    private func appendFailureIfNeeded(
        domain: String,
        message: String,
        evaluationID: String?,
        episode: EpisodeRecord? = nil
    ) async {
        guard shouldPersistVerboseTelemetry() else {
            return
        }
        guard let sessionID = try? await telemetryStore.ensureCurrentSession(reason: "runtime").id else {
            return
        }
        let resolvedEpisode = episode ?? activeEpisode
        try? await telemetryStore.appendEvent(
            TelemetryEvent(
                id: UUID().uuidString,
                kind: .failure,
                timestamp: Date(),
                sessionID: sessionID,
                episodeID: resolvedEpisode?.id,
                episode: resolvedEpisode,
                session: nil,
                observation: nil,
                evaluation: nil,
                modelInput: nil,
                modelOutput: nil,
                parsedOutput: nil,
                policy: nil,
                action: nil,
                reaction: nil,
                annotation: nil,
                failure: FailureRecord(domain: domain, message: message, evaluationID: evaluationID)
            ),
            sessionID: sessionID
        )
    }

    private func appendMonitoringMetric(
        kind: MonitoringMetricKind,
        reason: String,
        state: ACState,
        detail: String? = nil
    ) async {
        guard shouldPersistVerboseTelemetry(state: state) else {
            return
        }
        guard let sessionID = try? await telemetryStore.ensureCurrentSession(reason: "runtime").id else {
            return
        }
        let active = state.activeProfile
        try? await telemetryStore.appendEvent(
            TelemetryEvent(
                id: UUID().uuidString,
                kind: .monitoringMetric,
                timestamp: Date(),
                sessionID: sessionID,
                episodeID: activeEpisode?.id,
                episode: activeEpisode,
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
                    activeProfileID: active.id,
                    activeProfileName: active.name,
                    detail: detail
                ),
                reaction: nil,
                annotation: nil,
                failure: nil
            ),
            sessionID: sessionID
        )
    }

    private func currentUsageRecords(from state: ACState, now: Date) -> [AppUsageRecord] {
        let dayUsage = state.usageByDay[now.acDayKey] ?? [:]
        return dayUsage
            .map { AppUsageRecord(appName: $0.key, seconds: $0.value) }
            .sorted { $0.seconds > $1.seconds }
    }

    private func currentDistractionMetadata(from state: ACState) -> DistractionMetadata {
        (try? monitoringAlgorithmRegistry.distractionMetadata(
            configuration: state.monitoringConfiguration,
            state: state.algorithmState
        )) ?? DistractionMetadata()
    }

    private func handleMonitoringConfigurationError(_ error: Error) {
        moodSink?(.setup)
        statusSink?("Monitoring configuration is invalid. Reset it in the app settings.")
        Task {
            await ActivityLogService.shared.append(category: "monitoring-config", message: error.localizedDescription)
        }
    }

    private func resetRuntimeContext() {
        cancelActiveEvaluationIfNeeded(reason: "runtime_context_reset")
        pendingReactionsByEvaluationID = [:]
        activeEpisode = nil
        lastObservedContext = nil
        lastObservedAt = Date()
    }

    private func checkEvaluationHealth() {
        guard isEvaluating, let startedAt = evaluationStartedAt else { return }
        guard Date().timeIntervalSince(startedAt) > 35 else { return }
        cancelActiveEvaluationIfNeeded(reason: "watchdog_stale_evaluation")
    }

    private func cancelActiveEvaluationIfNeeded(reason: String) {
        guard let activeEvaluationTask else { return }
        guard !activeEvaluationTask.isCancelled else { return }

        activeEvaluationTask.cancel()
        Task {
            await ActivityLogService.shared.append(
                category: "monitoring-cancel",
                message: reason
            )
        }
    }

    private func matchingPendingReaction(for reaction: UserReactionRecord) -> PendingReaction? {
        mostRecentPendingReaction { pending in
            guard Self.matches(action: pending.action, reaction: reaction) else { return false }
            if !pending.episodeID.isEmpty, pending.episodeID != activeEpisode?.id {
                return false
            }
            return true
        }
    }

    private func mostRecentPendingReaction(
        where predicate: (PendingReaction) -> Bool
    ) -> PendingReaction? {
        pendingReactionsByEvaluationID.values
            .filter(predicate)
            .max { $0.issuedAt < $1.issuedAt }
    }

    private static func matches(action: CompanionAction, reaction: UserReactionRecord) -> Bool {
        guard let relatedAction = reaction.relatedAction else { return true }

        switch (action, relatedAction.kind) {
        case let (.showNudge(message), .nudge):
            if let relatedMessage = relatedAction.message?.cleanedSingleLine, !relatedMessage.isEmpty {
                return message.cleanedSingleLine == relatedMessage
            }
            return true
        case (.showOverlay(_), .overlay):
            return true
        case (.none, .none):
            return true
        default:
            return false
        }
    }
}

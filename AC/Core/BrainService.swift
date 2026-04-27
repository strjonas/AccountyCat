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
    var stateSink: ((ACState) -> Void)?
    var moodSink: ((CompanionMood) -> Void)?
    var statusSink: ((String) -> Void)?

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

    /// Maps a user reaction kind to a bandit reward value.
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

    private func cleanupEphemeralScreenshotIfNeeded(_ snapshot: AppSnapshot, sessionID: String?) {
        guard sessionID == nil,
              let screenshotPath = snapshot.screenshotPath,
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
        RunLoop.main.add(timer!, forMode: .common)
        RunLoop.main.add(contextProbeTimer!, forMode: .common)
    }

    func stop() {
        cancelActiveEvaluationIfNeeded(reason: "monitoring_stop")
        timer?.invalidate()
        timer = nil
        contextProbeTimer?.invalidate()
        contextProbeTimer = nil
        isTickScheduled = false
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    func resetDistractionState() {
        guard var state = stateProvider?() else { return }
        do {
            try monitoringAlgorithmRegistry.resetSelectedAlgorithmTransientState(
                configuration: state.monitoringConfiguration,
                state: &state.algorithmState
            )
        } catch {
            handleMonitoringConfigurationError(error)
        }
        stateSink?(state)
    }

    func resetAlgorithmProfile() {
        cancelActiveEvaluationIfNeeded(reason: "reset_algorithm_profile")
        recentSwitches = []
        resetRuntimeContext()
        resetDistractionState()
    }

    func handleMonitoringConfigurationChange() {
        cancelActiveEvaluationIfNeeded(reason: "monitoring_configuration_changed")
        guard var state = stateProvider?() else { return }
        state.algorithmState = AlgorithmStateEnvelope()
        stateSink?(state)
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

        // Feed reward signal to the active algorithm (bandit learns; LLM algorithm is a no-op).
        if let reward = Self.rewardValue(for: reaction.kind),
           let captured = matchingPendingReaction(for: reaction),
           var state = stateProvider?() {
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
            stateSink?(state)
            maybePersist(state: state, at: Date(), force: true)
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

    private func tick() async {
        guard let stateProvider, var state = Optional(stateProvider()) else {
            return
        }

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
        let idleSeconds = SnapshotService.idleSeconds()
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
            stateSink?(state)
            moodSink?(.idle)
            statusSink?("You look idle, so AC backed off.")
            lastObservedAt = now
            return
        }

        guard let context = SnapshotService.frontmostContext() else {
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
        maybePersist(state: state, at: now)

        await resolvePendingReactionIfNeeded(now: now, context: context)

        let heuristics = MonitoringHeuristics.telemetrySnapshot(for: context)

        guard !isEvaluating else {
            moodSink?(.watching)
            statusSink?("Watching \(context.appName) quietly.")
            stateSink?(state)
            return
        }

        let evaluationPlan: MonitoringEvaluationPlan
        do {
            evaluationPlan = try monitoringAlgorithmRegistry.evaluationPlan(
                configuration: state.monitoringConfiguration,
                context: context,
                heuristics: heuristics,
                policyMemory: state.policyMemory,
                now: now,
                state: &state.algorithmState
            )
        } catch {
            handleMonitoringConfigurationError(error)
            return
        }

        guard evaluationPlan.shouldEvaluate else {
            moodSink?(.watching)
            statusSink?("Watching \(context.appName) quietly.")
            stateSink?(state)
            return
        }

        isEvaluating = true
        defer { isEvaluating = false }

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
            promptProfileID: PromptCatalog.monitoringDescriptor(id: state.monitoringConfiguration.promptProfileID).id,
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
        await appendEvaluationRequestedEvent(
            sessionID: session?.id,
            evaluationID: evaluationID,
            episode: evaluationEpisode,
            reason: evaluationPlan.reason ?? "stable_context",
            promptMode: evaluationPlan.promptMode,
            promptVersion: evaluationPlan.promptVersion,
            execution: executionMetadata
        )

        let snapshot: AppSnapshot
        do {
            snapshot = try await buildSnapshot(
                from: context,
                state: state,
                idle: false,
                now: now,
                sessionID: session?.id,
                evaluationID: evaluationID,
                requiresScreenshot: evaluationPlan.requiresScreenshot
            )
        } catch {
            statusSink?("Snapshot capture failed. Trying again later.")
            stateSink?(state)
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
            cleanupEphemeralScreenshotIfNeeded(snapshot, sessionID: session?.id)
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

        let evaluationTask = Task { [monitoringAlgorithmRegistry] in
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
                policyMemory: state.policyMemory,
                runtimeOverride: state.runtimePathOverride,
                configuration: state.monitoringConfiguration,
                algorithmState: state.algorithmState,
                characterPersonalityPrefix: state.character.personalityPrefix,
                calendarContext: calendarContext
                )
            )
        }
        activeEvaluationTask = evaluationTask
        defer {
            activeEvaluationTask = nil
        }

        let decisionResult: MonitoringDecisionResult
        do {
            decisionResult = try await evaluationTask.value
        } catch is CancellationError {
            moodSink?(.watching)
            statusSink?("Context changed during evaluation — cancelled.")
            stateSink?(state)
            return
        } catch {
            handleMonitoringConfigurationError(error)
            return
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
            state.policyMemory.apply(policyMemoryUpdate, now: now)
        }

        await appendPolicyDecisionEvent(
            sessionID: session?.id,
            episode: evaluationEpisode,
            policy: decisionResult.policy.record
        )

        guard lastObservedContext?.contextKey == context.contextKey else {
            moodSink?(.watching)
            statusSink?("Context changed during evaluation — action discarded.")
            stateSink?(state)
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
            maybePersist(state: state, at: now, force: true)
            return
        }

        switch decisionResult.policy.action {
        case let .showNudge(message):
            state.recentActions.insert(ActionRecord(kind: .nudge, message: message, timestamp: now), at: 0)
            state.recentActions = Array(state.recentActions.prefix(12))
            stateSink?(state)
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
            state.recentActions.insert(ActionRecord(kind: .overlay, message: nil, timestamp: now), at: 0)
            state.recentActions = Array(state.recentActions.prefix(12))
            stateSink?(state)
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
            stateSink?(state)
        }

        await appendActionExecutedEvent(
            sessionID: session?.id,
            episode: evaluationEpisode,
            evaluationID: evaluationID,
            action: decisionResult.policy.action,
            execution: decisionResult.execution
        )

        maybePersist(state: state, at: now, force: true)
    }

    private func buildSnapshot(
        from context: FrontmostContext,
        state: ACState,
        idle: Bool,
        now: Date,
        sessionID: String?,
        evaluationID: String,
        requiresScreenshot: Bool
    ) async throws -> AppSnapshot {
        let persistVerboseTelemetry = shouldPersistVerboseTelemetry(state: state)
        let screenshotURL: URL?
        if requiresScreenshot {
            screenshotURL = try await SnapshotService.captureScreenshot()
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
    }

    private func maybePersist(state: ACState, at now: Date, force: Bool = false) {
        guard force || now.timeIntervalSince(lastPersistAt) >= 30 else {
            return
        }

        storageService.saveState(state)
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
        execution: MonitoringExecutionMetadata
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
                    strategy: execution.telemetryRecord
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
                            stderrPreview: output.stderr.cleanedSingleLine.prefix(220).description
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

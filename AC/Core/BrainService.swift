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
    /// Called when repeated API failures suggest a provider-side issue. Pass nil to clear.
    var connectionProblemSink: ((String?) -> Void)?
    /// Called when a hard-escalated app is auto-minimized so the UI can re-show the overlay.
    var hardEscalationReopenSink: ((String) -> Void)?
    /// Called on every tick that reaches evaluation (or skip) so the UI can show "last check" ago.
    var lastCheckSink: ((Date) -> Void)?
    /// Lets AppController tear down long-lived runtime resources when monitoring enters standby.
    var runtimeStandbySink: (() async -> Void)?

    /// Override for testing: substitute a real `SnapshotService.frontmostContext()` call.
    var contextProvider: (() -> FrontmostContext?)?
    /// Override for testing: substitute a real `SnapshotService.captureScreenshot()` call.
    var screenshotCapture: (() async throws -> URL?)?
    /// Override for testing: substitute a real `SnapshotService.idleSeconds()` call.
    var idleSecondsProvider: (() -> TimeInterval)?

    let monitoringAlgorithmRegistry: MonitoringAlgorithmRegistry
    private let executiveArm: ExecutiveArm
    private let storageService: StorageService
    let telemetryStore: TelemetryStore
    private let pollingInterval: TimeInterval = 10
    private let contextChangeProbeInterval: TimeInterval = 5

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
    var recentSwitches: [AppSwitchRecord] = []
    private var lastPersistAt = Date.distantPast
    var activeEpisode: EpisodeRecord?
    var pendingReactionsByEvaluationID: [String: PendingReaction] = [:]
    private var wasInCallLastTick = false
    private var consecutiveAPIFailures = 0

    struct PendingReaction: Sendable {
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

    /// Outcome of `applySoftProfileLifecycle`. Reported back to the caller so it can
    /// drive side effects (chat sink, telemetry, activity log) without the lifecycle
    /// helper itself needing access to those services.
    enum SoftProfileLifecycleOutcome: Equatable {
        case idle
        case preWarned(profileName: String, minutesLeft: Int)
        case autoExtended(profileName: String, until: Date)
        case ended(profileName: String)
    }

    /// Soft profile lifecycle: clears stale `recentlyEndedSession`, posts a single
    /// pre-expiry warning ~5 min before expiry, and at expiry either auto-extends
    /// the session by 30m (when last assessment was focused AND the visible title
    /// still relates to the goal AND we haven't already auto-extended this run) or
    /// ends the profile and stamps `recentlyEndedSession` for ~30 min so the
    /// monitoring payload retains the goal anchor across the transition.
    /// Pure mutation — no I/O, no main-actor dependencies. Returns an outcome the
    /// caller drives side effects on.
    static func applySoftProfileLifecycle(
        state: inout ACState,
        lastObservedContext: FrontmostContext?,
        now: Date
    ) -> SoftProfileLifecycleOutcome {
        if let staleSession = state.recentlyEndedSession, staleSession.isStale(at: now) {
            state.recentlyEndedSession = nil
        }

        let activeProfile = state.activeProfile
        guard !activeProfile.isDefault else { return .idle }

        if let secondsLeft = activeProfile.secondsUntilExpiry(at: now),
           secondsLeft > 0,
           secondsLeft <= 5 * 60,
           activeProfile.prewarnSentAt == nil {
            if let i = state.profiles.firstIndex(where: { $0.id == activeProfile.id }) {
                state.profiles[i].prewarnSentAt = now
            }
            let minutesLeft = max(1, Int((secondsLeft / 60).rounded(.up)))
            let warning = "Heads up — your \(activeProfile.name) session ends in \(minutesLeft) min. Want to extend?"
            state.chatHistory.append(ChatMessage(
                role: .assistant,
                text: warning,
                timestamp: now,
                interruptionPolicy: .deferred
            ))
            return .preWarned(profileName: activeProfile.name, minutesLeft: minutesLeft)
        }

        guard activeProfile.isExpired(at: now) else { return .idle }

        // Heuristic recheck — auto-extend once when the user clearly looks on-task.
        let allowAutoExtend = activeProfile.autoExtendedAt == nil
        let lastAssessment = state.algorithmState.llmPolicy.distraction.lastAssessment
        let focusGoalForExpiry: String? = {
            if let description = activeProfile.description, !description.isEmpty {
                return description
            }
            return activeProfile.name
        }()
        let titleStillRelevant = MonitoringHeuristics.titleRelatesToFocus(
            lastObservedContext?.windowTitle,
            focusGoal: focusGoalForExpiry
        ) == true
        let stillOnTask = allowAutoExtend
            && lastAssessment == .focused
            && titleStillRelevant

        if stillOnTask {
            let extendedExpiry = now.addingTimeInterval(30 * 60)
            if let i = state.profiles.firstIndex(where: { $0.id == activeProfile.id }) {
                state.profiles[i].expiresAt = extendedExpiry
                state.profiles[i].autoExtendedAt = now
                state.profiles[i].prewarnSentAt = nil
            }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "HH:mm"
            let untilText = formatter.string(from: extendedExpiry)
            state.chatHistory.append(ChatMessage(
                role: .assistant,
                text: "Still in the zone — extending \(activeProfile.name) to \(untilText). Wrap up when you're ready.",
                timestamp: now,
                interruptionPolicy: .deferred
            ))
            return .autoExtended(profileName: activeProfile.name, until: extendedExpiry)
        }

        if let i = state.profiles.firstIndex(where: { $0.id == activeProfile.id }) {
            state.profiles[i].activatedAt = nil
            state.profiles[i].expiresAt = nil
            state.profiles[i].autoExtendedAt = nil
            state.profiles[i].prewarnSentAt = nil
        }
        state.activeProfileID = PolicyRule.defaultProfileID
        state.recentlyEndedSession = RecentlyEndedSession(
            name: activeProfile.name,
            description: activeProfile.description,
            endedAt: now,
            goalSummary: activeProfile.createdReason
        )
        state.sessionCelebrationPending = true
        let modeChange = "You did it — \(activeProfile.name) wrapped. Really proud of you. Take a well-earned break."
        state.chatHistory.append(ChatMessage(
            role: .assistant,
            text: modeChange,
            timestamp: now,
            interruptionPolicy: .deferred
        ))
        return .ended(profileName: activeProfile.name)
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

    nonisolated static func shouldUsePeriodicFullScreenCapture(
        lastFullScreenCheckAt: Date?,
        interval: TimeInterval,
        now: Date
    ) -> Bool {
        guard let lastFullScreenCheckAt else {
            return false
        }
        return now.timeIntervalSince(lastFullScreenCheckAt) >= interval
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

    private func refreshPermissionsAfterScreenCaptureFailure(
        _ error: Error,
        state: inout ACState,
        baseState: ACState,
        category: String
    ) -> Bool {
        guard SnapshotService.indicatesScreenCapturePermissionLoss(error) else {
            return false
        }

        state.permissions = PermissionService.currentSnapshot()
        statusSink?("Screen Recording access appears unavailable. Re-enable it in System Settings to restore screenshots.")
        stateSink?(baseState, state)

        Task {
            await ActivityLogService.shared.append(
                category: category,
                message: "Detected Screen Recording permission loss while capturing a screenshot."
            )
        }
        return true
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
        transitionToStandby(
            cancellationReason: "system_sleep",
            heartbeatReason: "system_will_sleep",
            logMessage: "System will sleep. Monitoring is standing by."
        )
    }

    @objc private func handleDidWake() {
        isSessionAvailable = true
        appendLifecycleHeartbeat(reason: "system_did_wake")
        Task {
            await ActivityLogService.shared.append(category: "app", message: "System woke up. Monitoring resumed.")
        }
        scheduleTickIfNeeded()
    }

    @objc private func handleSessionInactive() {
        transitionToStandby(
            cancellationReason: "session_inactive",
            heartbeatReason: "session_inactive",
            logMessage: "User session became inactive. Monitoring is standing by."
        )
    }

    @objc private func handleSessionActive() {
        isSessionAvailable = true
        appendLifecycleHeartbeat(reason: "session_active")
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

    private func transitionToStandby(
        cancellationReason: String,
        heartbeatReason: String,
        logMessage: String
    ) {
        cancelActiveEvaluationIfNeeded(reason: cancellationReason)
        isSessionAvailable = false
        consecutiveAPIFailures = 0
        wasInCallLastTick = false
        connectionProblemSink?(nil)
        appendLifecycleHeartbeat(reason: heartbeatReason)

        Task {
            await ActivityLogService.shared.append(category: "app", message: logMessage)
        }

        if let runtimeStandbySink {
            Task {
                await runtimeStandbySink()
            }
        }

        let observedContext = lastObservedContext
        let idleSeconds = SnapshotService.idleSeconds()
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let state = self.stateProvider?() {
                await self.endActiveEpisode(
                    reason: .sessionInactive,
                    context: observedContext,
                    state: state,
                    idleSeconds: idleSeconds,
                    at: Date()
                )
            }
            self.resetMonitoringBaselineForStandby()
            self.moodSink?(.idle)
        }
    }

    private func resetMonitoringBaselineForStandby() {
        resetDistractionState()
        pendingReactionsByEvaluationID = [:]
        activeEpisode = nil
        lastObservedContext = nil
        lastObservedAt = Date()
        recentSwitches = []
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

        // Soft profile lifecycle (clock-driven, no separate scheduler). The pure-state
        // logic lives in `applySoftProfileLifecycle` so it can be unit-tested in isolation;
        // here we drive the side effects (chat sink, activity log, telemetry).
        let lifecycleOutcome = Self.applySoftProfileLifecycle(
            state: &state,
            lastObservedContext: lastObservedContext,
            now: now
        )
        switch lifecycleOutcome {
        case .idle:
            break
        case .preWarned(let profileName, let minutes):
            stateSink?(baseState, state)
            await ActivityLogService.shared.append(
                category: "profile",
                message: "Pre-expiry warning posted: \(profileName) ends in \(minutes) min"
            )
        case .autoExtended(let profileName, _):
            stateSink?(baseState, state)
            await appendMonitoringMetric(
                kind: .profileChanged,
                reason: "auto_extended_at_expiry",
                state: state,
                detail: profileName
            )
            await ActivityLogService.shared.append(
                category: "profile",
                message: "Auto-extended \(profileName) by 30m at expiry"
            )
        case .ended(let profileName):
            stateSink?(baseState, state)
            await appendMonitoringMetric(
                kind: .profileChanged,
                reason: "profile_expired",
                state: state,
                detail: profileName
            )
            await ActivityLogService.shared.append(
                category: "profile",
                message: "Ended \(profileName) at expiry — back to Everyday"
            )
        }

        // Recurring profile activation (clock-driven). If a profile has a recurring schedule
        // that matches the current time and is not already active, activate it.
        // Uses a 2-minute grace window (see RecurringSchedule.matches) so startup
        // at 9:03 still catches a 9:00 schedule. Same-day dedup via lastScheduleFireDate.
        let calendar = Calendar.current
        if let scheduledProfile = state.profiles.first(where: { profile in
            !profile.isDefault
                && profile.recurringSchedule?.matches(now: now, calendar: calendar) == true
                && profile.id != state.activeProfileID
                && (profile.lastScheduleFireDate.map { !calendar.isDate($0, inSameDayAs: now) } ?? true)
        }) {
            if let i = state.profiles.firstIndex(where: { $0.id == scheduledProfile.id }) {
                state.profiles[i].activatedAt = now
                state.profiles[i].lastUsedAt = now
                state.profiles[i].lastScheduleFireDate = now
                state.profiles[i].expiresAt = now.addingTimeInterval(
                    TimeInterval(scheduledProfile.defaultDurationMin ?? 90) * 60
                )
            }
            state.activeProfileID = scheduledProfile.id
            state.chatHistory.append(ChatMessage(
                role: .assistant,
                text: "\(scheduledProfile.name) activated (\(scheduledProfile.recurringSchedule?.scheduleDescription() ?? "scheduled")).",
                timestamp: now,
                interruptionPolicy: .deferred
            ))
            stateSink?(baseState, state)
            await appendMonitoringMetric(
                kind: .profileChanged,
                reason: "recurring_schedule",
                state: state,
                detail: scheduledProfile.id
            )
        }

        // Recurring nudges (clock-driven). Fire each due nudge once per day.
        for nudgeIndex in state.recurringNudges.indices {
            let nudge = state.recurringNudges[nudgeIndex]
            guard nudge.enabled,
                  nudge.matches(now: now, calendar: calendar) else { continue }
            if let lastFired = nudge.lastFiredAt,
               calendar.isDate(lastFired, inSameDayAs: now) {
                continue
            }
            state.recurringNudges[nudgeIndex].lastFiredAt = now
            let message = nudge.message
            executiveArm.perform(.showNudge(message))
        }

        // Persist any nudge lastFiredAt updates before continuing.
        if state.recurringNudges != baseState.recurringNudges {
            stateSink?(baseState, state)
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
            lastCheckSink?(now)
            return
        }

        guard let context = contextProvider?() ?? SnapshotService.frontmostContext() else {
            moodSink?(.idle)
            statusSink?("Could not read the active app yet.")
            return
        }

        // Hard escalation: if the user re-opened an app that was force-minimized,
        // minimize it again immediately before doing any evaluation.
        if let escalation = state.hardEscalation,
           context.bundleIdentifier == escalation.bundleIdentifier || context.appName == escalation.appName {
            executiveArm.hideApp(bundleIdentifier: context.bundleIdentifier)
            state.hardEscalation?.timesMinimized += 1
            state.hardEscalation?.lastMinimizedAt = now
            state.recentActions.insert(ActionRecord(
                kind: .autoMinimizeApp,
                message: "Auto-minimized \(context.appName)",
                timestamp: now,
                contextKey: context.contextKey,
                appName: context.appName
            ), at: 0)
            state.recentActions = Array(state.recentActions.prefix(12))
            stateSink?(baseState, state)
            moodSink?(.escalatedHard)
            statusSink?("\(context.appName) was minimized. Explain why it serves your goals.")
            hardEscalationReopenSink?(context.appName)
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

        // Auto-quiet on calls: skip evaluations and hide UI while in a call.
        let inCall = state.autoQuietOnCalls && CallDetectionService.isInCall()
        if inCall {
            if !wasInCallLastTick {
                executiveArm.dismissOverlay()
                if state.displayMode.showsOrb {
                    executiveArm.hideCompanionPanel()
                }
            }
            moodSink?(.watching)
            statusSink?("In a call — AC is quiet.")
            wasInCallLastTick = true
            return
        } else if wasInCallLastTick {
            if state.displayMode.showsOrb {
                executiveArm.showCompanionPanel()
            }
            wasInCallLastTick = false
        }

        // Compute the focus-goal text for the title-relevance heuristic.
        // Active session description wins; otherwise fall back to a recently
        // ended session's goalSummary (kept for ~30 min after expiry) so the
        // model still sees the anchor right after a profile transition.
        let focusGoalForHeuristic: String? = {
            let active = state.activeProfile
            if !active.isDefault {
                if let description = active.description, !description.isEmpty {
                    return description
                }
                return active.name
            }
            if let recentlyEnded = state.recentlyEndedSession, !recentlyEnded.isStale(at: now) {
                return recentlyEnded.goalSummary ?? recentlyEnded.description ?? recentlyEnded.name
            }
            return nil
        }()
        let heuristics = MonitoringHeuristics.telemetrySnapshot(
            for: context,
            focusGoal: focusGoalForHeuristic
        )

        guard !isEvaluating else {
            moodSink?(.watching)
            statusSink?("Watching \(context.appName) quietly.")
            stateSink?(baseState, state)
            return
        }

        // Scoped policy memory: global rules (profileID == nil) always apply, plus rules
        // scoped to the active profile. Rules scoped to other profiles are hidden.
        let activeProfileID = state.activeProfileID
        var scopedPolicyMemory = state.policyMemory
        scopedPolicyMemory.rules = scopedPolicyMemory.rules.filter {
            $0.profileID == nil || $0.profileID == activeProfileID
        }
        // Inject active profile blocklist as temporary disallow rules for this tick.
        if let activeProfile = state.profile(withID: activeProfileID),
           !activeProfile.blocklist.isEmpty {
            for entry in activeProfile.blocklist {
                let trimmed = entry.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                scopedPolicyMemory.rules.append(PolicyRule(
                    kind: .disallow,
                    summary: "Block \(trimmed)",
                    source: .system,
                    scope: PolicyRuleScope(appName: trimmed, titleContains: [trimmed]),
                    profileID: activeProfileID
                ))
            }
        }

        let evaluationPlan: MonitoringEvaluationPlan
        do {
            evaluationPlan = try monitoringAlgorithmRegistry.evaluationPlan(
                configuration: state.monitoringConfiguration,
                context: context,
                heuristics: heuristics,
                policyMemory: scopedPolicyMemory,
                activeProfileID: state.activeProfileID,
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
            await ActivityLogService.shared.append(
                level: .verbose,
                category: "monitoring",
                message: "skip: \(evaluationPlan.reason ?? "not_due") · \(context.appName)"
            )
            moodSink?(.watching)
            statusSink?("Watching \(context.appName) quietly.")
            stateSink?(baseState, state)
            lastCheckSink?(now)
            return
        }

        isEvaluating = true
        evaluationStartedAt = Date()
        defer {
            isEvaluating = false
            evaluationStartedAt = nil
            lastCheckSink?(now)
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
            promptProfileID: algorithmDescriptor.id,
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
            let lostScreenRecordingPermission = refreshPermissionsAfterScreenCaptureFailure(
                error,
                state: &state,
                baseState: baseState,
                category: "snapshot-permission"
            )
            if !lostScreenRecordingPermission {
                statusSink?("Snapshot capture failed. Trying again later.")
            }
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
        // Carry a recently-ended session into the payload (~30 min retention).
        // The model sees what the user just finished even after the profile drops
        // back to Everyday; without this, the goal anchor evaporates at expiry.
        let recentlyEndedForPayload: RecentlyEndedSessionSummary? = {
            guard let recentlyEnded = state.recentlyEndedSession,
                  !recentlyEnded.isStale(at: now) else { return nil }
            return recentlyEnded.promptSummary
        }()
        let evaluationTask = Task { [monitoringAlgorithmRegistry, scopedPolicyMemory, currentProfile, recentlyEndedForPayload] in
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
                character: state.character,
                calendarContext: calendarContext,
                activeProfileID: currentProfile.id,
                activeProfileName: currentProfile.name,
                activeProfileDescription: currentProfile.description,
                activeProfileExpiresAt: currentProfile.expiresAt,
                recentlyEndedSession: recentlyEndedForPayload
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

        let pipelineSupportsScreenshot = LLMPolicyCatalog
            .pipelineProfile(id: state.monitoringConfiguration.pipelineProfileID)
            .descriptor
            .requiresScreenshot

        // Online text-path outages are often model/provider-specific. If this
        // tick can support vision, try the configured image model once before
        // backing off globally.
        if decisionResult.evaluation.failureMessage == "all_attempts_failed",
           state.monitoringConfiguration.usesOnlineInference,
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
                        character: state.character,
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
                        message: "Text-path API failed; retried with screenshot. New verdict: \(retried.decision.assessment.rawValue)"
                    )
                    await appendMonitoringMetric(
                        kind: .visionRetried,
                        reason: "api_failure:\(retried.decision.assessment.rawValue)",
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
                _ = refreshPermissionsAfterScreenCaptureFailure(
                    error,
                    state: &state,
                    baseState: baseState,
                    category: "vision-retry-permission"
                )
                await ActivityLogService.shared.append(
                    category: "vision-retry-error",
                    message: error.localizedDescription
                )
            }
        }

        // If every attempt failed at the infrastructure level, apply exponential backoff and
        // surface a gentle banner once the streak becomes persistent.
        if decisionResult.evaluation.failureMessage == "all_attempts_failed" {
            consecutiveAPIFailures += 1
            let backoff = min(10 * pow(2.0, Double(consecutiveAPIFailures - 1)), 300)
            state.algorithmState.llmPolicy.distraction.nextEvaluationAt = now.addingTimeInterval(backoff)
            moodSink?(.watching)
            if consecutiveAPIFailures >= 3 {
                let banner = "AC is having trouble reaching the model provider. Retrying with backup models…"
                statusSink?(banner)
                connectionProblemSink?(banner)
            } else {
                statusSink?("AC check-in hiccup — retrying…")
            }
            stateSink?(baseState, state)
            await appendMonitoringMetric(
                kind: .evaluationSkipped,
                reason: "api_failure",
                state: state,
                detail: context.appName
            )
            return
        }
        consecutiveAPIFailures = 0
        connectionProblemSink?(nil)

        // One-shot vision escalation: if text-only returned `unclear` and the pipeline supports
        // a screenshot, capture one and retry. Bound to a single retry per tick.
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
                character: state.character,
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
                _ = refreshPermissionsAfterScreenCaptureFailure(
                    error,
                    state: &state,
                    baseState: baseState,
                    category: "vision-retry-permission"
                )
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
            // Rules carry their own profile scoping (nil = global, value = profile-scoped).
            // Don't stamp them here — the LLM or safelist builder decides the scope.
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
            if presentation.isHardEscalation {
                state.hardEscalation = ActiveEscalation(
                    appName: context.appName,
                    bundleIdentifier: context.bundleIdentifier,
                    evaluationID: evaluationID,
                    startedAt: now
                )
            }
            stateSink?(baseState, state)
            moodSink?(presentation.isHardEscalation ? .escalatedHard : .escalated)
            statusSink?(presentation.isHardEscalation
                ? "Hard escalation — asking why \(context.appName) serves your goals."
                : "Escalated after repeated distraction signals.")
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

        await ActivityLogService.shared.append(
            level: .verbose,
            category: "monitoring",
            message: "eval: \(decisionResult.decision.assessment.rawValue) · \(context.appName) · action: \(decisionResult.policy.action.telemetryLabel)"
        )

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
                    if Self.shouldUsePeriodicFullScreenCapture(
                        lastFullScreenCheckAt: state.lastFullScreenCheckAt,
                        interval: state.monitoringConfiguration.periodicFullScreenInterval,
                        now: now
                    ) {
                        screenshotURL = try await SnapshotService.captureScreenshotIfPermitted()
                        state.lastFullScreenCheckAt = now
                    } else {
                        screenshotURL = try await SnapshotService.captureActiveWindowScreenshot()
                        if state.lastFullScreenCheckAt == nil {
                            state.lastFullScreenCheckAt = now
                        }
                    }
                case .fullScreen:
                    screenshotURL = try await SnapshotService.captureScreenshotIfPermitted()
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

        state.pruneUsageHistory(now: now)
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
        appendLifecycleHeartbeat(
            reason: "watchdog_stale_evaluation",
            details: ["ageSeconds": String(Int(Date().timeIntervalSince(startedAt)))]
        )
        cancelActiveEvaluationIfNeeded(reason: "watchdog_stale_evaluation")
    }

    private func cancelActiveEvaluationIfNeeded(reason: String) {
        guard let activeEvaluationTask else { return }
        guard !activeEvaluationTask.isCancelled else { return }

        activeEvaluationTask.cancel()
        appendLifecycleHeartbeat(reason: "evaluation_cancelled", details: ["reason": reason])
        Task {
            await ActivityLogService.shared.append(
                category: "monitoring-cancel",
                message: reason
            )
        }
    }

    private func appendLifecycleHeartbeat(reason: String, details: [String: String] = [:]) {
        guard shouldPersistVerboseTelemetry() else { return }
        Task { [telemetryStore] in
            await telemetryStore.appendSessionHeartbeat(reason: reason, details: details)
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

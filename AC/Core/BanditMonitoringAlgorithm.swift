//
//  BanditMonitoringAlgorithm.swift
//  AC
//

import Foundation

// MARK: - BanditMonitoringAlgorithm

/// Two-brain monitoring algorithm — independent of `LLMFocusAlgorithm`.
///
/// **Brain 1** (VLM): `ScreenStateExtractorService` takes a screenshot and returns a
/// `BanditScreenState` — a structured observation including `productivityScore`, `onTask`,
/// `appCategory`, and an optional `candidateNudge`.
///
/// **Brain 2** (multi-arm LinUCB): `ContextualBanditEngine` picks the best arm from
/// `.none`, `.supportiveNudge`, `.challengingNudge`, or `.overlay` given a 16-dimensional
/// feature vector.
///
/// When the bandit picks a nudge arm, `NudgeCopywriterService` (a text-only LLM call)
/// crafts the actual nudge text in the arm's tone. The VLM's `candidateNudge` is used
/// only as a safety net if the copywriter fails.
///
/// Anti-spam is handled by `BanditCooldown` — intentionally minimal, so the bandit has
/// enough signal to learn. Heavy filtering belongs in the LLM algorithm.
///
/// This algorithm never delegates to `MonitoringLLMClient`. If Brain 1 extraction fails,
/// the tick yields no action and the bandit waits for the next stable window.
///
/// Algorithm ID: `"bandit_focus_v1"`.
final class BanditMonitoringAlgorithm: MonitoringAlgorithm {
    let descriptor = MonitoringAlgorithmDescriptor(
        id: MonitoringConfiguration.banditAlgorithmID,
        version: "2.0",
        displayName: "Bandit Focus",
        summary: "Multi-arm LinUCB over VLM screen-state, with LLM-authored nudge copy."
    )

    private let screenStateExtractor: any ScreenStateExtracting
    private let nudgeCopywriter: any NudgeCopywriting
    private let cooldown: BanditCooldown

    init(
        screenStateExtractor: any ScreenStateExtracting,
        nudgeCopywriter: any NudgeCopywriting,
        cooldown: BanditCooldown = BanditCooldown()
    ) {
        self.screenStateExtractor = screenStateExtractor
        self.nudgeCopywriter = nudgeCopywriter
        self.cooldown = cooldown
    }

    // MARK: - State lifecycle

    func resetState(_ state: inout AlgorithmStateEnvelope) {
        state.banditFocus = BanditFocusAlgorithmState()
    }

    func resetTransientState(_ state: inout AlgorithmStateEnvelope) {
        state.banditFocus.lastInterventionByContext = [:]
        state.banditFocus.pendingInterventionsByEvaluationID = [:]
    }

    /// Returns true if the frontmost context changed — caller uses this to record a
    /// switch event. The bandit tracks context transitions through the feature vector
    /// (time-in-app), so there's no ladder state to reset.
    func noteContext(
        _ contextKey: String?,
        at now: Date,
        state: inout AlgorithmStateEnvelope
    ) -> Bool {
        let current = state.banditFocus.currentContextKey
        guard current != contextKey else { return false }
        state.banditFocus.currentContextKey = contextKey
        state.banditFocus.currentContextEnteredAt = contextKey == nil ? nil : now
        return true
    }

    func distractionMetadata(from state: AlgorithmStateEnvelope) -> DistractionMetadata {
        // The bandit does not maintain DistractionLadder state. Telemetry gets an empty
        // record — downstream consumers can detect "bandit mode" by the algorithmID.
        DistractionMetadata()
    }

    // MARK: - Evaluation plan

    func evaluationPlan(
        state: inout AlgorithmStateEnvelope,
        context: FrontmostContext,
        heuristics: TelemetryHeuristicSnapshot,
        configuration: MonitoringConfiguration,
        now: Date
    ) -> MonitoringEvaluationPlan {
        let contextKey = context.contextKey
        let enteredAt = state.banditFocus.currentContextEnteredAt
        let lastInterventionAt = state.banditFocus.lastInterventionByContext[contextKey]

        let mayEvaluate = cooldown.shouldEvaluate(
            contextKey: contextKey,
            enteredContextAt: enteredAt,
            lastInterventionInContextAt: lastInterventionAt,
            now: now
        )
        guard mayEvaluate else { return .none }

        return MonitoringEvaluationPlan(
            shouldEvaluate: true,
            reason: "bandit_stable_context",
            visualCheckReason: heuristics.periodicVisualReason,
            requiresScreenshot: true,
            promptMode: "extraction",
            promptVersion: "screen_state_v1"
        )
    }

    // MARK: - Evaluate

    func evaluate(input: MonitoringDecisionInput) async -> MonitoringDecisionResult {
        let runtimePath = RuntimeSetupService.normalizedRuntimePath(from: input.runtimeOverride)
        let contextKey = input.snapshot.bundleIdentifier.map { $0 + "|" + (input.snapshot.windowTitle?.normalizedForContextKey ?? "") } ?? input.snapshot.appName

        // Brain 1: extract structured screen state.
        let recentNudgeMessages = input.recentActions
            .compactMap { $0.kind == .nudge ? $0.message : nil }
            .prefix(3)
            .map { $0 }

        let screenState = await screenStateExtractor.extract(
            snapshot: input.snapshot,
            goals: input.goals,
            recentNudgeMessages: recentNudgeMessages,
            runtimePath: runtimePath
        )

        guard let screenState else {
            return makeNoActionResult(
                input: input,
                reason: "extraction_failed",
                updatedState: input.algorithmState
            )
        }

        // Feature vector.
        let timeInAppSeconds = input.snapshot.perAppDurations
            .first(where: { $0.appName == input.snapshot.appName })?.seconds ?? 0
        let timeSinceLastNudge = input.algorithmState.banditFocus.lastNudgeAt
            .map { input.now.timeIntervalSince($0) }
        let context = BanditFeatureVector.build(
            screenState: screenState,
            now: input.now,
            timeInAppSeconds: timeInAppSeconds,
            timeSinceLastNudgeSeconds: timeSinceLastNudge,
            lastNudgeWasPositive: input.algorithmState.banditFocus.lastNudgeWasPositive
        )

        // Brain 2: pick an arm.
        let engine = input.algorithmState.banditFocus.engine
        let selection = engine.selectArm(context: context)

        var updatedState = input.algorithmState

        // Cooldown gate — even if the bandit picks an intervention arm, skip it while
        // the per-context cooldown is active.
        let lastInterventionAt = updatedState.banditFocus.lastInterventionByContext[contextKey]
        let mayIntervene = cooldown.mayIntervene(
            contextKey: contextKey,
            lastInterventionInContextAt: lastInterventionAt,
            now: input.now
        )
        let effectiveArm: BanditArm = mayIntervene ? selection.arm : .none
        let blockReason: String? = {
            if !mayIntervene && selection.arm != .none { return "bandit_cooldown" }
            return nil
        }()

        // Translate arm → CompanionAction (potentially using the copywriter).
        let action: CompanionAction
        switch effectiveArm {
        case .none:
            action = .none

        case .supportiveNudge, .challengingNudge:
            let crafted = await nudgeCopywriter.craftNudge(
                arm: effectiveArm,
                request: NudgeCopywriteRequest(
                    goals: input.goals,
                    memory: input.memory,
                    appName: input.snapshot.appName,
                    windowTitle: input.snapshot.windowTitle,
                    contentSummary: screenState.contentSummary,
                    recentNudgeMessages: recentNudgeMessages,
                    candidateNudge: screenState.candidateNudge,
                    timestamp: input.now
                ),
                runtimePath: runtimePath
            )
            let text = crafted?.cleanedSingleLine
                ?? screenState.candidateNudge?.cleanedSingleLine
                ?? ""
            if text.isEmpty {
                action = .none
            } else {
                action = .showNudge(text)
            }

        case .overlay:
            action = .showOverlay(
                OverlayPresentation(
                    headline: "Pause for a second.",
                    body: "You still look off-track in \(input.snapshot.appName).",
                    prompt: "Why should I let you keep going here?",
                    appName: input.snapshot.appName,
                    evaluationID: input.evaluationID,
                    submitButtonTitle: "Submit",
                    secondaryButtonTitle: "Back to work"
                )
            )
        }

        // Build the synthetic decision that appears in telemetry (no LLM decision was made).
        let assessment: ModelAssessment = screenState.onTask ? .focused : .distracted
        let syntheticDecision = LLMDecision(
            assessment: assessment,
            suggestedAction: suggestedAction(for: action),
            confidence: screenState.confidence,
            reasonTags: [
                screenState.appCategory.rawValue,
                "arm:\(effectiveArm.rawValue)",
            ],
            nudge: {
                if case let .showNudge(text) = action { return text }
                return nil
            }(),
            abstainReason: nil
        )

        let execution = MonitoringExecutionMetadata(
            algorithmID: descriptor.id,
            algorithmVersion: descriptor.version,
            promptProfileID: "screen_state_v1",
            pipelineProfileID: nil,
            runtimeProfileID: nil,
            experimentArm: input.configuration.experimentArm
        )

        // If we're firing an intervention, record the cooldown timestamp and pending arm.
        if action != .none {
            updatedState.banditFocus.pendingInterventionsByEvaluationID[input.evaluationID] = BanditPendingIntervention(
                context: context,
                issuedAt: input.now,
                arm: effectiveArm
            )
            updatedState.banditFocus.lastNudgeAt = input.now
            updatedState.banditFocus.lastInterventionByContext[contextKey] = input.now
        }

        let evaluation = LLMEvaluationResult(
            runtimePath: runtimePath,
            modelIdentifier: LocalModelRuntime.defaultModelIdentifier,
            promptProfileID: "screen_state_v1",
            promptProfileVersion: "screen_state_v1",
            attempts: [],
            finalDecision: syntheticDecision,
            failureMessage: nil
        )

        let policyRecord = PolicyDecisionRecord(
            evaluationID: input.evaluationID,
            model: syntheticDecision.parsedRecord,
            strategy: execution.telemetryRecord,
            ladderSignal: "none",
            interventionSignal: "bandit:\(effectiveArm.rawValue)",
            allowIntervention: action != .none,
            allowEscalation: {
                if case .showOverlay = action { return true }
                return false
            }(),
            blockReason: blockReason,
            finalAction: CompanionPolicy.telemetryActionRecord(for: action),
            distractionBefore: CompanionPolicy.telemetryState(from: DistractionMetadata()),
            distractionAfter: CompanionPolicy.telemetryState(from: DistractionMetadata())
        )

        return MonitoringDecisionResult(
            execution: execution,
            evaluation: evaluation,
            decision: syntheticDecision,
            policy: CompanionPolicyResult(action: action, record: policyRecord),
            updatedAlgorithmState: updatedState
        )
    }

    // MARK: - Reward

    func observeReward(_ signal: MonitoringRewardSignal, state: inout AlgorithmStateEnvelope) {
        guard let pending = state.banditFocus.pendingInterventionsByEvaluationID[signal.evaluationID] else { return }

        state.banditFocus.engine.update(arm: pending.arm, context: pending.context, reward: signal.value)
        state.banditFocus.lastNudgeWasPositive = signal.value > 0

        state.banditFocus.pendingInterventionsByEvaluationID.removeValue(forKey: signal.evaluationID)
    }

    // MARK: - Helpers

    private func suggestedAction(for action: CompanionAction) -> ModelSuggestedAction {
        switch action {
        case .none:         return .none
        case .showNudge:    return .nudge
        case .showOverlay:  return .overlay
        }
    }

    private func makeNoActionResult(
        input: MonitoringDecisionInput,
        reason: String,
        updatedState: AlgorithmStateEnvelope
    ) -> MonitoringDecisionResult {
        let runtimePath = RuntimeSetupService.normalizedRuntimePath(from: input.runtimeOverride)
        let decision = LLMDecision.unclear
        let execution = MonitoringExecutionMetadata(
            algorithmID: descriptor.id,
            algorithmVersion: descriptor.version,
            promptProfileID: "screen_state_v1",
            pipelineProfileID: nil,
            runtimeProfileID: nil,
            experimentArm: input.configuration.experimentArm
        )
        let evaluation = LLMEvaluationResult(
            runtimePath: runtimePath,
            modelIdentifier: LocalModelRuntime.defaultModelIdentifier,
            promptProfileID: "screen_state_v1",
            promptProfileVersion: "screen_state_v1",
            attempts: [],
            finalDecision: decision,
            failureMessage: reason
        )
        let policyRecord = PolicyDecisionRecord(
            evaluationID: input.evaluationID,
            model: decision.parsedRecord,
            strategy: execution.telemetryRecord,
            ladderSignal: "none",
            interventionSignal: "bandit:none",
            allowIntervention: false,
            allowEscalation: false,
            blockReason: reason,
            finalAction: CompanionPolicy.telemetryActionRecord(for: .none),
            distractionBefore: CompanionPolicy.telemetryState(from: DistractionMetadata()),
            distractionAfter: CompanionPolicy.telemetryState(from: DistractionMetadata())
        )
        return MonitoringDecisionResult(
            execution: execution,
            evaluation: evaluation,
            decision: decision,
            policy: CompanionPolicyResult(action: .none, record: policyRecord),
            updatedAlgorithmState: updatedState
        )
    }
}

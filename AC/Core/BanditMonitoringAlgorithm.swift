//
//  BanditMonitoringAlgorithm.swift
//  AC
//

import Foundation

// MARK: - BanditMonitoringAlgorithm

/// Two-brain monitoring algorithm.
///
/// **Brain 1** (VLM): `ScreenStateExtractorService` takes a screenshot and returns a
/// `BanditScreenState` — a structured observation including `productivityScore`, `onTask`,
/// `appCategory`, and a pre-written `candidateNudge`.
///
/// **Brain 2** (LinUCB): `ContextualBanditEngine` decides *whether* to show the candidate nudge
/// based on a 16-dimensional context vector and accumulated per-user reward history.
///
/// The bandit updates its weights when `observeReward` is called after the user reacts to a nudge
/// (thumbs up/down, ignored, switched to productive app, etc.).
///
/// Falls back to the LLM-only path when Brain 1 extraction fails.
///
/// Algorithm ID: `"bandit_focus_v1"`
final class BanditMonitoringAlgorithm: MonitoringAlgorithm {
    let descriptor = MonitoringAlgorithmDescriptor(
        id: MonitoringConfiguration.banditAlgorithmID,
        version: "1.0",
        displayName: "Bandit Focus",
        summary: "LinUCB contextual bandit on VLM screen-state extraction."
    )

    private let screenStateExtractor: any ScreenStateExtracting
    private let monitoringLLMClient: any MonitoringLLMEvaluating

    init(
        monitoringLLMClient: any MonitoringLLMEvaluating,
        screenStateExtractor: any ScreenStateExtracting
    ) {
        self.monitoringLLMClient = monitoringLLMClient
        self.screenStateExtractor = screenStateExtractor
    }

    // MARK: - MonitoringAlgorithm — state lifecycle

    func resetState(_ state: inout AlgorithmStateEnvelope) {
        state.banditFocus = BanditFocusAlgorithmState()
    }

    func resetTransientState(_ state: inout AlgorithmStateEnvelope) {
        state.banditFocus.distraction = DistractionMetadata()
    }

    func noteContext(
        _ contextKey: String?,
        at now: Date,
        state: inout AlgorithmStateEnvelope
    ) -> Bool {
        var ladder = DistractionLadder(metadata: state.banditFocus.distraction)
        let didChange = ladder.noteContext(contextKey, at: now)
        state.banditFocus.distraction = ladder.metadata
        return didChange
    }

    func distractionMetadata(from state: AlgorithmStateEnvelope) -> DistractionMetadata {
        state.banditFocus.distraction
    }

    // MARK: - MonitoringAlgorithm — evaluation plan

    func evaluationPlan(
        state: inout AlgorithmStateEnvelope,
        context: FrontmostContext,
        heuristics: TelemetryHeuristicSnapshot,
        configuration: MonitoringConfiguration,
        now: Date
    ) -> MonitoringEvaluationPlan {
        let visualContextKey = context.bundleIdentifier ?? context.appName.lowercased()
        let lastVisualCheckAt =
            state.banditFocus.lastVisualCheckByContext[visualContextKey] ?? .distantPast
        let periodicVisualCheckDue =
            heuristics.periodicVisualReason != nil
            && now.timeIntervalSince(lastVisualCheckAt) >= MonitoringHeuristics.periodicVisualCheckInterval

        let ladder = DistractionLadder(metadata: state.banditFocus.distraction)
        guard ladder.shouldEvaluate(at: now) || periodicVisualCheckDue else {
            return .none
        }

        if periodicVisualCheckDue {
            state.banditFocus.lastVisualCheckByContext[visualContextKey] = now
        }

        return MonitoringEvaluationPlan(
            shouldEvaluate: true,
            reason: periodicVisualCheckDue ? "periodic_visual_check" : "stable_context",
            visualCheckReason: periodicVisualCheckDue ? heuristics.periodicVisualReason : nil,
            promptMode: "extraction",
            promptVersion: "screen_state_v1"
        )
    }

    // MARK: - MonitoringAlgorithm — evaluate

    func evaluate(input: MonitoringDecisionInput) async -> MonitoringDecisionResult {
        let runtimePath = RuntimeSetupService.normalizedRuntimePath(from: input.runtimeOverride)

        // Brain 1: extract structured screen state
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

        // Fallback: if Brain 1 fails, delegate to the LLM-only path
        guard let screenState else {
            return await fallbackToLLMPath(input: input)
        }

        // Build feature vector from observation
        let timeInAppSeconds =
            input.snapshot.perAppDurations
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

        // Brain 2: bandit decision
        var updatedState = input.algorithmState
        var engine = updatedState.banditFocus.engine
        let (banditSaysNudge, _) = engine.shouldNudge(context: context)
        updatedState.banditFocus.engine = engine

        // Translate extraction result into a synthetic LLMDecision for CompanionPolicy
        let assessment: ModelAssessment = screenState.onTask ? .focused : .distracted
        let syntheticDecision = LLMDecision(
            assessment: assessment,
            suggestedAction: banditSaysNudge && !screenState.onTask ? .nudge : .none,
            confidence: screenState.confidence,
            reasonTags: [screenState.appCategory.rawValue],
            nudge: screenState.candidateNudge,
            abstainReason: nil
        )

        // DistractionLadder — spam guard
        let distractionBefore = updatedState.banditFocus.distraction
        var ladder = DistractionLadder(metadata: distractionBefore)
        let ladderSignal = ladder.record(assessment: assessment, at: input.now)
        updatedState.banditFocus.distraction = ladder.metadata

        let execution = MonitoringExecutionMetadata(
            algorithmID: descriptor.id,
            algorithmVersion: descriptor.version,
            promptProfileID: "screen_state_v1",
            experimentArm: input.configuration.experimentArm
        )

        let policy = CompanionPolicy.decide(
            evaluationID: input.evaluationID,
            modelDecision: syntheticDecision,
            ladderSignal: ladderSignal,
            distractionBefore: distractionBefore,
            distractionAfter: ladder.metadata,
            strategy: execution.telemetryRecord
        )

        // If a nudge fired, save pending context for deferred reward
        if case .showNudge = policy.action {
            updatedState.banditFocus.pendingNudgeContext = context
            updatedState.banditFocus.pendingNudgeEvaluationID = input.evaluationID
            updatedState.banditFocus.pendingNudgeIssuedAt = input.now
            updatedState.banditFocus.lastNudgeAt = input.now
        }

        // Synthetic evaluation result (no LLM was called, no attempts)
        let evaluation = LLMEvaluationResult(
            runtimePath: runtimePath,
            modelIdentifier: LocalModelRuntime.defaultModelIdentifier,
            promptProfileID: "screen_state_v1",
            promptProfileVersion: "screen_state_v1",
            attempts: [],
            finalDecision: syntheticDecision,
            failureMessage: nil
        )

        return MonitoringDecisionResult(
            execution: execution,
            evaluation: evaluation,
            decision: syntheticDecision,
            policy: policy,
            updatedAlgorithmState: updatedState
        )
    }

    // MARK: - MonitoringAlgorithm — reward

    func observeReward(_ signal: MonitoringRewardSignal, state: inout AlgorithmStateEnvelope) {
        guard
            let pendingContext = state.banditFocus.pendingNudgeContext,
            let pendingID = state.banditFocus.pendingNudgeEvaluationID,
            pendingID == signal.evaluationID
        else { return }

        state.banditFocus.engine.update(context: pendingContext, reward: signal.value)
        state.banditFocus.lastNudgeWasPositive = signal.value > 0

        // Clear pending state
        state.banditFocus.pendingNudgeContext = nil
        state.banditFocus.pendingNudgeEvaluationID = nil
        state.banditFocus.pendingNudgeIssuedAt = nil
    }

    // MARK: - Fallback

    private func fallbackToLLMPath(input: MonitoringDecisionInput) async -> MonitoringDecisionResult {
        let evaluation = await monitoringLLMClient.evaluate(
            snapshot: input.snapshot,
            goals: input.goals,
            recentActions: input.recentActions,
            distraction: input.algorithmState.banditFocus.distraction,
            heuristics: input.heuristics,
            memory: input.memory,
            promptProfileID: MonitoringConfiguration.defaultPromptProfileID,
            runtimeOverride: input.runtimeOverride
        )

        let decision = evaluation.finalDecision ?? .unclear
        var updatedState = input.algorithmState
        var ladder = DistractionLadder(metadata: updatedState.banditFocus.distraction)
        let ladderSignal = ladder.record(assessment: decision.assessment, at: input.now)
        updatedState.banditFocus.distraction = ladder.metadata

        let execution = MonitoringExecutionMetadata(
            algorithmID: descriptor.id,
            algorithmVersion: descriptor.version,
            promptProfileID: evaluation.promptProfileID,
            experimentArm: input.configuration.experimentArm
        )

        let policy = CompanionPolicy.decide(
            evaluationID: input.evaluationID,
            modelDecision: decision,
            ladderSignal: ladderSignal,
            distractionBefore: input.algorithmState.banditFocus.distraction,
            distractionAfter: ladder.metadata,
            strategy: execution.telemetryRecord
        )

        return MonitoringDecisionResult(
            execution: execution,
            evaluation: evaluation,
            decision: decision,
            policy: policy,
            updatedAlgorithmState: updatedState
        )
    }
}

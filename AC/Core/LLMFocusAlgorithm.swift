//
//  LLMFocusAlgorithm.swift
//  AC
//

import Foundation

/// The LLM-brain monitoring algorithm.
///
/// The VLM assesses the screen, decides if the user is distracted, and generates nudge text — all in
/// a single inference call. The DistractionLadder enforces spam-prevention timing; CompanionPolicy
/// applies the confidence threshold and escalation rules.
///
/// Algorithm ID: "legacy_focus_v1" (kept stable for state persistence and telemetry continuity)
final class LLMFocusAlgorithm: MonitoringAlgorithm {
    let descriptor = MonitoringAlgorithmDescriptor(
        id: MonitoringConfiguration.defaultAlgorithmID,
        version: "1.0",
        displayName: "LLM Focus",
        summary: "VLM-driven nudge policy with DistractionLadder spam prevention."
    )

    private let monitoringLLMClient: any MonitoringLLMEvaluating

    init(monitoringLLMClient: any MonitoringLLMEvaluating) {
        self.monitoringLLMClient = monitoringLLMClient
    }

    func resetState(_ state: inout AlgorithmStateEnvelope) {
        state.llmFocus = LLMFocusAlgorithmState()
    }

    func resetTransientState(_ state: inout AlgorithmStateEnvelope) {
        state.llmFocus.distraction = DistractionMetadata()
    }

    func noteContext(
        _ contextKey: String?,
        at now: Date,
        state: inout AlgorithmStateEnvelope
    ) -> Bool {
        var ladder = DistractionLadder(metadata: state.llmFocus.distraction)
        let didChange = ladder.noteContext(contextKey, at: now)
        state.llmFocus.distraction = ladder.metadata
        return didChange
    }

    func evaluationPlan(
        state: inout AlgorithmStateEnvelope,
        context: FrontmostContext,
        heuristics: TelemetryHeuristicSnapshot,
        configuration: MonitoringConfiguration,
        now: Date
    ) -> MonitoringEvaluationPlan {
        let promptProfile = PromptCatalog.monitoringProfile(id: configuration.promptProfileID)
        let visualContextKey = context.bundleIdentifier ?? context.appName.lowercased()
        let lastVisualCheckAt = state.llmFocus.lastVisualCheckByContext[visualContextKey] ?? .distantPast
        let periodicVisualCheckDue = heuristics.periodicVisualReason != nil &&
            now.timeIntervalSince(lastVisualCheckAt) >= MonitoringHeuristics.periodicVisualCheckInterval

        let ladder = DistractionLadder(metadata: state.llmFocus.distraction)
        let shouldEvaluateNow = ladder.shouldEvaluate(at: now) || periodicVisualCheckDue

        guard shouldEvaluateNow else {
            return .none
        }

        if periodicVisualCheckDue {
            state.llmFocus.lastVisualCheckByContext[visualContextKey] = now
        }

        return MonitoringEvaluationPlan(
            shouldEvaluate: true,
            reason: periodicVisualCheckDue ? "periodic_visual_check" : "stable_context",
            visualCheckReason: periodicVisualCheckDue ? heuristics.periodicVisualReason : nil,
            promptMode: MonitoringPromptVariant.visionPrimary.rawValue,
            promptVersion: promptProfile.descriptor.version
        )
    }

    func distractionMetadata(from state: AlgorithmStateEnvelope) -> DistractionMetadata {
        state.llmFocus.distraction
    }

    func evaluate(input: MonitoringDecisionInput) async -> MonitoringDecisionResult {
        let evaluation = await monitoringLLMClient.evaluate(
            snapshot: input.snapshot,
            goals: input.goals,
            recentActions: input.recentActions,
            distraction: input.algorithmState.llmFocus.distraction,
            heuristics: input.heuristics,
            memory: input.memory,
            promptProfileID: input.configuration.promptProfileID,
            runtimeOverride: input.runtimeOverride
        )

        let decision = evaluation.finalDecision ?? .unclear
        let distractionBefore = input.algorithmState.llmFocus.distraction
        var updatedState = input.algorithmState
        var ladder = DistractionLadder(metadata: distractionBefore)
        let ladderSignal = ladder.record(assessment: decision.assessment, at: input.now)
        updatedState.llmFocus.distraction = ladder.metadata
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
            distractionBefore: distractionBefore,
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

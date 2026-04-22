//
//  LLMFocusAlgorithm.swift
//  AC
//

import Foundation

/// The LLM-brain monitoring algorithm.
///
/// A screenshot perception step first describes what the user is doing, then a text-only decision step
/// decides whether the user is distracted and what AC should do next. The DistractionLadder enforces
/// spam-prevention timing; CompanionPolicy applies the confidence threshold and escalation rules.
///
/// Algorithm ID: `"llm_focus_v1"`, with a decoder shim for persisted `"legacy_focus_v1"` state.
final class LLMFocusAlgorithm: MonitoringAlgorithm {
    let descriptor = MonitoringAlgorithmDescriptor(
        id: MonitoringConfiguration.llmAlgorithmID,
        version: "1.0",
        displayName: "LLM Focus",
        summary: "Two-step screenshot perception plus text decision with DistractionLadder spam prevention."
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
            requiresScreenshot: true,
            promptMode: "legacy_two_step",
            promptVersion: promptProfile.descriptor.version
        )
    }

    func distractionMetadata(from state: AlgorithmStateEnvelope) -> DistractionMetadata {
        state.llmFocus.distraction
    }

    func evaluate(input: MonitoringDecisionInput) async -> MonitoringDecisionResult {
        let evaluation = await monitoringLLMClient.evaluate(
            evaluationID: input.evaluationID,
            snapshot: input.snapshot,
            goals: input.goals,
            recentActions: input.recentActions,
            distraction: input.algorithmState.llmFocus.distraction,
            heuristics: input.heuristics,
            memory: input.memory,
            promptProfileID: input.configuration.promptProfileID,
            runtimeProfileID: input.configuration.runtimeProfileID,
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
            pipelineProfileID: nil,
            runtimeProfileID: nil,
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

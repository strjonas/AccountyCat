//
//  MonitoringAlgorithm.swift
//  AC
//
//  Created by Codex on 15.04.26.
//

import Foundation

enum MonitoringAlgorithmResolutionError: LocalizedError, Equatable {
    case unknownAlgorithmID(String)

    var errorDescription: String? {
        switch self {
        case let .unknownAlgorithmID(id):
            return "Unknown monitoring algorithm id: \(id)"
        }
    }
}

struct MonitoringEvaluationPlan: Sendable {
    static let none = MonitoringEvaluationPlan(
        shouldEvaluate: false,
        reason: nil,
        visualCheckReason: nil,
        requiresScreenshot: true,
        promptMode: MonitoringPromptVariant.visionPrimary.rawValue,
        promptVersion: PromptCatalog.defaultMonitoringPromptProfile.descriptor.version
    )

    var shouldEvaluate: Bool
    var reason: String?
    var visualCheckReason: String?
    var requiresScreenshot: Bool
    var promptMode: String
    var promptVersion: String
}

struct MonitoringDecisionInput: Sendable {
    var now: Date
    var evaluationID: String
    var snapshot: AppSnapshot
    var goals: String
    var recentActions: [ActionRecord]
    var heuristics: TelemetryHeuristicSnapshot
    /// Pre-rendered prompt-facing memory (with timestamps). The algorithm no longer
    /// condenses or filters this — the LLM is the authority on what matters.
    var memory: String
    /// Last few user chat messages (most recent first is fine — the LLM reads order).
    /// This is a safety net so fresh intent always reaches the decision stage even
    /// if memory extraction is lagging.
    var recentUserMessages: [String] = []
    var policyMemory: PolicyMemory
    var runtimeOverride: String?
    var configuration: MonitoringConfiguration
    var algorithmState: AlgorithmStateEnvelope
    /// Personality prefix from the selected ACCharacter — threaded into nudge-copy prompts.
    var characterPersonalityPrefix: String = ""
    /// Optional Calendar Intelligence context (compact, single-line). Threaded
    /// into both the decision and the nudge-copy prompts as a soft hint.
    /// See `MonitoringDecisionPromptPayload.calendarContext` for ranking notes.
    var calendarContext: String? = nil
}

struct MonitoringDecisionResult: Sendable {
    var execution: MonitoringExecutionMetadata
    var evaluation: LLMEvaluationResult
    var decision: LLMDecision
    var policy: CompanionPolicyResult
    var updatedAlgorithmState: AlgorithmStateEnvelope
}

struct MonitoringAppealReviewInput: Sendable {
    var now: Date
    var appealText: String
    var snapshot: AppSnapshot?
    var goals: String
    var recentActions: [ActionRecord]
    var memory: String
    var recentUserMessages: [String] = []
    var policyMemory: PolicyMemory
    var configuration: MonitoringConfiguration
    var algorithmState: AlgorithmStateEnvelope
    var runtimeOverride: String?
}

struct MonitoringAppealReviewOutput: Sendable {
    var result: AppealReviewResult
    var evaluation: LLMEvaluationResult
    var updatedPolicyMemory: PolicyMemory
    var updatedAlgorithmState: AlgorithmStateEnvelope
}

/// Signal passed to `observeReward` after a nudge receives user feedback.
struct MonitoringRewardSignal: Sendable {
    /// The evaluation that triggered the nudge.
    var evaluationID: String
    var kind: UserReactionKind
    /// Pre-computed reward value (positive = good, negative = bad).
    var value: Double
}

protocol MonitoringAlgorithm: Sendable {
    var descriptor: MonitoringAlgorithmDescriptor { get }

    func resetState(_ state: inout AlgorithmStateEnvelope)
    func resetTransientState(_ state: inout AlgorithmStateEnvelope)
    func noteContext(
        _ contextKey: String?,
        at now: Date,
        state: inout AlgorithmStateEnvelope
    ) -> Bool
    func evaluationPlan(
        state: inout AlgorithmStateEnvelope,
        context: FrontmostContext,
        heuristics: TelemetryHeuristicSnapshot,
        policyMemory: PolicyMemory,
        configuration: MonitoringConfiguration,
        now: Date
    ) -> MonitoringEvaluationPlan
    func distractionMetadata(from state: AlgorithmStateEnvelope) -> DistractionMetadata
    func evaluate(input: MonitoringDecisionInput) async -> MonitoringDecisionResult
    func reviewAppeal(input: MonitoringAppealReviewInput) async -> MonitoringAppealReviewOutput?
    /// Called when the system receives a reward signal for a prior nudge.
    /// Algorithms that do not learn (e.g. LegacyLLMFocusAlgorithm) inherit the default no-op.
    func observeReward(_ signal: MonitoringRewardSignal, state: inout AlgorithmStateEnvelope)
}

extension MonitoringAlgorithm {
    /// Default no-op: algorithms that do not learn from rewards implement nothing.
    func observeReward(_ signal: MonitoringRewardSignal, state: inout AlgorithmStateEnvelope) {}

    func reviewAppeal(input: MonitoringAppealReviewInput) async -> MonitoringAppealReviewOutput? {
        nil
    }
}

final class MonitoringAlgorithmRegistry: @unchecked Sendable {
    private let legacyLLMFocusAlgorithm: LegacyLLMFocusAlgorithm
    private let llmMonitorAlgorithm: LLMMonitorAlgorithm
    private let banditFocusAlgorithm: BanditMonitoringAlgorithm

    init(
        monitoringLLMClient: any MonitoringLLMEvaluating,
        screenStateExtractor: some ScreenStateExtracting,
        nudgeCopywriter: any NudgeCopywriting,
        runtime: LocalModelRuntime,
        onlineModelService: any OnlineModelServing,
        policyMemoryService: PolicyMemoryServicing
    ) {
        self.legacyLLMFocusAlgorithm = LegacyLLMFocusAlgorithm(
            monitoringLLMClient: monitoringLLMClient
        )
        self.llmMonitorAlgorithm = LLMMonitorAlgorithm(
            runtime: runtime,
            onlineModelService: onlineModelService,
            policyMemoryService: policyMemoryService
        )
        self.banditFocusAlgorithm = BanditMonitoringAlgorithm(
            screenStateExtractor: screenStateExtractor,
            nudgeCopywriter: nudgeCopywriter
        )
    }

    var availableAlgorithms: [MonitoringAlgorithmDescriptor] {
        [
            llmMonitorAlgorithm.descriptor,
            legacyLLMFocusAlgorithm.descriptor,
            banditFocusAlgorithm.descriptor,
        ]
    }

    func containsAlgorithm(id: String) -> Bool {
        let normalizedID = MonitoringConfiguration.normalizedAlgorithmID(id)
        return availableAlgorithms.contains { $0.id == normalizedID }
    }

    func descriptor(for id: String) throws -> MonitoringAlgorithmDescriptor {
        try resolve(id: id).descriptor
    }

    func noteContext(
        configuration: MonitoringConfiguration,
        contextKey: String?,
        at now: Date,
        state: inout AlgorithmStateEnvelope
    ) throws -> Bool {
        try resolve(id: configuration.algorithmID).noteContext(
            contextKey,
            at: now,
            state: &state
        )
    }

    func evaluationPlan(
        configuration: MonitoringConfiguration,
        context: FrontmostContext,
        heuristics: TelemetryHeuristicSnapshot,
        policyMemory: PolicyMemory,
        now: Date,
        state: inout AlgorithmStateEnvelope
    ) throws -> MonitoringEvaluationPlan {
        try resolve(id: configuration.algorithmID).evaluationPlan(
            state: &state,
            context: context,
            heuristics: heuristics,
            policyMemory: policyMemory,
            configuration: configuration,
            now: now
        )
    }

    func distractionMetadata(
        configuration: MonitoringConfiguration,
        state: AlgorithmStateEnvelope
    ) throws -> DistractionMetadata {
        try resolve(id: configuration.algorithmID).distractionMetadata(from: state)
    }

    func resetSelectedAlgorithmState(
        configuration: MonitoringConfiguration,
        state: inout AlgorithmStateEnvelope
    ) throws {
        try resolve(id: configuration.algorithmID).resetState(&state)
    }

    func resetSelectedAlgorithmTransientState(
        configuration: MonitoringConfiguration,
        state: inout AlgorithmStateEnvelope
    ) throws {
        try resolve(id: configuration.algorithmID).resetTransientState(&state)
    }

    func evaluate(input: MonitoringDecisionInput) async throws -> MonitoringDecisionResult {
        try await resolve(id: input.configuration.algorithmID).evaluate(input: input)
    }

    func observeReward(
        _ signal: MonitoringRewardSignal,
        configuration: MonitoringConfiguration,
        state: inout AlgorithmStateEnvelope
    ) throws {
        try resolve(id: configuration.algorithmID).observeReward(signal, state: &state)
    }

    func reviewAppeal(
        input: MonitoringAppealReviewInput
    ) async throws -> MonitoringAppealReviewOutput? {
        try await resolve(id: input.configuration.algorithmID).reviewAppeal(input: input)
    }

    private func resolve(id: String) throws -> any MonitoringAlgorithm {
        switch MonitoringConfiguration.normalizedAlgorithmID(id) {
        case llmMonitorAlgorithm.descriptor.id:
            return llmMonitorAlgorithm
        case legacyLLMFocusAlgorithm.descriptor.id:
            return legacyLLMFocusAlgorithm
        case banditFocusAlgorithm.descriptor.id:
            return banditFocusAlgorithm
        default:
            throw MonitoringAlgorithmResolutionError.unknownAlgorithmID(id)
        }
    }
}

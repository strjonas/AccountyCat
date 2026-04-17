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
        promptMode: MonitoringPromptVariant.visionPrimary.rawValue,
        promptVersion: PromptCatalog.defaultMonitoringPromptProfile.descriptor.version
    )

    var shouldEvaluate: Bool
    var reason: String?
    var visualCheckReason: String?
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
    var memory: String
    var runtimeOverride: String?
    var configuration: MonitoringConfiguration
    var algorithmState: AlgorithmStateEnvelope
}

struct MonitoringDecisionResult: Sendable {
    var execution: MonitoringExecutionMetadata
    var evaluation: LLMEvaluationResult
    var decision: LLMDecision
    var policy: CompanionPolicyResult
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
        configuration: MonitoringConfiguration,
        now: Date
    ) -> MonitoringEvaluationPlan
    func distractionMetadata(from state: AlgorithmStateEnvelope) -> DistractionMetadata
    func evaluate(input: MonitoringDecisionInput) async -> MonitoringDecisionResult
    /// Called when the system receives a reward signal for a prior nudge.
    /// Algorithms that do not learn (e.g. LLMFocusAlgorithm) inherit the default no-op.
    func observeReward(_ signal: MonitoringRewardSignal, state: inout AlgorithmStateEnvelope)
}

extension MonitoringAlgorithm {
    /// Default no-op: algorithms that do not learn from rewards implement nothing.
    func observeReward(_ signal: MonitoringRewardSignal, state: inout AlgorithmStateEnvelope) {}
}

final class MonitoringAlgorithmRegistry {
    private let llmFocusAlgorithm: LLMFocusAlgorithm
    private let banditFocusAlgorithm: BanditMonitoringAlgorithm

    init(
        monitoringLLMClient: MonitoringLLMClient,
        screenStateExtractor: some ScreenStateExtracting
    ) {
        self.llmFocusAlgorithm = LLMFocusAlgorithm(
            monitoringLLMClient: monitoringLLMClient
        )
        self.banditFocusAlgorithm = BanditMonitoringAlgorithm(
            monitoringLLMClient: monitoringLLMClient,
            screenStateExtractor: screenStateExtractor
        )
    }

    var availableAlgorithms: [MonitoringAlgorithmDescriptor] {
        [
            llmFocusAlgorithm.descriptor,
            banditFocusAlgorithm.descriptor,
        ]
    }

    func containsAlgorithm(id: String) -> Bool {
        availableAlgorithms.contains { $0.id == id }
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
        now: Date,
        state: inout AlgorithmStateEnvelope
    ) throws -> MonitoringEvaluationPlan {
        try resolve(id: configuration.algorithmID).evaluationPlan(
            state: &state,
            context: context,
            heuristics: heuristics,
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

    private func resolve(id: String) throws -> any MonitoringAlgorithm {
        switch id {
        case llmFocusAlgorithm.descriptor.id:
            return llmFocusAlgorithm
        case banditFocusAlgorithm.descriptor.id:
            return banditFocusAlgorithm
        default:
            throw MonitoringAlgorithmResolutionError.unknownAlgorithmID(id)
        }
    }
}

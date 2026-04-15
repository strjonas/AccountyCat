//
//  MonitoringAlgorithm.swift
//  AC
//
//  Created by Codex on 15.04.26.
//

import Foundation

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
}

final class MonitoringAlgorithmRegistry {
    private let legacyFocusAlgorithm: LegacyMonitoringAlgorithm

    init(monitoringLLMClient: MonitoringLLMClient) {
        self.legacyFocusAlgorithm = LegacyMonitoringAlgorithm(
            monitoringLLMClient: monitoringLLMClient
        )
    }

    var availableAlgorithms: [MonitoringAlgorithmDescriptor] {
        [
            legacyFocusAlgorithm.descriptor,
        ]
    }

    func descriptor(for id: String) -> MonitoringAlgorithmDescriptor {
        resolve(id: id).descriptor
    }

    func noteContext(
        configuration: MonitoringConfiguration,
        contextKey: String?,
        at now: Date,
        state: inout AlgorithmStateEnvelope
    ) -> Bool {
        resolve(id: configuration.algorithmID).noteContext(
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
    ) -> MonitoringEvaluationPlan {
        resolve(id: configuration.algorithmID).evaluationPlan(
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
    ) -> DistractionMetadata {
        resolve(id: configuration.algorithmID).distractionMetadata(from: state)
    }

    func resetSelectedAlgorithmState(
        configuration: MonitoringConfiguration,
        state: inout AlgorithmStateEnvelope
    ) {
        resolve(id: configuration.algorithmID).resetState(&state)
    }

    func resetSelectedAlgorithmTransientState(
        configuration: MonitoringConfiguration,
        state: inout AlgorithmStateEnvelope
    ) {
        resolve(id: configuration.algorithmID).resetTransientState(&state)
    }

    func evaluate(input: MonitoringDecisionInput) async -> MonitoringDecisionResult {
        await resolve(id: input.configuration.algorithmID).evaluate(input: input)
    }

    private func resolve(id: String) -> any MonitoringAlgorithm {
        switch id {
        case legacyFocusAlgorithm.descriptor.id:
            return legacyFocusAlgorithm
        default:
            return legacyFocusAlgorithm
        }
    }
}

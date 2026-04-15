//
//  CompanionPolicy.swift
//  AC
//
//  Created by Codex on 13.04.26.
//

import Foundation

struct CompanionPolicyResult: Sendable {
    var action: CompanionAction
    var record: PolicyDecisionRecord
}

enum CompanionPolicy {
    private static let distractionConfidenceThreshold = 0.60

    static func decide(
        evaluationID: String,
        modelDecision: LLMDecision,
        ladderSignal: DistractionSignal,
        distractionBefore: DistractionMetadata,
        distractionAfter: DistractionMetadata,
        strategy: MonitoringExecutionMetadataRecord? = nil
    ) -> CompanionPolicyResult {
        let sanitizedNudge = modelDecision.nudge?.cleanedSingleLine
        let normalizedDecision = normalized(modelDecision, sanitizedNudge: sanitizedNudge)
        let confidentDistracted = isConfidentDistracted(normalizedDecision)

        let action: CompanionAction
        let allowIntervention: Bool
        let allowEscalation: Bool
        let blockReason: String?

        switch ladderSignal {
        case .none:
            action = .none
            allowIntervention = false
            allowEscalation = false
            blockReason = normalizedDecision.assessment == .distracted ? "ladder_waiting" : nil

        case .nudgeEligible:
            allowIntervention = confidentDistracted
            allowEscalation = false

            if !confidentDistracted {
                action = .none
                blockReason = "insufficient_distracted_confidence"
            } else if normalizedDecision.suggestedAction != .nudge {
                action = .none
                blockReason = "model_did_not_request_nudge"
            } else if let sanitizedNudge, !sanitizedNudge.isEmpty {
                action = .showNudge(sanitizedNudge)
                blockReason = nil
            } else {
                action = .none
                blockReason = "missing_nudge_copy"
            }

        case .overlayEligible:
            allowIntervention = confidentDistracted
            allowEscalation = confidentDistracted && normalizedDecision.suggestedAction == .overlay

            if !confidentDistracted {
                action = .none
                blockReason = "insufficient_distracted_confidence"
            } else if normalizedDecision.suggestedAction != .overlay {
                action = .none
                blockReason = "model_did_not_request_overlay"
            } else {
                action = .showOverlay
                blockReason = nil
            }
        }

        return CompanionPolicyResult(
            action: action,
            record: PolicyDecisionRecord(
                evaluationID: evaluationID,
                model: normalizedDecision.parsedRecord,
                strategy: strategy,
                ladderSignal: signalName(ladderSignal),
                allowIntervention: allowIntervention,
                allowEscalation: allowEscalation,
                blockReason: blockReason,
                finalAction: telemetryActionRecord(for: action),
                distractionBefore: telemetryState(from: distractionBefore),
                distractionAfter: telemetryState(from: distractionAfter)
            )
        )
    }

    static func telemetryState(from metadata: DistractionMetadata) -> TelemetryDistractionState {
        TelemetryDistractionState(
            stableSince: metadata.stableSince,
            lastAssessment: metadata.lastAssessment,
            consecutiveDistractedCount: metadata.consecutiveDistractedCount,
            nextEvaluationAt: metadata.nextEvaluationAt
        )
    }

    static func telemetryActionRecord(for action: CompanionAction) -> TelemetryCompanionActionRecord {
        switch action {
        case .none:
            return TelemetryCompanionActionRecord(kind: .none, message: nil)
        case let .showNudge(message):
            return TelemetryCompanionActionRecord(kind: .nudge, message: message)
        case .showOverlay:
            return TelemetryCompanionActionRecord(kind: .overlay, message: nil)
        }
    }

    private static func normalized(
        _ decision: LLMDecision,
        sanitizedNudge: String?
    ) -> LLMDecision {
        LLMDecision(
            assessment: decision.assessment,
            suggestedAction: decision.suggestedAction,
            confidence: decision.confidence,
            reasonTags: decision.reasonTags,
            nudge: sanitizedNudge,
            abstainReason: decision.abstainReason
        )
    }

    private static func isConfidentDistracted(_ decision: LLMDecision) -> Bool {
        guard decision.assessment == .distracted else {
            return false
        }
        let effectiveConfidence = decision.confidence ?? 0.75
        return effectiveConfidence >= distractionConfidenceThreshold
    }

    private static func signalName(_ signal: DistractionSignal) -> String {
        switch signal {
        case .none:
            return "none"
        case let .nudgeEligible(sequence):
            return "nudge_eligible_\(sequence)"
        case let .overlayEligible(sequence):
            return "overlay_eligible_\(sequence)"
        }
    }
}

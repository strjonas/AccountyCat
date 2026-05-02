//
//  MonitoringLLMClient.swift
//  AC
//
//  Created by Codex on 15.04.26.
//

import Foundation

struct LLMEvaluationAttempt: Sendable {
    var promptMode: String
    var promptVersion: String
    var template: PromptTemplateRecord
    var templateContents: String
    var payloadJSON: String
    var renderedPrompt: String
    var runtimeOptions: TelemetryRuntimeOptions?
    var runtimeOutput: RuntimeProcessOutput?
    var parsedDecision: LLMDecision?
}

struct LLMEvaluationResult: Sendable {
    var runtimePath: String
    var modelIdentifier: String
    var promptProfileID: String
    var promptProfileVersion: String
    var attempts: [LLMEvaluationAttempt]
    var finalDecision: LLMDecision?
    var failureMessage: String?

    var lastUsedModelIdentifier: String {
        attempts
            .reversed()
            .compactMap { attempt in
                attempt.runtimeOutput?.usedModelIdentifier ?? attempt.runtimeOptions?.modelIdentifier
            }
            .first ?? modelIdentifier
    }
}

nonisolated struct VisionInterventionHistoryItem: Codable, Hashable, Sendable {
    var kind: String
    var message: String?
    var timestamp: Date
}

nonisolated struct VisionInterventionHistorySummary: Codable, Hashable, Sendable {
    var recentInterventions: [VisionInterventionHistoryItem]
    var recentNudgeMessages: [String]
    var lastInterventionKind: String?
    var nudgeCount: Int
    var overlayCount: Int
    var backToWorkCount: Int
    var dismissOverlayCount: Int
}

enum MonitoringLLMClient {
    nonisolated static func monitoringRelevantActions(
        from recentActions: [ActionRecord],
        at now: Date
    ) -> [ActionRecord] {
        let relevanceWindow: TimeInterval = 90 * 60
        let filtered = recentActions.filter { action in
            guard now.timeIntervalSince(action.timestamp) <= relevanceWindow else {
                return false
            }
            if action.kind == .nudge,
               action.message?.lowercased().contains("debug nudge") == true {
                return false
            }
            return true
        }

        return Array(filtered.prefix(3))
    }

    nonisolated static func makeInterventionHistorySummary(
        from recentActions: [ActionRecord]
    ) -> VisionInterventionHistorySummary {
        let recentInterventions = recentActions
            .prefix(3)
            .map {
                VisionInterventionHistoryItem(
                    kind: $0.kind.rawValue,
                    message: $0.message?.cleanedSingleLine,
                    timestamp: $0.timestamp
                )
            }

        let recentNudgeMessages = recentActions
            .lazy
            .filter { $0.kind == .nudge }
            .compactMap { $0.message?.cleanedSingleLine }
            .filter { !$0.isEmpty }
            .prefix(2)
            .map { $0 }

        return VisionInterventionHistorySummary(
            recentInterventions: recentInterventions,
            recentNudgeMessages: Array(recentNudgeMessages),
            lastInterventionKind: recentInterventions.first?.kind,
            nudgeCount: recentActions.filter { $0.kind == .nudge }.count,
            overlayCount: recentActions.filter { $0.kind == .overlay }.count,
            backToWorkCount: recentActions.filter { $0.kind == .backToWork }.count,
            dismissOverlayCount: recentActions.filter { $0.kind == .dismissOverlay }.count
        )
    }

    nonisolated static func encodePayload<T: Encodable>(_ payload: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(payload),
              let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return string
    }
}

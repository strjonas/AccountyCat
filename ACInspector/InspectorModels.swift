//
//  InspectorModels.swift
//  ACInspector
//
//  Created by Codex on 13.04.26.
//

import Foundation

nonisolated enum IndexedEpisodeKind: String, Hashable, Sendable, CaseIterable, Codable {
    case focusDecision = "focus_decision"
    case chat
    case chatAction = "chat_action"
    case policyMemory = "policy_memory"
    case memoryConsolidation = "memory_consolidation"
    case monitoringText = "monitoring_text"
    case monitoringVision = "monitoring_vision"
    case safelistAppeal = "safelist_appeal"
    case localChat = "local_chat"

    var displayName: String {
        switch self {
        case .focusDecision: return "Focus Decision"
        case .chat: return "Chat"
        case .chatAction: return "Chat Action"
        case .policyMemory: return "Policy Memory"
        case .memoryConsolidation: return "Memory Consolidation"
        case .monitoringText: return "Monitoring (Text)"
        case .monitoringVision: return "Monitoring (Vision)"
        case .safelistAppeal: return "Safelist Appeal"
        case .localChat: return "Local Chat"
        }
    }
}

struct IndexedEpisode: Identifiable, Hashable, Sendable {
    var id: String
    var sessionID: String
    var appName: String
    var windowTitle: String?
    var startedAt: Date
    var endedAt: Date?
    var status: EpisodeStatus
    var endReason: EpisodeEndReason?
    var pinned: Bool
    var labels: [EpisodeAnnotationLabel]
    var note: String
    var screenshotPath: String?
    var renderedPromptPath: String?
    var promptPayloadPath: String?
    var modelOutputJSON: String?
    var reactionSummary: String?
    var algorithmID: String?
    var algorithmVersion: String?
    var promptProfileID: String?
    var experimentArm: String?
    var kind: IndexedEpisodeKind = .focusDecision
    var parentEpisodeID: String? = nil
    /// Stable kind-specific extracted fields shown in the inspector detail.
    var extractedFields: [String: String] = [:]
    /// Extra raw paths for non-monitoring kinds.
    var systemPromptPath: String? = nil
    var rawStdoutPath: String? = nil
    var rawStderrPath: String? = nil
    var summary: String = ""
    var modelIdentifier: String? = nil
    var failureMessage: String? = nil

    var title: String {
        if let windowTitle, !windowTitle.isEmpty {
            return windowTitle
        }
        return appName
    }

    var strategySummary: String? {
        guard let algorithmID else { return nil }
        return [algorithmID, promptProfileID].compactMap { $0 }.joined(separator: " • ")
    }

    var episodeRecord: EpisodeRecord {
        EpisodeRecord(
            id: id,
            sessionID: sessionID,
            contextKey: "",
            appName: appName,
            windowTitle: windowTitle,
            startedAt: startedAt,
            endedAt: endedAt,
            status: status,
            endReason: endReason,
            pinned: pinned
        )
    }
}

struct IndexedEvent: Identifiable, Hashable, Sendable {
    var id: String
    var sessionID: String
    var episodeID: String?
    var kind: String
    var timestamp: Date
    var summary: String
    var rawJSON: String
}

struct IndexedModelAttempt: Identifiable, Hashable, Sendable {
    var evaluationID: String
    var promptMode: String
    var timestamp: Date
    var promptTemplatePath: String?
    var promptPayloadPath: String?
    var renderedPromptPath: String?
    var runtimePath: String?
    var modelIdentifier: String?
    var runtimeOptions: TelemetryRuntimeOptions?
    var stdoutPath: String?
    var stderrPath: String?
    var stdoutPreview: String?
    var stderrPreview: String?
    var parsedOutputJSON: String?

    var id: String {
        "\(evaluationID):\(promptMode)"
    }

    var title: String {
        promptMode.replacingOccurrences(of: "_", with: " ")
    }
}

struct InspectorDetailRow: Identifiable, Hashable, Sendable {
    var label: String
    var value: String

    var id: String {
        "\(label):\(value)"
    }
}

enum IndexedEvaluationStageKind: String, Hashable, Sendable {
    case perception
    case decision
    case nudge
    case additional
}

struct IndexedEvaluationStage: Identifiable, Hashable, Sendable {
    var evaluationID: String
    var promptMode: String
    var timestamp: Date
    var kind: IndexedEvaluationStageKind
    var title: String
    var summary: String
    var details: [InspectorDetailRow]
    var promptTemplatePath: String?
    var promptPayloadPath: String?
    var renderedPromptPath: String?
    var runtimePath: String?
    var modelIdentifier: String?
    var runtimeOptions: TelemetryRuntimeOptions?
    var stdoutPath: String?
    var stderrPath: String?
    var stdoutPreview: String?
    var stderrPreview: String?

    var id: String {
        "\(evaluationID):\(promptMode)"
    }
}

struct IndexedEvaluationRun: Identifiable, Hashable, Sendable {
    var evaluationID: String
    var requestedAt: Date
    var outcomeSummary: String
    var primaryStages: [IndexedEvaluationStage]
    var secondaryStages: [IndexedEvaluationStage]

    var id: String { evaluationID }
}

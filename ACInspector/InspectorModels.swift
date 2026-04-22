//
//  InspectorModels.swift
//  ACInspector
//
//  Created by Codex on 13.04.26.
//

import Foundation

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
    var promptPayloadPath: String?
    var renderedPromptPath: String?
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
    var promptPayloadPath: String?
    var renderedPromptPath: String?
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

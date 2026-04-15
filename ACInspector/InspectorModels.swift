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

    var title: String {
        if let windowTitle, !windowTitle.isEmpty {
            return windowTitle
        }
        return appName
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

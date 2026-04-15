//
//  TelemetryMetadataTests.swift
//  ACTests
//
//  Created by Codex on 15.04.26.
//

import Foundation
import Testing
@testable import AC

struct TelemetryMetadataTests {

    @Test
    func trainingExportIncludesStrategyMetadataAndOutcomeLabels() throws {
        let episode = EpisodeRecord(
            id: "episode-1",
            sessionID: "session-1",
            contextKey: "context",
            appName: "Chrome",
            windowTitle: "Feed",
            startedAt: Date(),
            endedAt: nil,
            status: .active,
            endReason: nil,
            pinned: false
        )
        let strategy = MonitoringExecutionMetadataRecord(
            algorithmID: "legacy_focus_v1",
            algorithmVersion: "1.0",
            promptProfileID: "focus_default_v2",
            experimentArm: "fixed:legacy_focus_v1:focus_default_v2"
        )
        let events = [
            TelemetryEvent(
                id: "evaluation-1",
                kind: .evaluationRequested,
                timestamp: Date(),
                sessionID: "session-1",
                episodeID: "episode-1",
                episode: episode,
                session: nil,
                observation: nil,
                evaluation: EvaluationRequestRecord(
                    evaluationID: "eval-1",
                    reason: "stable_context",
                    promptMode: "vision_primary",
                    promptVersion: "focus_default_v2",
                    strategy: strategy
                ),
                modelInput: nil,
                modelOutput: nil,
                parsedOutput: nil,
                policy: nil,
                action: nil,
                reaction: nil,
                annotation: nil,
                failure: nil
            ),
            TelemetryEvent(
                id: "reaction-1",
                kind: .userReaction,
                timestamp: Date(),
                sessionID: "session-1",
                episodeID: "episode-1",
                episode: episode,
                session: nil,
                observation: nil,
                evaluation: nil,
                modelInput: nil,
                modelOutput: nil,
                parsedOutput: nil,
                policy: nil,
                action: nil,
                reaction: UserReactionRecord(
                    kind: .postNudgeAppSwitch,
                    relatedAction: nil,
                    positive: true,
                    details: nil
                ),
                annotation: nil,
                failure: nil
            ),
            TelemetryEvent(
                id: "annotation-1",
                kind: .annotationSaved,
                timestamp: Date(),
                sessionID: "session-1",
                episodeID: "episode-1",
                episode: episode,
                session: nil,
                observation: nil,
                evaluation: nil,
                modelInput: nil,
                modelOutput: nil,
                parsedOutput: nil,
                policy: nil,
                action: nil,
                reaction: nil,
                annotation: EpisodeAnnotation(
                    id: "annotation-1",
                    sessionID: "session-1",
                    episodeID: "episode-1",
                    labels: [.goodNudge],
                    note: "helpful",
                    pinned: false,
                    source: .human,
                    createdAt: Date()
                ),
                failure: nil
            ),
        ]

        let manifest = try TrainingDatasetExporter.buildManifest(events: events, sessionIDs: ["session-1"])
        let export = try #require(manifest.episodes.first)

        #expect(manifest.version == 2)
        #expect(export.strategy == strategy)
        #expect(export.shortTermOutcomeLabels == ["post_nudge_app_switch"])
        #expect(export.longTermOutcomeLabels == ["good_nudge"])
    }
}

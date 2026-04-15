//
//  TrainingDatasetExporterTests.swift
//  ACTests
//
//  Created by Codex on 13.04.26.
//

import Foundation
import Testing
@testable import AC

struct TrainingDatasetExporterTests {

    @Test
    func rejectsMixedAnnotationSources() throws {
        let baseEpisode = EpisodeRecord(
            id: "episode-1",
            sessionID: "session-1",
            contextKey: "context",
            appName: "Safari",
            windowTitle: "Feed",
            startedAt: Date(),
            endedAt: nil,
            status: .active,
            endReason: nil,
            pinned: false
        )

        let events = [
            TelemetryEvent(
                id: "annotation-1",
                kind: .annotationSaved,
                timestamp: Date(),
                sessionID: "session-1",
                episodeID: "episode-1",
                episode: baseEpisode,
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
                    id: "a1",
                    sessionID: "session-1",
                    episodeID: "episode-1",
                    labels: [.goodNudge],
                    note: "human",
                    pinned: false,
                    source: .human,
                    createdAt: Date()
                ),
                failure: nil
            ),
            TelemetryEvent(
                id: "annotation-2",
                kind: .annotationSaved,
                timestamp: Date(),
                sessionID: "session-1",
                episodeID: "episode-1",
                episode: baseEpisode,
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
                    id: "a2",
                    sessionID: "session-1",
                    episodeID: "episode-1",
                    labels: [.tooEarly],
                    note: "weak",
                    pinned: false,
                    source: .weak,
                    createdAt: Date()
                ),
                failure: nil
            ),
        ]

        #expect(throws: TrainingExportError.self) {
            try TrainingDatasetExporter.buildManifest(events: events, sessionIDs: ["session-1"])
        }
    }
}

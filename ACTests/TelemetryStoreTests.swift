//
//  TelemetryStoreTests.swift
//  ACTests
//
//  Created by Codex on 13.04.26.
//

import Foundation
import Testing
@testable import AC

struct TelemetryStoreTests {

    @Test
    func startsSessionAndLoadsEvents() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ac-telemetry-tests-\(UUID().uuidString)", isDirectory: true)
        let store = TelemetryStore(rootURL: rootURL)
        let session = try await store.startSession(reason: "test")

        try await store.appendEvent(
            TelemetryEvent(
                id: "event-1",
                kind: .failure,
                timestamp: Date(timeIntervalSince1970: 10),
                sessionID: session.id,
                episodeID: nil,
                episode: nil,
                session: nil,
                observation: nil,
                evaluation: nil,
                modelInput: nil,
                modelOutput: nil,
                parsedOutput: nil,
                policy: nil,
                action: nil,
                reaction: nil,
                annotation: nil,
                failure: FailureRecord(domain: "test", message: "boom", evaluationID: nil)
            ),
            sessionID: session.id
        )

        let events = await store.loadEvents(sessionID: session.id)
        #expect(events.count == 2)
        #expect(events.last?.failure?.message == "boom")
    }

    @Test
    func pinnedSessionsSurviveCleanup() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ac-telemetry-tests-\(UUID().uuidString)", isDirectory: true)
        let store = TelemetryStore(rootURL: rootURL)
        let session = try await store.startSession(reason: "cleanup")

        let annotation = EpisodeAnnotation(
            id: "annotation-1",
            sessionID: session.id,
            episodeID: "episode-1",
            labels: [.goodNudge],
            note: "keep this",
            pinned: true,
            source: .human,
            createdAt: Date(timeIntervalSince1970: 10)
        )
        try await store.appendAnnotation(annotation, episode: nil)
        try await store.cleanupExpiredSessions(retentionDays: 0)

        let sessions = await store.listSessions()
        #expect(sessions.contains { $0.id == session.id })
    }
}

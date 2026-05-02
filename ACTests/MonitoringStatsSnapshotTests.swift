//
//  MonitoringStatsSnapshotTests.swift
//  ACTests
//
//  Created by Codex on 01.05.26.
//

import Foundation
import Testing
@testable import AC

@MainActor
struct MonitoringStatsSnapshotTests {

    @Test
    func aggregatesDecisionMixSkipCausesTokensAndProfiles() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ac-monitoring-stats-tests-\(UUID().uuidString)", isDirectory: true)
        let store = TelemetryStore(rootURL: rootURL)
        let session = try await store.startSession(reason: "stats")
        let now = Date()
        let timestamp = now.addingTimeInterval(-60)

        try await store.appendEvent(
            TelemetryEvent(
                id: "eval-1",
                kind: .evaluationRequested,
                timestamp: timestamp,
                sessionID: session.id,
                episodeID: nil,
                episode: nil,
                session: nil,
                observation: nil,
                evaluation: EvaluationRequestRecord(
                    evaluationID: "eval-1",
                    reason: "stable_context",
                    promptMode: "decision",
                    promptVersion: "v1"
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
            sessionID: session.id
        )

        try await store.appendEvent(
            TelemetryEvent(
                id: "out-1",
                kind: .modelOutputReceived,
                timestamp: timestamp,
                sessionID: session.id,
                episodeID: nil,
                episode: nil,
                session: nil,
                observation: nil,
                evaluation: nil,
                modelInput: nil,
                modelOutput: ModelOutputRecord(
                    evaluationID: "eval-1",
                    runtimePath: "/tmp/runtime",
                    modelIdentifier: "test-model",
                    promptMode: "decision",
                    runtimeOptions: nil,
                    stdoutArtifact: nil,
                    stderrArtifact: nil,
                    stdoutPreview: "{}",
                    stderrPreview: "",
                    tokenUsage: TokenUsageRecord(
                        promptTokens: 120,
                        completionTokens: 30,
                        totalTokens: 150,
                        cacheReadTokens: nil,
                        imageTokens: 40,
                        costUSD: nil,
                        estimated: false,
                        includesScreenshot: true
                    )
                ),
                parsedOutput: nil,
                policy: nil,
                action: nil,
                reaction: nil,
                annotation: nil,
                failure: nil
            ),
            sessionID: session.id
        )

        try await store.appendEvent(
            TelemetryEvent(
                id: "policy-1",
                kind: .policyDecided,
                timestamp: timestamp,
                sessionID: session.id,
                episodeID: nil,
                episode: nil,
                session: nil,
                observation: nil,
                evaluation: nil,
                modelInput: nil,
                modelOutput: nil,
                parsedOutput: nil,
                policy: PolicyDecisionRecord(
                    evaluationID: "eval-1",
                    model: ModelOutputParsedRecord(
                        assessment: .focused,
                        suggestedAction: .none,
                        confidence: 0.91,
                        reasonTags: ["allowed_work"],
                        nudge: nil,
                        abstainReason: nil
                    ),
                    strategy: nil,
                    ladderSignal: "none",
                    interventionSignal: nil,
                    allowIntervention: false,
                    allowEscalation: false,
                    blockReason: nil,
                    finalAction: TelemetryCompanionActionRecord(kind: .none, message: nil),
                    distractionBefore: TelemetryDistractionState(
                        stableSince: nil,
                        lastAssessment: nil,
                        consecutiveDistractedCount: 0,
                        nextEvaluationAt: nil
                    ),
                    distractionAfter: TelemetryDistractionState(
                        stableSince: nil,
                        lastAssessment: .focused,
                        consecutiveDistractedCount: 0,
                        nextEvaluationAt: nil
                    ),
                    activeProfileID: "coding",
                    activeProfileName: "Coding"
                ),
                action: nil,
                metric: nil,
                reaction: nil,
                annotation: nil,
                failure: nil
            ),
            sessionID: session.id
        )

        try await store.appendEvent(
            TelemetryEvent(
                id: "policy-2",
                kind: .policyDecided,
                timestamp: timestamp,
                sessionID: session.id,
                episodeID: nil,
                episode: nil,
                session: nil,
                observation: nil,
                evaluation: nil,
                modelInput: nil,
                modelOutput: nil,
                parsedOutput: nil,
                policy: PolicyDecisionRecord(
                    evaluationID: "eval-2",
                    model: ModelOutputParsedRecord(
                        assessment: .unclear,
                        suggestedAction: .abstain,
                        confidence: 0.45,
                        reasonTags: ["ambiguous"],
                        nudge: nil,
                        abstainReason: "need vision"
                    ),
                    strategy: nil,
                    ladderSignal: "none",
                    interventionSignal: nil,
                    allowIntervention: false,
                    allowEscalation: false,
                    blockReason: "unclear_assessment",
                    finalAction: TelemetryCompanionActionRecord(kind: .none, message: nil),
                    distractionBefore: TelemetryDistractionState(
                        stableSince: nil,
                        lastAssessment: nil,
                        consecutiveDistractedCount: 0,
                        nextEvaluationAt: nil
                    ),
                    distractionAfter: TelemetryDistractionState(
                        stableSince: nil,
                        lastAssessment: .unclear,
                        consecutiveDistractedCount: 0,
                        nextEvaluationAt: nil
                    ),
                    activeProfileID: "general",
                    activeProfileName: "General"
                ),
                action: nil,
                metric: nil,
                reaction: nil,
                annotation: nil,
                failure: nil
            ),
            sessionID: session.id
        )

        try await store.appendEvent(
            TelemetryEvent(
                id: "skip-idle",
                kind: .monitoringMetric,
                timestamp: timestamp,
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
                metric: MonitoringMetricRecord(
                    kind: .evaluationSkipped,
                    reason: "idle",
                    activeProfileID: "general",
                    activeProfileName: "General",
                    detail: nil
                ),
                reaction: nil,
                annotation: nil,
                failure: nil
            ),
            sessionID: session.id
        )

        try await store.appendEvent(
            TelemetryEvent(
                id: "skip-cache",
                kind: .monitoringMetric,
                timestamp: timestamp,
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
                metric: MonitoringMetricRecord(
                    kind: .evaluationSkipped,
                    reason: "same_title",
                    activeProfileID: "coding",
                    activeProfileName: "Coding",
                    detail: nil
                ),
                reaction: nil,
                annotation: nil,
                failure: nil
            ),
            sessionID: session.id
        )

        try await store.appendEvent(
            TelemetryEvent(
                id: "retry-1",
                kind: .monitoringMetric,
                timestamp: timestamp,
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
                metric: MonitoringMetricRecord(
                    kind: .visionRetried,
                    reason: "focused",
                    activeProfileID: "coding",
                    activeProfileName: "Coding",
                    detail: nil
                ),
                reaction: nil,
                annotation: nil,
                failure: nil
            ),
            sessionID: session.id
        )

        let snapshot = await MonitoringStatsSnapshot.load(from: store, window: .day)

        #expect(snapshot.callsPerHour == "0.0")
        #expect(snapshot.averageTokenSummary == "120 / 30 / 40")
        #expect(snapshot.visionAttachRate == "100%")
        #expect(snapshot.visionRetryCount == 1)
        #expect(snapshot.decisionMix.first(where: { $0.label == "focused" })?.value == "1 · 50%")
        #expect(snapshot.decisionMix.first(where: { $0.label == "unclear" })?.value == "1 · 50%")
        #expect(snapshot.decisionMix.first(where: { $0.label == "abstain action" })?.value == "1 · 50%")
        #expect(snapshot.skipCauses.first(where: { $0.label == "idle" })?.value == "1 · 50%")
        #expect(snapshot.skipCauses.first(where: { $0.label == "same_title" })?.value == "1 · 50%")
        #expect(snapshot.stageBreakdown.first(where: { $0.label == "decision" })?.value == "1x · avg 150 · img 40 · total 150")
        #expect(snapshot.profileBreakdown.first(where: { $0.label == "Coding" })?.value == "1x · F 1 / D 0 / U 0")
        #expect(snapshot.profileBreakdown.first(where: { $0.label == "General" })?.value == "1x · F 0 / D 0 / U 1")
    }
}

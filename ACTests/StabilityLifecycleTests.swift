//
//  StabilityLifecycleTests.swift
//  ACTests
//
//  Created by Codex on 11.05.26.
//

import Foundation
import Testing
@testable import AC

@MainActor
struct StabilityLifecycleTests {

    @Test
    func resetTransientStateClearsActiveContextBaseline() {
        let runtime = LocalModelRuntime()
        let algorithm = LLMMonitorAlgorithm(
            runtime: runtime,
            onlineModelService: OnlineModelService(),
            policyMemoryService: PolicyMemoryService(
                runtime: runtime,
                onlineModelService: OnlineModelService()
            )
        )
        let enteredAt = Date(timeIntervalSince1970: 2_000)
        let cachedDecision = CachedDecision(
            assessment: .focused,
            decidedAt: enteredAt,
            contextKey: "com.apple.dt.Xcode|main.swift"
        )

        var state = AlgorithmStateEnvelope()
        state.llmPolicy.currentContextKey = cachedDecision.contextKey
        state.llmPolicy.currentContextEnteredAt = enteredAt
        state.llmPolicy.distraction = DistractionMetadata(
            contextKey: cachedDecision.contextKey,
            stableSince: enteredAt,
            lastAssessment: .distracted,
            consecutiveDistractedCount: 2,
            nextEvaluationAt: enteredAt.addingTimeInterval(30)
        )
        state.llmPolicy.decisionCacheByContext[cachedDecision.contextKey] = cachedDecision

        algorithm.resetTransientState(&state)

        #expect(state.llmPolicy.currentContextKey == nil)
        #expect(state.llmPolicy.currentContextEnteredAt == nil)
        #expect(state.llmPolicy.distraction == DistractionMetadata())
        #expect(state.llmPolicy.decisionCacheByContext[cachedDecision.contextKey] == cachedDecision)
    }

    @Test
    func usageHistoryPrunesOldDaysAndEmptyEntries() {
        var state = ACState()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let calendar = Calendar(identifier: .gregorian)
        let keptDay = calendar.date(byAdding: .day, value: -(ACState.usageHistoryRetentionDays - 2), to: now)!
        let droppedDay = calendar.date(byAdding: .day, value: -(ACState.usageHistoryRetentionDays + 3), to: now)!

        state.usageByDay = [
            keptDay.acDayKey: ["Xcode": 600, "Idle": 0],
            droppedDay.acDayKey: ["Safari": 900],
            now.acDayKey: ["Mail": 0],
        ]

        state.pruneUsageHistory(now: now)

        #expect(state.usageByDay[droppedDay.acDayKey] == nil)
        #expect(state.usageByDay[now.acDayKey] == nil)
        #expect(state.usageByDay[keptDay.acDayKey] == ["Xcode": 600])
    }

    @Test
    func mergeBrainStatePreservesLifecycleFieldsOwnedByMonitoring() {
        let controller = AppController.makeForTesting(storageService: .temporary())
        let baseLastFullScreenCheckAt = Date(timeIntervalSince1970: 1_000)
        let resumedAt = Date(timeIntervalSince1970: 2_000)

        var base = controller.state
        base.lastFullScreenCheckAt = baseLastFullScreenCheckAt
        base.permissions = PermissionsSnapshot(screenRecording: .granted, accessibility: .granted)
        base.recurringNudges = [
            RecurringNudge(
                id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
                hour: 9,
                minute: 0,
                message: "Ship it."
            )
        ]
        controller.state = base

        var updated = base
        updated.permissions = PermissionsSnapshot(screenRecording: .denied, accessibility: .granted)
        updated.lastFullScreenCheckAt = resumedAt
        updated.recurringNudges[0].lastFiredAt = resumedAt
        updated.recentlyEndedSession = RecentlyEndedSession(
            name: "Deep Work",
            description: "Refactor monitoring",
            endedAt: resumedAt,
            goalSummary: "Finish the monitoring cleanup"
        )
        updated.hardEscalation = ActiveEscalation(
            appName: "Safari",
            bundleIdentifier: "com.apple.Safari",
            evaluationID: "eval-1",
            startedAt: resumedAt
        )

        controller.mergeBrainState(base: base, updated: updated)

        #expect(controller.state.permissions.screenRecording == .denied)
        #expect(controller.state.permissions.accessibility == .granted)
        #expect(controller.state.lastFullScreenCheckAt == resumedAt)
        #expect(controller.state.recurringNudges[0].lastFiredAt == resumedAt)
        #expect(controller.state.recentlyEndedSession == updated.recentlyEndedSession)
        #expect(controller.state.hardEscalation == updated.hardEscalation)
    }
}

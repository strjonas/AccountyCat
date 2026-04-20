//
//  BanditMonitoringAlgorithmTests.swift
//  ACTests
//

import Foundation
import Testing
@testable import AC

// MARK: - Stubs

private actor StubScreenStateExtractor: ScreenStateExtracting {
    let result: BanditScreenState?

    init(result: BanditScreenState?) {
        self.result = result
    }

    func extract(
        snapshot: AppSnapshot,
        goals: String,
        recentNudgeMessages: [String],
        runtimePath: String
    ) async -> BanditScreenState? {
        result
    }
}

/// Copywriter stub — returns a canned line tagged with the arm's tone so tests can
/// verify the bandit called it with the right arm.
private actor StubCopywriter: NudgeCopywriting {
    private(set) var lastArm: BanditArm?
    private let override: String?

    init(override: String? = nil) {
        self.override = override
    }

    func craftNudge(
        arm: BanditArm,
        request: NudgeCopywriteRequest,
        runtimePath: String
    ) async -> String? {
        lastArm = arm
        if let override { return override }
        return "crafted-\(arm.rawValue)"
    }
}

/// No-op copywriter — simulates the runtime being missing.
private actor FailingCopywriter: NudgeCopywriting {
    func craftNudge(
        arm: BanditArm,
        request: NudgeCopywriteRequest,
        runtimePath: String
    ) async -> String? {
        nil
    }
}

// MARK: - Tests

struct BanditMonitoringAlgorithmTests {

    // MARK: - Helpers

    private func makeAlgorithm(
        extractor: BanditScreenState? = nil,
        copywriter: any NudgeCopywriting = StubCopywriter(),
        cooldown: BanditCooldown = BanditCooldown()
    ) -> BanditMonitoringAlgorithm {
        BanditMonitoringAlgorithm(
            screenStateExtractor: StubScreenStateExtractor(result: extractor),
            nudgeCopywriter: copywriter,
            cooldown: cooldown
        )
    }

    private func makeInput(
        evaluationID: String = "eval-1",
        state: AlgorithmStateEnvelope = AlgorithmStateEnvelope(),
        now: Date = Date(timeIntervalSince1970: 5_000)
    ) -> MonitoringDecisionInput {
        MonitoringDecisionInput(
            now: now,
            evaluationID: evaluationID,
            snapshot: makeSnapshot(),
            goals: "code",
            recentActions: [],
            heuristics: makeHeuristics(),
            memory: "",
            policyMemory: PolicyMemory(),
            runtimeOverride: nil,
            configuration: monitoringConfig(),
            algorithmState: state
        )
    }

    private func monitoringConfig() -> MonitoringConfiguration {
        var config = MonitoringConfiguration()
        config.algorithmID = MonitoringConfiguration.banditAlgorithmID
        return config
    }

    private func makeSnapshot() -> AppSnapshot {
        AppSnapshot(
            bundleIdentifier: "com.example.Social",
            appName: "Social",
            windowTitle: "Feed",
            recentSwitches: [],
            perAppDurations: [],
            screenshotArtifact: ArtifactRef(
                id: "shot",
                kind: .screenshotOriginal,
                relativePath: "shot.png",
                sha256: nil,
                byteCount: 0,
                width: nil,
                height: nil,
                createdAt: Date(timeIntervalSince1970: 1)
            ),
            screenshotThumbnail: nil,
            screenshotPath: "/tmp/shot.png",
            idle: false,
            timestamp: Date(timeIntervalSince1970: 1)
        )
    }

    private func makeHeuristics() -> TelemetryHeuristicSnapshot {
        TelemetryHeuristicSnapshot(
            clearlyProductive: false,
            browser: false,
            helpfulWindowTitle: false,
            periodicVisualReason: nil
        )
    }

    private func offTaskScreenState(withNudge nudge: String? = "Back to work!") -> BanditScreenState {
        BanditScreenState(
            appCategory: .social,
            productivityScore: 0.1,
            onTask: false,
            contentSummary: "social media feed",
            confidence: 0.9,
            candidateNudge: nudge
        )
    }

    // MARK: - Plan tests

    @Test func evaluationPlanRespectsStabilityWindow() {
        let algorithm = makeAlgorithm()
        var state = AlgorithmStateEnvelope()
        let context = FrontmostContext(
            bundleIdentifier: "com.example.Social",
            appName: "Social",
            windowTitle: "Feed"
        )
        let start = Date(timeIntervalSince1970: 1_000)

        _ = algorithm.noteContext(context.contextKey, at: start, state: &state)

        let before = algorithm.evaluationPlan(
            state: &state, context: context,
            heuristics: makeHeuristics(), configuration: monitoringConfig(),
            now: start.addingTimeInterval(19)
        )
        let after = algorithm.evaluationPlan(
            state: &state, context: context,
            heuristics: makeHeuristics(), configuration: monitoringConfig(),
            now: start.addingTimeInterval(20)
        )

        #expect(before.shouldEvaluate == false)
        #expect(after.shouldEvaluate == true)
        #expect(after.reason == "bandit_stable_context")
    }

    @Test func evaluationPlanBlocksWhileCooldownActive() {
        let algorithm = makeAlgorithm(
            cooldown: BanditCooldown(stabilityWindow: 20, minInterInterventionInterval: 60)
        )
        var state = AlgorithmStateEnvelope()
        let context = FrontmostContext(
            bundleIdentifier: "com.example.Social",
            appName: "Social",
            windowTitle: "Feed"
        )
        let start = Date(timeIntervalSince1970: 1_000)

        _ = algorithm.noteContext(context.contextKey, at: start, state: &state)
        state.banditFocus.lastInterventionByContext[context.contextKey] = start.addingTimeInterval(20)

        let within = algorithm.evaluationPlan(
            state: &state, context: context,
            heuristics: makeHeuristics(), configuration: monitoringConfig(),
            now: start.addingTimeInterval(30)
        )
        let after = algorithm.evaluationPlan(
            state: &state, context: context,
            heuristics: makeHeuristics(), configuration: monitoringConfig(),
            now: start.addingTimeInterval(90)
        )

        #expect(within.shouldEvaluate == false)
        #expect(after.shouldEvaluate == true)
    }

    // MARK: - Evaluate tests

    @Test func evaluateWithOffTaskFiresCopywriterCraftedNudge() async {
        // Fresh engine explores — at least one intervention arm has UCB > 0 on non-zero features.
        let copywriter = StubCopywriter(override: "Hey, back to it!")
        let algorithm = makeAlgorithm(extractor: offTaskScreenState(), copywriter: copywriter)
        let result = await algorithm.evaluate(input: makeInput())

        #expect(result.policy.action == .showNudge("Hey, back to it!"))
        #expect(result.execution.algorithmID == MonitoringConfiguration.banditAlgorithmID)
        #expect(result.updatedAlgorithmState.banditFocus.pendingInterventionsByEvaluationID["eval-1"] != nil)
        #expect(result.policy.record.ladderSignal == "none")
        #expect(result.policy.record.interventionSignal != nil)
    }

    @Test func evaluateFallsBackToCandidateNudgeWhenCopywriterFails() async {
        let algorithm = makeAlgorithm(
            extractor: offTaskScreenState(withNudge: "VLM fallback"),
            copywriter: FailingCopywriter()
        )
        let result = await algorithm.evaluate(input: makeInput())

        // Whatever arm the engine picked (supportive or challenging), the text should be the VLM fallback.
        if case let .showNudge(text) = result.policy.action {
            #expect(text == "VLM fallback")
        } else if case .showOverlay(_) = result.policy.action {
            // Overlay arms don't use the copywriter — still a valid outcome.
        } else {
            Issue.record("Expected an intervention on fresh-engine off-task input but got \(result.policy.action)")
        }
    }

    @Test func evaluateWithFailedExtractionYieldsNoAction() async {
        // Extractor returns nil. The bandit no longer falls back to the LLM path —
        // it just skips this tick.
        let algorithm = makeAlgorithm(extractor: nil)
        let result = await algorithm.evaluate(input: makeInput())

        #expect(result.policy.action == .none)
        #expect(result.policy.record.blockReason == "extraction_failed")
        #expect(result.execution.algorithmID == MonitoringConfiguration.banditAlgorithmID)
    }

    // MARK: - Reward tests

    @Test func observeRewardUpdatesEngineAndClearsPendingState() async {
        let algorithm = makeAlgorithm(extractor: offTaskScreenState())
        let input = makeInput(evaluationID: "eval-reward")

        let result = await algorithm.evaluate(input: input)
        #expect(result.updatedAlgorithmState.banditFocus.pendingInterventionsByEvaluationID["eval-reward"] != nil)

        var state = result.updatedAlgorithmState
        let engineBefore = state.banditFocus.engine
        let firedArm = state.banditFocus.pendingInterventionsByEvaluationID["eval-reward"]?.arm

        let signal = MonitoringRewardSignal(
            evaluationID: "eval-reward",
            kind: .nudgeRatedPositive,
            value: 1.0
        )
        algorithm.observeReward(signal, state: &state)

        #expect(state.banditFocus.pendingInterventionsByEvaluationID["eval-reward"] == nil)
        #expect(state.banditFocus.lastNudgeWasPositive == true)
        if let firedArm {
            // Only the fired arm's weights should change; other arms should be untouched.
            #expect(state.banditFocus.engine.arms[firedArm.rawValue] != engineBefore.arms[firedArm.rawValue])
        }
    }

    @Test func observeRewardIsNoOpWithoutPendingNudge() {
        let algorithm = makeAlgorithm()
        var state = AlgorithmStateEnvelope()
        let engineBefore = state.banditFocus.engine

        let signal = MonitoringRewardSignal(
            evaluationID: "non-existent",
            kind: .nudgeRatedPositive,
            value: 1.0
        )
        algorithm.observeReward(signal, state: &state)

        #expect(state.banditFocus.engine == engineBefore)
    }

    @Test func observeRewardIsNoOpWhenIDDoesNotMatch() async {
        let algorithm = makeAlgorithm(extractor: offTaskScreenState())
        let result = await algorithm.evaluate(input: makeInput(evaluationID: "eval-A"))

        var state = result.updatedAlgorithmState
        let engineBefore = state.banditFocus.engine

        let signal = MonitoringRewardSignal(
            evaluationID: "eval-B",
            kind: .nudgeRatedPositive,
            value: 1.0
        )
        algorithm.observeReward(signal, state: &state)

        #expect(state.banditFocus.engine == engineBefore)
        #expect(state.banditFocus.pendingInterventionsByEvaluationID["eval-A"] != nil)
    }

    @Test func observeRewardTargetsOnlyMatchingPendingIntervention() {
        let algorithm = makeAlgorithm()
        var state = AlgorithmStateEnvelope()
        state.banditFocus.pendingInterventionsByEvaluationID = [
            "eval-A": BanditPendingIntervention(
                context: BanditFeatureVector(values: Array(repeating: 0.1, count: BanditFeatureVector.dimension)),
                issuedAt: Date(timeIntervalSince1970: 10),
                arm: .supportiveNudge
            ),
            "eval-B": BanditPendingIntervention(
                context: BanditFeatureVector(values: Array(repeating: 0.2, count: BanditFeatureVector.dimension)),
                issuedAt: Date(timeIntervalSince1970: 20),
                arm: .challengingNudge
            ),
        ]

        algorithm.observeReward(
            MonitoringRewardSignal(
                evaluationID: "eval-A",
                kind: .nudgeRatedPositive,
                value: 1.0
            ),
            state: &state
        )

        #expect(state.banditFocus.pendingInterventionsByEvaluationID["eval-A"] == nil)
        #expect(state.banditFocus.pendingInterventionsByEvaluationID["eval-B"] != nil)
        #expect(state.banditFocus.pendingInterventionsByEvaluationID.count == 1)
    }

    @Test func resetStateClearsBanditSlice() {
        let algorithm = makeAlgorithm()
        var state = AlgorithmStateEnvelope()
        state.banditFocus.lastNudgeWasPositive = true
        state.banditFocus.lastInterventionByContext["foo"] = Date()

        algorithm.resetState(&state)

        #expect(state.banditFocus == BanditFocusAlgorithmState())
    }

    @Test func cooldownBlocksRepeatInterventionInSameContext() async {
        let algorithm = makeAlgorithm(
            extractor: offTaskScreenState(),
            cooldown: BanditCooldown(stabilityWindow: 20, minInterInterventionInterval: 60)
        )
        let start = Date(timeIntervalSince1970: 1_000)
        let first = await algorithm.evaluate(input: makeInput(evaluationID: "eval-1", now: start))
        #expect(first.policy.action != .none)

        // 10 seconds later — same context, cooldown still active → arm must be blocked.
        let second = await algorithm.evaluate(
            input: makeInput(
                evaluationID: "eval-2",
                state: first.updatedAlgorithmState,
                now: start.addingTimeInterval(10)
            )
        )
        #expect(second.policy.action == .none)
        #expect(second.policy.record.blockReason == "bandit_cooldown")
    }
}

//
//  LLMFocusAlgorithmTests.swift
//  ACTests
//

import Foundation
import Testing
@testable import AC

private actor StubMonitoringLLMClient: MonitoringLLMEvaluating {
    let result: LLMEvaluationResult

    init(result: LLMEvaluationResult) {
        self.result = result
    }

    func evaluate(
        snapshot: AppSnapshot,
        goals: String,
        recentActions: [ActionRecord],
        distraction: DistractionMetadata,
        heuristics: TelemetryHeuristicSnapshot,
        memory: String,
        promptProfileID: String,
        runtimeOverride: String?
    ) async -> LLMEvaluationResult {
        var result = result
        result.promptProfileID = promptProfileID
        return result
    }
}

struct LLMFocusAlgorithmTests {

    @Test
    func respectsStableWindowBeforeEvaluating() {
        let algorithm = LLMFocusAlgorithm(
            monitoringLLMClient: StubMonitoringLLMClient(result: makeEvaluationResult(finalDecision: .unclear))
        )
        var state = AlgorithmStateEnvelope()
        let context = FrontmostContext(
            bundleIdentifier: "com.apple.TextEdit",
            appName: "TextEdit",
            windowTitle: "notes"
        )
        let start = Date(timeIntervalSince1970: 1_000)

        _ = algorithm.noteContext(context.contextKey, at: start, state: &state)

        let beforeWindow = algorithm.evaluationPlan(
            state: &state,
            context: context,
            heuristics: MonitoringHeuristics.telemetrySnapshot(for: context),
            configuration: MonitoringConfiguration(),
            now: start.addingTimeInterval(19)
        )
        let afterWindow = algorithm.evaluationPlan(
            state: &state,
            context: context,
            heuristics: MonitoringHeuristics.telemetrySnapshot(for: context),
            configuration: MonitoringConfiguration(),
            now: start.addingTimeInterval(20)
        )

        #expect(beforeWindow.shouldEvaluate == false)
        #expect(afterWindow.shouldEvaluate == true)
        #expect(afterWindow.reason == "stable_context")
    }

    @Test
    func periodicVisualChecksUsePromptProfileWithoutTouchingLadder() {
        let algorithm = LLMFocusAlgorithm(
            monitoringLLMClient: StubMonitoringLLMClient(result: makeEvaluationResult(finalDecision: .unclear))
        )
        var state = AlgorithmStateEnvelope()
        let context = FrontmostContext(
            bundleIdentifier: "com.google.Chrome",
            appName: "Google Chrome",
            windowTitle: "Feed"
        )
        let now = Date(timeIntervalSince1970: 2_000)

        _ = algorithm.noteContext(context.contextKey, at: now, state: &state)
        let plan = algorithm.evaluationPlan(
            state: &state,
            context: context,
            heuristics: MonitoringHeuristics.telemetrySnapshot(for: context),
            configuration: MonitoringConfiguration(),
            now: now
        )

        #expect(plan.shouldEvaluate == true)
        #expect(plan.reason == "periodic_visual_check")
        #expect(plan.visualCheckReason == "browser")
        #expect(state.llmFocus.lastVisualCheckByContext.isEmpty == false)
    }

    @Test
    func turnsConfidentDistractedDecisionIntoFirstNudge() async {
        let decision = LLMDecision(
            assessment: .distracted,
            suggestedAction: .nudge,
            confidence: 0.95,
            reasonTags: ["scrolling"],
            nudge: "back to it",
            abstainReason: nil
        )
        let algorithm = LLMFocusAlgorithm(
            monitoringLLMClient: StubMonitoringLLMClient(result: makeEvaluationResult(finalDecision: decision))
        )
        let result = await algorithm.evaluate(
            input: MonitoringDecisionInput(
                now: Date(timeIntervalSince1970: 3_000),
                evaluationID: "eval-1",
                snapshot: makeSnapshot(),
                goals: "code",
                recentActions: [],
                heuristics: makeHeuristics(),
                memory: "",
                runtimeOverride: nil,
                configuration: MonitoringConfiguration(),
                algorithmState: AlgorithmStateEnvelope()
            )
        )

        #expect(result.policy.action == .showNudge("back to it"))
        #expect(result.updatedAlgorithmState.llmFocus.distraction.consecutiveDistractedCount == 1)
        #expect(result.execution.algorithmID == MonitoringConfiguration.defaultAlgorithmID)
        #expect(result.execution.promptProfileID == MonitoringConfiguration.defaultPromptProfileID)
    }

    @Test
    func blocksOverlayUnlessDecisionExplicitlyRequestsIt() async {
        let decision = LLMDecision(
            assessment: .distracted,
            suggestedAction: .nudge,
            confidence: 0.95,
            reasonTags: ["extended_distraction"],
            nudge: "back to it",
            abstainReason: nil
        )
        var state = AlgorithmStateEnvelope()
        state.llmFocus.distraction = DistractionMetadata(
            contextKey: "com.google.Chrome|feed",
            stableSince: Date(timeIntervalSince1970: 1),
            lastAssessment: .distracted,
            consecutiveDistractedCount: 3,
            nextEvaluationAt: Date(timeIntervalSince1970: 2)
        )
        let algorithm = LLMFocusAlgorithm(
            monitoringLLMClient: StubMonitoringLLMClient(result: makeEvaluationResult(finalDecision: decision))
        )

        let result = await algorithm.evaluate(
            input: MonitoringDecisionInput(
                now: Date(timeIntervalSince1970: 4_000),
                evaluationID: "eval-2",
                snapshot: makeSnapshot(),
                goals: "code",
                recentActions: [],
                heuristics: makeHeuristics(),
                memory: "",
                runtimeOverride: nil,
                configuration: MonitoringConfiguration(),
                algorithmState: state
            )
        )

        #expect(result.policy.action == .none)
        #expect(result.policy.record.allowEscalation == false)
        #expect(result.policy.record.blockReason == "model_did_not_request_overlay")
    }

    private func makeSnapshot() -> AppSnapshot {
        AppSnapshot(
            bundleIdentifier: "com.google.Chrome",
            appName: "Google Chrome",
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
            browser: true,
            helpfulWindowTitle: true,
            periodicVisualReason: "browser"
        )
    }

    private func makeEvaluationResult(finalDecision: LLMDecision?) -> LLMEvaluationResult {
        LLMEvaluationResult(
            runtimePath: "/tmp/runtime",
            modelIdentifier: LocalModelRuntime.defaultModelIdentifier,
            promptProfileID: MonitoringConfiguration.defaultPromptProfileID,
            promptProfileVersion: "focus_default_v2",
            attempts: [],
            finalDecision: finalDecision,
            failureMessage: finalDecision == nil ? "no_usable_decision" : nil
        )
    }
}

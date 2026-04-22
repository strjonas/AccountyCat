import Foundation
import Testing
@testable import AC

@MainActor
struct LLMPolicyAlgorithmTests {

    @Test
    func titleOnlyPipelineUsesSplitCopyAndStoresRecentNudge() async throws {
        let runtimeFixture = try FakeRuntimeFixture()
        let algorithm = makeAlgorithm()
        let now = Date(timeIntervalSince1970: 5_000)

        let result = await algorithm.evaluate(
            input: makeDecisionInput(
                now: now,
                evaluationID: "eval-nudge",
                runtimeOverride: runtimeFixture.runtimePath
            )
        )

        #expect(result.policy.action == .showNudge("Back to the build."))
        #expect(result.decision.nudge == "Back to the build.")
        #expect(result.evaluation.attempts.map(\.promptMode) == [
            "perception_title",
            "decision",
            "nudge_copy",
        ])
        #expect(result.updatedAlgorithmState.llmPolicy.recentNudgeMessages == ["Back to the build."])
        #expect(result.updatedAlgorithmState.llmPolicy.lastNudgeAt == now)
        #expect(result.updatedAlgorithmState.llmPolicy.distraction.consecutiveDistractedCount == 1)
    }

    @Test
    func overlayDecisionStartsAppealSession() async throws {
        var outputs = FakeRuntimeOutputSet()
        outputs.decision = """
        {"assessment":"distracted","suggested_action":"overlay","confidence":0.97,"reason_tags":["repeated_distraction"],"overlay_headline":"Pause now.","overlay_body":"This still looks off-track.","overlay_prompt":"Why should I let you continue?","submit_button_title":"Explain","secondary_button_title":"Return"}
        """
        let runtimeFixture = try FakeRuntimeFixture(outputs: outputs)
        let algorithm = makeAlgorithm()
        let now = Date(timeIntervalSince1970: 6_000)

        let result = await algorithm.evaluate(
            input: makeDecisionInput(
                now: now,
                evaluationID: "eval-overlay",
                runtimeOverride: runtimeFixture.runtimePath
            )
        )

        if case let .showOverlay(presentation) = result.policy.action {
            #expect(presentation.headline == "Pause now.")
            #expect(presentation.body == "This still looks off-track.")
            #expect(presentation.prompt == "Why should I let you continue?")
            #expect(presentation.submitButtonTitle == "Explain")
            #expect(presentation.secondaryButtonTitle == "Return")
            #expect(presentation.evaluationID == "eval-overlay")
        } else {
            Issue.record("Expected an overlay action but got \(result.policy.action)")
        }

        #expect(result.evaluation.attempts.map(\.promptMode) == [
            "perception_title",
            "decision",
        ])
        #expect(result.updatedAlgorithmState.llmPolicy.activeAppeal?.evaluationID == "eval-overlay")
        #expect(result.updatedAlgorithmState.llmPolicy.lastOverlayAt == now)
    }

    @Test
    func overlayDecisionFallsBackToDefaultPresentationWhenCopyIsMissing() async throws {
        var outputs = FakeRuntimeOutputSet()
        outputs.decision = """
        {"assessment":"distracted","suggested_action":"overlay","confidence":0.96,"reason_tags":["repeated_distraction"]}
        """
        let runtimeFixture = try FakeRuntimeFixture(outputs: outputs)
        let algorithm = makeAlgorithm()
        let now = Date(timeIntervalSince1970: 7_000)

        let result = await algorithm.evaluate(
            input: makeDecisionInput(
                now: now,
                evaluationID: "eval-overlay-cooldown",
                runtimeOverride: runtimeFixture.runtimePath
            )
        )

        if case let .showOverlay(presentation) = result.policy.action {
            #expect(presentation.headline == "Pause for a second.")
            #expect(presentation.body == "This still looks off-track in Google Chrome.")
            #expect(presentation.prompt == "Why should I let you continue on this?")
            #expect(presentation.submitButtonTitle == "Submit")
            #expect(presentation.secondaryButtonTitle == "Back to work")
        } else {
            Issue.record("Expected fallback overlay presentation but got \(result.policy.action)")
        }

        #expect(result.policy.record.blockReason == nil)
        #expect(result.updatedAlgorithmState.llmPolicy.activeAppeal?.evaluationID == "eval-overlay-cooldown")
    }

    @Test
    func appealReviewAppliesPolicyMemoryUpdateAndClearsSessionWhenAllowed() async throws {
        var outputs = FakeRuntimeOutputSet()
        outputs.appealReview = """
        {"decision":"allow","message":"That sounds directly useful to the task."}
        """
        outputs.policyMemory = """
        {"operations":[{"type":"add_rule","rule":{"id":"appeal-allow","kind":"allow","summary":"Allow this task context when the user explains the work relevance.","source":"appeal","createdAt":"2026-04-21T10:00:00Z","updatedAt":"2026-04-21T10:00:00Z","priority":95,"scope":{"appName":"Google Chrome","titleContains":["Docs"]},"schedule":{"startHour":null,"endHour":null,"weekdays":[],"expiresAt":null},"allowedTopics":["documentation"],"disallowedTopics":[],"maxMinutesPerDay":null,"tonePreference":null,"active":true}}]}
        """
        let runtimeFixture = try FakeRuntimeFixture(outputs: outputs)
        let runtime = LocalModelRuntime()
        let algorithm = LLMPolicyAlgorithm(
            runtime: runtime,
            policyMemoryService: PolicyMemoryService(runtime: runtime)
        )
        let now = Date(timeIntervalSince1970: 8_000)
        var state = AlgorithmStateEnvelope()
        state.llmPolicy.activeAppeal = MonitoringAppealSession(
            evaluationID: "eval-appeal",
            contextKey: "com.google.Chrome|Docs",
            appName: "Google Chrome",
            prompt: "Why should I let you continue?",
            createdAt: now.addingTimeInterval(-30),
            lastSubmittedAt: nil,
            lastResult: nil
        )
        state.llmPolicy.distraction = DistractionMetadata(
            contextKey: "com.google.Chrome|Docs",
            stableSince: now.addingTimeInterval(-300),
            lastAssessment: .distracted,
            consecutiveDistractedCount: 2,
            nextEvaluationAt: nil
        )

        let result = await algorithm.reviewAppeal(
            input: makeAppealInput(
                now: now,
                runtimeOverride: runtimeFixture.runtimePath,
                state: state
            )
        )

        #expect(result?.result == AppealReviewResult(
            decision: .allow,
            message: "That sounds directly useful to the task."
        ))
        #expect(result?.evaluation.attempts.map(\.promptMode) == ["appeal_review"])
        #expect(result?.updatedPolicyMemory.rules.contains(where: { $0.id == "appeal-allow" }) == true)
        #expect(result?.updatedAlgorithmState.llmPolicy.activeAppeal == nil)
        #expect(result?.updatedAlgorithmState.llmPolicy.distraction.lastAssessment == .unclear)
        #expect(result?.updatedAlgorithmState.llmPolicy.distraction.nextEvaluationAt == now.addingTimeInterval(45))
    }

    private func makeAlgorithm() -> LLMPolicyAlgorithm {
        let runtime = LocalModelRuntime()
        return LLMPolicyAlgorithm(
            runtime: runtime,
            policyMemoryService: PolicyMemoryService(runtime: runtime)
        )
    }

    private func makeDecisionInput(
        now: Date,
        evaluationID: String,
        runtimeOverride: String,
        state: AlgorithmStateEnvelope? = nil
    ) -> MonitoringDecisionInput {
        var configuration = MonitoringConfiguration()
        configuration.pipelineProfileID = "title_only_default"
        let algorithmState = state ?? AlgorithmStateEnvelope()

        return MonitoringDecisionInput(
            now: now,
            evaluationID: evaluationID,
            snapshot: makeSnapshot(now: now),
            goals: "Ship AC and stay focused on engineering work.",
            recentActions: [],
            heuristics: makeHeuristics(),
            memory: "Keep social media short during focused work.",
            policyMemory: PolicyMemory(),
            runtimeOverride: runtimeOverride,
            configuration: configuration,
            algorithmState: algorithmState
        )
    }

    private func makeAppealInput(
        now: Date,
        runtimeOverride: String,
        state: AlgorithmStateEnvelope
    ) -> MonitoringAppealReviewInput {
        var configuration = MonitoringConfiguration()
        configuration.pipelineProfileID = "title_only_default"

        return MonitoringAppealReviewInput(
            now: now,
            appealText: "This docs tab is directly needed to finish the feature.",
            snapshot: makeSnapshot(now: now),
            goals: "Ship AC and stay focused on engineering work.",
            recentActions: [],
            memory: "Keep social media short during focused work.",
            policyMemory: PolicyMemory(),
            configuration: configuration,
            algorithmState: state,
            runtimeOverride: runtimeOverride
        )
    }

    private func makeSnapshot(now: Date) -> AppSnapshot {
        AppSnapshot(
            bundleIdentifier: "com.google.Chrome",
            appName: "Google Chrome",
            windowTitle: "Docs",
            recentSwitches: [
                AppSwitchRecord(
                    fromAppName: "Xcode",
                    toAppName: "Google Chrome",
                    toWindowTitle: "Docs",
                    timestamp: now.addingTimeInterval(-15)
                ),
            ],
            perAppDurations: [
                AppUsageRecord(appName: "Google Chrome", seconds: 900),
                AppUsageRecord(appName: "Xcode", seconds: 3_600),
            ],
            screenshotArtifact: nil,
            screenshotThumbnail: nil,
            screenshotPath: nil,
            idle: false,
            timestamp: now
        )
    }

    private func makeHeuristics() -> TelemetryHeuristicSnapshot {
        TelemetryHeuristicSnapshot(
            clearlyProductive: false,
            browser: true,
            helpfulWindowTitle: true,
            periodicVisualReason: nil
        )
    }
}

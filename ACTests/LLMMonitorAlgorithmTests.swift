import Foundation
import Testing
@testable import AC

@MainActor
struct LLMMonitorAlgorithmTests {

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
            #expect(presentation.prompt == "This looks a bit off-track — what's going on?")
            #expect(presentation.submitButtonTitle == "Explain")
            #expect(presentation.secondaryButtonTitle == "Back to work")
        } else {
            Issue.record("Expected fallback overlay presentation but got \(result.policy.action)")
        }

        #expect(result.policy.record.blockReason == nil)
        #expect(result.updatedAlgorithmState.llmPolicy.activeAppeal?.evaluationID == "eval-overlay-cooldown")
    }

    @Test
    func focusedDecisionSchedulesLongFollowUpInsteadOfClearingCadence() async throws {
        var outputs = FakeRuntimeOutputSet()
        outputs.decision = """
        {"assessment":"focused","suggested_action":"none","confidence":0.88,"reason_tags":["allowed_work"]}
        """
        let runtimeFixture = try FakeRuntimeFixture(outputs: outputs)
        let algorithm = makeAlgorithm()
        let now = Date(timeIntervalSince1970: 7_500)

        let result = await algorithm.evaluate(
            input: makeDecisionInput(
                now: now,
                evaluationID: "eval-focused",
                runtimeOverride: runtimeFixture.runtimePath
            )
        )

        #expect(result.policy.action == .none)
        #expect(result.updatedAlgorithmState.llmPolicy.distraction.lastAssessment == .focused)
        #expect(result.updatedAlgorithmState.llmPolicy.distraction.nextEvaluationAt == now.addingTimeInterval(5 * 60))
        #expect(result.updatedAlgorithmState.llmPolicy.focusSignal.driftEMA < 0.2)
    }

    @Test
    func lowConfidenceDistractedDecisionIsSuppressedAsUnclear() async throws {
        var outputs = FakeRuntimeOutputSet()
        outputs.decision = """
        {"assessment":"distracted","suggested_action":"nudge","confidence":0.42,"reason_tags":["maybe_social"],"nudge":"Back to it."}
        """
        let runtimeFixture = try FakeRuntimeFixture(outputs: outputs)
        let algorithm = makeAlgorithm()
        let now = Date(timeIntervalSince1970: 7_600)

        let result = await algorithm.evaluate(
            input: makeDecisionInput(
                now: now,
                evaluationID: "eval-low-confidence",
                runtimeOverride: runtimeFixture.runtimePath
            )
        )

        #expect(result.policy.action == .none)
        #expect(result.decision.assessment == .unclear)
        #expect(result.decision.suggestedAction == .abstain)
        #expect(result.decision.reasonTags.contains("low_confidence_distracted"))
        #expect(result.policy.record.blockReason == "unclear_assessment")
        #expect(result.updatedAlgorithmState.llmPolicy.distraction.consecutiveDistractedCount == 0)
    }

    @Test
    func cadenceModeControlsInitialStableContextDelay() {
        let algorithm = makeAlgorithm()
        let context = FrontmostContext(
            bundleIdentifier: "com.google.Chrome",
            appName: "Google Chrome",
            windowTitle: "Docs"
        )
        let start = Date(timeIntervalSince1970: 7_700)
        var state = AlgorithmStateEnvelope()
        _ = algorithm.noteContext(context.contextKey, at: start, state: &state)

        var gentle = MonitoringConfiguration()
        gentle.cadenceMode = .gentle
        gentle.pipelineProfileID = "title_only_default"
        let gentlePlan = algorithm.evaluationPlan(
            state: &state,
            context: context,
            heuristics: makeHeuristics(),
            policyMemory: PolicyMemory(),
            configuration: gentle,
            now: start.addingTimeInterval(30)
        )

        var sharp = MonitoringConfiguration()
        sharp.cadenceMode = .sharp
        sharp.pipelineProfileID = "title_only_default"
        var sharpState = AlgorithmStateEnvelope()
        _ = algorithm.noteContext(context.contextKey, at: start, state: &sharpState)
        let sharpPlan = algorithm.evaluationPlan(
            state: &sharpState,
            context: context,
            heuristics: makeHeuristics(),
            policyMemory: PolicyMemory(),
            configuration: sharp,
            now: start.addingTimeInterval(30)
        )

        #expect(gentlePlan.shouldEvaluate == false)
        #expect(sharpPlan.shouldEvaluate == true)
    }

    @Test
    func recentExplicitAllowanceOverrideShortCircuitsDistractingDecision() async throws {
        let runtimeFixture = try FakeRuntimeFixture()
        let algorithm = makeAlgorithm()
        let now = try #require(makeLocalPromptDate("2026-04-23 16:15"))

        let result = await algorithm.evaluate(
            input: makeDecisionInput(
                now: now,
                evaluationID: "eval-allow-override",
                runtimeOverride: runtimeFixture.runtimePath,
                snapshot: makeSnapshot(
                    now: now,
                    windowTitle: "Home / X"
                ),
                memory: """
                [2026-04-23 16:05] Do not allow use of X.com today.
                [2026-04-23 16:06] Nudge user if they visit X.com in the next hour.
                """,
                recentUserMessages: [
                    "[2026-04-23 16:10] the next 1 hour x.com is okay",
                ]
            )
        )

        #expect(result.policy.action == .none)
        #expect(result.decision.assessment == .focused)
        #expect(result.decision.reasonTags == ["recent_allow_override"])
        #expect(result.policy.record.blockReason == "recent_allow_override")
        #expect(result.evaluation.attempts.isEmpty)
        #expect(result.updatedAlgorithmState.llmPolicy.distraction.lastAssessment == .focused)
        #expect(result.updatedAlgorithmState.llmPolicy.distraction.nextEvaluationAt == now.addingTimeInterval(5 * 60))
    }

    @Test
    func plainLanguageAllowForNowOverridesOlderMemoryBlock() async throws {
        let runtimeFixture = try FakeRuntimeFixture()
        let algorithm = makeAlgorithm()
        let now = try #require(makeLocalPromptDate("2026-04-25 14:15"))

        let result = await algorithm.evaluate(
            input: makeDecisionInput(
                now: now,
                evaluationID: "eval-allow-for-now",
                runtimeOverride: runtimeFixture.runtimePath,
                snapshot: makeSnapshot(
                    now: now,
                    windowTitle: "Instagram"
                ),
                memory: """
                [2026-04-25 12:00] do not allow instagram
                """,
                recentUserMessages: [
                    "[2026-04-25 14:10] allow instagram for now",
                ]
            )
        )

        #expect(result.policy.action == .none)
        #expect(result.decision.assessment == .focused)
        #expect(result.decision.reasonTags == ["recent_allow_override"])
        #expect(result.policy.record.blockReason == "recent_allow_override")
        #expect(result.evaluation.attempts.isEmpty)
    }

    @Test
    func noInterventionLanguageForCurrentAppShortCircuitsDecision() async throws {
        let runtimeFixture = try FakeRuntimeFixture()
        let algorithm = makeAlgorithm()
        let now = try #require(makeLocalPromptDate("2026-04-25 14:28"))

        let result = await algorithm.evaluate(
            input: makeDecisionInput(
                now: now,
                evaluationID: "eval-never-flag-instagram",
                runtimeOverride: runtimeFixture.runtimePath,
                snapshot: makeSnapshot(
                    now: now,
                    windowTitle: "(1) Instagram"
                ),
                memory: """
                [2026-04-25 14:13] Never again flag Instagram as a distraction.
                """,
                recentUserMessages: [
                    "[2026-04-25 14:01] DO NOT DISTRUB ME ON INSTAGRAM",
                    "[2026-04-25 14:13] never again flag instagram as a distraction",
                ]
            )
        )

        #expect(result.policy.action == .none)
        #expect(result.decision.assessment == .focused)
        #expect(result.decision.reasonTags == ["recent_allow_override"])
        #expect(result.policy.record.blockReason == "recent_allow_override")
        #expect(result.evaluation.attempts.isEmpty)
    }

    @Test
    func repeatedMatchingNudgesEscalateDistractedNudgeDecisionToOverlay() async throws {
        let runtimeFixture = try FakeRuntimeFixture()
        let algorithm = makeAlgorithm()
        let now = try #require(makeLocalPromptDate("2026-04-25 10:52"))

        let result = await algorithm.evaluate(
            input: makeDecisionInput(
                now: now,
                evaluationID: "eval-repeated-instagram",
                runtimeOverride: runtimeFixture.runtimePath,
                snapshot: makeSnapshot(
                    now: now,
                    windowTitle: "Instagram"
                ),
                memory: """
                [2026-04-25 10:51] Do not allow Instagram until 2026-04-25 23:59
                """,
                recentUserMessages: [
                    "[2026-04-25 10:51] Don't let me use Instagram today",
                ],
                recentActions: [
                    ActionRecord(kind: .nudge, message: "That Instagram feed is distracting. Return to studying.", timestamp: now.addingTimeInterval(-120)),
                    ActionRecord(kind: .nudge, message: "You're looking at Instagram stories. Return to studying.", timestamp: now.addingTimeInterval(-240)),
                    ActionRecord(kind: .nudge, message: "Still scrolling Instagram — get back to your goals.", timestamp: now.addingTimeInterval(-360)),
                ]
            )
        )

        if case let .showOverlay(presentation) = result.policy.action {
            #expect(presentation.evaluationID == "eval-repeated-instagram")
            #expect(presentation.body.contains("after a few nudges"))
        } else {
            Issue.record("Expected repeated nudges to escalate, got \(result.policy.action)")
        }
        #expect(result.policy.record.blockReason == "repeated_nudge_escalation")
        #expect(result.updatedAlgorithmState.llmPolicy.lastOverlayAt == now)
        #expect(result.updatedAlgorithmState.llmPolicy.activeAppeal?.evaluationID == "eval-repeated-instagram")
    }

    @Test
    func scheduledFocusedFollowUpDoesNotReevaluateUntilDue() {
        let algorithm = makeAlgorithm()
        let context = FrontmostContext(
            bundleIdentifier: "com.google.Chrome",
            appName: "Google Chrome",
            windowTitle: "Docs"
        )
        let start = Date(timeIntervalSince1970: 7_800)
        var state = AlgorithmStateEnvelope()

        _ = algorithm.noteContext(context.contextKey, at: start, state: &state)
        state.llmPolicy.distraction = DistractionMetadata(
            contextKey: context.contextKey,
            stableSince: start,
            lastAssessment: .focused,
            consecutiveDistractedCount: 0,
            nextEvaluationAt: start.addingTimeInterval(5 * 60)
        )

        let beforeDue = algorithm.evaluationPlan(
            state: &state,
            context: context,
            heuristics: makeHeuristics(),
            policyMemory: PolicyMemory(),
            configuration: MonitoringConfiguration(),
            now: start.addingTimeInterval(60)
        )
        let afterDue = algorithm.evaluationPlan(
            state: &state,
            context: context,
            heuristics: makeHeuristics(),
            policyMemory: PolicyMemory(),
            configuration: MonitoringConfiguration(),
            now: start.addingTimeInterval((5 * 60) + 1)
        )

        #expect(beforeDue.shouldEvaluate == false)
        #expect(beforeDue.reason == "scheduled_recheck")
        #expect(afterDue.shouldEvaluate == true)
        #expect(afterDue.reason == "scheduled_recheck")
    }

    @Test
    func cachedFocusedDecisionSuppressesExactTitleRevisitButNotSameContextFollowUp() {
        let algorithm = makeAlgorithm()
        let context = FrontmostContext(
            bundleIdentifier: "com.google.Chrome",
            appName: "Google Chrome",
            windowTitle: "Wie funktioniert lernen? - Google Slides"
        )
        let start = Date(timeIntervalSince1970: 7_850)
        var configuration = MonitoringConfiguration()
        configuration.pipelineProfileID = "title_only_default"
        var revisitState = AlgorithmStateEnvelope()
        _ = algorithm.noteContext(context.contextKey, at: start, state: &revisitState)
        revisitState.llmPolicy.decisionCacheByContext[context.contextKey] = CachedDecision(
            assessment: .focused,
            decidedAt: start,
            contextKey: context.contextKey
        )

        let revisitPlan = algorithm.evaluationPlan(
            state: &revisitState,
            context: context,
            heuristics: makeHeuristics(),
            policyMemory: PolicyMemory(),
            configuration: configuration,
            now: start.addingTimeInterval(10 * 60)
        )

        var sameContextState = revisitState
        sameContextState.llmPolicy.distraction.lastAssessment = .focused
        sameContextState.llmPolicy.distraction.nextEvaluationAt = start.addingTimeInterval(5 * 60)
        let sameContextPlan = algorithm.evaluationPlan(
            state: &sameContextState,
            context: context,
            heuristics: makeHeuristics(),
            policyMemory: PolicyMemory(),
            configuration: configuration,
            now: start.addingTimeInterval(10 * 60)
        )

        #expect(revisitPlan.shouldEvaluate == false)
        #expect(revisitPlan.reason == "cached_focused")
        #expect(sameContextPlan.shouldEvaluate == true)
        #expect(sameContextPlan.reason == "scheduled_recheck")
    }

    @Test
    func explicitAllowRuleSuppressesEvaluationEvenInBrowserContexts() {
        let algorithm = makeAlgorithm()
        let context = FrontmostContext(
            bundleIdentifier: "com.google.Chrome",
            appName: "Google Chrome",
            windowTitle: "Docs"
        )
        let start = Date(timeIntervalSince1970: 7_900)
        var state = AlgorithmStateEnvelope()

        _ = algorithm.noteContext(context.contextKey, at: start, state: &state)

        let allowRule = PolicyRule(
            kind: .allow,
            summary: "Always allow Docs for this work block.",
            source: .userChat,
            priority: 90,
            scope: PolicyRuleScope(appName: "Google Chrome", titleContains: ["Docs"])
        )
        let policyMemory = PolicyMemory(rules: [allowRule], tonePreference: nil, lastUpdatedAt: start)

        let plan = algorithm.evaluationPlan(
            state: &state,
            context: context,
            heuristics: makeHeuristics(),
            policyMemory: policyMemory,
            configuration: MonitoringConfiguration(),
            now: start.addingTimeInterval(30)
        )

        #expect(plan.shouldEvaluate == false)
        #expect(plan.reason == "explicit_allow_rule")
    }

    @Test
    func onlineVisionPipelineUsesSingleRoundDecisionAndNudge() async throws {
        let onlineService = StubOnlineModelService(
            output: RuntimeProcessOutput(
                stdout: """
                {"assessment":"distracted","suggested_action":"nudge","confidence":0.91,"reason_tags":["doomscrolling"],"nudge":"Back to the build."}
                """,
                stderr: ""
            )
        )
        let algorithm = makeAlgorithm(onlineModelService: onlineService)
        let now = Date(timeIntervalSince1970: 7_950)

        var configuration = MonitoringConfiguration()
        configuration.inferenceBackend = .openRouter
        configuration.pipelineProfileID = MonitoringConfiguration.defaultOnlineVisionPipelineProfileID

        let result = await algorithm.evaluate(
            input: makeDecisionInput(
                now: now,
                evaluationID: "eval-online",
                runtimeOverride: "/tmp/missing-runtime",
                snapshot: makeSnapshot(
                    now: now,
                    screenshotPath: "/tmp/fake-screenshot.png"
                ),
                configuration: configuration
            )
        )

        #expect(result.policy.action == .showNudge("Back to the build."))
        #expect(result.evaluation.attempts.map(\.promptMode) == ["online_decision"])
        let requests = await onlineService.requests()
        #expect(requests.count == 1)
        #expect(requests.first?.imagePath == "/tmp/fake-screenshot.png")
        #expect(requests.first?.modelIdentifier == MonitoringConfiguration.defaultOnlineModelIdentifier)
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
        let algorithm = LLMMonitorAlgorithm(
            runtime: runtime,
            onlineModelService: OnlineModelService(),
            policyMemoryService: PolicyMemoryService(
                runtime: runtime,
                onlineModelService: OnlineModelService()
            )
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

    private func makeAlgorithm(
        onlineModelService: any OnlineModelServing = OnlineModelService()
    ) -> LLMMonitorAlgorithm {
        let runtime = LocalModelRuntime()
        return LLMMonitorAlgorithm(
            runtime: runtime,
            onlineModelService: onlineModelService,
            policyMemoryService: PolicyMemoryService(
                runtime: runtime,
                onlineModelService: OnlineModelService()
            )
        )
    }

    private func makeDecisionInput(
        now: Date,
        evaluationID: String,
        runtimeOverride: String,
        state: AlgorithmStateEnvelope? = nil,
        snapshot: AppSnapshot? = nil,
        memory: String = "Keep social media short during focused work.",
        recentUserMessages: [String] = [],
        recentActions: [ActionRecord] = [],
        configuration: MonitoringConfiguration? = nil
    ) -> MonitoringDecisionInput {
        var configuration = configuration ?? MonitoringConfiguration()
        if configuration == MonitoringConfiguration() {
            configuration.pipelineProfileID = "title_only_default"
        }
        let algorithmState = state ?? AlgorithmStateEnvelope()

        return MonitoringDecisionInput(
            now: now,
            evaluationID: evaluationID,
            snapshot: snapshot ?? makeSnapshot(now: now),
            goals: "Ship AC and stay focused on engineering work.",
            recentActions: recentActions,
            heuristics: makeHeuristics(),
            memory: memory,
            recentUserMessages: recentUserMessages,
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

    private func makeSnapshot(
        now: Date,
        appName: String = "Google Chrome",
        windowTitle: String? = "Docs",
        bundleIdentifier: String = "com.google.Chrome",
        screenshotPath: String? = nil
    ) -> AppSnapshot {
        AppSnapshot(
            bundleIdentifier: bundleIdentifier,
            appName: appName,
            windowTitle: windowTitle,
            recentSwitches: [
                AppSwitchRecord(
                    fromAppName: "Xcode",
                    toAppName: appName,
                    toWindowTitle: windowTitle,
                    timestamp: now.addingTimeInterval(-15)
                ),
            ],
            perAppDurations: [
                AppUsageRecord(appName: appName, seconds: 900),
                AppUsageRecord(appName: "Xcode", seconds: 3_600),
            ],
            screenshotArtifact: nil,
            screenshotThumbnail: nil,
            screenshotPath: screenshotPath,
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

    private func makeLocalPromptDate(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.date(from: value)
    }
}

private actor StubOnlineModelService: OnlineModelServing {
    private let output: RuntimeProcessOutput
    private var recordedRequests: [OnlineModelRequest] = []

    init(output: RuntimeProcessOutput) {
        self.output = output
    }

    func runInference(_ request: OnlineModelRequest) async throws -> RuntimeProcessOutput {
        recordedRequests.append(request)
        return output
    }

    func requests() -> [OnlineModelRequest] {
        recordedRequests
    }
}

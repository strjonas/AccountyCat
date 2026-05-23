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
        var state = AlgorithmStateEnvelope()
        state.llmPolicy.distraction = DistractionMetadata(
            contextKey: "com.google.Chrome|docs",
            stableSince: now.addingTimeInterval(-90),
            lastAssessment: .distracted,
            consecutiveDistractedCount: 3,
            nextEvaluationAt: nil
        )
        state.llmPolicy.currentContextKey = "com.google.Chrome|docs"
        state.llmPolicy.currentContextEnteredAt = now.addingTimeInterval(-90)

        let result = await algorithm.evaluate(
            input: makeDecisionInput(
                now: now,
                evaluationID: "eval-overlay",
                runtimeOverride: runtimeFixture.runtimePath,
                state: state,
                activeProfileID: "coding",
                activeProfileName: "Coding"
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
        var state = AlgorithmStateEnvelope()
        state.llmPolicy.distraction = DistractionMetadata(
            contextKey: "com.google.Chrome|docs",
            stableSince: now.addingTimeInterval(-90),
            lastAssessment: .distracted,
            consecutiveDistractedCount: 3,
            nextEvaluationAt: nil
        )
        state.llmPolicy.currentContextKey = "com.google.Chrome|docs"
        state.llmPolicy.currentContextEnteredAt = now.addingTimeInterval(-90)

        let result = await algorithm.evaluate(
            input: makeDecisionInput(
                now: now,
                evaluationID: "eval-overlay-cooldown",
                runtimeOverride: runtimeFixture.runtimePath,
                state: state,
                activeProfileID: "coding",
                activeProfileName: "Coding"
            )
        )

        if case let .showOverlay(presentation) = result.policy.action {
            #expect(presentation.headline == "Quick gut-check.")
            #expect(presentation.body == "You've been on Docs for a bit. Is this part of what you set out to do?")
            #expect(presentation.prompt == "How does Docs help right now? If it doesn't, let's get back to it.")
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
        // Default profile is active here, so the everyday-mode cadence multiplier (1.5x)
        // is applied on top of the balanced focusedFollowUp (5 min) → 7.5 min.
        let expectedFollowUp = MonitoringCadenceMode.balanced.adjustedDelay(
            MonitoringCadenceMode.balanced.focusedFollowUp,
            isDefaultProfile: true
        )
        #expect(result.updatedAlgorithmState.llmPolicy.distraction.nextEvaluationAt == now.addingTimeInterval(expectedFollowUp))
        #expect(result.updatedAlgorithmState.llmPolicy.focusSignal.driftEMA < 0.2)
    }

    @Test
    func toleratedDecisionSchedulesShortFollowUpDoesNotCacheOrPromote() async throws {
        var outputs = FakeRuntimeOutputSet()
        outputs.decision = """
        {"assessment":"tolerated","suggested_action":"none","confidence":0.84,"reason_tags":["short_break"]}
        """
        let runtimeFixture = try FakeRuntimeFixture(outputs: outputs)
        let algorithm = makeAlgorithm()
        let now = Date(timeIntervalSince1970: 7_550)
        let snapshot = makeSnapshot(
            now: now,
            appName: "Instagram",
            windowTitle: "Reels",
            bundleIdentifier: "com.burbn.instagram"
        )
        var state = AlgorithmStateEnvelope()
        state.llmPolicy.currentContextKey = snapshot.contextKey
        state.llmPolicy.currentContextEnteredAt = now.addingTimeInterval(-90)
        state.llmPolicy.distraction = DistractionMetadata(
            contextKey: snapshot.contextKey,
            stableSince: now.addingTimeInterval(-90),
            lastAssessment: nil,
            consecutiveDistractedCount: 0,
            nextEvaluationAt: nil
        )
        let cacheKey = CachedDecision.cacheKey(
            activeProfileID: PolicyRule.defaultProfileID,
            pipelineProfileID: "title_only_default",
            promptVersion: algorithm.descriptor.version,
            contextKey: snapshot.contextKey
        )

        let result = await algorithm.evaluate(
            input: makeDecisionInput(
                now: now,
                evaluationID: "eval-tolerated",
                runtimeOverride: runtimeFixture.runtimePath,
                state: state,
                snapshot: snapshot
            )
        )

        let expectedFollowUp = MonitoringCadenceMode.balanced.adjustedDelay(
            MonitoringCadenceMode.balanced.toleratedFollowUp,
            isDefaultProfile: true
        )
        #expect(result.policy.action == .none)
        #expect(result.policy.record.blockReason == "tolerated_assessment")
        #expect(result.updatedAlgorithmState.llmPolicy.distraction.lastAssessment == .tolerated)
        #expect(result.updatedAlgorithmState.llmPolicy.distraction.consecutiveDistractedCount == 0)
        #expect(result.updatedAlgorithmState.llmPolicy.distraction.nextEvaluationAt == now.addingTimeInterval(expectedFollowUp))
        #expect(result.updatedAlgorithmState.llmPolicy.decisionCacheByContext[cacheKey] == nil)
        #expect(result.updatedAlgorithmState.llmPolicy.focusedObservations.isEmpty)
        #expect(result.updatedAlgorithmState.llmPolicy.focusSignal.lastFocusedBlockStartedAt == nil)
        #expect(FocusSegmentAssessment(distractionAssessment: .tolerated) == .unclear)
    }

    @Test
    func toleratedRecheckSecondsIsClampedToFocusedUpperBound() async throws {
        var outputs = FakeRuntimeOutputSet()
        // 600s exceeds the everyday focused follow-up (450s) → must clamp down to that ceiling.
        outputs.decision = """
        {"assessment":"tolerated","suggested_action":"none","recheck_seconds":600,"reason_tags":["user_allowance"]}
        """
        let runtimeFixture = try FakeRuntimeFixture(outputs: outputs)
        let algorithm = makeAlgorithm()
        let now = Date(timeIntervalSince1970: 7_550)
        let snapshot = makeSnapshot(
            now: now,
            appName: "Instagram",
            windowTitle: "Reels",
            bundleIdentifier: "com.burbn.instagram"
        )
        var state = AlgorithmStateEnvelope()
        state.llmPolicy.currentContextKey = snapshot.contextKey
        state.llmPolicy.currentContextEnteredAt = now.addingTimeInterval(-90)
        state.llmPolicy.distraction = DistractionMetadata(
            contextKey: snapshot.contextKey,
            stableSince: now.addingTimeInterval(-90),
            lastAssessment: nil,
            consecutiveDistractedCount: 0,
            nextEvaluationAt: nil
        )

        let result = await algorithm.evaluate(
            input: makeDecisionInput(
                now: now,
                evaluationID: "eval-tolerated-clamp",
                runtimeOverride: runtimeFixture.runtimePath,
                state: state,
                snapshot: snapshot
            )
        )

        let upperBound = MonitoringCadenceMode.balanced.adjustedDelay(
            MonitoringCadenceMode.balanced.focusedFollowUp,
            isDefaultProfile: true
        )
        #expect(result.updatedAlgorithmState.llmPolicy.distraction.lastAssessment == .tolerated)
        #expect(result.updatedAlgorithmState.llmPolicy.distraction.nextEvaluationAt == now.addingTimeInterval(upperBound))
    }

    @Test
    func everydayFirstOverlaySuggestionStillRequiresStrongerEvidence() async throws {
        var outputs = FakeRuntimeOutputSet()
        outputs.decision = """
        {"assessment":"distracted","suggested_action":"overlay","confidence":0.96,"reason_tags":["shopping_after_ended_session"],"overlay_headline":"Still shopping?","overlay_body":"Your writing session ended, but this looks off-track.","overlay_prompt":"Why continue?"}
        """
        let runtimeFixture = try FakeRuntimeFixture(outputs: outputs)
        let algorithm = makeAlgorithm()
        let now = Date(timeIntervalSince1970: 7_250)

        let result = await algorithm.evaluate(
            input: makeDecisionInput(
                now: now,
                evaluationID: "eval-everyday-expired-overlay",
                runtimeOverride: runtimeFixture.runtimePath,
                snapshot: makeSnapshot(
                    now: now,
                    windowTitle: "Sonnencreme Gesicht | dm"
                )
            )
        )

        #expect(result.policy.action == .none)
        #expect(result.policy.record.blockReason == "overlay_below_min_threshold")
        #expect(result.updatedAlgorithmState.llmPolicy.activeAppeal == nil)
        #expect(result.updatedAlgorithmState.llmPolicy.lastOverlayAt == nil)
        #expect(result.updatedAlgorithmState.llmPolicy.distraction.consecutiveDistractedCount == 1)
    }

    @Test
    func namedProfileFirstOverlaySuggestionRequiresRepeatEvidence() async throws {
        var outputs = FakeRuntimeOutputSet()
        outputs.decision = """
        {"assessment":"distracted","suggested_action":"overlay","confidence":0.96,"reason_tags":["off_task_shopping"],"overlay_headline":"Pause.","overlay_body":"This looks off-track.","overlay_prompt":"Why continue?"}
        """
        let runtimeFixture = try FakeRuntimeFixture(outputs: outputs)
        let algorithm = makeAlgorithm()
        let now = Date(timeIntervalSince1970: 7_275)

        let result = await algorithm.evaluate(
            input: makeDecisionInput(
                now: now,
                evaluationID: "eval-named-first-overlay",
                runtimeOverride: runtimeFixture.runtimePath,
                activeProfileID: "coding",
                activeProfileName: "Coding",
                activeProfileDescription: "Focus for coding and development work"
            )
        )

        #expect(result.policy.action == .none)
        #expect(result.policy.record.blockReason == "overlay_below_min_threshold")
        #expect(result.updatedAlgorithmState.llmPolicy.activeAppeal == nil)
        #expect(result.updatedAlgorithmState.llmPolicy.lastOverlayAt == nil)
        #expect(result.updatedAlgorithmState.llmPolicy.distraction.consecutiveDistractedCount == 1)
    }

    @Test
    func usagePayloadLabelsDailyAppTotalsAndSeparatesCurrentContextDuration() async throws {
        var outputs = FakeRuntimeOutputSet()
        outputs.decision = """
        {"assessment":"focused","suggested_action":"none","confidence":0.9,"reason_tags":["payload_check"]}
        """
        let runtimeFixture = try FakeRuntimeFixture(outputs: outputs)
        let algorithm = makeAlgorithm()
        let now = Date(timeIntervalSince1970: 7_300)
        var state = AlgorithmStateEnvelope()
        state.llmPolicy.currentContextKey = "com.apple.Safari|reddit"
        state.llmPolicy.currentContextEnteredAt = now.addingTimeInterval(-5 * 60)

        let result = await algorithm.evaluate(
            input: makeDecisionInput(
                now: now,
                evaluationID: "eval-usage-semantics",
                runtimeOverride: runtimeFixture.runtimePath,
                state: state,
                snapshot: makeSnapshot(
                    now: now,
                    appName: "Safari",
                    windowTitle: "reddit: the front page of the internet",
                    bundleIdentifier: "com.apple.Safari"
                )
            )
        )

        let decisionAttempt = try #require(result.evaluation.attempts.first {
            $0.promptMode == "decision"
        })
        #expect(decisionAttempt.payloadJSON.contains(#""scope":"today_app_total""#))
        #expect(decisionAttempt.payloadJSON.contains(#""currentContextSeconds":300"#))
        #expect(decisionAttempt.payloadJSON.contains(#""cadenceMode":"balanced""#))
        #expect(decisionAttempt.payloadJSON.contains(#""toleratedWindowSeconds":225"#))
    }

    @Test
    func payloadIncludesSessionGoalSummaryAndRecentActivityTimeline() async throws {
        var outputs = FakeRuntimeOutputSet()
        outputs.decision = """
        {"assessment":"focused","suggested_action":"none","confidence":0.9,"reason_tags":["payload_check"]}
        """
        let runtimeFixture = try FakeRuntimeFixture(outputs: outputs)
        let algorithm = makeAlgorithm()
        let now = Date(timeIntervalSince1970: 7_320)

        let snapshot = AppSnapshot(
            bundleIdentifier: "com.google.Chrome",
            appName: "Google Chrome",
            windowTitle: "Google Calendar - Week of May 18, 2026",
            recentSwitches: [
                AppSwitchRecord(fromAppName: "Google Chrome", toAppName: "Google Chrome", toWindowTitle: "Google Calendar - Week of May 18, 2026", timestamp: now.addingTimeInterval(-10)),
                AppSwitchRecord(fromAppName: "Google Chrome", toAppName: "Google Chrome", toWindowTitle: "Inbox - Gmail", timestamp: now.addingTimeInterval(-15)),
                AppSwitchRecord(fromAppName: "Google Chrome", toAppName: "Google Chrome", toWindowTitle: "Order details", timestamp: now.addingTimeInterval(-20)),
            ],
            perAppDurations: [
                AppUsageRecord(appName: "Google Chrome", seconds: 1200),
                AppUsageRecord(appName: "Xcode", seconds: 3600),
            ],
            screenshotArtifact: nil,
            screenshotThumbnail: nil,
            screenshotPath: nil,
            idle: false,
            timestamp: now
        )

        let result = await algorithm.evaluate(
            input: makeDecisionInput(
                now: now,
                evaluationID: "eval-goal-summary-payload",
                runtimeOverride: runtimeFixture.runtimePath,
                snapshot: snapshot,
                activeProfileID: "coding",
                activeProfileName: "Coding",
                activeProfileDescription: "Focus for coding and development work",
                activeProfileGoalSummary: "coding with browsing/order errands allowed right now"
            )
        )

        let decisionAttempt = try #require(result.evaluation.attempts.first {
            $0.promptMode == "decision"
        })
        let payload = decisionAttempt.payloadJSON
        #expect(payload.contains(#""goalSummary":"coding with browsing"#))
        #expect(payload.contains(#""recentActivityTimeline""#))
        #expect(payload.contains(#""durationSeconds":10"#))
        #expect(payload.contains(#""durationSeconds":5"#))
        #expect(!payload.contains(#""recentSwitches""#))
        #expect(payload.contains(#""matchingRuleSummary""#))
        #expect(payload.contains(#""decisionFrame""#))
        #expect(!payload.contains(#""policySummary""#))
        #expect(payload.contains("Google Calendar - Week of May 18, 2026"))
        #expect(payload.contains("Order details"))
    }

    @Test
    func decisionPayloadEncodesNormativeFieldsBeforeEvidenceAndDecisionFrameLast() throws {
        let activeProfile = MonitoringActiveProfilePromptPayload(
            id: "coding",
            name: "Coding",
            isDefault: false,
            description: "Development work",
            goalSummary: "Finish prompt ordering"
        )
        let payload = MonitoringDecisionPromptPayload(
            activeProfile: activeProfile,
            matchingRuleSummary: "disallow: Social feeds",
            recentUserMessages: ["[2026-05-18 10:00] User: coding now"],
            freeFormMemory: "User prefers quiet nudges.",
            calendarContext: "Coding block",
            now: Date(timeIntervalSince1970: 7_320),
            appName: "Xcode",
            bundleIdentifier: "com.apple.dt.Xcode",
            windowTitle: "ACPromptSets.swift",
            recentActivityTimeline: [],
            usage: [],
            currentContextSeconds: 42,
            cadenceMode: MonitoringCadenceMode.balanced.rawValue,
            toleratedWindowSeconds: MonitoringCadenceMode.balanced.toleratedFollowUp,
            recentInterventions: MonitoringPromptInterventionSummary(
                recentNudges: [],
                lastActionKind: nil,
                lastActionMessage: nil
            ),
            distraction: MonitoringPromptDistractionSummary(
                state: TelemetryDistractionState(
                    stableSince: nil,
                    lastAssessment: nil,
                    consecutiveDistractedCount: 0,
                    nextEvaluationAt: nil
                )
            ),
            titlePerception: nil,
            visionPerception: nil,
            decisionFrame: MonitoringDecisionFramePromptPayload.make(
                appName: "Xcode",
                windowTitle: "ACPromptSets.swift",
                currentContextSeconds: 42,
                matchingRuleSummary: "disallow: Social feeds",
                recentUserMessages: ["[2026-05-18 10:00] User: coding now"],
                activeProfile: activeProfile
            )
        )
        let json = MonitoringLLMClient.encodePayload(payload)
        let activeProfileIndex = try #require(json.range(of: #""activeProfile""#)?.lowerBound)
        let matchingRuleIndex = try #require(json.range(of: #""matchingRuleSummary""#)?.lowerBound)
        let recentUserIndex = try #require(json.range(of: #""recentUserMessages""#)?.lowerBound)
        let freeFormIndex = try #require(json.range(of: #""freeFormMemory""#)?.lowerBound)
        let appNameIndex = try #require(json.range(of: #""appName""#)?.lowerBound)
        let decisionFrameIndex = try #require(json.range(of: #""decisionFrame""#)?.lowerBound)

        #expect(activeProfileIndex < matchingRuleIndex)
        #expect(matchingRuleIndex < recentUserIndex)
        #expect(recentUserIndex < freeFormIndex)
        #expect(freeFormIndex < appNameIndex)
        #expect(decisionFrameIndex > appNameIndex)
        #expect(!json.contains(#""userGoals""#))
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
            bundleIdentifier: "com.apple.TextEdit",
            appName: "TextEdit",
            windowTitle: "Draft notes"
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
            heuristics: makeHeuristics(browser: false),
            policyMemory: PolicyMemory(),
            configuration: gentle,
            activeProfileID: PolicyRule.defaultProfileID,
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
            heuristics: makeHeuristics(browser: false),
            policyMemory: PolicyMemory(),
            configuration: sharp,
            activeProfileID: PolicyRule.defaultProfileID,
            now: start.addingTimeInterval(30)
        )

        #expect(gentlePlan.shouldEvaluate == false)
        #expect(sharpPlan.shouldEvaluate == true)
    }

    @Test
    func browserContextsHonorCadenceStableDelayInEverydayMode() {
        let algorithm = makeAlgorithm()
        let context = FrontmostContext(
            bundleIdentifier: "com.google.Chrome",
            appName: "Google Chrome",
            windowTitle: "YouTube - Cat videos"
        )
        let start = Date(timeIntervalSince1970: 7_730)
        var state = AlgorithmStateEnvelope()
        _ = algorithm.noteContext(context.contextKey, at: start, state: &state)

        let plan = algorithm.evaluationPlan(
            state: &state,
            context: context,
            heuristics: makeHeuristics(browser: true),
            policyMemory: PolicyMemory(),
            configuration: MonitoringConfiguration(),
            activeProfileID: PolicyRule.defaultProfileID,
            now: start.addingTimeInterval(5)
        )

        #expect(plan.shouldEvaluate == false)
        #expect(plan.reason == "stable_context")

        let readyPlan = algorithm.evaluationPlan(
            state: &state,
            context: context,
            heuristics: makeHeuristics(browser: true),
            policyMemory: PolicyMemory(),
            configuration: MonitoringConfiguration(),
            activeProfileID: PolicyRule.defaultProfileID,
            now: start.addingTimeInterval(46)
        )

        #expect(readyPlan.shouldEvaluate == true)
        #expect(readyPlan.reason == "stable_context")
    }

    @Test
    func nonBrowserContextsStillHonorLongerEverydayStableDelay() {
        let algorithm = makeAlgorithm()
        let context = FrontmostContext(
            bundleIdentifier: "com.apple.TextEdit",
            appName: "TextEdit",
            windowTitle: "Personal notes"
        )
        let start = Date(timeIntervalSince1970: 7_740)
        var state = AlgorithmStateEnvelope()
        _ = algorithm.noteContext(context.contextKey, at: start, state: &state)

        let plan = algorithm.evaluationPlan(
            state: &state,
            context: context,
            heuristics: makeHeuristics(browser: false),
            policyMemory: PolicyMemory(),
            configuration: MonitoringConfiguration(),
            activeProfileID: PolicyRule.defaultProfileID,
            now: start.addingTimeInterval(5)
        )

        #expect(plan.shouldEvaluate == false)
        #expect(plan.reason == "stable_context")
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
        // Default profile here → the everyday-mode 1.5x multiplier applies.
        let expectedFollowUp = MonitoringCadenceMode.balanced.adjustedDelay(
            MonitoringCadenceMode.balanced.focusedFollowUp,
            isDefaultProfile: true
        )
        #expect(result.updatedAlgorithmState.llmPolicy.distraction.nextEvaluationAt == now.addingTimeInterval(expectedFollowUp))
    }

    @Test
    func conditionalProseAllowanceDefersToModelInsteadOfPermanentOverride() async throws {
        // "short time on X is okay" is a conditional preference, not a permanent allow. It must
        // not short-circuit to a focused override; the model decides (here: tolerated).
        var outputs = FakeRuntimeOutputSet()
        outputs.decision = """
        {"assessment":"tolerated","suggested_action":"none","recheck_seconds":180,"reason_tags":["short_break"]}
        """
        let runtimeFixture = try FakeRuntimeFixture(outputs: outputs)
        let algorithm = makeAlgorithm()
        let now = try #require(makeLocalPromptDate("2026-04-25 14:15"))

        let result = await algorithm.evaluate(
            input: makeDecisionInput(
                now: now,
                evaluationID: "eval-conditional-allow",
                runtimeOverride: runtimeFixture.runtimePath,
                snapshot: makeSnapshot(
                    now: now,
                    windowTitle: "Home / X"
                ),
                recentUserMessages: [
                    "[2026-04-25 14:10] short time on X is okay",
                ]
            )
        )

        #expect(result.decision.reasonTags != ["recent_allow_override"])
        #expect(result.policy.record.blockReason != "recent_allow_override")
        #expect(result.evaluation.attempts.isEmpty == false)
        #expect(result.decision.assessment == .tolerated)
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
    func recentInteractionAllowanceOverrideShortCircuitsDecision() async throws {
        let runtimeFixture = try FakeRuntimeFixture()
        let algorithm = makeAlgorithm()
        let now = try #require(makeLocalPromptDate("2026-04-25 14:35"))
        var state = AlgorithmStateEnvelope()
        state.llmPolicy.recentInteractionAllowances = [
            RecentInteractionAllowance(
                createdAt: now.addingTimeInterval(-60),
                expiresAt: now.addingTimeInterval(10 * 60),
                contextKey: nil,
                bundleIdentifier: "dev.jon.ACInspector",
                appName: "ACInspector",
                windowTitle: nil,
                reason: "user correction"
            )
        ]

        let result = await algorithm.evaluate(
            input: makeDecisionInput(
                now: now,
                evaluationID: "eval-recent-interaction-override",
                runtimeOverride: runtimeFixture.runtimePath,
                state: state,
                snapshot: makeSnapshot(
                    now: now,
                    appName: "ACInspector",
                    windowTitle: "Google Chrome",
                    bundleIdentifier: "dev.jon.ACInspector"
                )
            )
        )

        #expect(result.policy.action == .none)
        #expect(result.decision.assessment == .focused)
        #expect(result.decision.reasonTags == ["recent_user_feedback_override"])
        #expect(result.policy.record.blockReason == "recent_user_feedback_override")
        #expect(result.evaluation.attempts.isEmpty)
        #expect(result.updatedAlgorithmState.llmPolicy.distraction.lastAssessment == .focused)
    }

    @Test
    func browserRecentInteractionAllowanceDoesNotCoverDifferentTabTitle() async throws {
        let runtimeFixture = try FakeRuntimeFixture()
        let algorithm = makeAlgorithm()
        let now = try #require(makeLocalPromptDate("2026-04-25 14:36"))
        var state = AlgorithmStateEnvelope()
        state.llmPolicy.recentInteractionAllowances = [
            RecentInteractionAllowance(
                createdAt: now.addingTimeInterval(-60),
                expiresAt: now.addingTimeInterval(10 * 60),
                contextKey: nil,
                bundleIdentifier: "com.google.Chrome",
                appName: "Google Chrome",
                windowTitle: "Docs",
                reason: "user correction"
            )
        ]

        let result = await algorithm.evaluate(
            input: makeDecisionInput(
                now: now,
                evaluationID: "eval-browser-allowance-scope",
                runtimeOverride: runtimeFixture.runtimePath,
                state: state,
                snapshot: makeSnapshot(
                    now: now,
                    appName: "Google Chrome",
                    windowTitle: "Instagram",
                    bundleIdentifier: "com.google.Chrome"
                )
            )
        )

        #expect(result.policy.action == .showNudge("Back to the build."))
        #expect(result.decision.assessment == .distracted)
        #expect(result.policy.record.blockReason != "recent_user_feedback_override")
        #expect(result.evaluation.attempts.isEmpty == false)
    }

    @Test
    func repeatedMatchingNudgesEscalateDistractedNudgeDecisionToOverlay() async throws {
        let runtimeFixture = try FakeRuntimeFixture()
        let algorithm = makeAlgorithm()
        let now = try #require(makeLocalPromptDate("2026-04-25 10:52"))

        // Sharp mode forces an overlay once matching nudges reach the mode max (4).
        var configuration = MonitoringConfiguration()
        configuration.cadenceMode = .sharp
        configuration.pipelineProfileID = "title_only_default"

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
                    ActionRecord(kind: .nudge, message: "Instagram again — your study block is still running.", timestamp: now.addingTimeInterval(-480)),
                ],
                configuration: configuration
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
            activeProfileID: PolicyRule.defaultProfileID,
            now: start.addingTimeInterval(60)
        )
        let afterDue = algorithm.evaluationPlan(
            state: &state,
            context: context,
            heuristics: makeHeuristics(),
            policyMemory: PolicyMemory(),
            configuration: MonitoringConfiguration(),
            activeProfileID: PolicyRule.defaultProfileID,
            now: start.addingTimeInterval((5 * 60) + 1)
        )

        #expect(beforeDue.shouldEvaluate == false)
        #expect(beforeDue.reason == "scheduled_recheck")
        #expect(afterDue.shouldEvaluate == true)
        #expect(afterDue.reason == "scheduled_recheck")
    }

    @Test
    func cachedFocusedDecisionSuppressesExactTitleRevisitAndSameContextFollowUp() {
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
        let revisitCacheKey = CachedDecision.cacheKey(
            activeProfileID: PolicyRule.defaultProfileID,
            pipelineProfileID: "title_only_default",
            promptVersion: algorithm.descriptor.version,
            contextKey: context.contextKey
        )
        revisitState.llmPolicy.decisionCacheByContext[revisitCacheKey] = CachedDecision(
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
            activeProfileID: PolicyRule.defaultProfileID,
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
            activeProfileID: PolicyRule.defaultProfileID,
            now: start.addingTimeInterval(10 * 60)
        )

        #expect(revisitPlan.shouldEvaluate == false)
        #expect(revisitPlan.reason == "cached_focused")
        #expect(sameContextPlan.shouldEvaluate == false)
        #expect(sameContextPlan.reason == "cached_focused")
    }

    @Test
    func distractedFollowUpRunsFreshEvaluationEvenWithCachedOldVerdict() async throws {
        var outputs = FakeRuntimeOutputSet()
        outputs.nudgeCopy = """
        {"nudge":"Fresh nudge."}
        """
        let runtimeFixture = try FakeRuntimeFixture(outputs: outputs)
        let algorithm = makeAlgorithm()
        let now = Date(timeIntervalSince1970: 8_100)
        var state = AlgorithmStateEnvelope()
        let snapshot = makeSnapshot(now: now)
        state.llmPolicy.currentContextKey = snapshot.contextKey
        state.llmPolicy.currentContextEnteredAt = now.addingTimeInterval(-120)
        state.llmPolicy.distraction = DistractionMetadata(
            contextKey: snapshot.contextKey,
            stableSince: now.addingTimeInterval(-120),
            lastAssessment: .distracted,
            consecutiveDistractedCount: 0,
            nextEvaluationAt: now.addingTimeInterval(-1)
        )
        let cacheKey = CachedDecision.cacheKey(
            activeProfileID: "coding",
            pipelineProfileID: "title_only_default",
            promptVersion: algorithm.descriptor.version,
            contextKey: snapshot.contextKey
        )
        state.llmPolicy.decisionCacheByContext[cacheKey] = CachedDecision(
            assessment: .distracted,
            decidedAt: now.addingTimeInterval(-120),
            contextKey: snapshot.contextKey,
            suggestedAction: .nudge,
            confidence: 0.9,
            reasonTags: ["off_task"],
            nudge: "Back to the build.",
            activeProfileID: "coding",
            pipelineProfileID: "title_only_default",
            promptVersion: algorithm.descriptor.version
        )

        let result = await algorithm.evaluate(
            input: makeDecisionInput(
                now: now,
                evaluationID: "eval-cached-distracted",
                runtimeOverride: runtimeFixture.runtimePath,
                state: state,
                snapshot: snapshot,
                activeProfileID: "coding",
                activeProfileName: "Coding"
            )
        )

        #expect(!result.evaluation.attempts.isEmpty)
        #expect(!result.decision.reasonTags.contains("cached_distracted"))
        #expect(result.updatedAlgorithmState.llmPolicy.distraction.consecutiveDistractedCount == 1)
        #expect(result.updatedAlgorithmState.llmPolicy.decisionCacheByContext[cacheKey] == nil)
        if case let .showNudge(message) = result.policy.action {
            #expect(message == "Fresh nudge.")
        } else {
            Issue.record("Expected fresh follow-up to nudge from the new evaluation")
        }
    }

    @Test
    func distractedEscalationInBalancedRunsFreshEvalNotSyntheticOverlay() async throws {
        // Escalation must be backed by a fresh evaluation rather than reused from cache.
        let runtimeFixture = try FakeRuntimeFixture()
        let algorithm = makeAlgorithm()
        let now = Date(timeIntervalSince1970: 8_100)
        var state = AlgorithmStateEnvelope()
        let snapshot = makeSnapshot(now: now)
        state.llmPolicy.currentContextKey = snapshot.contextKey
        state.llmPolicy.currentContextEnteredAt = now.addingTimeInterval(-120)
        state.llmPolicy.distraction = DistractionMetadata(
            contextKey: snapshot.contextKey,
            stableSince: now.addingTimeInterval(-120),
            lastAssessment: .distracted,
            consecutiveDistractedCount: 2,
            nextEvaluationAt: now.addingTimeInterval(-1)
        )
        let cacheKey = CachedDecision.cacheKey(
            activeProfileID: "coding",
            pipelineProfileID: "title_only_default",
            promptVersion: algorithm.descriptor.version,
            contextKey: snapshot.contextKey
        )
        state.llmPolicy.decisionCacheByContext[cacheKey] = CachedDecision(
            assessment: .distracted,
            decidedAt: now.addingTimeInterval(-120),
            contextKey: snapshot.contextKey,
            suggestedAction: .nudge,
            confidence: 0.9,
            reasonTags: ["off_task"],
            nudge: "Back to the build.",
            activeProfileID: "coding",
            pipelineProfileID: "title_only_default",
            promptVersion: algorithm.descriptor.version
        )

        let result = await algorithm.evaluate(
            input: makeDecisionInput(
                now: now,
                evaluationID: "eval-cached-distracted-escalate",
                runtimeOverride: runtimeFixture.runtimePath,
                state: state,
                snapshot: snapshot,
                activeProfileID: "coding",
                activeProfileName: "Coding"
            )
        )

        #expect(!result.evaluation.attempts.isEmpty)
    }

    @Test
    func switchIntoPreviouslyDistractedContextUsesNormalStableDelay() {
        let algorithm = makeAlgorithm()
        let now = Date(timeIntervalSince1970: 8_100)
        var state = AlgorithmStateEnvelope()
        let snapshot = makeSnapshot(now: now)
        // Fresh switch-in: distracted state was reset, but a stale cached verdict survives.
        state.llmPolicy.currentContextKey = snapshot.contextKey
        state.llmPolicy.currentContextEnteredAt = now
        state.llmPolicy.distraction = DistractionMetadata(
            contextKey: snapshot.contextKey,
            stableSince: now,
            lastAssessment: nil,
            consecutiveDistractedCount: 0,
            nextEvaluationAt: nil
        )
        let cacheKey = CachedDecision.cacheKey(
            activeProfileID: "coding",
            pipelineProfileID: "title_only_default",
            promptVersion: algorithm.descriptor.version,
            contextKey: snapshot.contextKey
        )
        state.llmPolicy.decisionCacheByContext[cacheKey] = CachedDecision(
            assessment: .distracted,
            decidedAt: now.addingTimeInterval(-30),
            contextKey: snapshot.contextKey,
            suggestedAction: .nudge,
            confidence: 0.9,
            reasonTags: ["off_task"],
            nudge: "Back to the build.",
            activeProfileID: "coding",
            pipelineProfileID: "title_only_default",
            promptVersion: algorithm.descriptor.version
        )

        let context = FrontmostContext(
            bundleIdentifier: snapshot.bundleIdentifier,
            appName: snapshot.appName,
            windowTitle: snapshot.windowTitle
        )
        var configuration = MonitoringConfiguration()
        configuration.cadenceMode = .balanced
        configuration.pipelineProfileID = "title_only_default"

        // Within the normal browser settle window: no evaluation yet.
        var settling = state
        let earlyPlan = algorithm.evaluationPlan(
            state: &settling,
            context: context,
            heuristics: makeHeuristics(browser: true),
            policyMemory: PolicyMemory(),
            configuration: configuration,
            activeProfileID: "coding",
            now: now.addingTimeInterval(20)
        )
        #expect(earlyPlan.shouldEvaluate == false)
        #expect(earlyPlan.reason == "stable_context")

        // After the normal settle window: evaluate fresh.
        var ready = state
        let readyPlan = algorithm.evaluationPlan(
            state: &ready,
            context: context,
            heuristics: makeHeuristics(browser: true),
            policyMemory: PolicyMemory(),
            configuration: configuration,
            activeProfileID: "coding",
            now: now.addingTimeInterval(31)
        )
        #expect(readyPlan.shouldEvaluate == true)
        #expect(readyPlan.reason == "stable_context")
    }

    @Test
    func repeatedVisionBackedUnclearInNamedProfileAsksOneClarification() async throws {
        var outputs = FakeRuntimeOutputSet()
        outputs.decision = """
        {"assessment":"unclear","suggested_action":"abstain","confidence":0.4,"reason_tags":["ambiguous"]}
        """
        let runtimeFixture = try FakeRuntimeFixture(outputs: outputs)
        let algorithm = makeAlgorithm()
        let now = Date(timeIntervalSince1970: 8_200)
        let snapshot = makeSnapshot(
            now: now,
            windowTitle: "Ambiguous research tab",
            screenshotPath: "/tmp/ac-test-screenshot.png"
        )
        var state = AlgorithmStateEnvelope()
        state.llmPolicy.currentContextKey = snapshot.contextKey
        state.llmPolicy.currentContextEnteredAt = now.addingTimeInterval(-120)
        let cacheKey = CachedDecision.cacheKey(
            activeProfileID: "research",
            pipelineProfileID: MonitoringConfiguration.defaultPipelineProfileID,
            promptVersion: algorithm.descriptor.version,
            contextKey: snapshot.contextKey
        )
        state.llmPolicy.decisionCacheByContext[cacheKey] = CachedDecision(
            assessment: .unclear,
            decidedAt: now.addingTimeInterval(-60),
            contextKey: snapshot.contextKey,
            suggestedAction: .abstain,
            activeProfileID: "research",
            pipelineProfileID: MonitoringConfiguration.defaultPipelineProfileID,
            promptVersion: algorithm.descriptor.version,
            screenshotIncluded: true,
            visionBackedUnclearCount: 2
        )
        var visionConfiguration = MonitoringConfiguration()
        visionConfiguration.cadenceMode = .sharp

        let result = await algorithm.evaluate(
            input: makeDecisionInput(
                now: now,
                evaluationID: "eval-unclear-clarification",
                runtimeOverride: runtimeFixture.runtimePath,
                state: state,
                snapshot: snapshot,
                configuration: visionConfiguration,
                activeProfileID: "research",
                activeProfileName: "Research"
            )
        )

        #expect(result.decision.assessment == .unclear)
        #expect(result.updatedAlgorithmState.llmPolicy.distraction.lastAssessment == .unclear)
        #expect(result.updatedAlgorithmState.llmPolicy.decisionCacheByContext[cacheKey]?.visionBackedUnclearCount == 3)
        #expect(result.updatedAlgorithmState.llmPolicy.decisionCacheByContext[cacheKey]?.clarificationAskedAt == now)
        #expect(result.policy.action == .showNudge("Quick check: is this part of your focus right now?"))
    }

    @Test
    func safelistAppealIsTextOnlyUntilHighRiskApprovalNeedsVisionConfirmation() async throws {
        var outputs = FakeRuntimeOutputSet()
        outputs.decision = """
        {"assessment":"focused","suggested_action":"none","confidence":0.9,"reason_tags":["focused"]}
        """
        let runtimeFixture = try FakeRuntimeFixture(outputs: outputs)
        let appealService = RecordingSafelistAppealService(envelopes: [
            MonitoringSafelistAppealEnvelope(
                approve: true,
                scopeKind: .titlePattern,
                titlePattern: "AC idea log",
                summary: "Research notes",
                reason: "looks stable"
            ),
            MonitoringSafelistAppealEnvelope(
                approve: true,
                scopeKind: .titlePattern,
                titlePattern: "AC idea log",
                summary: "Research notes",
                reason: "vision confirmed"
            ),
        ])
        let runtime = LocalModelRuntime()
        let algorithm = LLMMonitorAlgorithm(
            runtime: runtime,
            onlineModelService: OnlineModelService(),
            policyMemoryService: PolicyMemoryService(runtime: runtime, onlineModelService: OnlineModelService()),
            safelistAppealService: appealService
        )
        let now = Date(timeIntervalSince1970: 8_300)
        let snapshot = makeSnapshot(
            now: now,
            windowTitle: "AC idea log - Google Docs",
            screenshotPath: "/tmp/ac-test-screenshot.png"
        )
        var state = AlgorithmStateEnvelope()
        state.llmPolicy.currentContextKey = snapshot.contextKey
        state.llmPolicy.currentContextEnteredAt = now.addingTimeInterval(-120)
        let fingerprint = "coding::com.google.Chrome::AC idea log - Google Docs"
        state.llmPolicy.focusedObservations[fingerprint] = FocusedObservationStat(
            contextFingerprint: fingerprint,
            appName: "Google Chrome",
            bundleIdentifier: "com.google.Chrome",
            titleSignature: "AC idea log - Google Docs",
            sampleWindowTitles: ["AC idea log - Google Docs"],
            focusedCount: 1,
            firstSeenAt: now.addingTimeInterval(-300),
            lastSeenAt: now.addingTimeInterval(-60),
            distinctDayKeys: [now.acDayKey]
        )
        var visionConfiguration = MonitoringConfiguration()
        visionConfiguration.cadenceMode = .sharp

        let result = await algorithm.evaluate(
            input: makeDecisionInput(
                now: now,
                evaluationID: "eval-safelist-vision-confirm",
                runtimeOverride: runtimeFixture.runtimePath,
                state: state,
                snapshot: snapshot,
                configuration: visionConfiguration,
                activeProfileID: "coding",
                activeProfileName: "Coding"
            )
        )
        let paths = await appealService.screenshotPaths()

        #expect(paths == [nil, "/tmp/ac-test-screenshot.png"])
        #expect(result.policyMemoryUpdate?.operations.first?.rule?.kind == .allow)
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

        // A user-created allow rule must deterministically skip the LLM, same as a system
        // safelist rule — explicit user intent should never cost a model call.
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
            activeProfileID: PolicyRule.defaultProfileID,
            now: start.addingTimeInterval(30)
        )

        #expect(plan.shouldEvaluate == false)
        #expect(plan.reason == "explicit_allow_rule")
        #expect(state.llmPolicy.distraction.lastAssessment == .focused)
        #expect(state.llmPolicy.distraction.nextEvaluationAt == nil)
        #expect(state.llmPolicy.focusSignal.lastFocusedBlockStartedAt == start.addingTimeInterval(30))
    }

    @Test
    func tolerateRuleDoesNotDeterministicallySkipAndSurfacesToModel() {
        let algorithm = makeAlgorithm()
        let context = FrontmostContext(
            bundleIdentifier: "com.burbn.instagram",
            appName: "Instagram",
            windowTitle: "Reels"
        )
        let start = Date(timeIntervalSince1970: 7_920)
        var state = AlgorithmStateEnvelope()
        _ = algorithm.noteContext(context.contextKey, at: start, state: &state)

        // A `tolerate` rule is a soft preference, not a permanent allow: it must NOT short-circuit
        // the LLM, so the model can return `tolerated` and escalate if the detour drags on.
        let tolerateRule = PolicyRule(
            kind: .tolerate,
            summary: "Short check-ins on Instagram are okay.",
            source: .userChat,
            priority: 80,
            scope: PolicyRuleScope(appName: "Instagram"),
            profileID: PolicyRule.defaultProfileID
        )
        let policyMemory = PolicyMemory(rules: [tolerateRule], tonePreference: nil, lastUpdatedAt: start)

        let plan = algorithm.evaluationPlan(
            state: &state,
            context: context,
            heuristics: makeHeuristics(),
            policyMemory: policyMemory,
            configuration: MonitoringConfiguration(),
            activeProfileID: PolicyRule.defaultProfileID,
            now: start.addingTimeInterval(30)
        )

        // No deterministic focused skip: that path is reserved for `allow` rules and would set
        // reason "explicit_allow_rule" and stamp lastAssessment = .focused.
        #expect(plan.reason != "explicit_allow_rule")
        #expect(state.llmPolicy.distraction.lastAssessment == nil)

        // The tolerate rule is active and matches the context, so it reaches the model as context.
        let matching = policyMemory.activeRules(at: start.addingTimeInterval(30), matching: context)
        #expect(matching.contains { $0.kind == .tolerate })
    }

    @Test
    func explicitAllowRuleFromOtherProfileDoesNotSuppressEvaluationWhenScopedOut() {
        let algorithm = makeAlgorithm()
        let context = FrontmostContext(
            bundleIdentifier: "com.google.Chrome",
            appName: "Google Chrome",
            windowTitle: "Docs"
        )
        let start = Date(timeIntervalSince1970: 7_925)
        var state = AlgorithmStateEnvelope()
        _ = algorithm.noteContext(context.contextKey, at: start, state: &state)

        let writingAllow = PolicyRule(
            kind: .allow,
            summary: "Docs are ok only while writing.",
            source: .userChat,
            scope: PolicyRuleScope(appName: "Google Chrome", titleContains: ["Docs"]),
            profileID: "writing"
        )
        let policyMemory = PolicyMemory(rules: [writingAllow], tonePreference: nil, lastUpdatedAt: start)
        var scoped = policyMemory
        scoped.rules = scoped.rules.filter { $0.profileID == nil || $0.profileID == "coding" }

        // Use a named profile here so the everyday-mode cadence multiplier (1.5x) does
        // not push the stable-context threshold past the +30s probe used below — this
        // test is about cross-profile rule scoping, not cadence math.
        let plan = algorithm.evaluationPlan(
            state: &state,
            context: context,
            heuristics: makeHeuristics(),
            policyMemory: scoped,
            configuration: MonitoringConfiguration(),
            activeProfileID: "coding",
            now: start.addingTimeInterval(30)
        )

        #expect(plan.shouldEvaluate == true)
        #expect(plan.reason == "stable_context")
        #expect(state.llmPolicy.distraction.lastAssessment == nil)
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
        #expect(requests.first?.modelIdentifier == AITier.balanced.byokModelIdentifierImage)
    }

    @Test
    func requestScopeContextReusesSharedPromptFields() {
        let now = Date(timeIntervalSince1970: 8_100)
        let policyMemory = PolicyMemory(
            rules: [
                PolicyRule(
                    kind: .allow,
                    summary: "Allow docs needed to unblock the build.",
                    source: .userChat,
                    scope: PolicyRuleScope(appName: "Google Chrome", titleContains: ["Docs"])
                ),
            ],
            tonePreference: nil,
            lastUpdatedAt: now
        )
        let input = makeDecisionInput(
            now: now,
            evaluationID: "eval-request-scope",
            runtimeOverride: "/tmp/runtime",
            memory: """
            [2026-05-01 10:00] Keep nudges blunt during coding.
            [2026-05-01 10:05] Presentation prep is secondary today.
            """,
            recentUserMessages: [
                "[2026-05-01 10:10] focus on coding for the next hour",
                "[2026-05-01 10:12] docs are allowed if they unblock the build",
            ],
            policyMemory: policyMemory,
            activeProfileID: "coding",
            activeProfileName: "Coding",
            activeProfileDescription: "Deep coding work in this repo",
            activeProfileActivatedAt: now.addingTimeInterval(-300),
            activeProfileExpiresAt: now.addingTimeInterval(3600)
        )

        let scope = MonitoringRequestScopeContext(input: input)

        #expect(scope.freeFormMemory.contains("Keep nudges blunt during coding."))
        #expect(scope.recentUserMessages == [
            "[2026-05-01 10:10] focus on coding for the next hour",
            "[2026-05-01 10:12] docs are allowed if they unblock the build",
        ])
        #expect(scope.matchingRuleSummary.contains("Allow docs needed to unblock the build."))
        #expect(scope.activeProfile == MonitoringActiveProfilePromptPayload(
            id: "coding",
            name: "Coding",
            isDefault: false,
            description: "Deep coding work in this repo",
            activatedAt: now.addingTimeInterval(-300),
            expiresAt: now.addingTimeInterval(3600)
        ))
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
        #expect(result?.updatedAlgorithmState.llmPolicy.currentContextKey == "com.google.Chrome|docs")
        #expect(result?.updatedAlgorithmState.llmPolicy.distraction.contextKey == "com.google.Chrome|docs")
        #expect(result?.updatedAlgorithmState.llmPolicy.distraction.lastAssessment == .focused)
        let expectedAppealFollowUp = MonitoringCadenceMode.balanced.adjustedDelay(
            MonitoringCadenceMode.balanced.focusedFollowUp,
            isDefaultProfile: true
        )
        #expect(result?.updatedAlgorithmState.llmPolicy.distraction.nextEvaluationAt == now.addingTimeInterval(expectedAppealFollowUp))
        #expect(result?.updatedAlgorithmState.llmPolicy.recentInteractionAllowances.count == 1)
        #expect(result?.updatedAlgorithmState.llmPolicy.recentInteractionAllowances.first?.appName == "Google Chrome")
        #expect(result?.updatedAlgorithmState.llmPolicy.recentInteractionAllowances.first?.contextKey == nil)
        #expect(result?.updatedAlgorithmState.llmPolicy.recentInteractionAllowances.first?.windowTitle == "Docs")
    }

    @Test
    func appealReviewScopesLearnedRulesToActiveProfileAndPreservesOtherProfiles() async throws {
        var outputs = FakeRuntimeOutputSet()
        outputs.appealReview = """
        {"decision":"allow","message":"That explanation fits the coding session."}
        """
        outputs.policyMemory = """
        {"operations":[{"type":"add_rule","rule":{"id":"appeal-coding-docs","kind":"allow","summary":"Allow docs tabs when the user explains their coding relevance.","source":"appeal","createdAt":"2026-04-21T10:00:00Z","updatedAt":"2026-04-21T10:00:00Z","priority":95,"scope":{"appName":"Google Chrome","titleContains":["Docs"]},"schedule":{"startHour":null,"endHour":null,"weekdays":[],"expiresAt":null},"allowedTopics":["documentation"],"disallowedTopics":[],"maxMinutesPerDay":null,"tonePreference":null,"active":true}}]}
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
        let now = Date(timeIntervalSince1970: 8_050)
        var state = AlgorithmStateEnvelope()
        state.llmPolicy.activeAppeal = MonitoringAppealSession(
            evaluationID: "eval-profile-appeal",
            contextKey: "com.google.Chrome|Docs",
            appName: "Google Chrome",
            prompt: "Why should I let you continue?",
            createdAt: now.addingTimeInterval(-20),
            lastSubmittedAt: nil,
            lastResult: nil
        )

        let codingRule = PolicyRule(
            id: "coding-docs",
            kind: .allow,
            summary: "Coding docs are useful in Coding.",
            source: .userChat,
            priority: 80,
            scope: PolicyRuleScope(appName: "Google Chrome", titleContains: ["Docs"]),
            profileID: "coding"
        )
        let writingRule = PolicyRule(
            id: "writing-docs",
            kind: .disallow,
            summary: "Writing-only Docs rule should be hidden from Coding appeals.",
            source: .userChat,
            priority: 80,
            scope: PolicyRuleScope(appName: "Google Chrome", titleContains: ["Docs"]),
            profileID: "writing"
        )
        let policyMemory = PolicyMemory(
            rules: [codingRule, writingRule],
            tonePreference: nil,
            lastUpdatedAt: now
        )

        let result = await algorithm.reviewAppeal(
            input: makeAppealInput(
                now: now,
                runtimeOverride: runtimeFixture.runtimePath,
                state: state,
                policyMemory: policyMemory,
                activeProfileID: "coding",
                activeProfileName: "Coding",
                activeProfileDescription: "Deep implementation work",
                availableProfiles: [
                    ProfilePromptSummary(id: "writing", name: "Writing", isDefault: false)
                ]
            )
        )

        let updatedRules = result?.updatedPolicyMemory.rules ?? []
        #expect(updatedRules.contains { $0.id == "writing-docs" })
        #expect(updatedRules.first { $0.id == "appeal-coding-docs" }?.profileID == "coding")
        let appealPayload = try #require(result?.evaluation.attempts.first?.payloadJSON)
        #expect(appealPayload.contains("Coding docs are useful in Coding."))
        #expect(!appealPayload.contains("Writing-only Docs rule should be hidden"))
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
        configuration: MonitoringConfiguration? = nil,
        policyMemory: PolicyMemory = PolicyMemory(),
        activeProfileID: String = PolicyRule.defaultProfileID,
        activeProfileName: String = FocusProfile.defaultDisplayName,
        activeProfileDescription: String? = nil,
        activeProfileGoalSummary: String? = nil,
        activeProfileActivatedAt: Date? = nil,
        activeProfileExpiresAt: Date? = nil
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
            policyMemory: policyMemory,
            runtimeOverride: runtimeOverride,
            configuration: configuration,
            algorithmState: algorithmState,
            activeProfileID: activeProfileID,
            activeProfileName: activeProfileName,
            activeProfileDescription: activeProfileDescription,
            activeProfileGoalSummary: activeProfileGoalSummary,
            activeProfileActivatedAt: activeProfileActivatedAt,
            activeProfileExpiresAt: activeProfileExpiresAt
        )
    }

    private func makeAppealInput(
        now: Date,
        runtimeOverride: String,
        state: AlgorithmStateEnvelope,
        policyMemory: PolicyMemory = PolicyMemory(),
        activeProfileID: String = PolicyRule.defaultProfileID,
        activeProfileName: String = FocusProfile.defaultDisplayName,
        activeProfileDescription: String? = nil,
        availableProfiles: [ProfilePromptSummary] = []
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
            policyMemory: policyMemory,
            configuration: configuration,
            algorithmState: state,
            runtimeOverride: runtimeOverride,
            activeProfileID: activeProfileID,
            activeProfileName: activeProfileName,
            activeProfileDescription: activeProfileDescription,
            availableProfiles: availableProfiles
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

    private func makeHeuristics(browser: Bool = true) -> TelemetryHeuristicSnapshot {
        TelemetryHeuristicSnapshot(
            clearlyProductive: false,
            browser: browser,
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

    func runFirstSuccessfulInference(from requests: [OnlineModelRequest]) async throws -> RuntimeProcessOutput {
        for request in requests {
            recordedRequests.append(request)
        }
        return output
    }

    func hasHadSuccessfulChat() async -> Bool {
        false
    }

    func requests() -> [OnlineModelRequest] {
        recordedRequests
    }
}

private actor RecordingSafelistAppealService: SafelistAppealEvaluating {
    private var envelopes: [MonitoringSafelistAppealEnvelope]
    private var recordedScreenshotPaths: [String?] = []

    init(envelopes: [MonitoringSafelistAppealEnvelope]) {
        self.envelopes = envelopes
    }

    func runAppeal(
        observation: SafelistObservationContext,
        sampleWindowTitles: [String],
        focusedCount: Int,
        distinctDays: Int,
        freeFormMemory: String,
        activeProfile: MonitoringActiveProfilePromptPayload,
        configuration: MonitoringConfiguration,
        runtimeOverride: String?,
        screenshotPath: String?
    ) async -> MonitoringSafelistAppealEnvelope? {
        recordedScreenshotPaths.append(screenshotPath)
        guard !envelopes.isEmpty else { return nil }
        return envelopes.removeFirst()
    }

    func screenshotPaths() -> [String?] {
        recordedScreenshotPaths
    }
}

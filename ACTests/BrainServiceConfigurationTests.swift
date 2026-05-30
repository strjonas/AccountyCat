//
//  BrainServiceConfigurationTests.swift
//  ACTests
//
//  Created by Codex on 15.04.26.
//

import Foundation
import Testing
@testable import AC

@MainActor
struct BrainServiceConfigurationTests {

    @Test
    func configurationChangeResetsSelectedAlgorithmState() {
        let runtime = LocalModelRuntime()
        let registry = MonitoringAlgorithmRegistry(
            runtime: runtime,
            onlineModelService: OnlineModelService(),
            policyMemoryService: PolicyMemoryService(
                runtime: runtime,
                onlineModelService: OnlineModelService()
            )
        )
        let brainService = BrainService(
            monitoringAlgorithmRegistry: registry,
            executiveArm: ExecutiveArm(
                showNudge: { _ in },
                showOverlay: { _ in },
                hideOverlay: { },
                minimizeApp: { _ in }
            ),
            runtime: runtime,
            storageService: StorageService.temporary(),
            telemetryStore: TelemetryStore(
                rootURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent("ac-brain-tests-\(UUID().uuidString)", isDirectory: true)
            )
        )
        var state = ACState()
        state.algorithmState.llmPolicy.distraction = DistractionMetadata(
            contextKey: "com.google.Chrome|feed",
            stableSince: Date(timeIntervalSince1970: 1),
            lastAssessment: .distracted,
            consecutiveDistractedCount: 2,
            nextEvaluationAt: Date(timeIntervalSince1970: 2)
        )

        brainService.stateProvider = { state }
        func applyStateUpdate(_: ACState, updatedState: ACState) {
            state = updatedState
        }
        brainService.stateSink = applyStateUpdate

        brainService.handleMonitoringConfigurationChange()

        #expect(state.monitoringConfiguration.algorithmID == MonitoringConfiguration.defaultAlgorithmID)
        #expect(state.algorithmState == AlgorithmStateEnvelope())
    }

    @Test
    func invalidateContextAndCooldownPreservesActiveAppeal() {
        let runtime = LocalModelRuntime()
        let registry = MonitoringAlgorithmRegistry(
            runtime: runtime,
            onlineModelService: OnlineModelService(),
            policyMemoryService: PolicyMemoryService(
                runtime: runtime,
                onlineModelService: OnlineModelService()
            )
        )
        let brainService = BrainService(
            monitoringAlgorithmRegistry: registry,
            executiveArm: ExecutiveArm(
                showNudge: { _ in },
                showOverlay: { _ in },
                hideOverlay: { },
                minimizeApp: { _ in }
            ),
            runtime: runtime,
            storageService: StorageService.temporary(),
            telemetryStore: TelemetryStore(
                rootURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent("ac-brain-tests-\(UUID().uuidString)", isDirectory: true)
            )
        )
        var state = ACState()
        let currentKey = "com.google.Chrome|Docs"
        let otherKey = "com.apple.dt.Xcode|Project"
        state.algorithmState.llmPolicy.currentContextKey = currentKey
        state.algorithmState.llmPolicy.distraction = DistractionMetadata(
            contextKey: currentKey,
            stableSince: Date(timeIntervalSince1970: 1),
            lastAssessment: .distracted,
            consecutiveDistractedCount: 2,
            nextEvaluationAt: Date(timeIntervalSince1970: 2)
        )
        state.algorithmState.llmPolicy.activeAppeal = MonitoringAppealSession(
            evaluationID: "appeal-1",
            contextKey: otherKey,
            appName: "Xcode",
            prompt: "Why should I let you continue?",
            createdAt: Date(timeIntervalSince1970: 6)
        )
        state.algorithmState.llmPolicy.lastLLMEvalAt = Date(timeIntervalSince1970: 3)
        state.algorithmState.llmPolicy.decisionCacheByContext[currentKey] = CachedDecision(
            assessment: .focused,
            decidedAt: Date(timeIntervalSince1970: 4),
            contextKey: currentKey
        )
        state.algorithmState.llmPolicy.decisionCacheByContext[otherKey] = CachedDecision(
            assessment: .focused,
            decidedAt: Date(timeIntervalSince1970: 5),
            contextKey: otherKey
        )

        brainService.stateProvider = { state }
        func applyStateUpdate(_: ACState, updatedState: ACState) {
            state = updatedState
        }
        brainService.stateSink = applyStateUpdate

        brainService.invalidateContextAndCooldown(reason: "chat_actions_applied")

        #expect(state.algorithmState.llmPolicy.activeAppeal?.evaluationID == "appeal-1")
        #expect(state.algorithmState.llmPolicy.decisionCacheByContext[currentKey] == nil)
        #expect(state.algorithmState.llmPolicy.decisionCacheByContext[otherKey] == nil)
        #expect(state.algorithmState.llmPolicy.distraction.lastAssessment == nil)
        #expect(state.algorithmState.llmPolicy.distraction.consecutiveDistractedCount == 0)
        #expect(state.algorithmState.llmPolicy.distraction.nextEvaluationAt == nil)
        #expect(state.algorithmState.llmPolicy.lastLLMEvalAt == nil)
    }

    @Test
    func registryRejectsUnknownAlgorithmIDs() {
        let runtime = LocalModelRuntime()
        let registry = MonitoringAlgorithmRegistry(
            runtime: runtime,
            onlineModelService: OnlineModelService(),
            policyMemoryService: PolicyMemoryService(
                runtime: runtime,
                onlineModelService: OnlineModelService()
            )
        )

        #expect(throws: MonitoringAlgorithmResolutionError.self) {
            _ = try registry.descriptor(for: "corrupted_algorithm_id")
        }
    }

    @Test
    func activeWindowModeSkipsInitialFullScreenButUsesPeriodicSafetyNet() {
        let now = Date(timeIntervalSince1970: 10_000)
        let interval: TimeInterval = 1_800

        #expect(BrainService.shouldUsePeriodicFullScreenCapture(
            lastFullScreenCheckAt: nil,
            interval: interval,
            now: now
        ) == false)
        #expect(BrainService.shouldUsePeriodicFullScreenCapture(
            lastFullScreenCheckAt: now.addingTimeInterval(-interval + 1),
            interval: interval,
            now: now
        ) == false)
        #expect(BrainService.shouldUsePeriodicFullScreenCapture(
            lastFullScreenCheckAt: now.addingTimeInterval(-interval),
            interval: interval,
            now: now
        ) == true)
    }

    @Test
    func skipDetailExplainsBrowserStableContextWait() {
        let now = Date(timeIntervalSince1970: 10_000)
        var state = ACState()
        state.algorithmState.llmPolicy.currentContextEnteredAt = now.addingTimeInterval(-3)

        let detail = BrainService.evaluationSkipDetail(
            plan: MonitoringEvaluationPlan(
                shouldEvaluate: false,
                reason: "stable_context",
                visualCheckReason: nil,
                requiresScreenshot: true,
                promptMode: "mode",
                promptVersion: "1.0"
            ),
            state: state,
            context: FrontmostContext(
                bundleIdentifier: "com.google.Chrome",
                appName: "Google Chrome",
                windowTitle: "YouTube - Cat videos"
            ),
            heuristics: TelemetryHeuristicSnapshot(
                clearlyProductive: false,
                browser: true,
                helpfulWindowTitle: true,
                periodicVisualReason: nil
            ),
            now: now
        )

        #expect(detail.contains("browser/tab settle 3s/52s"))
        #expect(detail.contains("YouTube - Cat videos"))
    }

    @Test
    func skipDetailExplainsScheduledRecheckCountdown() {
        let now = Date(timeIntervalSince1970: 20_000)
        var state = ACState()
        state.algorithmState.llmPolicy.distraction.lastAssessment = .focused
        state.algorithmState.llmPolicy.distraction.nextEvaluationAt = now.addingTimeInterval(42)

        let detail = BrainService.evaluationSkipDetail(
            plan: MonitoringEvaluationPlan(
                shouldEvaluate: false,
                reason: "scheduled_recheck",
                visualCheckReason: nil,
                requiresScreenshot: true,
                promptMode: "mode",
                promptVersion: "1.0"
            ),
            state: state,
            context: FrontmostContext(
                bundleIdentifier: "com.apple.TextEdit",
                appName: "TextEdit",
                windowTitle: "Notes"
            ),
            heuristics: TelemetryHeuristicSnapshot(
                clearlyProductive: false,
                browser: false,
                helpfulWindowTitle: true,
                periodicVisualReason: nil
            ),
            now: now
        )

        #expect(detail.contains("next recheck in 42s"))
        #expect(detail.contains("last assessment focused"))
    }

    @Test
    func skipDetailExplainsAppScopeExclusion() {
        var state = ACState()
        state.appMonitoringScopeMode = .allowlist
        state.appMonitoringAllowlist = [
            AppMonitoringSelection(bundleIdentifier: "com.apple.dt.Xcode", appName: "Xcode")
        ]

        let detail = BrainService.evaluationSkipDetail(
            plan: MonitoringEvaluationPlan(
                shouldEvaluate: false,
                reason: "app_scope_excluded",
                visualCheckReason: nil,
                requiresScreenshot: false,
                promptMode: "",
                promptVersion: ""
            ),
            state: state,
            context: FrontmostContext(
                bundleIdentifier: "com.google.Chrome",
                appName: "Google Chrome",
                windowTitle: "Docs"
            ),
            heuristics: TelemetryHeuristicSnapshot(
                clearlyProductive: false,
                browser: true,
                helpfulWindowTitle: true,
                periodicVisualReason: nil
            ),
            now: Date(timeIntervalSince1970: 1)
        )

        #expect(detail.contains("allowlist"))
    }

    @Test
    func apiFailureBackoffCapsAtNinetySeconds() {
        #expect(BrainService.apiFailureBackoffSeconds(consecutiveFailures: 1) == 10)
        #expect(BrainService.apiFailureBackoffSeconds(consecutiveFailures: 2) == 20)
        #expect(BrainService.apiFailureBackoffSeconds(consecutiveFailures: 4) == 80)
        #expect(BrainService.apiFailureBackoffSeconds(consecutiveFailures: 5) == 90)
        #expect(BrainService.apiFailureBackoffSeconds(consecutiveFailures: 8) == 90)
    }

    @Test
    func monitoringFailureNoticeOnlyPromotesRepeatedFailuresToBanner() {
        let earlyTimeout = BrainService.monitoringFailureNotice(
            consecutiveFailures: 1,
            timedOut: true
        )
        #expect(earlyTimeout.banner == nil)
        #expect(earlyTimeout.status.contains("timed out"))

        let repeatedTimeout = BrainService.monitoringFailureNotice(
            consecutiveFailures: 3,
            timedOut: true
        )
        #expect(repeatedTimeout.banner != nil)
        #expect(repeatedTimeout.status.contains("Connection looks unstable"))

        let repeatedProviderFailure = BrainService.monitoringFailureNotice(
            consecutiveFailures: 3,
            timedOut: false
        )
        #expect(repeatedProviderFailure.banner != nil)
        #expect(repeatedProviderFailure.status.contains("trouble reaching the model provider"))

        let billingFailure = BrainService.monitoringFailureNotice(
            consecutiveFailures: 1,
            timedOut: false,
            failureMessage: OnlineModelService.openRouterBillingFailureMessage
        )
        #expect(billingFailure.banner != nil)
        #expect(billingFailure.status.contains("OpenRouter key"))
        #expect(billingFailure.status.contains("credits"))
        #expect(!billingFailure.status.contains("backup models"))
    }

    @Test
    func evaluationWatchdogTimeoutExpandsForLocalVisionSplitPipeline() {
        let timeout = BrainService.evaluationWatchdogTimeout(configuration: MonitoringConfiguration())

        #expect(timeout > BrainService.defaultEvaluationWatchdogTimeout)
        #expect(timeout == 130)
    }

    @Test
    func evaluationWatchdogTimeoutBudgetsForOnlineSplitNudgeCopy() {
        var configuration = MonitoringConfiguration()
        configuration.inferenceBackend = .openRouter
        configuration.pipelineProfileID = "online_single_round_vision"

        let timeout = BrainService.evaluationWatchdogTimeout(configuration: configuration)

        // Online pipelines now split nudge copy into its own in-character call (parity with the
        // local pipelines), so the budget covers onlineDecision + nudgeCopy, still well under the
        // local vision-split pipeline's 130.
        #expect(timeout == 70)
        #expect(timeout < 130)
    }

    @Test
    func localInteractiveRequestDefersMonitoringEvaluation() async {
        let runtime = LocalModelRuntime()
        let registry = MonitoringAlgorithmRegistry(
            runtime: runtime,
            onlineModelService: OnlineModelService(),
            policyMemoryService: PolicyMemoryService(
                runtime: runtime,
                onlineModelService: OnlineModelService()
            )
        )
        let brainService = BrainService(
            monitoringAlgorithmRegistry: registry,
            executiveArm: ExecutiveArm(
                showNudge: { _ in },
                showOverlay: { _ in },
                hideOverlay: { },
                minimizeApp: { _ in }
            ),
            runtime: runtime,
            storageService: StorageService.temporary(),
            telemetryStore: TelemetryStore(
                rootURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent("ac-brain-busy-tests-\(UUID().uuidString)", isDirectory: true)
            )
        )

        let context = FrontmostContext(
            bundleIdentifier: "com.example.focus",
            appName: "FocusApp",
            windowTitle: "Deep Work"
        )
        var state = ACState()
        state.setupStatus = .ready
        state.permissions = PermissionsSnapshot(screenRecording: .granted, accessibility: .granted)
        state.algorithmState.llmPolicy.currentContextKey = context.contextKey
        state.algorithmState.llmPolicy.currentContextEnteredAt = .distantPast

        var latestStatus = ""
        brainService.stateProvider = { state }
        brainService.stateSink = { _, updatedState in state = updatedState }
        brainService.statusSink = { latestStatus = $0 }
        brainService.contextProvider = { context }
        brainService.idleSecondsProvider = { 0 }

        await runtime.withInteractiveRequest {
            await brainService.tick()
        }

        #expect(latestStatus.contains("Local chat has priority"))
        #expect(state.algorithmState.llmPolicy.distraction.nextEvaluationAt != nil)
    }

    @Test
    func onlineVisionTimeoutsDegradeToTextOnlyAfterThreshold() {
        var configuration = MonitoringConfiguration(inferenceBackend: .openRouter)
        configuration.pipelineProfileID = MonitoringConfiguration.defaultOnlineVisionPipelineProfileID

        #expect(
            BrainService.shouldDegradeOnlineVisionToTextOnly(
                configuration: configuration,
                consecutiveVisionTimeouts: 1
            ) == false
        )
        #expect(
            BrainService.shouldDegradeOnlineVisionToTextOnly(
                configuration: configuration,
                consecutiveVisionTimeouts: 2
            ) == true
        )
    }

    @Test
    func degradedMonitoringConfigurationUsesTransientOnlineTextPipelineOnlyForOnlineVision() {
        var onlineVision = MonitoringConfiguration(inferenceBackend: .openRouter)
        onlineVision.pipelineProfileID = MonitoringConfiguration.defaultOnlineVisionPipelineProfileID

        let degraded = BrainService.effectiveMonitoringConfiguration(
            from: onlineVision,
            degradeOnlineVisionToTextOnly: true
        )
        #expect(degraded.pipelineProfileID == MonitoringConfiguration.defaultOnlineTextPipelineProfileID)
        #expect(onlineVision.pipelineProfileID == MonitoringConfiguration.defaultOnlineVisionPipelineProfileID)

        var onlineText = MonitoringConfiguration(inferenceBackend: .openRouter)
        onlineText.pipelineProfileID = MonitoringConfiguration.defaultOnlineTextPipelineProfileID
        let unchangedOnlineText = BrainService.effectiveMonitoringConfiguration(
            from: onlineText,
            degradeOnlineVisionToTextOnly: true
        )
        #expect(unchangedOnlineText.pipelineProfileID == MonitoringConfiguration.defaultOnlineTextPipelineProfileID)

        var localVision = MonitoringConfiguration(inferenceBackend: .local)
        localVision.pipelineProfileID = MonitoringConfiguration.defaultPipelineProfileID
        let unchangedLocal = BrainService.effectiveMonitoringConfiguration(
            from: localVision,
            degradeOnlineVisionToTextOnly: true
        )
        #expect(unchangedLocal.pipelineProfileID == MonitoringConfiguration.defaultPipelineProfileID)
    }
}

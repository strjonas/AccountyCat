import Foundation
import Testing
@testable import AC

@MainActor
struct LLMMonitorAlgorithmCooldownTests {

    @Test
    func cooldownBlocksFreshReevaluationInsideMinimumGap() {
        let algorithm = makeAlgorithm()
        let now = Date(timeIntervalSince1970: 10_000)
        var state = AlgorithmStateEnvelope()
        state.llmPolicy.currentContextKey = "com.google.Chrome|Docs"
        state.llmPolicy.currentContextEnteredAt = now.addingTimeInterval(-120)
        state.llmPolicy.lastLLMEvalAt = now.addingTimeInterval(-5)

        let plan = algorithm.evaluationPlan(
            state: &state,
            context: makeContext(),
            heuristics: makeHeuristics(),
            policyMemory: PolicyMemory(),
            configuration: MonitoringConfiguration(),
            activeProfileID: PolicyRule.defaultProfileID,
            now: now
        )

        #expect(!plan.shouldEvaluate)
        #expect(plan.reason == "cooldown")
    }

    @Test
    func restrictiveRuleOverridesCooldown() {
        let algorithm = makeAlgorithm()
        let now = Date(timeIntervalSince1970: 10_000)
        var state = AlgorithmStateEnvelope()
        state.llmPolicy.currentContextKey = "com.google.Chrome|Docs"
        state.llmPolicy.currentContextEnteredAt = now.addingTimeInterval(-120)
        state.llmPolicy.lastLLMEvalAt = now.addingTimeInterval(-5)
        let rule = PolicyRule(
            kind: .disallow,
            summary: "Block Docs",
            source: .userChat,
            scope: PolicyRuleScope(bundleIdentifier: "com.google.Chrome", appName: nil, titleContains: [])
        )
        let policyMemory = PolicyMemory(rules: [rule])

        let plan = algorithm.evaluationPlan(
            state: &state,
            context: makeContext(),
            heuristics: makeHeuristics(),
            policyMemory: policyMemory,
            configuration: MonitoringConfiguration(),
            activeProfileID: PolicyRule.defaultProfileID,
            now: now
        )

        #expect(plan.shouldEvaluate)
        #expect(plan.reason == "stable_context")
    }

    @Test
    func cooldownDoesNotBlockScheduledFollowUpCycles() {
        let algorithm = makeAlgorithm()
        let now = Date(timeIntervalSince1970: 10_000)
        var state = AlgorithmStateEnvelope()
        state.llmPolicy.currentContextKey = "com.google.Chrome|Docs"
        state.llmPolicy.currentContextEnteredAt = now.addingTimeInterval(-120)
        state.llmPolicy.lastLLMEvalAt = now.addingTimeInterval(-2)
        state.llmPolicy.distraction.lastAssessment = .focused
        state.llmPolicy.distraction.nextEvaluationAt = now.addingTimeInterval(-1)

        let plan = algorithm.evaluationPlan(
            state: &state,
            context: makeContext(),
            heuristics: makeHeuristics(),
            policyMemory: PolicyMemory(),
            configuration: MonitoringConfiguration(),
            activeProfileID: PolicyRule.defaultProfileID,
            now: now
        )

        #expect(plan.shouldEvaluate)
        #expect(plan.reason == "scheduled_recheck")
    }

    @Test
    func cachedFocusedSkipSchedulesNextFollowUpInsteadOfImmediateRecheck() {
        let algorithm = makeAlgorithm()
        let now = Date(timeIntervalSince1970: 10_000)
        let context = makeContext()
        var state = AlgorithmStateEnvelope()
        _ = algorithm.noteContext(context.contextKey, at: now.addingTimeInterval(-60), state: &state)
        let cacheKey = CachedDecision.cacheKey(
            activeProfileID: PolicyRule.defaultProfileID,
            pipelineProfileID: LLMPolicyCatalog.pipelineProfile(
                id: MonitoringConfiguration().pipelineProfileID
            ).descriptor.id,
            promptVersion: algorithm.descriptor.version,
            contextKey: context.contextKey
        )
        state.llmPolicy.decisionCacheByContext[cacheKey] = CachedDecision(
            assessment: .focused,
            decidedAt: now.addingTimeInterval(-60),
            contextKey: context.contextKey
        )

        let firstPlan = algorithm.evaluationPlan(
            state: &state,
            context: context,
            heuristics: makeHeuristics(),
            policyMemory: PolicyMemory(),
            configuration: MonitoringConfiguration(),
            activeProfileID: PolicyRule.defaultProfileID,
            now: now
        )

        let expectedFollowUp = now.addingTimeInterval(
            MonitoringCadenceMode.balanced.adjustedDelay(
                MonitoringCadenceMode.balanced.focusedFollowUp,
                isDefaultProfile: true
            )
        )
        #expect(!firstPlan.shouldEvaluate)
        #expect(firstPlan.reason == "cached_focused")
        #expect(state.llmPolicy.distraction.nextEvaluationAt == expectedFollowUp)

        let nextTickPlan = algorithm.evaluationPlan(
            state: &state,
            context: context,
            heuristics: makeHeuristics(),
            policyMemory: PolicyMemory(),
            configuration: MonitoringConfiguration(),
            activeProfileID: PolicyRule.defaultProfileID,
            now: now.addingTimeInterval(10)
        )

        #expect(!nextTickPlan.shouldEvaluate)
        #expect(nextTickPlan.reason == "scheduled_recheck")
    }

    @Test
    func focusedCacheIsScopedToProfileAndExactTitle() {
        let algorithm = makeAlgorithm()
        let now = Date(timeIntervalSince1970: 10_500)
        let context = FrontmostContext(
            bundleIdentifier: "com.apple.TextEdit",
            appName: "TextEdit",
            windowTitle: "Focused essay draft - Notes"
        )
        var configuration = MonitoringConfiguration()
        configuration.pipelineProfileID = "title_only_default"
        var state = AlgorithmStateEnvelope()
        _ = algorithm.noteContext(context.contextKey, at: now.addingTimeInterval(-120), state: &state)
        let cacheKey = CachedDecision.cacheKey(
            activeProfileID: "writing",
            pipelineProfileID: "title_only_default",
            promptVersion: algorithm.descriptor.version,
            contextKey: context.contextKey
        )
        state.llmPolicy.decisionCacheByContext[cacheKey] = CachedDecision(
            assessment: .focused,
            decidedAt: now.addingTimeInterval(-60),
            contextKey: context.contextKey,
            activeProfileID: "writing",
            pipelineProfileID: "title_only_default",
            promptVersion: algorithm.descriptor.version
        )

        let differentProfilePlan = algorithm.evaluationPlan(
            state: &state,
            context: context,
            heuristics: makeHeuristics(browser: false),
            policyMemory: PolicyMemory(),
            configuration: configuration,
            activeProfileID: "coding",
            now: now
        )
        #expect(differentProfilePlan.shouldEvaluate)
        #expect(differentProfilePlan.reason == "stable_context")

        let changedContext = FrontmostContext(
            bundleIdentifier: "com.apple.TextEdit",
            appName: "TextEdit",
            windowTitle: "Different essay draft - Notes"
        )
        _ = algorithm.noteContext(changedContext.contextKey, at: now.addingTimeInterval(-120), state: &state)
        let changedTitlePlan = algorithm.evaluationPlan(
            state: &state,
            context: changedContext,
            heuristics: makeHeuristics(browser: false),
            policyMemory: PolicyMemory(),
            configuration: configuration,
            activeProfileID: "writing",
            now: now
        )
        #expect(changedTitlePlan.shouldEvaluate)
        #expect(changedTitlePlan.reason == "stable_context")
    }

    private func makeAlgorithm() -> LLMMonitorAlgorithm {
        let runtime = LocalModelRuntime()
        return LLMMonitorAlgorithm(
            runtime: runtime,
            onlineModelService: OnlineModelService(),
            policyMemoryService: PolicyMemoryService(
                runtime: runtime,
                onlineModelService: OnlineModelService()
            )
        )
    }

    private func makeContext() -> FrontmostContext {
        FrontmostContext(
            bundleIdentifier: "com.google.Chrome",
            appName: "Google Chrome",
            windowTitle: "Docs"
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
}

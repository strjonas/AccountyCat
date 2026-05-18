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

    private func makeHeuristics() -> TelemetryHeuristicSnapshot {
        TelemetryHeuristicSnapshot(
            clearlyProductive: false,
            browser: true,
            helpfulWindowTitle: true,
            periodicVisualReason: nil
        )
    }
}

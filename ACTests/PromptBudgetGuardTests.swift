import Foundation
import Testing
@testable import AC

@MainActor
struct PromptBudgetGuardTests {

    @Test
    func heuristicEstimateIsMonotonicForTextAndImages() {
        let base = PromptBudgetGuard.heuristicEstimate(charCount: 400, imageWidth: 512, imageHeight: 512)
        let moreText = PromptBudgetGuard.heuristicEstimate(charCount: 800, imageWidth: 512, imageHeight: 512)
        let moreImage = PromptBudgetGuard.heuristicEstimate(charCount: 400, imageWidth: 1024, imageHeight: 1024)

        #expect(moreText > base)
        #expect(moreImage > base)
    }

    @Test
    func truncationKeepsPromptWithinBudget() async {
        let systemPrompt = String(repeating: "S", count: 1_600)
        let userPrompt = String(repeating: "U", count: 6_000)
        let ctxSize = 2_048
        let maxTokens = 220
        let reserve = max(maxTokens, ctxSize / 10)
        let allowedPromptTokens = ctxSize - reserve - maxTokens

        let result = await PromptBudgetGuard.guardedUserPrompt(
            systemPrompt: systemPrompt,
            userPrompt: userPrompt,
            imagePath: nil,
            ctxSize: ctxSize,
            maxTokens: maxTokens,
            serverPort: 8080,
            transport: { request in
                max(0, request.content.count / 4)
            }
        )

        #expect(result.wasTruncated)
        #expect(result.userPrompt.count < userPrompt.count)
        #expect(result.promptTokensEstimate + result.imageTokensEstimate <= allowedPromptTokens)
    }

    @Test
    func tokenizationFailureFallsBackToHeuristic() async {
        let result = await PromptBudgetGuard.guardedUserPrompt(
            systemPrompt: String(repeating: "S", count: 1_200),
            userPrompt: String(repeating: "U", count: 5_500),
            imagePath: nil,
            ctxSize: 2_048,
            maxTokens: 180,
            serverPort: 8080,
            transport: { _ in
                struct TokenizeFailed: LocalizedError {
                    var errorDescription: String? { "timeout" }
                }
                throw TokenizeFailed()
            }
        )

        #expect(result.warning?.contains("timeout") == true)
        #expect(!result.userPrompt.isEmpty)
    }

    @Test
    func tokenizedTruncationUsesSingleVerificationRoundTrip() async {
        let systemPrompt = String(repeating: "S", count: 1_600)
        let userPrompt = String(repeating: "U", count: 6_000)
        let counter = CounterBox()

        let result = await PromptBudgetGuard.guardedUserPrompt(
            systemPrompt: systemPrompt,
            userPrompt: userPrompt,
            imagePath: nil,
            ctxSize: 2_048,
            maxTokens: 220,
            serverPort: 8080,
            transport: { request in
                await counter.increment()
                return max(0, request.content.count / 4)
            }
        )

        let calls = await counter.value
        #expect(result.wasTruncated)
        #expect(calls == 3)
    }

    @Test
    func chatTemplateTokenizationAccountsForModelWrapperOverhead() async {
        let systemPrompt = String(repeating: "S", count: 400)
        let userPrompt = String(repeating: "U", count: 6_000)
        let ctxSize = 2_048
        let maxTokens = 220
        let reserve = max(maxTokens, ctxSize / 10)
        let allowedPromptTokens = ctxSize - reserve - maxTokens
        let chatCounter = CounterBox()

        let result = await PromptBudgetGuard.guardedUserPrompt(
            systemPrompt: systemPrompt,
            userPrompt: userPrompt,
            imagePath: nil,
            ctxSize: ctxSize,
            maxTokens: maxTokens,
            serverPort: 8080,
            transport: { request in
                max(0, request.content.count / 4)
            },
            chatTransport: { request in
                await chatCounter.increment()
                return 900 + max(0, (request.systemPrompt.count + request.userPrompt.count) / 4)
            }
        )

        #expect(result.wasTruncated)
        #expect(result.promptTokensEstimate <= allowedPromptTokens)
        #expect(result.userPrompt.count < userPrompt.count)
        #expect(await chatCounter.value >= 2)
    }

    @Test
    func preflightPlanPrefersCtxGrowthBeforeTextTruncation() {
        let plan = PromptBudgetGuard.preflightPlan(
            systemPrompt: String(repeating: "S", count: 1_600),
            userPrompt: String(repeating: "U", count: 6_000),
            imagePath: nil,
            ctxSize: 2_048,
            maxTokens: 220,
            maxCtxGrowth: 2_048
        )

        #expect(plan.recommendedCtxSize > 2_048)
        #expect(plan.recommendedCtxSize <= 4_096)
        #expect(plan.imageMaxDimension == nil)
        #expect(plan.exceededGrowthCap == false)
    }
}

actor CounterBox {
    private var count = 0

    func increment() {
        count += 1
    }

    var value: Int { count }
}

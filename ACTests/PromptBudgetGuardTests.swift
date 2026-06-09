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
    func truncationPreservesProtectedTail() async {
        // The compressible head (older chat context) is huge; the protected tail is
        // the user's actual new message. Truncation must keep the tail verbatim.
        let systemPrompt = String(repeating: "S", count: 1_600)
        let head = String(repeating: "H", count: 6_000)
        let userMessage = "[New user message]\nactivate the coding profile"
        let userPrompt = head + "\n" + userMessage
        let ctxSize = 2_048
        let maxTokens = 220

        let result = await PromptBudgetGuard.guardedUserPrompt(
            systemPrompt: systemPrompt,
            userPrompt: userPrompt,
            imagePath: nil,
            ctxSize: ctxSize,
            maxTokens: maxTokens,
            serverPort: 8080,
            protectedTailCharacters: userMessage.count,
            transport: { request in
                max(0, request.content.count / 4)
            }
        )

        #expect(result.wasTruncated)
        #expect(result.userPrompt.count < userPrompt.count)
        // The user's message survived intact; the head was trimmed instead.
        #expect(result.userPrompt.hasSuffix(userMessage))
        #expect(result.userPrompt.contains("activate the coding profile"))
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
    func grownCtxFromPreflightLeavesPromptUntruncated() async {
        // Regression: a prompt that overflows the base ctx but sits well under the
        // growth cap must grow *and then survive the guard intact*. Previously the
        // preflight sized the ctx using a reserve computed from the base ctx, while
        // the guard recomputed a larger reserve from the grown ctx — so every such
        // prompt was needlessly trimmed by ~ctx/10. Mirrors the local `decision`
        // stage (base ctx 3072, maxTokens 220, growth 4096) and its CLI call shape
        // (heuristic transport, no chatTransport).
        let systemPrompt = String(repeating: "S", count: 1_600)   // ~400 tokens
        let userPrompt = String(repeating: "U", count: 17_200)    // ~4300 tokens
        let baseCtx = 3_072
        let maxTokens = 220
        let maxCtxGrowth = 4_096

        let plan = PromptBudgetGuard.preflightPlan(
            systemPrompt: systemPrompt,
            userPrompt: userPrompt,
            imagePath: nil,
            ctxSize: baseCtx,
            maxTokens: maxTokens,
            maxCtxGrowth: maxCtxGrowth
        )

        // The prompt forces growth but stays under the cap.
        #expect(plan.recommendedCtxSize > baseCtx)
        #expect(plan.recommendedCtxSize <= baseCtx + maxCtxGrowth)
        #expect(plan.exceededGrowthCap == false)

        let result = await PromptBudgetGuard.guardedUserPrompt(
            systemPrompt: systemPrompt,
            userPrompt: userPrompt,
            imagePath: nil,
            ctxSize: plan.recommendedCtxSize,
            maxTokens: maxTokens,
            serverPort: 0,
            transport: { request in
                max(0, request.content.count / 4)
            }
        )

        #expect(result.wasTruncated == false)
        #expect(result.userPrompt == userPrompt)
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

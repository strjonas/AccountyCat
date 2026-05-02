import Foundation
import Testing
@testable import AC

struct OnlineModelServiceTests {

    @Test
    func paidModelStillGetsCrossModelFallback() {
        #expect(
            OnlineModelService.requestFallbackModelIdentifiers(for: "deepseek/deepseek-v4-flash")
            == [
                "nvidia/nemotron-3-super-120b-a12b",
            ]
        )
    }

    @Test
    func freeModelPrefersPaidVariantBeforeCrossModelFallback() {
        #expect(
            OnlineModelService.requestFallbackModelIdentifiers(for: "google/gemma-4-31b-it:free")
            == [
                "google/gemma-4-31b-it",
                "nvidia/nemotron-3-super-120b-a12b",
                "deepseek/deepseek-v4-flash",
            ]
        )
    }

    @Test
    func parsesActualUsedModelFromOpenRouterResponse() throws {
        let json = try #require(
            JSONSerialization.jsonObject(
                with: Data("""
                {
                  "model": "mistralai/mistral-small-3.1-24b-instruct",
                  "choices": [
                    {
                      "message": {
                        "content": "{\\"ok\\":true}"
                      }
                    }
                  ]
                }
                """.utf8)
            ) as? [String: Any]
        )

        #expect(
            OnlineModelService.responseModelIdentifier(from: json)
            == "mistralai/mistral-small-3.1-24b-instruct"
        )
    }

    @Test
    func classifies429AsRetryable() {
        #expect(
            OnlineModelService.isRetryable(
                error: OnlineModelError.httpFailure(
                    statusCode: 429,
                    message: "Provider returned error",
                    rawBody: "temporarily rate-limited upstream"
                )
            )
        )
    }

    @Test
    func chatFallbackReplyExplainsTransientOverload() {
        let reply = CompanionChatService.fallbackReply(
            for: OnlineModelError.httpFailure(
                statusCode: 429,
                message: "Provider returned error",
                rawBody: "temporarily rate-limited upstream"
            )
        )

        #expect(reply.contains("overloaded"))
        #expect(reply.contains("backup path"))
    }

    @Test
    func deepseekPrimaryFallsBackToTierAlternativesOnRetry() {
        let fallbacks = OnlineModelService.requestFallbackModelIdentifiers(for: "deepseek/deepseek-v4-flash")

        #expect(fallbacks.first == "nvidia/nemotron-3-super-120b-a12b")
        #expect(fallbacks.count == 1)
    }

    @Test
    func visionRequestsFallBackToVisionCapableTierAlternatives() {
        #expect(
            OnlineModelService.requestFallbackModelIdentifiers(
                for: "google/gemma-4-31b-it",
                includesImage: true
            ) == [
                "qwen/qwen3.5-9b",
                "google/gemini-3-flash-preview",
            ]
        )
    }
}

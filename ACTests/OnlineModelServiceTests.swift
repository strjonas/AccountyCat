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
                "moonshotai/kimi-k2.6",
            ]
        )
    }

    @Test
    func providerPreferencesPreferLowLatencyForMonitoringWithoutGlobalModelSorting() throws {
        let provider = OnlineModelService.providerPreferences(
            enforceZDR: true,
            includesModelFallbacks: true,
            source: .monitoringVision
        )

        #expect(provider["zdr"] as? Bool == true)
        #expect(provider["allow_fallbacks"] as? Bool == true)
        #expect(provider["sort"] as? String == "latency")
        #expect(provider["preferred_max_latency"] != nil)
    }

    @Test
    func backgroundProviderPreferencesCanSortAcrossFallbackModels() throws {
        let provider = OnlineModelService.providerPreferences(
            enforceZDR: true,
            includesModelFallbacks: true,
            source: .policyMemory
        )
        let sort = try #require(provider["sort"] as? [String: Any])

        #expect(sort["by"] as? String == "latency")
        #expect(sort["partition"] as? String == "none")
    }

    @Test
    func datedOpenRouterAliasesAreNotCountedAsDifferentModels() {
        #expect(
            OnlineModelService.modelIdentifiersEquivalent(
                "google/gemma-4-31b-it",
                "google/gemma-4-31b-it-20260402"
            )
        )
        #expect(
            OnlineModelService.modelIdentifiersEquivalent(
                "deepseek/deepseek-v4-flash-20260423",
                "deepseek/deepseek-v4-flash"
            )
        )
        #expect(
            !OnlineModelService.modelIdentifiersEquivalent(
                "deepseek/deepseek-v4-flash",
                "nvidia/nemotron-3-super-120b-a12b"
            )
        )
    }
}

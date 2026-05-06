import Foundation
import Testing
@testable import AC

struct OnlineModelServiceTests {

    @Test
    func paidModelStillGetsCrossModelFallback() async {
        let fallbacks = await fallbackModelIdentifiers(for: "deepseek/deepseek-v4-flash")
        #expect(
            fallbacks
            == [
                "nvidia/nemotron-3-super-120b-a12b",
            ]
        )
    }

    @Test
    func freeModelPrefersPaidVariantBeforeCrossModelFallback() async {
        let fallbacks = await fallbackModelIdentifiers(for: "google/gemma-4-31b-it:free")
        #expect(
            fallbacks
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
    func deepseekPrimaryFallsBackToTierAlternativesOnRetry() async {
        let fallbacks = await fallbackModelIdentifiers(for: "deepseek/deepseek-v4-flash")

        #expect(fallbacks.first == "nvidia/nemotron-3-super-120b-a12b")
        #expect(fallbacks.count == 1)
    }

    @Test
    func visionRequestsFallBackToVisionCapableTierAlternatives() async {
        let fallbacks = await fallbackModelIdentifiers(
            for: "google/gemma-4-31b-it",
            includesImage: true
        )
        #expect(
            fallbacks == [
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
        #expect(provider["require_parameters"] as? Bool == true)
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

    @Test
    func premiumPathPrependsReliableFallbackModel() async {
        let fallbacks = await fallbackModelIdentifiers(
            for: "deepseek/deepseek-v4-flash",
            isPremium: true
        )
        #expect(fallbacks.contains("google/gemini-3-flash-preview"))
    }

    @Test
    func nonPremiumPathOmitsPremiumFallbackModel() async {
        let fallbacks = await fallbackModelIdentifiers(
            for: "deepseek/deepseek-v4-flash",
            isPremium: false
        )
        #expect(!fallbacks.contains("google/gemini-3-flash-preview"))
    }

    @Test
    func classifiesEmptyResponseAsRetryable() {
        #expect(
            OnlineModelService.isRetryable(error: OnlineModelError.emptyResponse)
        )
    }

    @Test
    func classifiesMalformedResponseAsRetryable() {
        #expect(
            OnlineModelService.isRetryable(error: OnlineModelError.malformedResponse)
        )
    }

    @Test
    func classifies401AsNotRetryable() {
        #expect(
            !OnlineModelService.isRetryable(
                error: OnlineModelError.httpFailure(statusCode: 401, message: "Unauthorized", rawBody: "")
            )
        )
    }
}

private func fallbackModelIdentifiers(
    for modelIdentifier: String,
    includesImage: Bool = false,
    isPremium: Bool = false
) async -> [String] {
    await OnlineModelService.requestFallbackModelIdentifiers(
        for: modelIdentifier,
        includesImage: includesImage,
        isPremium: isPremium,
        healthStats: makeTemporaryOnlineModelHealthStatsService()
    )
}

private func makeTemporaryOnlineModelHealthStatsService() -> OpenRouterHealthStatsService {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("ac-online-model-health-tests-\(UUID().uuidString)", isDirectory: true)
    return OpenRouterHealthStatsService(
        fileURL: directory.appendingPathComponent("openrouter-health.json")
    )
}

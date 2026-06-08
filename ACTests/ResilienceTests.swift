import Foundation
import Testing
@testable import AC

@MainActor
struct ResilienceTests {

    // MARK: - Model Mismatch Notice

    @Test
    func modelMismatchNoticeIsNilWhenLastUsedMatchesConfigured() {
        let controller = AppController.makeForTesting(storageService: .temporary())
        controller.noteUsedModel("deepseek/deepseek-v4-flash")
        var state = controller.state
        state.monitoringConfiguration = MonitoringConfiguration(
            inferenceBackend: .openRouter,
            onlineModelIdentifier: "deepseek/deepseek-v4-flash",
            onlineModelIdentifierText: "deepseek/deepseek-v4-flash"
        )
        controller.state = state
        #expect(controller.modelMismatchNotice == nil)
    }

    @Test
    func modelMismatchNoticeAppearsWhenLastUsedDiffersFromConfigured() {
        let controller = AppController.makeForTesting(storageService: .temporary())
        controller.noteUsedModel("google/gemini-3-flash-preview")
        var state = controller.state
        state.monitoringConfiguration = MonitoringConfiguration(
            inferenceBackend: .openRouter,
            onlineModelIdentifier: "deepseek/deepseek-v4-flash",
            onlineModelIdentifierText: "deepseek/deepseek-v4-flash"
        )
        controller.state = state
        let notice = controller.modelMismatchNotice
        #expect(notice != nil)
        #expect(notice?.contains("gemini-3-flash-preview") == true)
        #expect(notice?.contains("DeepSeek V4") == true)
    }

    @Test
    func modelMismatchNoticeHandlesDatedAliasEquivalence() {
        let controller = AppController.makeForTesting(storageService: .temporary())
        controller.noteUsedModel("deepseek/deepseek-v4-flash-20260423")
        var state = controller.state
        state.monitoringConfiguration = MonitoringConfiguration(
            inferenceBackend: .openRouter,
            onlineModelIdentifier: "deepseek/deepseek-v4-flash"
        )
        controller.state = state
        #expect(controller.modelMismatchNotice == nil)
    }

    @Test
    func modelMismatchNoticeIsNilWhenNoLastUsedModel() {
        let controller = AppController.makeForTesting(storageService: .temporary())
        var state = controller.state
        state.monitoringConfiguration = MonitoringConfiguration(
            inferenceBackend: .openRouter,
            onlineModelIdentifier: "deepseek/deepseek-v4-flash"
        )
        controller.state = state
        #expect(controller.modelMismatchNotice == nil)
    }

    @Test
    func pendingLocalModelNoticeNamesDownloadAndFallback() {
        let controller = AppController.makeForTesting(storageService: .temporary())
        var state = controller.state
        state.monitoringConfiguration = MonitoringConfiguration(
            inferenceBackend: .local,
            localModelIdentifierText: "unsloth/Qwen3.5-9B-GGUF:UD-Q4_K_XL",
            localModelIdentifierImage: "unsloth/Qwen3.5-9B-GGUF:UD-Q4_K_XL"
        )
        controller.state = state
        controller.setPendingLocalModelChange(
            AppController.PendingLocalModelChange(
                modelIdentifier: "unsloth/gemma-4-12b-it-GGUF:Q4_K_M",
                fallbackIdentifier: "unsloth/Qwen3.5-9B-GGUF:UD-Q4_K_XL",
                autoSelectWhenReady: true
            )
        )

        let notice = controller.modelMismatchNotice
        #expect(notice?.contains("Downloading") == true)
        #expect(notice?.contains("gemma-4-12b") == true)
        #expect(notice?.contains("Qwen 3.5 9B") == true)
        #expect(notice?.contains("switch automatically") == true)
    }

    @Test
    func pendingLocalModelChangeRestoresFromPersistedState() {
        let storage = StorageService.temporary()
        var state = ACState()
        state.monitoringConfiguration = MonitoringConfiguration(
            inferenceBackend: .local,
            localModelIdentifierText: "unsloth/Qwen3.5-9B-GGUF:UD-Q4_K_XL",
            localModelIdentifierImage: "unsloth/Qwen3.5-9B-GGUF:UD-Q4_K_XL"
        )
        state.pendingLocalModelIdentifier = "unsloth/gemma-4-12b-it-GGUF:Q4_K_M"
        state.pendingLocalModelFallbackIdentifier = "unsloth/Qwen3.5-9B-GGUF:UD-Q4_K_XL"
        state.pendingLocalModelAutoSelect = false
        storage.saveState(state)

        let controller = AppController.makeForTesting(storageService: storage)

        #expect(controller.pendingLocalModelChange?.modelIdentifier == state.pendingLocalModelIdentifier)
        #expect(controller.pendingLocalModelChange?.fallbackIdentifier == state.pendingLocalModelFallbackIdentifier)
        #expect(controller.pendingLocalModelChange?.autoSelectWhenReady == false)
        #expect(controller.state.monitoringConfiguration.localModelIdentifierText == "unsloth/Qwen3.5-9B-GGUF:UD-Q4_K_XL")
    }

    // MARK: - Health Stats Ban Escalation

    @Test
    func healthStatsEscalatesBanDurationWithConsecutiveFailures() async {
        let service = makeTemporaryHealthStatsService()
        let model = "test/model"
        let source = OnlineModelRequestSource.monitoringText

        // First two failures are tracked, but not enough to ban a model.
        await service.recordFailure(requestedModel: model, source: source, statusCode: 503, providerName: "test")
        let banned1 = await service.isModelBanned(model)
        #expect(banned1 == false)

        await service.recordFailure(requestedModel: model, source: source, statusCode: 503, providerName: "test")
        let banned2 = await service.isModelBanned(model)
        #expect(banned2 == false)

        // Third real provider failure triggers a short ban.
        await service.recordFailure(requestedModel: model, source: source, statusCode: 503, providerName: "test")
        let banned3 = await service.isModelBanned(model)
        #expect(banned3 == true)

        // Success clears the ban
        await service.recordSuccess(requestedModel: model, servedModel: model, source: source)
        let banned4 = await service.isModelBanned(model)
        #expect(banned4 == false)
    }

    @Test
    func healthStatsBansAreRespectedBySortedHealthyModels() async {
        let service = makeTemporaryHealthStatsService()
        let badModel = "test/bad"
        let goodModel = "test/good"
        let source = OnlineModelRequestSource.monitoringText

        await service.recordFailure(requestedModel: badModel, source: source, statusCode: 503, providerName: "test")
        await service.recordFailure(requestedModel: badModel, source: source, statusCode: 503, providerName: "test")
        await service.recordFailure(requestedModel: badModel, source: source, statusCode: 503, providerName: "test")

        let sorted = await service.sortedHealthyModels([badModel, goodModel])
        #expect(sorted == [goodModel])
    }

    @Test
    func healthStatsKeepsRecoveryChainWhenEveryFallbackIsBanned() async {
        let service = makeTemporaryHealthStatsService()
        let firstModel = "test/first"
        let secondModel = "test/second"
        let source = OnlineModelRequestSource.monitoringText

        for model in [firstModel, secondModel] {
            await service.recordFailure(requestedModel: model, source: source, statusCode: 503, providerName: "test")
            await service.recordFailure(requestedModel: model, source: source, statusCode: 503, providerName: "test")
            await service.recordFailure(requestedModel: model, source: source, statusCode: 503, providerName: "test")
        }

        let sorted = await service.sortedHealthyModels([firstModel, secondModel])
        #expect(sorted == [firstModel, secondModel])
    }

    @Test
    func healthStatsCanClearBansAfterExternalProviderRecovery() async {
        let service = makeTemporaryHealthStatsService()
        let model = "test/model"
        let source = OnlineModelRequestSource.monitoringText

        await service.recordFailure(requestedModel: model, source: source, statusCode: 503, providerName: "test")
        await service.recordFailure(requestedModel: model, source: source, statusCode: 503, providerName: "test")
        await service.recordFailure(requestedModel: model, source: source, statusCode: 503, providerName: "test")
        #expect(await service.isModelBanned(model) == true)

        await service.clearBans()

        #expect(await service.isModelBanned(model) == false)
    }

    @Test
    func nonPenalizedFailuresDoNotBanModels() async {
        let service = makeTemporaryHealthStatsService()
        let model = "test/model"
        let source = OnlineModelRequestSource.chat

        await service.recordFailure(
            requestedModel: model,
            source: source,
            statusCode: nil,
            providerName: nil,
            countsTowardBan: false
        )
        await service.recordFailure(
            requestedModel: model,
            source: source,
            statusCode: nil,
            providerName: nil,
            countsTowardBan: false
        )
        await service.recordFailure(
            requestedModel: model,
            source: source,
            statusCode: nil,
            providerName: nil,
            countsTowardBan: false
        )

        #expect(await service.isModelBanned(model) == false)
    }
}

private func makeTemporaryHealthStatsService() -> OpenRouterHealthStatsService {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("ac-openrouter-health-tests-\(UUID().uuidString)", isDirectory: true)
    let fileURL = directory.appendingPathComponent("openrouter-health.json")
    return OpenRouterHealthStatsService(fileURL: fileURL)
}

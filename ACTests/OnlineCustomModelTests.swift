import Foundation
import Testing
@testable import AC

/// Validation logic for adding a custom OpenRouter model (text+image pair) against
/// the live `/models` catalog. The pure catalog check is split out from the network
/// call so it can be exercised without hitting OpenRouter.
struct OnlineModelValidationTests {

    private func catalog(_ json: String) throws -> OpenRouterModelCatalog {
        try JSONDecoder().decode(OpenRouterModelCatalog.self, from: Data(json.utf8))
    }

    private let standardCatalog = """
    {
      "data": [
        { "id": "openai/gpt-4o", "architecture": { "input_modalities": ["text", "image"] } },
        { "id": "openai/gpt-4o-mini", "architecture": { "input_modalities": ["text"] } },
        { "id": "legacy/no-arch" },
        { "id": "weird/vision-only", "architecture": { "input_modalities": ["image"] } }
      ]
    }
    """

    @Test
    func acceptsValidTextAndImagePair() throws {
        let catalog = try catalog(standardCatalog)
        #expect(throws: Never.self) {
            try OnlineModelService.validateCatalog(
                catalog, textID: "openai/gpt-4o-mini", imageID: "openai/gpt-4o")
        }
    }

    @Test
    func rejectsUnknownTextModel() throws {
        let catalog = try catalog(standardCatalog)
        #expect {
            try OnlineModelService.validateCatalog(
                catalog, textID: "openai/does-not-exist", imageID: "openai/gpt-4o")
        } throws: { error in
            error as? OnlineModelValidationError
                == .modelNotFound(id: "openai/does-not-exist", slot: .text)
        }
    }

    @Test
    func rejectsImageSlotWithoutImageModality() throws {
        let catalog = try catalog(standardCatalog)
        // gpt-4o-mini is text-only, so it can't fill the vision slot.
        #expect {
            try OnlineModelService.validateCatalog(
                catalog, textID: "openai/gpt-4o", imageID: "openai/gpt-4o-mini")
        } throws: { error in
            error as? OnlineModelValidationError
                == .unsupportedModality(id: "openai/gpt-4o-mini", slot: .image)
        }
    }

    @Test
    func matchesVariantSuffixAgainstBaseID() throws {
        let catalog = try catalog(standardCatalog)
        // A pasted `:free` (or other) variant should match the base catalog id.
        #expect(throws: Never.self) {
            try OnlineModelService.validateCatalog(
                catalog, textID: "openai/gpt-4o-mini:free", imageID: "openai/gpt-4o:nitro")
        }
    }

    @Test
    func entryWithoutModalitiesIsTextCapableButNotVision() throws {
        let catalog = try catalog(standardCatalog)
        // No declared modalities → usable as text...
        #expect(throws: Never.self) {
            try OnlineModelService.validateCatalog(
                catalog, textID: "legacy/no-arch", imageID: "openai/gpt-4o")
        }
        // ...but not trusted for the vision slot.
        #expect {
            try OnlineModelService.validateCatalog(
                catalog, textID: "openai/gpt-4o-mini", imageID: "legacy/no-arch")
        } throws: { error in
            error as? OnlineModelValidationError
                == .unsupportedModality(id: "legacy/no-arch", slot: .image)
        }
    }
}

/// Round-trip + management of custom online models on `AppController`. Add() is not
/// exercised here because it makes a live OpenRouter call; the validation logic is
/// covered above and the post-validation mutation mirrors the local custom-model path.
@MainActor
struct OnlineCustomModelManagementTests {

    @Test
    func stateOmittingOnlineCustomModelsDecodesToEmpty() throws {
        let state = ACState()
        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(ACState.self, from: data)
        #expect(decoded.onlineCustomModels.isEmpty)
    }

    @Test
    func onlineCustomModelsRoundTripThroughCodable() throws {
        var state = ACState()
        state.onlineCustomModels = [
            OnlineCustomModel(
                displayName: "My pair",
                textModelIdentifier: "openai/gpt-4o-mini",
                imageModelIdentifier: "openai/gpt-4o")
        ]
        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(ACState.self, from: data)
        #expect(decoded.onlineCustomModels.count == 1)
        #expect(decoded.onlineCustomModels.first?.textModelIdentifier == "openai/gpt-4o-mini")
        #expect(decoded.onlineCustomModels.first?.imageModelIdentifier == "openai/gpt-4o")
    }

    @Test
    func renameUpdatesDisplayNameByStableID() {
        let controller = AppController.makeForTesting(storageService: .temporary())
        let original = controller.state
        defer { controller.state = original; controller.storageService.saveState(original) }

        let model = OnlineCustomModel(
            displayName: "Old name", textModelIdentifier: "a/text", imageModelIdentifier: "b/image")
        controller.state.onlineCustomModels = [model]

        controller.renameCustomOnlineModel(id: model.id, displayName: "New name")

        #expect(controller.state.onlineCustomModels.first?.displayName == "New name")
        // Renaming must not change the pair or the stable id.
        #expect(controller.state.onlineCustomModels.first?.id == model.id)
        #expect(controller.state.onlineCustomModels.first?.textModelIdentifier == "a/text")
    }

    @Test
    func selectPointsActiveIdentifiersAtThePair() {
        let controller = AppController.makeForTesting(storageService: .temporary())
        let original = controller.state
        defer { controller.state = original; controller.storageService.saveState(original) }

        let model = OnlineCustomModel(
            displayName: "Custom", textModelIdentifier: "a/text", imageModelIdentifier: "b/image")
        controller.state.onlineCustomModels = [model]

        controller.selectOnlineCustomModel(model)

        #expect(controller.state.monitoringConfiguration.onlineModelIdentifierText == "a/text")
        #expect(controller.state.monitoringConfiguration.onlineModelIdentifierImage == "b/image")
        #expect(controller.activeOnlineCustomModel()?.id == model.id)
    }

    @Test
    func removingActiveModelFallsBackToTierDefaults() {
        let controller = AppController.makeForTesting(storageService: .temporary())
        let original = controller.state
        defer { controller.state = original; controller.storageService.saveState(original) }

        controller.state.monitoringConfiguration.inferenceBackend = .openRouter
        let model = OnlineCustomModel(
            displayName: "Custom", textModelIdentifier: "a/text", imageModelIdentifier: "b/image")
        controller.state.onlineCustomModels = [model]
        controller.selectOnlineCustomModel(model)
        #expect(controller.activeOnlineCustomModel()?.id == model.id)

        controller.removeCustomOnlineModel(id: model.id)

        #expect(controller.state.onlineCustomModels.isEmpty)
        // No custom model is active anymore; identifiers track the active tier.
        #expect(controller.activeOnlineCustomModel() == nil)
        let tier = controller.currentAITier
        #expect(controller.activeOnlineModelIdentifiers().text == tier.byokModelIdentifierText)
        #expect(controller.activeOnlineModelIdentifiers().image == tier.byokModelIdentifierImage)
    }

    @Test
    func localDraftAddCreatesCardAndClearsDraft() {
        let controller = AppController.makeForTesting(storageService: .temporary())
        let original = controller.state
        defer { controller.state = original; controller.storageService.saveState(original) }
        controller.state.localCustomModels = []

        controller.addLocalModelExpanded = true
        controller.localModelDraftSource = .huggingFace
        controller.localModelDraftName = "My Gemma"
        controller.localModelDraftRepo = "unsloth/gemma-4-12b-it-GGUF:Q4_K_M"

        controller.addCustomLocalModelFromDraft()

        #expect(controller.state.localCustomModels.contains {
            $0.modelIdentifier == "unsloth/gemma-4-12b-it-GGUF:Q4_K_M" && $0.displayName == "My Gemma"
        })
        // The draft is consumed: form collapses and fields clear.
        #expect(controller.addLocalModelExpanded == false)
        #expect(controller.localModelDraftName.isEmpty)
        #expect(controller.localModelDraftRepo.isEmpty)
    }

    @Test
    func resetOnlineModelDraftClearsEverything() {
        let controller = AppController.makeForTesting(storageService: .temporary())
        let original = controller.state
        defer { controller.state = original; controller.storageService.saveState(original) }

        controller.addOnlineModelExpanded = true
        controller.onlineModelDraftName = "Pair"
        controller.onlineModelDraftText = "a/text"
        controller.onlineModelDraftImage = "b/image"
        controller.addOnlineModelError = "stale error"

        controller.resetOnlineModelDraft()

        #expect(controller.addOnlineModelExpanded == false)
        #expect(controller.onlineModelDraftName.isEmpty)
        #expect(controller.onlineModelDraftText.isEmpty)
        #expect(controller.onlineModelDraftImage.isEmpty)
        #expect(controller.addOnlineModelError == nil)
    }

    @Test
    func displayListIsSortedByName() {
        let controller = AppController.makeForTesting(storageService: .temporary())
        let original = controller.state
        defer { controller.state = original; controller.storageService.saveState(original) }

        controller.state.onlineCustomModels = [
            OnlineCustomModel(displayName: "Zebra", textModelIdentifier: "z/t", imageModelIdentifier: "z/i"),
            OnlineCustomModel(displayName: "alpha", textModelIdentifier: "a/t", imageModelIdentifier: "a/i"),
        ]
        let names = controller.onlineCustomModelsForDisplay().map(\.displayName)
        #expect(names == ["alpha", "Zebra"])
    }
}

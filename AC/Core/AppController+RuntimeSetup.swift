//
//  AppController+RuntimeSetup.swift
//  AC
//

import AppKit
import Foundation

@MainActor
extension AppController {
    var selectedLocalModelIdentifier: String {
        state.monitoringConfiguration.localModelIdentifierImage
            ?? state.monitoringConfiguration.localModelIdentifierText
            ?? state.aiTier.localModelIdentifierText
    }

    var localModelDiagnostics: RuntimeDiagnostics {
        RuntimeSetupService.inspect(
            runtimeOverride: state.runtimePathOverride,
            modelIdentifier: selectedLocalModelIdentifier
        )
    }

    var installedManagedModels: [InstalledLocalModel] {
        RuntimeSetupService.managedInstalledModels()
    }

    var selectedInstalledModel: InstalledLocalModel? {
        let installed = installedManagedModels
        guard !installed.isEmpty else { return nil }

        if let selectedInstalledModelCachePath,
            let exact = installed.first(where: { $0.cachePath == selectedInstalledModelCachePath })
        {
            return exact
        }

        if let current = installed.first(where: {
            $0.modelIdentifier == selectedLocalModelIdentifier
        }) {
            return current
        }

        return installed.first
    }

    func selectInstalledModel(cachePath: String) {
        selectedInstalledModelCachePath = cachePath
    }

    static func pendingLocalModelChange(from state: ACState) -> PendingLocalModelChange? {
        guard state.monitoringConfiguration.inferenceBackend == .local,
              let target = state.pendingLocalModelIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines),
              !target.isEmpty else {
            return nil
        }

        let savedFallback = state.pendingLocalModelFallbackIdentifier?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveFallback: String
        if let savedFallback, !savedFallback.isEmpty {
            effectiveFallback = savedFallback
        } else {
            effectiveFallback = state.monitoringConfiguration.localModelIdentifierImage
                ?? state.monitoringConfiguration.localModelIdentifierText
                ?? state.aiTier.localModelIdentifierText
        }
        return PendingLocalModelChange(
            modelIdentifier: target,
            fallbackIdentifier: effectiveFallback,
            autoSelectWhenReady: state.pendingLocalModelAutoSelect
        )
    }

    func setPendingLocalModelChange(_ change: PendingLocalModelChange?) {
        pendingLocalModelChange = change
        state.pendingLocalModelIdentifier = change?.modelIdentifier
        state.pendingLocalModelFallbackIdentifier = change?.fallbackIdentifier
        state.pendingLocalModelAutoSelect = change?.autoSelectWhenReady ?? true
    }

    func clearPendingLocalModelChange() {
        setPendingLocalModelChange(nil)
    }

    func localModelInstalled(_ identifier: String) -> Bool {
        RuntimeSetupService.inspect(
            runtimeOverride: state.runtimePathOverride,
            modelIdentifier: identifier
        ).modelArtifactsPresent
    }

    func localModelDownloadedBytes(_ identifier: String) -> Int64 {
        RuntimeSetupService.downloadedModelBytes(for: identifier)
    }

    func localCustomModelsForDisplay() -> [LocalCustomModel] {
        let catalog = Set(AITier.allCases.map(\.localModelIdentifierText))
        var modelsByID = state.localCustomModels.reduce(into: [String: LocalCustomModel]()) { partial, model in
            partial[model.modelIdentifier] = model
        }

        for installed in installedManagedModels where !catalog.contains(installed.modelIdentifier) {
            if modelsByID[installed.modelIdentifier] == nil {
                modelsByID[installed.modelIdentifier] = LocalCustomModel(
                    displayName: Self.shortModelName(for: installed.modelIdentifier),
                    modelIdentifier: installed.modelIdentifier
                )
            }
        }

        if let pending = pendingLocalModelChange,
           !catalog.contains(pending.modelIdentifier),
           modelsByID[pending.modelIdentifier] == nil {
            modelsByID[pending.modelIdentifier] = LocalCustomModel(
                displayName: Self.shortModelName(for: pending.modelIdentifier),
                modelIdentifier: pending.modelIdentifier
            )
        }

        let active = activeLocalModelIdentifier()
        if !catalog.contains(active), modelsByID[active] == nil {
            modelsByID[active] = LocalCustomModel(
                displayName: Self.shortModelName(for: active),
                modelIdentifier: active
            )
        }

        return modelsByID.values.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    func revealManagedModelLocation() {
        localModelStorageError = nil
        guard let selectedInstalledModel else {
            localModelStorageError = "No AC-downloaded local models were found."
            return
        }
        let targetPath = selectedInstalledModel.modelPath
        let url = URL(fileURLWithPath: targetPath)
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
            return
        }

        let parentURL = url.deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: parentURL.path) else {
            localModelStorageError = "The model folder does not exist yet."
            return
        }

        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: parentURL.path)
    }

    func deleteManagedModels() {
        guard !deletingManagedModels else { return }
        guard let selectedInstalledModel else {
            localModelStorageError = "No AC-downloaded local models were found."
            return
        }

        deletingManagedModels = true
        localModelStorageMessage = nil
        localModelStorageError = nil

        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.localModelRuntime.shutdown()

            do {
                let removed = try RuntimeSetupService.deleteCachesCreatedByAC(
                    for: selectedInstalledModel.modelIdentifier,
                    selectedCachePath: selectedInstalledModel.cachePath,
                    runtimePath: RuntimeSetupService.normalizedRuntimePath(
                        from: self.state.runtimePathOverride)
                )
                self.clearPendingLocalModelChange()
                self.modelDownloadNotice = nil
                self.modelDownloadSuccess = nil
                self.refreshSystemState()
                let remaining = self.installedManagedModels
                self.selectedInstalledModelCachePath = remaining.first?.cachePath
                self.localModelStorageMessage =
                    removed > 0
                    ? "Deleted \(Self.shortModelName(for: selectedInstalledModel.modelIdentifier))."
                    : "That AC-downloaded local model was already gone."
            } catch {
                self.localModelStorageError = error.localizedDescription
            }

            self.deletingManagedModels = false
        }
    }

    func importCurrentModelToOllama() {
        guard !importingModelToOllama else { return }
        guard let selectedInstalledModel else {
            localModelStorageError = "Download a local model first."
            return
        }
        guard let ollamaPath = Self.resolvedExecutablePath("ollama") else {
            localModelStorageError = "Ollama is not installed or not on PATH."
            return
        }

        importingModelToOllama = true
        localModelStorageMessage = nil
        localModelStorageError = nil

        let ollamaModelName = Self.ollamaModelName(for: selectedInstalledModel.modelIdentifier)
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await Self.importModelToOllama(
                    ollamaPath: ollamaPath,
                    modelPath: selectedInstalledModel.modelPath,
                    modelName: ollamaModelName
                )
                self.localModelStorageMessage =
                    "Imported to Ollama as \(ollamaModelName). Ollama stores its own copy; check `ollama list`."
            } catch {
                self.localModelStorageError = error.localizedDescription
            }
            self.importingModelToOllama = false
        }
    }

    /// Friendly label for the active model, used in the footer status line and its
    /// quick-switch menu. Built-in local tiers read "Default · Qwen 3.5 9B"; custom
    /// local models use the name the user gave them; online keeps the short name.
    /// Never the raw Hugging Face id.
    var activeModelFooterLabel: String {
        let config = state.monitoringConfiguration
        guard !config.usesOnlineInference else { return activeModelShortName }

        let id = activeLocalModelIdentifier()
        if let tier = AITier.allCases.first(where: { $0.localModelIdentifierText == id }) {
            return "\(tier.displayName) · \(tier.localModelDisplayName)"
        }
        if let custom = state.localCustomModels.first(where: { $0.modelIdentifier == id }) {
            return custom.displayName
        }
        return Self.shortModelName(for: id)
    }

    /// Renames a user-added custom local model card. No-op for built-in tiers or
    /// unknown identifiers. An empty name falls back to the derived short name.
    func renameCustomLocalModel(identifier: String, displayName: String) {
        let id = identifier.cleanedSingleLine
        guard let index = state.localCustomModels.firstIndex(where: { $0.modelIdentifier == id })
        else { return }
        let trimmed = displayName.cleanedSingleLine
        state.localCustomModels[index].displayName =
            trimmed.isEmpty ? Self.shortModelName(for: id) : trimmed
        state.localCustomModels.sort {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
        persistState()
        refreshSystemState(persist: false)
    }

    var activeModelShortName: String {
        let config = state.monitoringConfiguration

        if config.usesOnlineInference, directOpenAIEnabled {
            return Self.shortModelName(for: OnlineProviderRouting.directOpenAIModelIdentifier)
        }

        let textModel: String?
        let imageModel: String?

        if config.usesOnlineInference {
            textModel = config.onlineModelIdentifierText
            imageModel = config.onlineModelIdentifierImage
        } else {
            textModel = config.localModelIdentifierText
            imageModel = config.localModelIdentifierImage
        }

        if let text = textModel, !text.isEmpty,
            let image = imageModel, !image.isEmpty,
            text != image
        {
            return "\(Self.veryShortModelName(for: text)) / \(Self.veryShortModelName(for: image))"
        }

        let id = lastUsedModelIdentifier ?? Self.effectiveSetupModelIdentifier(for: config)
        return Self.shortModelName(for: id)
    }

    /// Converts a full OpenRouter/local model identifier to a compact display name.
    static func shortModelName(for identifier: String) -> String {
        let raw = identifier.trimmingCharacters(in: .whitespacesAndNewlines)

        // A user-linked file: name it after the filename, sans extension.
        if raw.hasPrefix("/"), raw.lowercased().hasSuffix(".gguf") {
            return URL(fileURLWithPath: raw).deletingPathExtension().lastPathComponent
        }

        let base = raw.hasSuffix(":free") ? String(raw.dropLast(5)) : raw

        // Known models → friendly names
        switch base {
        case "gpt-5.4-nano": return "GPT-5.4 Nano"
        case "google/gemma-4-31b-it": return "Gemma 4 31B"
        case "google/gemma-4-26b-a4b-it": return "Gemma 4 26B"
        case "mistralai/mistral-small-3.1-24b-instruct": return "Mistral Small 3.1"
        case "mistralai/mistral-small-24b-instruct-2501": return "Mistral Small"
        case "meta-llama/llama-4-scout": return "Llama 4 Scout"
        case "meta-llama/llama-4-maverick": return "Llama 4 Maverick"
        case "anthropic/claude-3.5-haiku": return "Claude 3.5 Haiku"
        case "anthropic/claude-3.5-sonnet": return "Claude 3.5 Sonnet"
        case "anthropic/claude-3-haiku": return "Claude 3 Haiku"
        case "google/gemini-flash-1.5": return "Gemini Flash 1.5"
        case "google/gemini-2.0-flash-001": return "Gemini 2 Flash"
        case "google/gemini-2.5-flash": return "Gemini 2.5 Flash"
        case "google/gemini-2.5-flash-preview": return "Gemini 2.5 Flash"
        case "moonshotai/kimi-k2.6": return "Kimi K2.6"
        case "qwen/qwen2.5-vl-72b-instruct": return "Qwen 2.5 VL"
        case "qwen/qwen3.5-9b": return "Qwen 3.5 9B"
        case "qwen/qwen3.6-35b-a3b": return "Qwen 3.6 35B"
        case "nvidia/nemotron-3-super-120b-a12b": return "Nemotron 3"
        case "deepseek/deepseek-v4-flash": return "DeepSeek V4"
        case "unsloth/gemma-4-E2B-it-GGUF:Q4_0": return "Gemma 4 2B"
        case "unsloth/gemma-4-E4B-it-GGUF:Q4_K_M": return "Gemma 4 4B"
        case "unsloth/Qwen3.5-4B-GGUF:UD-Q4_K_XL": return "Qwen 3.5 4B"
        case "unsloth/Qwen3.5-9B-GGUF:UD-Q4_K_XL": return "Qwen 3.5 9B"
        case "unsloth/Qwen3.6-27B-GGUF:UD-Q4_K_XL": return "Qwen 3.6 27B"

        default: break
        }

        // Generic fallback: strip provider prefix and the `:quant` suffix, then drop
        // GGUF/instruct noise so an auto-named custom model reads like a real name
        // (e.g. "unsloth/gemma-4-12b-it-GGUF:Q4_K_M" → "gemma-4-12b").
        let withoutQuant = base.split(separator: ":", maxSplits: 1).first.map(String.init) ?? base
        let modelPart = withoutQuant.components(separatedBy: "/").last ?? withoutQuant
        let cleaned =
            modelPart
            .replacingOccurrences(of: "-GGUF", with: "")
            .replacingOccurrences(of: "-gguf", with: "")
            .replacingOccurrences(of: "-instruct", with: "")
            .replacingOccurrences(of: "-it", with: "")
        return cleaned
    }

    /// Even more compact version for dual-model display (e.g. "DS V4 / Gema 31B").
    static func veryShortModelName(for identifier: String) -> String {
        let raw = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = raw.hasSuffix(":free") ? String(raw.dropLast(5)) : raw

        // Specific overrides for split view — prioritized over generic replacements
        switch base {
        case "gpt-5.4-nano": return "GPT-5.4N"
        case "deepseek/deepseek-v4-flash": return "DS V4"
        case "google/gemma-4-31b-it": return "Gema 31B"
        case "google/gemma-4-26b-a4b-it": return "Gema 26B"
        case "moonshotai/kimi-k2.6": return "Kimi K2.6"
        case "google/gemini-2.0-flash-001": return "Gem 2"
        case "nvidia/nemotron-3-super-120b-a12b": return "Nemot 3"
        case "qwen/qwen3.5-9b": return "Qwen 9B"
        case "qwen/qwen3.6-35b-a3b": return "Qwen 35B"
        case "unsloth/Qwen3.5-4B-GGUF:UD-Q4_K_XL": return "Qwen 4B"
        case "unsloth/Qwen3.5-9B-GGUF:UD-Q4_K_XL": return "Qwen 9B"
        default: break
        }

        let short = shortModelName(for: identifier)
        // If it's already reasonably short, keep it as is
        if short.count <= 8 { return short }

        // Otherwise apply common abbreviations
        return
            short
            .replacingOccurrences(of: "DeepSeek", with: "DS")
            .replacingOccurrences(of: "Gemini", with: "Gem")
            .replacingOccurrences(of: "Gemma", with: "Gema")
            .replacingOccurrences(of: "Mistral", with: "Mist")
    }

    /// On launch, rewrite persisted online model identifiers that map to models we no
    /// longer ship as defaults. The user's tier choice is authoritative; the tier-to-model
    /// mapping changed in v1, so we follow the tier and update the stored identifier.
    ///
    /// Only well-known deprecated identifiers are touched — custom models entered via
    /// Advanced mode are preserved untouched.
    static func migrateDeprecatedOnlineModelIdentifiers(in state: inout ACState) -> Bool {
        let deprecated: Set<String> = [
            "google/gemma-4-31b-it",
            "google/gemma-4-31b-it:free",
            "google/gemma-4-26b-a4b-it",
            "nvidia/nemotron-3-super-120b-a12b",
            "nvidia/nemotron-3-super-120b-a12b:free",
        ]
        let tier = state.aiTier
        var changed = false

        if let identifier = state.monitoringConfiguration.onlineModelIdentifierText,
            deprecated.contains(identifier)
        {
            state.monitoringConfiguration.onlineModelIdentifierText = tier.byokModelIdentifierText
            changed = true
        }
        if let identifier = state.monitoringConfiguration.onlineModelIdentifierImage,
            deprecated.contains(identifier)
        {
            state.monitoringConfiguration.onlineModelIdentifierImage = tier.byokModelIdentifierImage
            changed = true
        }
        return changed
    }

    /// Best-effort: delete the OpenRouter health-stats file so any bans/consecutive-
    /// failure counters from a model we just migrated away from don't poison the
    /// fresh model's first few requests.
    static func clearStaleOpenRouterHealthBans() {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AC/openrouter-health.json")
        try? FileManager.default.removeItem(at: url)
    }

    /// Returns the tier whose preset text/image models match `configuration` for the active backend.
    static func tierMatching(configuration: MonitoringConfiguration) -> AITier? {
        AITier.allCases.first {
            monitoringConfigurationMatchesTier($0, configuration: configuration)
        }
    }

    /// Whether persisted model identifiers match the preset for `tier` on the active backend.
    static func monitoringConfigurationMatchesTier(
        _ tier: AITier,
        configuration: MonitoringConfiguration
    ) -> Bool {
        switch configuration.inferenceBackend {
        case .openRouter:
            let text = configuration.onlineModelIdentifierText
                ?? configuration.onlineModelIdentifierImage
                ?? configuration.onlineModelIdentifier
            let image = configuration.onlineModelIdentifierImage
                ?? configuration.onlineModelIdentifierText
                ?? configuration.onlineModelIdentifier
            return OnlineModelService.modelIdentifiersEquivalent(text, tier.byokModelIdentifierText)
                && OnlineModelService.modelIdentifiersEquivalent(image, tier.byokModelIdentifierImage)
        case .local:
            guard let text = configuration.localModelIdentifierText,
                  let image = configuration.localModelIdentifierImage else {
                return false
            }
            return text == tier.localModelIdentifierText
                && image == tier.localModelIdentifierImage
        }
    }

    /// Writes the tier's preset models into `monitoringConfiguration` for the active backend.
    static func applyTierModels(_ tier: AITier, to configuration: inout MonitoringConfiguration) {
        switch configuration.inferenceBackend {
        case .openRouter:
            configuration.onlineModelIdentifierText = tier.byokModelIdentifierText
            configuration.onlineModelIdentifierImage = tier.byokModelIdentifierImage
        case .local:
            configuration.localModelIdentifierText = tier.localModelIdentifierText
            configuration.localModelIdentifierImage = tier.localModelIdentifierImage
        }
    }

    /// True when `identifier` is one of the built-in tier presets (not a custom Advanced pick).
    static func isKnownTierCatalogModel(
        _ identifier: String,
        inferenceBackend: MonitoringInferenceBackend
    ) -> Bool {
        AITier.allCases.contains { tier in
            let candidates: [String]
            switch inferenceBackend {
            case .openRouter:
                candidates = [tier.byokModelIdentifierText, tier.byokModelIdentifierImage]
            case .local:
                candidates = [tier.localModelIdentifierText, tier.localModelIdentifierImage]
            }
            return candidates.contains {
                inferenceBackend == .openRouter
                    ? OnlineModelService.modelIdentifiersEquivalent($0, identifier)
                    : $0 == identifier
            }
        }
    }

    /// Keeps `aiTier` aligned with the models AC will actually call. Settings shows tier from
    /// `aiTier` but inference reads `monitoringConfiguration` — they can drift after migrations,
    /// tier mapping updates, or partial saves.
    @discardableResult
    static func reconcileAIModelSelection(in state: inout ACState) -> Bool {
        var changed = false
        let configuration = state.monitoringConfiguration
        if let matchingTier = tierMatching(configuration: configuration) {
            if state.aiTier != matchingTier {
                state.aiTier = matchingTier
                changed = true
            }
        } else if !monitoringConfigurationMatchesTier(state.aiTier, configuration: configuration) {
            let backend = configuration.inferenceBackend
            let textModel: String?
            let imageModel: String?
            switch backend {
            case .openRouter:
                textModel = configuration.onlineModelIdentifierText
                    ?? configuration.onlineModelIdentifierImage
                imageModel = configuration.onlineModelIdentifierImage
                    ?? configuration.onlineModelIdentifierText
            case .local:
                textModel = configuration.localModelIdentifierText
                imageModel = configuration.localModelIdentifierImage
            }
            if let textModel,
               let imageModel,
               isKnownTierCatalogModel(textModel, inferenceBackend: backend),
               isKnownTierCatalogModel(imageModel, inferenceBackend: backend) {
                applyTierModels(state.aiTier, to: &state.monitoringConfiguration)
                changed = true
            }
        }
        return changed
    }

    /// When cadence was persisted but the vision gate still reflects another cadence preset
    /// (e.g. sharp cadence + gentle title-length threshold), monitoring feels like the wrong mode.
    @discardableResult
    static func reconcileCadenceTitleLength(in state: inout ACState) -> Bool {
        let current = state.monitoringConfiguration.titleLengthForTextOnly
        let expected = state.monitoringConfiguration.cadenceMode.recommendedTitleLengthForTextOnly
        guard current != expected else { return false }

        let matchesAnotherCadence = MonitoringCadenceMode.allCases.contains { mode in
            mode != state.monitoringConfiguration.cadenceMode
                && current == mode.recommendedTitleLengthForTextOnly
        }
        guard matchesAnotherCadence else { return false }

        state.monitoringConfiguration.titleLengthForTextOnly = expected
        return true
    }

    func updateMonitoringInferenceBackend(_ backend: MonitoringInferenceBackend) {
        guard state.monitoringConfiguration.inferenceBackend != backend else { return }
        state.monitoringConfiguration.inferenceBackend = backend
        if backend == .openRouter {
            // Switching away from Local must actually stop any in-flight runtime
            // install / model download. Without this the llama.cpp download keeps
            // running and installingRuntime stays true, which pins setupStatus at
            // .installing ("setup needed") until the app is restarted.
            cancelRuntimeInstall()
            clearPendingLocalModelChange()
            modelDownloadNotice = nil
            prewarmTask?.cancel()
            prewarmTask = nil
            localModelWarmupState = .idle
            Task { [localModelRuntime] in
                await localModelRuntime.scheduleShutdown(
                    after: 130,  // keep it long so that if user accidently swithces to byok, its not restarted for nothing AND importantly: so that pending local requests still work
                    reason: "backend_switched_to_byok"
                )
            }
        } else {
            Task { [localModelRuntime] in
                await localModelRuntime.cancelScheduledShutdown()
            }
        }
        state.monitoringConfiguration.pipelineProfileID =
            backend == .openRouter
            ? (visionEnabled
                ? MonitoringConfiguration.defaultOnlineVisionPipelineProfileID
                : MonitoringConfiguration.defaultOnlineTextPipelineProfileID)
            : (visionEnabled
                ? MonitoringConfiguration.defaultPipelineProfileID
                : "title_only_default")
        // Re-apply the current tier's model for the new backend
        applyTierToActiveBackend()
        updateDisplayedModelIdentifier()
        brainService?.handleMonitoringConfigurationChange()
        refreshSystemState(persist: false)
        persistState()
        // Switching to Local would otherwise make the first query pay a full cold
        // model-load + prefill. Warm it now (no-ops for OpenRouter or a not-yet-
        // downloaded model).
        schedulePrewarmIfNeeded()
        logActivity("monitoring", "Inference backend: \(backend.rawValue)")
    }

    func updateOnlineModelIdentifierText(_ identifier: String?) {
        guard state.monitoringConfiguration.onlineModelIdentifierText != identifier else { return }
        state.monitoringConfiguration.onlineModelIdentifierText = identifier
        brainService?.handleMonitoringConfigurationChange()
        refreshSystemState(persist: false)
        persistState()
        logActivity("monitoring", "Online text model: \(identifier ?? "cleared")")
    }

    func updateOnlineModelIdentifierImage(_ identifier: String?) {
        guard state.monitoringConfiguration.onlineModelIdentifierImage != identifier else { return }
        state.monitoringConfiguration.onlineModelIdentifierImage = identifier
        brainService?.handleMonitoringConfigurationChange()
        refreshSystemState(persist: false)
        persistState()
        logActivity("monitoring", "Online image model: \(identifier ?? "cleared")")
    }

    // MARK: - Custom online models

    /// The user-added OpenRouter models, sorted by name. The online analogue of
    /// `localCustomModelsForDisplay()` — but with no "installed" concept, since an
    /// online model needs no download.
    func onlineCustomModelsForDisplay() -> [OnlineCustomModel] {
        state.onlineCustomModels.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    /// The text/image pair currently driving online inference, falling back to the
    /// active tier's defaults when the config hasn't overridden them. Used to decide
    /// which card (tier or custom) renders as active.
    func activeOnlineModelIdentifiers() -> (text: String, image: String) {
        let config = state.monitoringConfiguration
        let text = config.onlineModelIdentifierText ?? state.aiTier.byokModelIdentifierText
        let image = config.onlineModelIdentifierImage ?? state.aiTier.byokModelIdentifierImage
        return (text, image)
    }

    /// The custom online model (if any) whose pair matches the active identifiers.
    func activeOnlineCustomModel() -> OnlineCustomModel? {
        let active = activeOnlineModelIdentifiers()
        return state.onlineCustomModels.first {
            $0.textModelIdentifier == active.text && $0.imageModelIdentifier == active.image
        }
    }

    /// Validates a text/image pair against OpenRouter's catalog and, on success,
    /// adds (or updates) a named custom-model card. Mirrors `addCustomLocalModel`,
    /// but online models are verified before they're persisted so a card never
    /// silently fails at runtime. Sets `validatingOnlineModel` / `addOnlineModelError`.
    func addCustomOnlineModel(displayName: String, textID: String, imageID: String) async {
        let text = textID.cleanedSingleLine
        let image = imageID.cleanedSingleLine
        guard !text.isEmpty, !image.isEmpty else {
            addOnlineModelError = "Enter both a text model and an image model."
            return
        }

        validatingOnlineModel = true
        addOnlineModelError = nil
        let key = onlineAPIKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try await onlineModelService.validateCustomOnlineModels(
                textID: text,
                imageID: image,
                apiKey: key.isEmpty ? nil : key
            )
        } catch {
            validatingOnlineModel = false
            addOnlineModelError = error.localizedDescription
            return
        }

        let name = displayName.cleanedSingleLine.isEmpty
            ? Self.shortModelName(for: text)
            : displayName.cleanedSingleLine

        if let index = state.onlineCustomModels.firstIndex(where: {
            $0.textModelIdentifier == text && $0.imageModelIdentifier == image
        }) {
            state.onlineCustomModels[index].displayName = name
        } else {
            state.onlineCustomModels.append(
                OnlineCustomModel(displayName: name, textModelIdentifier: text, imageModelIdentifier: image)
            )
        }
        state.onlineCustomModels.sort {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
        validatingOnlineModel = false
        addOnlineModelError = nil
        persistState()
        refreshSystemState(persist: false)
        logActivity("monitoring", "Custom online model added: \(text) / \(image)")
    }

    func renameCustomOnlineModel(id: String, displayName: String) {
        guard let index = state.onlineCustomModels.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = displayName.cleanedSingleLine
        state.onlineCustomModels[index].displayName =
            trimmed.isEmpty ? Self.shortModelName(for: state.onlineCustomModels[index].textModelIdentifier) : trimmed
        state.onlineCustomModels.sort {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
        persistState()
        refreshSystemState(persist: false)
    }

    /// Removes a custom online model card. If the removed card was the active one,
    /// AC falls back to the current tier's default models.
    func removeCustomOnlineModel(id: String) {
        guard let model = state.onlineCustomModels.first(where: { $0.id == id }) else { return }
        let wasActive = activeOnlineCustomModel()?.id == id
        state.onlineCustomModels.removeAll { $0.id == id }
        if wasActive {
            // Reset to the current tier's defaults via the shared tier-apply path.
            applyTierToActiveBackend()
            updateDisplayedModelIdentifier()
            brainService?.handleMonitoringConfigurationChange()
        }
        persistState()
        refreshSystemState(persist: false)
        logActivity("monitoring", "Custom online model removed: \(model.textModelIdentifier)")
    }

    /// Selects a custom online model: points both online identifiers at its pair.
    /// Does not touch `state.aiTier`, so tier cards naturally deselect (their pair no
    /// longer matches the active identifiers).
    func selectOnlineCustomModel(_ model: OnlineCustomModel) {
        updateOnlineModelIdentifierText(model.textModelIdentifier)
        updateOnlineModelIdentifierImage(model.imageModelIdentifier)
        updateDisplayedModelIdentifier()
    }

    // MARK: - Add-form drafts (shared by local + online custom-model forms)

    /// The model identifier the in-progress local add form would produce: a Hugging
    /// Face GGUF repo id, or the absolute path of a linked `.gguf`.
    var localModelDraftIdentifier: String {
        switch localModelDraftSource {
        case .huggingFace: return localModelDraftRepo.trimmingCharacters(in: .whitespacesAndNewlines)
        case .file: return localModelDraftFilePath.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    func addCustomLocalModelFromDraft() {
        let id = localModelDraftIdentifier
        guard !id.isEmpty else { return }
        addCustomLocalModel(displayName: localModelDraftName, modelIdentifier: id)
        resetLocalModelDraft()
    }

    func resetLocalModelDraft() {
        addLocalModelExpanded = false
        localModelDraftSource = .huggingFace
        localModelDraftName = ""
        localModelDraftRepo = ""
        localModelDraftFilePath = ""
    }

    /// Validates and adds the in-progress online model, clearing the draft on success
    /// (a validation failure keeps the form open with its text so the user can fix it).
    func addCustomOnlineModelFromDraft() async {
        await addCustomOnlineModel(
            displayName: onlineModelDraftName,
            textID: onlineModelDraftText,
            imageID: onlineModelDraftImage
        )
        if addOnlineModelError == nil {
            resetOnlineModelDraft()
        }
    }

    func resetOnlineModelDraft() {
        addOnlineModelExpanded = false
        onlineModelDraftName = ""
        onlineModelDraftText = ""
        onlineModelDraftImage = ""
        addOnlineModelError = nil
    }

    func updateLocalModelIdentifierText(_ identifier: String?) {
        updateLocalModelIdentifier(identifier)
    }

    func updateLocalModelIdentifierImage(_ identifier: String?) {
        updateLocalModelIdentifier(identifier)
    }

    func updateLocalModelIdentifier(_ identifier: String?) {
        let trimmed = identifier?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let target = trimmed, !target.isEmpty else { return }

        let diagnostics = RuntimeSetupService.inspect(
            runtimeOverride: state.runtimePathOverride,
            modelIdentifier: target
        )

        if diagnostics.modelArtifactsPresent {
            cancelRuntimeInstall()
            clearPendingLocalModelChange()
            modelDownloadNotice = nil
            modelDownloadSuccess = nil
            applyLocalModelSelection(textModel: target, imageModel: target)
            brainService?.handleMonitoringConfigurationChange()
            refreshSystemState(persist: false)
            persistState()
            schedulePrewarmIfNeeded()
            logActivity("monitoring", "Local model: \(target)")
            return
        }

        let fallback = activeLocalModelIdentifier()
        _ = queueLocalModelDownloadIfNeeded(
            targetModelIdentifier: target,
            fallbackIdentifier: fallback,
            autoSelectWhenReady: true
        )
        refreshSystemState(persist: false)
        persistState()
        logActivity("monitoring", "Queued local model download: \(target)")
    }

    func useInstalledLocalModel(_ identifier: String) {
        updateLocalModelIdentifier(identifier)
    }

    func selectInstalledLocalModel(identifier: String, tier: AITier? = nil) {
        guard localModelInstalled(identifier) else { return }
        if let tier {
            state.aiTier = tier
        }
        applyLocalModelSelection(textModel: identifier, imageModel: identifier)
        if let pending = pendingLocalModelChange {
            if pending.modelIdentifier == identifier {
                clearPendingLocalModelChange()
            } else {
                setPendingLocalModelChange(
                    PendingLocalModelChange(
                        modelIdentifier: pending.modelIdentifier,
                        fallbackIdentifier: identifier,
                        autoSelectWhenReady: pending.autoSelectWhenReady
                    )
                )
            }
        }
        modelDownloadNotice = nil
        modelDownloadSuccess = nil
        brainService?.handleMonitoringConfigurationChange()
        refreshSystemState(persist: false)
        persistState()
        schedulePrewarmIfNeeded()
        logActivity("monitoring", "Local model selected: \(identifier)")
    }

    func addCustomLocalModel(displayName: String, modelIdentifier: String) {
        let identifier = modelIdentifier.cleanedSingleLine
        guard !identifier.isEmpty else { return }
        let name = displayName.cleanedSingleLine.isEmpty
            ? Self.shortModelName(for: identifier)
            : displayName.cleanedSingleLine
        let model = LocalCustomModel(displayName: name, modelIdentifier: identifier)
        if let index = state.localCustomModels.firstIndex(where: { $0.modelIdentifier == identifier }) {
            state.localCustomModels[index] = model
        } else {
            state.localCustomModels.append(model)
        }
        state.localCustomModels.sort {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
        persistState()
    }

    /// Removes a user-added custom local model card entirely: cancels any in-flight
    /// download, clears pending/error state, deletes any partial or full downloaded
    /// cache, and drops the card from `localCustomModels`. Built-in tier models are
    /// never custom, so this should only be called for custom cards. This is the
    /// escape hatch for a custom model whose download never resolved on Hugging
    /// Face — there is otherwise no way to make a failed, never-installed card go away.
    func removeCustomLocalModel(identifier: String) {
        let id = identifier.cleanedSingleLine
        guard !id.isEmpty else { return }

        if pendingLocalModelChange?.modelIdentifier == id {
            cancelRuntimeInstall()
            clearPendingLocalModelChange()
        }
        setupErrorMessage = nil
        modelDownloadNotice = nil

        // A linked file lives on the user's own disk — removing the card must never
        // delete their file. Just drop the card and fall back if it was active.
        let isLinkedFile = RuntimeSetupService.isLocalFileModelIdentifier(id)
        let wasActive = activeLocalModelIdentifier() == id
        let hadDownload = !isLinkedFile && (localModelInstalled(id) || localModelDownloadedBytes(id) > 0)

        state.localCustomModels.removeAll { $0.modelIdentifier == id }
        persistState()

        if hadDownload {
            // Reuse the tested deletion path for cache cleanup + active-model fallback.
            deleteLocalModel(identifier: id)
        } else {
            if isLinkedFile, wasActive {
                let fallback = installedManagedModels.first?.modelIdentifier
                    ?? AITier.recommendedLocalTier().localModelIdentifierText
                applyLocalModelSelection(textModel: fallback, imageModel: fallback)
                brainService?.handleMonitoringConfigurationChange()
            }
            localModelStorageError = nil
            refreshSystemState(persist: false)
        }
    }

    func startLocalModelDownload(identifier: String, autoSelectWhenReady: Bool = false) {
        let target = identifier.cleanedSingleLine
        guard !target.isEmpty, !localModelInstalled(target) else { return }
        _ = queueLocalModelDownloadIfNeeded(
            targetModelIdentifier: target,
            fallbackIdentifier: activeLocalModelIdentifier(),
            autoSelectWhenReady: autoSelectWhenReady
        )
        refreshSystemState(persist: false)
        persistState()
    }

    func pauseLocalModelDownload(identifier: String) {
        guard pendingLocalModelChange?.modelIdentifier == identifier, installingRuntime else { return }
        cancelRuntimeInstall()
        refreshSystemState(persist: false)
        persistState()
    }

    func resumeLocalModelDownload(identifier: String) {
        let target = identifier.cleanedSingleLine
        guard !target.isEmpty, !installingRuntime, !localModelInstalled(target) else { return }
        if pendingLocalModelChange?.modelIdentifier != target {
            setPendingLocalModelChange(
                PendingLocalModelChange(
                    modelIdentifier: target,
                    fallbackIdentifier: activeLocalModelIdentifier(),
                    autoSelectWhenReady: false
                )
            )
        }
        installRuntime(modelIdentifier: target)
        refreshSystemState(persist: false)
        persistState()
    }

    func stopLocalModelDownload(identifier: String, deleteCache: Bool = true) {
        guard pendingLocalModelChange?.modelIdentifier == identifier else { return }
        cancelRuntimeInstall()
        clearPendingLocalModelChange()
        modelDownloadNotice = nil
        if deleteCache {
            try? RuntimeSetupService.deleteManagedModelCache(for: identifier)
        }
        refreshSystemState(persist: false)
        persistState()
    }

    func deleteLocalModel(identifier: String) {
        guard !deletingManagedModels else { return }
        deletingManagedModels = true
        localModelStorageMessage = nil
        localModelStorageError = nil

        Task { @MainActor [weak self] in
            guard let self else { return }
            if self.activeLocalModelIdentifier() == identifier {
                await self.localModelRuntime.shutdown()
            }
            do {
                let diagnostics = RuntimeSetupService.inspect(
                    runtimeOverride: self.state.runtimePathOverride,
                    modelIdentifier: identifier
                )
                let removed = try RuntimeSetupService.deleteCachesCreatedByAC(
                    for: identifier,
                    selectedCachePath: diagnostics.modelCachePath,
                    runtimePath: RuntimeSetupService.normalizedRuntimePath(from: self.state.runtimePathOverride)
                )
                if self.pendingLocalModelChange?.modelIdentifier == identifier {
                    self.clearPendingLocalModelChange()
                }
                if self.activeLocalModelIdentifier() == identifier,
                   let fallback = self.installedManagedModels.first(where: { $0.modelIdentifier != identifier }) {
                    self.applyLocalModelSelection(
                        textModel: fallback.modelIdentifier,
                        imageModel: fallback.modelIdentifier
                    )
                }
                self.localModelStorageMessage = removed > 0
                    ? "Deleted \(Self.shortModelName(for: identifier))."
                    : "That local model was already gone."
                self.brainService?.handleMonitoringConfigurationChange()
                self.refreshSystemState(persist: false)
                self.persistState()
            } catch {
                self.localModelStorageError = error.localizedDescription
            }
            self.deletingManagedModels = false
        }
    }

    func updateOnlineAPIKey(_ value: String) {
        onlineAPIKeyDraft = value
        _ = OnlineProviderCredentialStore.saveOpenRouterAPIKey(value)
        Task {
            await OpenRouterHealthStatsService.shared.clearBans()
        }
        refreshSystemState()
        refreshOpenRouterKeyInfo()
    }

    func updateDirectOpenAIAPIKey(_ value: String) {
        directOpenAIAPIKeyDraft = value
        _ = OnlineProviderCredentialStore.saveDirectOpenAIAPIKey(value)
        refreshSystemState()
    }

    func updateDirectOpenAIEnabled(_ enabled: Bool) {
        directOpenAIEnabled = enabled
        OnlineProviderRoutingStore.saveDirectOpenAIEnabled(enabled)
        refreshSystemState()
    }

    /// Non-nil when the most recently served model differs from the one currently
    /// selected in Settings. Used to show a transparent notice in the AI tab.
    var modelMismatchNotice: String? {
        if state.monitoringConfiguration.usesOnlineInference, directOpenAIEnabled {
            return
                "Direct OpenAI mode active: all online LLM traffic uses \(OnlineProviderRouting.directOpenAIModelIdentifier)."
        }
        if !state.monitoringConfiguration.usesOnlineInference,
           let pending = pendingLocalModelChange {
            let pendingName = Self.shortModelName(for: pending.modelIdentifier)
            let fallbackName = Self.shortModelName(for: pending.fallbackIdentifier)
            if pending.autoSelectWhenReady {
                return "Downloading \(pendingName). Using \(fallbackName) until it finishes, then AC will switch automatically."
            }
            return "Downloading \(pendingName). Current active model stays \(fallbackName)."
        }
        guard let lastUsed = lastUsedModelIdentifier else { return nil }
        let config = state.monitoringConfiguration
        let configured: String
        if config.usesOnlineInference {
            configured =
                config.onlineModelIdentifierText
                ?? config.onlineModelIdentifierImage
                ?? config.onlineModelIdentifier
        } else {
            configured =
                config.localModelIdentifierText
                ?? config.localModelIdentifierImage
                ?? AITier.balanced.localModelIdentifierText
        }
        guard !OnlineModelService.modelIdentifiersEquivalent(lastUsed, configured) else {
            return nil
        }
        let usedShort = Self.shortModelName(for: lastUsed)
        let configShort = Self.shortModelName(for: configured)
        return "Using \(usedShort) while \(configShort) is temporarily unavailable."
    }

    func refreshOpenRouterKeyInfo() {
        guard hasOnlineAPIKeyConfigured else {
            openRouterKeyInfo = nil
            openRouterKeyInfoError = nil
            return
        }
        let key = onlineAPIKeyDraft
        let hadConnectionProblem = connectionProblemNotice != nil
        let previouslyEmptyBudget = openRouterKeyInfo.map { !Self.openRouterKeyHasUsableBudget($0) } ?? false
        Task { [weak self, onlineModelService] in
            do {
                let info = try await onlineModelService.fetchKeyInfo(apiKey: key)
                let hasUsableBudget = Self.openRouterKeyHasUsableBudget(info)
                if hasUsableBudget && (hadConnectionProblem || previouslyEmptyBudget) {
                    await OpenRouterHealthStatsService.shared.clearBans()
                }
                await MainActor.run {
                    self?.openRouterKeyInfo = info
                    self?.openRouterKeyInfoError = nil
                    if hasUsableBudget && (hadConnectionProblem || previouslyEmptyBudget) {
                        self?.connectionProblemNotice = nil
                        self?.brainService?.invalidateContextAndCooldown(reason: "openrouter_credits_restored")
                    }
                }
            } catch {
                await MainActor.run {
                    self?.openRouterKeyInfo = nil
                    self?.openRouterKeyInfoError = error.localizedDescription
                }
            }
        }
    }

    private static func openRouterKeyHasUsableBudget(_ info: OpenRouterKeyInfo) -> Bool {
        guard let remaining = info.data.limitRemaining else {
            return true
        }
        return remaining > 0
    }

    // MARK: - Onboarding wizard

    func completeOnboardingWizard() {
        hasCompletedOnboardingWizard = true
        UserDefaults.standard.set(true, forKey: "acOnboardingWizardCompleted")
        UserDefaults.standard.set(true, forKey: "acOnboardingWizardEverCompleted")
        // Clear resumable in-progress state — the wizard is done.
        UserDefaults.standard.removeObject(forKey: "acOnboardingResumeStep")
        UserDefaults.standard.removeObject(forKey: "acOnboardingResumeStep2")
        UserDefaults.standard.removeObject(forKey: "acOnboardingResumeMode")
        refreshSystemState()
    }

    func resetOnboardingWizard() {
        hasCompletedOnboardingWizard = false
        UserDefaults.standard.set(false, forKey: "acOnboardingWizardCompleted")
        UserDefaults.standard.set(false, forKey: "acOnboardingWizardEverCompleted")
        UserDefaults.standard.removeObject(forKey: "acOnboardingResumeStep")
        UserDefaults.standard.removeObject(forKey: "acOnboardingResumeStep2")
        UserDefaults.standard.removeObject(forKey: "acOnboardingResumeMode")
        showingOnboardingCompletion = false
        refreshSystemState()
    }

    // MARK: - AI tier

    var currentAITier: AITier { state.aiTier }

    func updateAITier(_ tier: AITier) {
        guard state.aiTier != tier else { return }
        state.aiTier = tier
        applyTierToActiveBackend()
        updateDisplayedModelIdentifier()
        brainService?.handleMonitoringConfigurationChange()
        refreshSystemState()
        persistState()
        logActivity("monitoring", "AI tier: \(tier.rawValue)")
    }

    func applyTierToActiveBackend() {
        let previousLocalModelIdentifier = activeLocalModelIdentifier()
        Self.applyTierModels(state.aiTier, to: &state.monitoringConfiguration)
        switch state.monitoringConfiguration.inferenceBackend {
        case .openRouter:
            break
        case .local:
            if !queueLocalModelDownloadIfNeeded(
                targetModelIdentifier: state.aiTier.localModelIdentifierText,
                fallbackIdentifier: previousLocalModelIdentifier
            ) {
                clearPendingLocalModelChange()
                modelDownloadNotice = nil
                modelDownloadSuccess = nil
                cancelRuntimeInstall()
                applyLocalModelSelection(
                    textModel: state.aiTier.localModelIdentifierText,
                    imageModel: state.aiTier.localModelIdentifierImage
                )
            }
        }
    }

    func updateDisplayedModelIdentifier() {
        lastUsedModelIdentifier = Self.effectiveSetupModelIdentifier(
            for: state.monitoringConfiguration)
    }

    func runtimeProfileModelIdentifier() -> String {
        state.monitoringConfiguration.localModelIdentifierText
            ?? state.aiTier.localModelIdentifierText
    }

    func activeLocalModelIdentifier() -> String {
        if let imageModel = state.monitoringConfiguration.localModelIdentifierImage,
            !imageModel.isEmpty
        {
            return imageModel
        }
        if let textModel = state.monitoringConfiguration.localModelIdentifierText,
            !textModel.isEmpty
        {
            return textModel
        }
        return runtimeProfileModelIdentifier()
    }

    func applyLocalModelSelection(textModel: String?, imageModel: String?) {
        state.monitoringConfiguration.localModelIdentifierText = textModel
        state.monitoringConfiguration.localModelIdentifierImage = imageModel ?? textModel
        let effectiveModel = activeLocalModelIdentifier()
        let lowerModel = effectiveModel.lowercased()
        let isTextOnly =
            lowerModel.contains("phi") && !lowerModel.contains("vision")
            && !lowerModel.contains("multimodal")
        if isTextOnly && visionEnabled {
            state.monitoringConfiguration.pipelineProfileID = "title_only_default"
        }
    }

    func applyLocalModelFallback(_ fallbackIdentifier: String) {
        applyLocalModelSelection(textModel: fallbackIdentifier, imageModel: fallbackIdentifier)
    }

    @discardableResult
    func queueLocalModelDownloadIfNeeded(
        targetModelIdentifier: String,
        fallbackIdentifier: String,
        autoSelectWhenReady: Bool = true
    ) -> Bool {
        let diagnostics = RuntimeSetupService.inspect(
            runtimeOverride: state.runtimePathOverride,
            modelIdentifier: targetModelIdentifier
        )
        guard !diagnostics.modelArtifactsPresent else { return false }

        let targetName = Self.shortModelName(for: targetModelIdentifier)
        let fallbackName = Self.shortModelName(for: fallbackIdentifier)
        let shouldRestartInstall = installingRuntime
            && pendingLocalModelChange?.modelIdentifier != targetModelIdentifier
        if shouldRestartInstall {
            cancelRuntimeInstall()
        }
        setPendingLocalModelChange(
            PendingLocalModelChange(
                modelIdentifier: targetModelIdentifier,
                fallbackIdentifier: fallbackIdentifier,
                autoSelectWhenReady: autoSelectWhenReady
            )
        )
        modelDownloadNotice = ModelDownloadNotice(
            modelIdentifier: targetModelIdentifier,
            modelDisplayName: targetName,
            fallbackDisplayName: fallbackName
        )
        if autoSelectWhenReady {
            applyLocalModelFallback(fallbackIdentifier)
        }

        if !installingRuntime {
            installRuntime(modelIdentifier: targetModelIdentifier)
        }
        return true
    }

    @discardableResult
    func applyPendingLocalModelIfReady() -> Bool {
        guard let pending = pendingLocalModelChange else { return false }
        guard state.monitoringConfiguration.inferenceBackend == .local else {
            clearPendingLocalModelChange()
            return true
        }
        let diagnostics = RuntimeSetupService.inspect(
            runtimeOverride: state.runtimePathOverride,
            modelIdentifier: pending.modelIdentifier
        )
        guard diagnostics.modelArtifactsPresent else { return false }

        if pending.autoSelectWhenReady {
            applyLocalModelSelection(
                textModel: pending.modelIdentifier,
                imageModel: pending.modelIdentifier
            )
        }
        clearPendingLocalModelChange()
        modelDownloadSuccess = ModelDownloadSuccess(
            modelIdentifier: pending.modelIdentifier,
            modelDisplayName: Self.shortModelName(for: pending.modelIdentifier)
        )
        modelDownloadNotice = nil
        if pending.autoSelectWhenReady {
            brainService?.handleMonitoringConfigurationChange()
        }
        persistState()
        return true
    }

    func resumePendingLocalModelDownloadIfNeeded() {
        guard state.monitoringConfiguration.inferenceBackend == .local,
              let pending = pendingLocalModelChange,
              !installingRuntime else {
            return
        }

        let diagnostics = RuntimeSetupService.inspect(
            runtimeOverride: state.runtimePathOverride,
            modelIdentifier: pending.modelIdentifier
        )
        if diagnostics.modelArtifactsPresent {
            _ = applyPendingLocalModelIfReady()
            return
        }

        guard setupDiagnostics.canInstall else { return }
        installRuntime(modelIdentifier: pending.modelIdentifier)
    }

    func installMissingDependencies() {
        guard !installingDependencies else { return }

        let missingTools = setupDiagnostics.missingTools
        guard !missingTools.isEmpty else {
            refreshSystemState()
            return
        }

        dependencyInstallPromptVisible = false
        installingDependencies = true
        setupErrorMessage = nil
        appendSetupLog("Preparing dependency install for: \(missingTools.joined(separator: ", "))")
        logActivity(
            "setup", "Installing missing dependencies: \(missingTools.joined(separator: ", "))")
        refreshSystemState()

        Task {
            do {
                try await DependencyInstallerService.installMissingTools(missingTools) {
                    [weak self] chunk in
                    self?.appendSetupLog(chunk)
                }
                logActivity("setup", "Dependency install finished")
            } catch {
                setupErrorMessage = error.localizedDescription
                logActivity("setup", "Dependency install failed: \(error.localizedDescription)")
            }

            installingDependencies = false
            refreshSystemState()
        }
    }

    /// Cancels an in-flight runtime install/download and clears all transient setup
    /// progress state. Safe to call when nothing is installing. The install task's
    /// cancellation path intentionally leaves these flags for its canceller to reset.
    func cancelRuntimeInstall() {
        installRuntimeTask?.cancel()
        installRuntimeTask = nil
        stopDownloadProgressPolling()
        if installingRuntime {
            installingRuntime = false
        }
        setupProgressValue = nil
        setupProgressMessage = nil
        setupDownloadedBytes = nil
        setupTotalBytes = nil
    }

    /// Polls the on-disk model cache to drive a real byte-level progress bar while
    /// llama.cpp downloads the model. Total size is fetched once (best-effort) from
    /// Hugging Face; the downloaded figure comes from summing the cache blob sizes.
    func startDownloadProgressPolling(modelIdentifier: String) {
        downloadProgressTask?.cancel()
        setupDownloadedBytes = nil
        setupTotalBytes = nil

        downloadProgressTask = Task { [weak self] in
            // Resolve the specific files this model downloads (chosen quant + projector)
            // so progress reflects exactly those blobs, not whatever else is in the cache.
            let expectedFiles = await RuntimeSetupService.expectedModelFiles(for: modelIdentifier)
            let oids = expectedFiles.compactMap(\.oid)
            let total = expectedFiles.reduce(Int64(0)) { $0 + $1.size }
            let cacheRoot = RuntimeSetupService.managedModelCacheURL(for: modelIdentifier)
            await MainActor.run { self?.setupTotalBytes = total > 0 ? total : nil }

            while !Task.isCancelled {
                // Prefer the oid-scoped measurement; fall back to the whole-cache sum only
                // when the manifest is unavailable (offline / private repo).
                let downloaded =
                    oids.isEmpty
                    ? RuntimeSetupService.downloadedModelBytes(for: modelIdentifier)
                    : RuntimeSetupService.downloadedModelBytes(forOids: oids, inCacheRoot: cacheRoot)
                await MainActor.run {
                    guard let self else { return }
                    self.setupDownloadedBytes = downloaded
                    if let total = self.setupTotalBytes, total > 0 {
                        self.setupProgressValue = max(0, Double(downloaded) / Double(total))
                    }
                }
                try? await Task.sleep(nanoseconds: 600_000_000)
            }
        }
    }

    func stopDownloadProgressPolling() {
        downloadProgressTask?.cancel()
        downloadProgressTask = nil
    }

    /// Logs achieved download throughput so we can tell, in the wild, whether real users
    /// are throttle-capped or pipe-limited — and whether the HF token actually helps.
    /// Skips when nothing meaningful was fetched (model already cached → fast warm-up).
    func logModelDownloadThroughput(
        modelIdentifier: String,
        bytesBeforeDownload: Int64,
        startedAt: Date,
        authenticated: Bool
    ) {
        let downloadedThisRun =
            RuntimeSetupService.downloadedModelBytes(for: modelIdentifier) - bytesBeforeDownload
        let elapsed = Date().timeIntervalSince(startedAt)
        guard downloadedThisRun > 5_000_000, elapsed > 1 else { return }

        let megabytes = Double(downloadedThisRun) / 1_000_000
        let mbps = megabytes / elapsed
        logActivity(
            "setup-download-speed",
            String(
                format: "Model download: %.0f MB in %.0fs (%.2f MB/s) [%@]",
                megabytes,
                elapsed,
                mbps,
                authenticated ? "authenticated" : "unauthenticated"
            )
        )
    }

    /// Roll an existing, working install forward to the pinned llama.cpp commit by
    /// re-fetching, checking out, and rebuilding in place — **without** dropping the
    /// user back into onboarding. This is deliberately separate from `installRuntime`:
    ///
    /// - It does not touch `installingRuntime` / `setupStatus`, so the app stays
    ///   `.ready` and the existing `llama-server` keeps serving its previous binary
    ///   inode (monitoring + chat continue) throughout the rebuild.
    /// - Progress is surfaced inline via `updatingRuntime` / `runtimeUpdateMessage`
    ///   (the AITab banner), not the full-screen setup flow.
    /// - On success it cycles the shared server onto the new binary and re-prewarms;
    ///   no app restart required.
    func updateRuntime() {
        guard !updatingRuntime, !installingRuntime, !installingDependencies else { return }

        refreshSystemState()
        guard setupDiagnostics.canInstall else {
            runtimeUpdateMessage = nil
            setupErrorMessage =
                "Missing tools: \(setupDiagnostics.missingTools.joined(separator: ", "))"
            dependencyInstallPromptVisible = true
            return
        }

        updatingRuntime = true
        runtimeUpdateMessage = "Updating local runtime…"
        setupErrorMessage = nil
        logActivity(
            "setup",
            "Runtime update started (target \(RuntimeSetupService.pinnedRuntimeCommit.prefix(8)))"
        )

        updateRuntimeTask?.cancel()
        updateRuntimeTask = Task {
            do {
                try await RuntimeSetupService.installRuntime { [weak self] chunk in
                    let line = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !line.isEmpty {
                        self?.runtimeUpdateMessage = "Updating runtime — \(line.prefix(80))"
                    }
                }
                try Task.checkCancellation()

                // The old llama-server is still serving the previous binary's inode;
                // cycle it so the next request launches the freshly built one.
                await localModelRuntime.shutdown()
                didCheckRuntimeUpdate = false
                runtimeUpdateAvailable = false
                updatingRuntime = false
                runtimeUpdateMessage = nil
                logActivity(
                    "setup",
                    "Local runtime updated to \(RuntimeSetupService.pinnedRuntimeCommit.prefix(8))"
                )
                refreshSystemState()
                schedulePrewarmIfNeeded()
            } catch is CancellationError {
                updatingRuntime = false
                runtimeUpdateMessage = nil
            } catch {
                updatingRuntime = false
                runtimeUpdateMessage = nil
                setupErrorMessage = "Runtime update failed: \(error.localizedDescription)"
                logActivity("setup", "Runtime update failed: \(error.localizedDescription)")
                refreshSystemState()
            }
        }
    }

    func installRuntime(modelIdentifier: String? = nil) {
        guard !installingRuntime else { return }

        refreshSystemState()
        guard setupDiagnostics.canInstall else {
            setupErrorMessage =
                "Missing tools: \(setupDiagnostics.missingTools.joined(separator: ", "))"
            dependencyInstallPromptVisible = true
            return
        }

        installingRuntime = true
        setupProgressValue = nil
        setupProgressMessage = nil
        setupDownloadedBytes = nil
        setupTotalBytes = nil
        setupLog = ""
        setupErrorMessage = nil
        logActivity("setup", "Runtime install started")
        refreshSystemState()

        installRuntimeTask?.cancel()
        let task = Task {
            var cancelledDuringInstall = false
            do {
                let setupModelIdentifier =
                    modelIdentifier
                    ?? Self.effectiveSetupModelIdentifier(for: state.monitoringConfiguration)
                let diagnosticsBeforeInstall = RuntimeSetupService.inspect(
                    runtimeOverride: state.runtimePathOverride,
                    modelIdentifier: setupModelIdentifier
                )
                if diagnosticsBeforeInstall.runtimePresent {
                    appendSetupLog(
                        "Runtime already installed. Skipping build and warming selected model.")
                } else {
                    try await RuntimeSetupService.installRuntime { [weak self] chunk in
                        self?.appendSetupLog(chunk)
                    }
                }

                guard !Task.isCancelled else { throw CancellationError() }

                let diagnostics = RuntimeSetupService.inspect(
                    runtimeOverride: state.runtimePathOverride,
                    modelIdentifier: setupModelIdentifier
                )
                startDownloadProgressPolling(modelIdentifier: setupModelIdentifier)
                // Best-effort authenticated download (recovers the HF unauth throttle).
                // nil token → unauthenticated, same as before.
                let hfToken = await HuggingFaceTokenService.fetchToken()
                let bytesBeforeDownload = RuntimeSetupService.downloadedModelBytes(
                    for: setupModelIdentifier)
                let downloadStartedAt = Date()
                try await RuntimeSetupService.warmUpRuntime(
                    runtimePath: diagnostics.runtimePath,
                    modelIdentifier: setupModelIdentifier,
                    hfToken: hfToken
                ) { [weak self] chunk in
                    self?.appendSetupLog(chunk)
                }
                stopDownloadProgressPolling()
                logModelDownloadThroughput(
                    modelIdentifier: setupModelIdentifier,
                    bytesBeforeDownload: bytesBeforeDownload,
                    startedAt: downloadStartedAt,
                    authenticated: hfToken != nil
                )

                guard !Task.isCancelled else { throw CancellationError() }

                // Warm-up can complete slightly before cache metadata settles; poll
                // briefly so setup/chat unlocks without requiring an app restart.
                await waitForRuntimeReadinessAfterWarmUp(
                    modelIdentifier: setupModelIdentifier,
                    timeoutSeconds: 12
                )
                if Task.isCancelled { throw CancellationError() }
                logActivity("setup", "Runtime setup warm-up finished")
            } catch is CancellationError {
                cancelledDuringInstall = true
            } catch {
                setupErrorMessage = error.localizedDescription
                logActivity("setup", "Runtime setup failed: \(error.localizedDescription)")
            }

            if cancelledDuringInstall {
                return
            }
            stopDownloadProgressPolling()
            installingRuntime = false
            setupProgressValue = nil
            setupProgressMessage = nil
            setupDownloadedBytes = nil
            setupTotalBytes = nil
            _ = applyPendingLocalModelIfReady()
            refreshSystemState()
        }
        installRuntimeTask = task
    }

    func appendSetupLog(_ chunk: String) {
        let sanitizedChunk = chunk.trimmingCharacters(in: .newlines)
        guard !sanitizedChunk.isEmpty else { return }
        if setupLog.isEmpty {
            setupLog = sanitizedChunk
        } else {
            setupLog += "\n" + sanitizedChunk
        }
        logActivity("setup-output", sanitizedChunk)
        updateSetupProgress(from: sanitizedChunk)
    }

    func updateSetupProgress(from chunk: String) {
        let line =
            chunk
            .split(whereSeparator: { $0.isNewline })
            .last
            .map(String.init) ?? chunk
        let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedLine.isEmpty else { return }

        let lowered = trimmedLine.lowercased()
        // Keywords that indicate this line is about download / load progress.
        // We deliberately do NOT treat every `\d+%` as progress — llama.cpp and
        // cmake both log percentages for unrelated things (sampling parameters,
        // build fractions), which made the progress bar jump around.
        let progressKeywords = [
            "download",
            "fetch",
            "pull",
            "resolving",
            "receiving",
            "loading model",
            "loading weights",
            "load_tensors",
            "warming",
            "warm up",
        ]
        let looksLikeProgress = progressKeywords.contains(where: lowered.contains)

        // When byte-level polling has a real total, it owns the progress fraction —
        // don't let scraped percentages (which also fire for unrelated load steps)
        // fight it.
        if setupTotalBytes == nil,
            looksLikeProgress,
            let range = trimmedLine.range(of: #"\b(\d{1,3})%"#, options: .regularExpression)
        {
            let percentString = String(trimmedLine[range]).replacingOccurrences(of: "%", with: "")
            if let percent = Double(percentString), (0...100).contains(percent) {
                setupProgressValue = max(0, min(1, percent / 100))
                setupProgressMessage = trimmedLine
                return
            }
        }

        if looksLikeProgress {
            setupProgressMessage = trimmedLine
        }
    }

    func waitForRuntimeReadinessAfterWarmUp(modelIdentifier: String, timeoutSeconds: TimeInterval)
        async
    {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            let diagnostics = RuntimeSetupService.inspect(
                runtimeOverride: state.runtimePathOverride,
                modelIdentifier: modelIdentifier
            )
            if diagnostics.isReady {
                return
            }
            try? await Task.sleep(nanoseconds: 400_000_000)
        }
    }

    struct PendingLocalModelChange: Equatable, Sendable {
        let modelIdentifier: String
        let fallbackIdentifier: String
        let autoSelectWhenReady: Bool
    }

    enum LocalModelStorageActionError: LocalizedError {
        case commandFailed(command: String, status: Int32, output: String)

        var errorDescription: String? {
            switch self {
            case .commandFailed(let command, let status, let output):
                let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    return "Command failed (\(status)): \(command)"
                }
                return "Command failed (\(status)): \(trimmed)"
            }
        }
    }

    final class ProcessOutputBuffer: @unchecked Sendable {
        private let lock = NSLock()
        nonisolated(unsafe) private var data = Data()

        nonisolated init() {}

        nonisolated func append(_ chunk: Data) {
            lock.lock()
            data.append(chunk)
            lock.unlock()
        }

        nonisolated func snapshot() -> Data {
            lock.lock()
            let snapshot = data
            lock.unlock()
            return snapshot
        }
    }

    struct ModelDownloadNotice: Identifiable, Sendable {
        let id = UUID()
        let modelIdentifier: String
        let modelDisplayName: String
        let fallbackDisplayName: String
    }

    struct ModelDownloadSuccess: Identifiable, Sendable {
        let id = UUID()
        let modelIdentifier: String
        let modelDisplayName: String
    }

    func repairInvalidMonitoringConfigurationIfNeeded() {
        let algorithmID = state.monitoringConfiguration.algorithmID
        if !state.hasMigratedPolicyAlgorithmDefault,
            MonitoringConfiguration.shouldAutoMigrateDeprecatedDefaultAlgorithm(algorithmID)
        {
            state.monitoringConfiguration.algorithmID =
                MonitoringConfiguration.currentLLMMonitorAlgorithmID
            state.algorithmState = AlgorithmStateEnvelope()
            state.hasMigratedPolicyAlgorithmDefault = true
            logActivity(
                "monitoring",
                "Migrated saved monitoring algorithm from \(algorithmID) to \(MonitoringConfiguration.currentLLMMonitorAlgorithmID)"
            )
        }

        guard !monitoringAlgorithmRegistry.containsAlgorithm(id: algorithmID) else {
            if !LLMPolicyCatalog.availablePipelineProfiles.contains(where: {
                $0.descriptor.id == state.monitoringConfiguration.pipelineProfileID
            }) {
                state.monitoringConfiguration.pipelineProfileID =
                    state.monitoringConfiguration.usesOnlineInference
                    ? MonitoringConfiguration.defaultOnlineVisionPipelineProfileID
                    : MonitoringConfiguration.defaultPipelineProfileID
            }
            if let pipeline = LLMPolicyCatalog.availablePipelineProfiles.first(
                where: { $0.descriptor.id == state.monitoringConfiguration.pipelineProfileID }
            ),
                pipeline.inferenceBackend != state.monitoringConfiguration.inferenceBackend
            {
                state.monitoringConfiguration.pipelineProfileID =
                    state.monitoringConfiguration.usesOnlineInference
                    ? (pipeline.descriptor.requiresScreenshot
                        ? MonitoringConfiguration.defaultOnlineVisionPipelineProfileID
                        : MonitoringConfiguration.defaultOnlineTextPipelineProfileID)
                    : (pipeline.descriptor.requiresScreenshot
                        ? MonitoringConfiguration.defaultPipelineProfileID
                        : "title_only_default")
            }
            if !LLMPolicyCatalog.availableRuntimeProfiles.contains(where: {
                $0.descriptor.id == state.monitoringConfiguration.runtimeProfileID
            }) {
                state.monitoringConfiguration.runtimeProfileID =
                    MonitoringConfiguration.defaultRuntimeProfileID
            }
            state.hasMigratedPolicyAlgorithmDefault = true
            return
        }

        state.monitoringConfiguration.algorithmID = MonitoringConfiguration.defaultAlgorithmID
        state.algorithmState = AlgorithmStateEnvelope()
        state.hasMigratedPolicyAlgorithmDefault = true
        setupErrorMessage =
            "Saved monitoring algorithm '\(algorithmID)' was invalid. AC reset it to '\(MonitoringConfiguration.defaultAlgorithmID)'."
        logActivity("monitoring", "Reset invalid monitoring algorithm: \(algorithmID)")
    }

    func handleSetupStatusTransition(from previousStatus: SetupStatus, to newStatus: SetupStatus) {
        defer { hasPerformedInitialRefresh = true }

        guard previousStatus != newStatus else { return }
        logActivity(
            "setup", "Setup state changed: \(previousStatus.rawValue) -> \(newStatus.rawValue)")

        guard hasPerformedInitialRefresh else { return }

        if newStatus == .ready {
            configureBrainIfNeeded()
            schedulePrewarmIfNeeded()
            onboardingCompletionTask?.cancel()
            onboardingDismissed = false
            showingOnboardingCompletion = true

            let workItem = DispatchWorkItem { [weak self] in
                self?.showingOnboardingCompletion = false
            }
            onboardingCompletionTask = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.0, execute: workItem)
        } else {
            onboardingCompletionTask?.cancel()
            showingOnboardingCompletion = false
            onboardingDismissed = false

            // If we were previously ready and now something is missing,
            // proactively open the popover so the user sees the setup dialog.
            if previousStatus == .ready {
                DispatchQueue.main.async { [weak self] in
                    self?.openMainPopover?()
                }
            }
        }
    }

    func maybePromptForMissingDependencies() {
        if state.monitoringConfiguration.usesOnlineInference {
            lastPromptedDependencySignature = nil
            dependencyInstallPromptVisible = false
            return
        }

        let signature = setupDiagnostics.missingTools.sorted().joined(separator: ",")
        if signature.isEmpty {
            lastPromptedDependencySignature = nil
            dependencyInstallPromptVisible = false
            return
        }

        guard state.setupStatus == .blocked, !installingDependencies else { return }
        guard signature != lastPromptedDependencySignature else { return }

        lastPromptedDependencySignature = signature
        dependencyInstallPromptVisible = true
    }

    func updateActivityStatusLine() {
        activityStatusText = AppControllerSetupSupport.activityStatusText(
            state: state,
            diagnostics: setupDiagnostics,
            installingRuntime: installingRuntime,
            installingDependencies: installingDependencies
        )
    }
}

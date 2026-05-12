//
//  AppController+RuntimeSetup.swift
//  AC
//

import AppKit
import Foundation

@MainActor
extension AppController {
    var selectedLocalModelIdentifier: String {
        pendingLocalModelChange?.modelIdentifier
            ?? state.monitoringConfiguration.localModelIdentifierImage
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
                self.pendingLocalModelChange = nil
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

        // Generic fallback: strip provider prefix, truncate version noise
        let modelPart = base.components(separatedBy: "/").last ?? base
        let cleaned =
            modelPart
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
           deprecated.contains(identifier) {
            state.monitoringConfiguration.onlineModelIdentifierText = tier.byokModelIdentifierText
            changed = true
        }
        if let identifier = state.monitoringConfiguration.onlineModelIdentifierImage,
           deprecated.contains(identifier) {
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

    func updateMonitoringInferenceBackend(_ backend: MonitoringInferenceBackend) {
        guard state.monitoringConfiguration.inferenceBackend != backend else { return }
        state.monitoringConfiguration.inferenceBackend = backend
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

    func updateLocalModelIdentifierText(_ identifier: String?) {
        guard state.monitoringConfiguration.localModelIdentifierText != identifier else { return }
        state.monitoringConfiguration.localModelIdentifierText = identifier
        brainService?.handleMonitoringConfigurationChange()
        refreshSystemState(persist: false)
        persistState()
        logActivity("monitoring", "Local text model: \(identifier ?? "cleared")")
    }

    func updateLocalModelIdentifierImage(_ identifier: String?) {
        guard state.monitoringConfiguration.localModelIdentifierImage != identifier else { return }
        state.monitoringConfiguration.localModelIdentifierImage = identifier
        brainService?.handleMonitoringConfigurationChange()
        refreshSystemState(persist: false)
        persistState()
        logActivity("monitoring", "Local image model: \(identifier ?? "cleared")")
    }

    func updateOnlineAPIKey(_ value: String) {
        onlineAPIKeyDraft = value
        _ = OnlineProviderCredentialStore.saveOpenRouterAPIKey(value)
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
        Task { [weak self, onlineModelService] in
            do {
                let info = try await onlineModelService.fetchKeyInfo(apiKey: key)
                await MainActor.run {
                    self?.openRouterKeyInfo = info
                    self?.openRouterKeyInfoError = nil
                }
            } catch {
                await MainActor.run {
                    self?.openRouterKeyInfo = nil
                    self?.openRouterKeyInfoError = error.localizedDescription
                }
            }
        }
    }

    // MARK: - Onboarding wizard

    func completeOnboardingWizard() {
        hasCompletedOnboardingWizard = true
        UserDefaults.standard.set(true, forKey: "acOnboardingWizardCompleted")
        UserDefaults.standard.set(true, forKey: "acOnboardingWizardEverCompleted")
        refreshSystemState()
    }

    func resetOnboardingWizard() {
        hasCompletedOnboardingWizard = false
        UserDefaults.standard.set(false, forKey: "acOnboardingWizardCompleted")
        UserDefaults.standard.set(false, forKey: "acOnboardingWizardEverCompleted")
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
        switch state.monitoringConfiguration.inferenceBackend {
        case .openRouter:
            state.monitoringConfiguration.onlineModelIdentifierText =
                state.aiTier.byokModelIdentifierText
            state.monitoringConfiguration.onlineModelIdentifierImage =
                state.aiTier.byokModelIdentifierImage
        case .local:
            state.monitoringConfiguration.localModelIdentifierText =
                state.aiTier.localModelIdentifierText
            state.monitoringConfiguration.localModelIdentifierImage =
                state.aiTier.localModelIdentifierImage
            if !queueLocalModelDownloadIfNeeded(
                targetModelIdentifier: state.aiTier.localModelIdentifierText,
                fallbackIdentifier: activeLocalModelIdentifier()
            ) {
                pendingLocalModelChange = nil
                modelDownloadNotice = nil
                modelDownloadSuccess = nil
                installRuntimeTask?.cancel()
                installRuntimeTask = nil
                if installingRuntime {
                    installingRuntime = false
                    setupProgressValue = nil
                    setupProgressMessage = nil
                }
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
        fallbackIdentifier: String
    ) -> Bool {
        let diagnostics = RuntimeSetupService.inspect(
            runtimeOverride: state.runtimePathOverride,
            modelIdentifier: targetModelIdentifier
        )
        guard !diagnostics.modelArtifactsPresent else { return false }

        let targetName = Self.shortModelName(for: targetModelIdentifier)
        let fallbackName = Self.shortModelName(for: fallbackIdentifier)
        pendingLocalModelChange = PendingLocalModelChange(
            modelIdentifier: targetModelIdentifier
        )
        modelDownloadNotice = ModelDownloadNotice(
            modelIdentifier: targetModelIdentifier,
            modelDisplayName: targetName,
            fallbackDisplayName: fallbackName
        )
        applyLocalModelFallback(fallbackIdentifier)

        if !installingRuntime {
            installRuntime(modelIdentifier: targetModelIdentifier)
        }
        return true
    }

    @discardableResult
    func applyPendingLocalModelIfReady() -> Bool {
        guard let pending = pendingLocalModelChange else { return false }
        guard state.monitoringConfiguration.inferenceBackend == .local else {
            pendingLocalModelChange = nil
            return true
        }
        let diagnostics = RuntimeSetupService.inspect(
            runtimeOverride: state.runtimePathOverride,
            modelIdentifier: pending.modelIdentifier
        )
        guard diagnostics.modelArtifactsPresent else { return false }

        applyLocalModelSelection(
            textModel: pending.modelIdentifier,
            imageModel: pending.modelIdentifier
        )
        pendingLocalModelChange = nil
        modelDownloadSuccess = ModelDownloadSuccess(
            modelIdentifier: pending.modelIdentifier,
            modelDisplayName: Self.shortModelName(for: pending.modelIdentifier)
        )
        brainService?.handleMonitoringConfigurationChange()
        persistState()
        return true
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
                try await RuntimeSetupService.warmUpRuntime(
                    runtimePath: diagnostics.runtimePath,
                    modelIdentifier: setupModelIdentifier
                ) { [weak self] chunk in
                    self?.appendSetupLog(chunk)
                }

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
                pendingLocalModelChange = nil
            }

            if cancelledDuringInstall {
                return
            }
            installingRuntime = false
            setupProgressValue = nil
            setupProgressMessage = nil
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

        if looksLikeProgress,
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

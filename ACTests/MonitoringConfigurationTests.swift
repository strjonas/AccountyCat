//
//  MonitoringConfigurationTests.swift
//  ACTests
//
//  Created by Codex on 15.04.26.
//

import Foundation
import Testing
@testable import AC

@MainActor
struct MonitoringConfigurationTests {

    @Test
    func decodesLegacyDistractionIntoAlgorithmEnvelope() throws {
        let data = Data("""
        {
          "distraction": {
            "contextKey": "com.google.Chrome|youtube",
            "consecutiveDistractedCount": 2,
            "lastAssessment": "distracted"
          }
        }
        """.utf8)

        let state = try JSONDecoder().decode(ACState.self, from: data)

        #expect(state.monitoringConfiguration.algorithmID == MonitoringConfiguration.defaultAlgorithmID)
        #expect(state.monitoringConfiguration.pipelineProfileID == MonitoringConfiguration.defaultPipelineProfileID)
        #expect(state.monitoringConfiguration.runtimeProfileID == MonitoringConfiguration.defaultRuntimeProfileID)
        #expect(state.algorithmState.llmPolicy.distraction.contextKey == "com.google.Chrome|youtube")
        #expect(state.algorithmState.llmPolicy.distraction.consecutiveDistractedCount == 2)
        #expect(state.algorithmState.llmPolicy.distraction.lastAssessment == .distracted)
    }

    @Test
    func decodesLegacyLLMAlgorithmIDIntoRenamedID() throws {
        let data = Data("""
        {
          "monitoringConfiguration": {
            "algorithmID": "legacy_focus_v1",
            "promptProfileID": "focus_default_v2",
            "selectionMode": "fixed"
          }
        }
        """.utf8)

        let state = try JSONDecoder().decode(ACState.self, from: data)

        #expect(state.monitoringConfiguration.algorithmID == MonitoringConfiguration.currentLLMMonitorAlgorithmID)
        #expect(
            state.monitoringConfiguration.experimentArm
            == [
                "fixed",
                MonitoringConfiguration.currentLLMMonitorAlgorithmID,
                MonitoringInferenceBackend.local.rawValue,
                MonitoringCadenceMode.balanced.rawValue,
            MonitoringConfiguration.defaultPipelineProfileID,
            MonitoringConfiguration.defaultRuntimeProfileID,
        ].joined(separator: ":")
        )
    }

    @Test
    func defaultConfigurationUsesLLMPolicyDefaults() {
        let configuration = MonitoringConfiguration()

        #expect(configuration.algorithmID == MonitoringConfiguration.currentLLMMonitorAlgorithmID)
        #expect(configuration.inferenceBackend == .local)
        #expect(configuration.cadenceMode == .balanced)
        #expect(configuration.pipelineProfileID == MonitoringConfiguration.defaultPipelineProfileID)
        #expect(configuration.runtimeProfileID == MonitoringConfiguration.defaultRuntimeProfileID)
        #expect(configuration.onlineModelIdentifier == AITier.balanced.byokModelIdentifierImage)
        #expect(configuration.onlineModelIdentifierText == AITier.balanced.byokModelIdentifierImage)
        #expect(configuration.onlineModelIdentifierImage == AITier.balanced.byokModelIdentifierImage)
        #expect(configuration.localModelIdentifierText == AITier.balanced.localModelIdentifierText)
        #expect(configuration.localModelIdentifierImage == AITier.balanced.localModelIdentifierImage)
        #expect(configuration.titleLengthForTextOnly == MonitoringHeuristics.defaultTitleLengthForTextOnly)
    }

    @Test
    func clampsTitleLengthForTextOnlyIntoSupportedRange() {
        let low = MonitoringConfiguration(titleLengthForTextOnly: 1)
        let high = MonitoringConfiguration(titleLengthForTextOnly: 999)

        #expect(low.titleLengthForTextOnly == MonitoringConfiguration.minTitleLengthForTextOnly)
        #expect(high.titleLengthForTextOnly == MonitoringConfiguration.maxTitleLengthForTextOnly)
    }

    @Test
    func reconcileAIModelSelectionSyncsTierFromPersistedModels() {
        var state = ACState()
        state.aiTier = .economy
        state.monitoringConfiguration = MonitoringConfiguration(
            inferenceBackend: .openRouter,
            onlineModelIdentifier: AITier.balanced.byokModelIdentifierImage,
            onlineModelIdentifierText: AITier.balanced.byokModelIdentifierText,
            onlineModelIdentifierImage: AITier.balanced.byokModelIdentifierImage
        )

        let changed = AppController.reconcileAIModelSelection(in: &state)

        #expect(changed)
        #expect(state.aiTier == .balanced)
    }

    @Test
    func reconcileAIModelSelectionAppliesTierWhenCatalogModelsDrift() {
        // smartest.text (kimi-k2.6) + economy.image (qwen3.5-9b) is a genuinely mixed pair
        // that doesn't resolve to any single tier, so reconcile should re-apply aiTier.
        var state = ACState()
        state.aiTier = .smartest
        state.monitoringConfiguration = MonitoringConfiguration(
            inferenceBackend: .openRouter,
            onlineModelIdentifier: AITier.economy.byokModelIdentifierImage,
            onlineModelIdentifierText: AITier.smartest.byokModelIdentifierText,
            onlineModelIdentifierImage: AITier.economy.byokModelIdentifierImage
        )

        let changed = AppController.reconcileAIModelSelection(in: &state)

        #expect(changed)
        #expect(state.aiTier == .smartest)
        #expect(
            AppController.monitoringConfigurationMatchesTier(
                .smartest,
                configuration: state.monitoringConfiguration
            )
        )
    }

    @Test
    func reconcileAIModelSelectionPreservesCustomAdvancedModels() {
        var state = ACState()
        state.aiTier = .balanced
        state.monitoringConfiguration = MonitoringConfiguration(
            inferenceBackend: .openRouter,
            onlineModelIdentifier: "openai/gpt-4o-mini",
            onlineModelIdentifierText: "openai/gpt-4o-mini",
            onlineModelIdentifierImage: "openai/gpt-4o"
        )

        let changed = AppController.reconcileAIModelSelection(in: &state)

        #expect(!changed)
        #expect(state.monitoringConfiguration.onlineModelIdentifierText == "openai/gpt-4o-mini")
        #expect(state.monitoringConfiguration.onlineModelIdentifierImage == "openai/gpt-4o")
    }

    @Test
    func reconcileCadenceTitleLengthFixesStaleVisionGate() {
        var state = ACState()
        state.monitoringConfiguration.cadenceMode = .sharp
        state.monitoringConfiguration.titleLengthForTextOnly =
            MonitoringCadenceMode.gentle.recommendedTitleLengthForTextOnly

        let changed = AppController.reconcileCadenceTitleLength(in: &state)

        #expect(changed)
        #expect(
            state.monitoringConfiguration.titleLengthForTextOnly
                == MonitoringCadenceMode.sharp.recommendedTitleLengthForTextOnly
        )
    }

    @Test
    func normalizesFreeSuffixOutOfOnlineModelIdentifier() {
        let configuration = MonitoringConfiguration(
            inferenceBackend: .openRouter,
            onlineModelIdentifier: "google/gemma-4-31b-it:free"
        )

        #expect(configuration.onlineModelIdentifier == "google/gemma-4-31b-it")
        #expect(
            MonitoringConfiguration.normalizedOnlineModelIdentifier(
                "https://openrouter.ai/google/gemma-4-31b-it:free"
            ) == "google/gemma-4-31b-it"
        )
        #expect(configuration.onlineModelIdentifierText == "google/gemma-4-31b-it")
        #expect(configuration.onlineModelIdentifierImage == "google/gemma-4-31b-it")
    }

    @Test
    func migratesLegacyModelOverrideIntoExplicitLocalModelSelections() throws {
        let data = Data("""
        {
          "monitoringConfiguration": {
            "modelOverride": "unsloth/Qwen3.5-4B-GGUF:UD-Q4_K_XL"
          }
        }
        """.utf8)

        let state = try JSONDecoder().decode(ACState.self, from: data)

        #expect(state.monitoringConfiguration.localModelIdentifierText == "unsloth/Qwen3.5-4B-GGUF:UD-Q4_K_XL")
        #expect(state.monitoringConfiguration.localModelIdentifierImage == "unsloth/Qwen3.5-4B-GGUF:UD-Q4_K_XL")
    }

    @Test
    func rendersPolicyRulesForChatPrompt() {
        var state = ACState()
        let writingProfile = FocusProfile(
            id: "writing",
            name: "Writing",
            description: "Drafting docs"
        )
        state.profiles.append(writingProfile)
        state.activeProfileID = writingProfile.id
        state.policyMemory.rules = [
            PolicyRule(
                kind: .allow,
                summary: "Default-profile Xcode rule should not leak into writing.",
                source: .explicitFeedback,
                scope: PolicyRuleScope(appName: "Xcode"),
                profileID: PolicyRule.defaultProfileID
            ),
            PolicyRule(
                kind: .discourage,
                summary: "Do not let me drift into YouTube during work blocks.",
                source: .explicitFeedback,
                scope: PolicyRuleScope(appName: "Google Chrome"),
                isLocked: true,
                profileID: writingProfile.id
            )
        ]

        let rendered = state.policyRulesForChatPrompt(now: Date(timeIntervalSince1970: 10_000))

        #expect(rendered.contains("Do not let me drift into YouTube during work blocks."))
        #expect(rendered.contains("fixed"))
        #expect(rendered.contains("app Google Chrome"))
        #expect(!rendered.contains("Default-profile Xcode rule"))
    }

    @Test
    func decodesLegacyUnscopedPolicyRulesIntoGeneralProfile() throws {
        let json = """
        {
            "policyMemory": {
                "rules": [
                    {
                        "id":"legacy-allow",
                        "kind":"allow",
                        "summary":"Old unscoped allow",
                        "source":"system",
                        "createdAt":"2026-05-01T10:00:00Z",
                        "updatedAt":"2026-05-01T10:00:00Z",
                        "priority":30,
                        "scope":{"appName":"Xcode","titleContains":[]},
                        "schedule":{"startHour":null,"endHour":null,"weekdays":[],"expiresAt":null},
                        "allowedTopics":[],
                        "disallowedTopics":[],
                        "maxMinutesPerDay":null,
                        "tonePreference":null,
                        "active":true
                    }
                ],
                "tonePreference": null,
                "lastUpdatedAt": null
            }
        }
        """
        let data = try #require(json.data(using: .utf8))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let state = try decoder.decode(ACState.self, from: data)
        #expect(state.policyMemory.rules.first?.profileID == PolicyRule.defaultProfileID)
    }

    @Test
    func runtimeInspectionUsesTheSelectedModelCache() throws {
      let fileManager = FileManager.default
      let rootURL = fileManager.temporaryDirectory
        .appendingPathComponent("ac-runtime-setup-\(UUID().uuidString)", isDirectory: true)
      let runtimePath = rootURL
        .appendingPathComponent("runtime/llama.cpp/build/bin/llama-cli")
        .path
      let cacheRootURL = rootURL
        .appendingPathComponent("runtime/llama.cpp/unsloth/Qwen3-4B-GGUF/models--unsloth--Qwen3-4B-GGUF", isDirectory: true)
      let refsURL = cacheRootURL.appendingPathComponent("refs", isDirectory: true)
      let snapshotsURL = cacheRootURL.appendingPathComponent("snapshots", isDirectory: true)
      let snapshotID = "snapshot-123"
      let snapshotURL = snapshotsURL.appendingPathComponent(snapshotID, isDirectory: true)

      try fileManager.createDirectory(
        at: URL(fileURLWithPath: runtimePath).deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try fileManager.createDirectory(at: refsURL, withIntermediateDirectories: true)
      try fileManager.createDirectory(at: snapshotURL, withIntermediateDirectories: true)

      _ = fileManager.createFile(
        atPath: runtimePath,
        contents: Data(),
        attributes: [.posixPermissions: 0o755]
      )
      try fileManager.setAttributes(
        [.posixPermissions: 0o755],
        ofItemAtPath: runtimePath
      )
      try "\(snapshotID)".write(
        to: refsURL.appendingPathComponent("main"),
        atomically: true,
        encoding: .utf8
      )
      _ = fileManager.createFile(
        atPath: snapshotURL.appendingPathComponent("model.Q4_0.gguf").path,
        contents: Data([0x00]),
        attributes: nil
      )

      defer { try? fileManager.removeItem(at: rootURL) }

      let selectedModel = "unsloth/Qwen3-4B-GGUF:Q4_0"
      let diagnostics = RuntimeSetupService.inspect(
        runtimeOverride: runtimePath,
        modelIdentifier: selectedModel
      )
      let otherDiagnostics = RuntimeSetupService.inspect(
        runtimeOverride: runtimePath,
        modelIdentifier: "example.invalid/NoSuchModel:Q4_0"
      )

      #expect(diagnostics.runtimePresent)
      #expect(diagnostics.modelCachePresent)
      #expect(diagnostics.modelArtifactsPresent)
      #expect(otherDiagnostics.modelCachePresent == false)
      #expect(otherDiagnostics.modelArtifactsPresent == false)
    }

    @Test
    func downloadedModelBytesSumsCompletedAndInProgressBlobs() throws {
      let fileManager = FileManager.default
      let cacheRoot = fileManager.temporaryDirectory
        .appendingPathComponent("ac-blob-bytes-\(UUID().uuidString)", isDirectory: true)
      let blobsURL = cacheRoot.appendingPathComponent("blobs", isDirectory: true)
      try fileManager.createDirectory(at: blobsURL, withIntermediateDirectories: true)
      defer { try? fileManager.removeItem(at: cacheRoot) }

      // Empty cache → zero, never a crash.
      #expect(RuntimeSetupService.downloadedModelBytes(inCacheRoot: cacheRoot) == 0)

      // A completed blob plus an in-progress partial: both count toward "downloaded".
      _ = fileManager.createFile(
        atPath: blobsURL.appendingPathComponent("abc123").path,
        contents: Data(count: 1000),
        attributes: nil
      )
      _ = fileManager.createFile(
        atPath: blobsURL.appendingPathComponent("def456.downloadInProgress").path,
        contents: Data(count: 500),
        attributes: nil
      )
      // A nested directory should be ignored (only regular files count).
      try fileManager.createDirectory(
        at: blobsURL.appendingPathComponent("nested", isDirectory: true),
        withIntermediateDirectories: true
      )

      #expect(RuntimeSetupService.downloadedModelBytes(inCacheRoot: cacheRoot) == 1500)
    }

    @Test
    func downloadedModelBytesIsZeroWhenCacheMissing() {
      let missing = FileManager.default.temporaryDirectory
        .appendingPathComponent("ac-blob-missing-\(UUID().uuidString)", isDirectory: true)
      #expect(RuntimeSetupService.downloadedModelBytes(inCacheRoot: missing) == 0)
    }

    @Test
    func downloadedModelBytesForOidsCountsOnlyTheModelsOwnBlobs() throws {
      let fileManager = FileManager.default
      let cacheRoot = fileManager.temporaryDirectory
        .appendingPathComponent("ac-oid-bytes-\(UUID().uuidString)", isDirectory: true)
      let blobsURL = cacheRoot.appendingPathComponent("blobs", isDirectory: true)
      try fileManager.createDirectory(at: blobsURL, withIntermediateDirectories: true)
      defer { try? fileManager.removeItem(at: cacheRoot) }

      let modelOid = "aaa111"
      let projectorOid = "bbb222"
      // Completed model blob, in-progress projector partial, and an orphan blob from a
      // previous attempt / different quant that must NOT be counted.
      _ = fileManager.createFile(
        atPath: blobsURL.appendingPathComponent(modelOid).path,
        contents: Data(count: 1000))
      _ = fileManager.createFile(
        atPath: blobsURL.appendingPathComponent(projectorOid + ".downloadInProgress").path,
        contents: Data(count: 200))
      _ = fileManager.createFile(
        atPath: blobsURL.appendingPathComponent("orphan999").path,
        contents: Data(count: 9_999))

      let downloaded = RuntimeSetupService.downloadedModelBytes(
        forOids: [modelOid, projectorOid], inCacheRoot: cacheRoot)
      #expect(downloaded == 1200)
    }

    @Test
    func purgeCorruptModelBlobsRemovesOversizedAndKeepsHealthy() throws {
      let fileManager = FileManager.default
      let cacheRoot = fileManager.temporaryDirectory
        .appendingPathComponent("ac-purge-\(UUID().uuidString)", isDirectory: true)
      let blobsURL = cacheRoot.appendingPathComponent("blobs", isDirectory: true)
      try fileManager.createDirectory(at: blobsURL, withIntermediateDirectories: true)
      defer { try? fileManager.removeItem(at: cacheRoot) }

      let corruptOid = "corrupt1"  // finalized blob, way larger than expected
      let healthyOid = "healthy1"  // finalized blob at the exact expected size
      let resumingOid = "resume1"  // legitimate partial, smaller than expected

      // Expected size is well under the corrupt blob, and the gap exceeds the 1 MiB
      // tolerance the purge uses to avoid fighting healthy files over rounding.
      let expectedSize: Int64 = 1_000
      _ = fileManager.createFile(
        atPath: blobsURL.appendingPathComponent(corruptOid).path,
        contents: Data(count: 3_000_000))
      _ = fileManager.createFile(
        atPath: blobsURL.appendingPathComponent(corruptOid + ".etag").path,
        contents: Data("etag".utf8))
      _ = fileManager.createFile(
        atPath: blobsURL.appendingPathComponent(healthyOid).path,
        contents: Data(count: Int(expectedSize)))
      _ = fileManager.createFile(
        atPath: blobsURL.appendingPathComponent(resumingOid + ".downloadInProgress").path,
        contents: Data(count: 400))

      let expected = [
        ExpectedModelFile(oid: corruptOid, size: expectedSize),
        ExpectedModelFile(oid: healthyOid, size: expectedSize),
        ExpectedModelFile(oid: resumingOid, size: expectedSize),
      ]
      let removed = RuntimeSetupService.purgeCorruptModelBlobs(
        expectedFiles: expected, inCacheRoot: cacheRoot)

      #expect(removed == 1)
      #expect(!fileManager.fileExists(atPath: blobsURL.appendingPathComponent(corruptOid).path))
      #expect(!fileManager.fileExists(atPath: blobsURL.appendingPathComponent(corruptOid + ".etag").path))
      #expect(fileManager.fileExists(atPath: blobsURL.appendingPathComponent(healthyOid).path))
      #expect(
        fileManager.fileExists(
          atPath: blobsURL.appendingPathComponent(resumingOid + ".downloadInProgress").path))
    }
}

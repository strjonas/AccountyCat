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
        #expect(state.monitoringConfiguration.promptProfileID == MonitoringConfiguration.defaultPromptProfileID)
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
                MonitoringConfiguration.defaultPipelineProfileID,
                MonitoringConfiguration.defaultRuntimeProfileID,
                MonitoringConfiguration.defaultPromptProfileID,
            ].joined(separator: ":")
        )
    }

    @Test
    func defaultConfigurationUsesLLMPolicyDefaults() {
        let configuration = MonitoringConfiguration()

        #expect(configuration.algorithmID == MonitoringConfiguration.currentLLMMonitorAlgorithmID)
        #expect(configuration.inferenceBackend == .local)
        #expect(configuration.pipelineProfileID == MonitoringConfiguration.defaultPipelineProfileID)
        #expect(configuration.runtimeProfileID == MonitoringConfiguration.defaultRuntimeProfileID)
        #expect(configuration.onlineModelIdentifier == MonitoringConfiguration.defaultOnlineModelIdentifier)
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
    }

    @Test
    func rendersPolicyRulesForChatPrompt() {
        var state = ACState()
        state.policyMemory.rules = [
            PolicyRule(
                kind: .discourage,
                summary: "Do not let me drift into YouTube during work blocks.",
                source: .explicitFeedback,
                scope: PolicyRuleScope(appName: "Google Chrome"),
                isLocked: true
            )
        ]

        let rendered = state.policyRulesForChatPrompt(now: Date(timeIntervalSince1970: 10_000))

        #expect(rendered.contains("Do not let me drift into YouTube during work blocks."))
        #expect(rendered.contains("fixed"))
        #expect(rendered.contains("app Google Chrome"))
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
}

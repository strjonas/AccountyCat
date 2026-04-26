//
//  MonitoringModels.swift
//  AC
//
//  Created by Codex on 15.04.26.
//

import Foundation

enum MonitoringSelectionMode: String, Codable, CaseIterable, Sendable {
    case fixed
}

struct MonitoringConfiguration: Codable, Hashable, Sendable {
    nonisolated static let deprecatedLegacyLLMAlgorithmID = "legacy_focus_v1"
    nonisolated static let deprecatedLLMFocusAlgorithmID = "llm_focus_v1"
    nonisolated static let deprecatedLLMMonitorAlgorithmID = "llm_policy_v1"
    nonisolated static let legacyLLMFocusAlgorithmID = "llm_focus_legacy_v1"
    nonisolated static let currentLLMMonitorAlgorithmID = "llm_monitor_v1"
    nonisolated static let defaultAlgorithmID = currentLLMMonitorAlgorithmID
    nonisolated static let defaultPromptProfileID = "focus_default_v2"
    nonisolated static let defaultPipelineProfileID = "vision_split_default"
    nonisolated static let defaultOnlineVisionPipelineProfileID = "online_single_round_vision"
    nonisolated static let defaultOnlineTextPipelineProfileID = "online_single_round_text"
    nonisolated static let defaultRuntimeProfileID = "gemma_balanced_v1"
    nonisolated static let defaultInferenceBackend: MonitoringInferenceBackend = .local
    nonisolated static let defaultOnlineModelIdentifier = "google/gemma-4-31b-it:free"
    nonisolated static let banditAlgorithmID = "bandit_focus_v1"

    var algorithmID: String
    var promptProfileID: String
    var pipelineProfileID: String
    var runtimeProfileID: String
    var inferenceBackend: MonitoringInferenceBackend
    var selectionMode: MonitoringSelectionMode
    var experimentArmOverride: String?
    var modelOverride: String?
    var onlineModelIdentifier: String
    var thinkingEnabled: Bool

    enum CodingKeys: String, CodingKey {
        case algorithmID
        case promptProfileID
        case pipelineProfileID
        case runtimeProfileID
        case inferenceBackend
        case selectionMode
        case experimentArmOverride
        case modelOverride
        case onlineModelIdentifier
        case thinkingEnabled
    }

    init(
        algorithmID: String = Self.defaultAlgorithmID,
        promptProfileID: String = Self.defaultPromptProfileID,
        pipelineProfileID: String = Self.defaultPipelineProfileID,
        runtimeProfileID: String = Self.defaultRuntimeProfileID,
        inferenceBackend: MonitoringInferenceBackend = Self.defaultInferenceBackend,
        selectionMode: MonitoringSelectionMode = .fixed,
        experimentArmOverride: String? = nil,
        modelOverride: String? = nil,
        onlineModelIdentifier: String = Self.defaultOnlineModelIdentifier,
        thinkingEnabled: Bool = false
    ) {
        self.algorithmID = Self.normalizedAlgorithmID(algorithmID)
        self.promptProfileID = promptProfileID
        self.pipelineProfileID = pipelineProfileID
        self.runtimeProfileID = runtimeProfileID
        self.inferenceBackend = inferenceBackend
        self.selectionMode = selectionMode
        self.experimentArmOverride = experimentArmOverride
        self.modelOverride = modelOverride
        self.onlineModelIdentifier = Self.normalizedOnlineModelIdentifier(onlineModelIdentifier)
        self.thinkingEnabled = thinkingEnabled
    }

    nonisolated static func normalizedAlgorithmID(_ id: String) -> String {
        switch id {
        case deprecatedLegacyLLMAlgorithmID, deprecatedLLMFocusAlgorithmID:
            return legacyLLMFocusAlgorithmID
        case deprecatedLLMMonitorAlgorithmID:
            return currentLLMMonitorAlgorithmID
        default:
            return id
        }
    }

    nonisolated static func shouldAutoMigrateDeprecatedDefaultAlgorithm(_ id: String) -> Bool {
        switch id {
        case deprecatedLegacyLLMAlgorithmID, deprecatedLLMFocusAlgorithmID:
            return true
        default:
            return false
        }
    }

    var experimentArm: String {
        experimentArmOverride ?? [
            selectionMode.rawValue,
            Self.normalizedAlgorithmID(algorithmID),
            inferenceBackend.rawValue,
            pipelineProfileID,
            runtimeProfileID,
            promptProfileID,
        ].joined(separator: ":")
    }

    nonisolated var usesOnlineInference: Bool {
        inferenceBackend == .openRouter
    }

    nonisolated static func normalizedOnlineModelIdentifier(_ rawValue: String) -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return defaultOnlineModelIdentifier
        }

        if let url = URL(string: trimmed),
           let host = url.host?.lowercased(),
           host.contains("openrouter.ai") {
            let parts = url.pathComponents.filter { $0 != "/" }
            if parts.count >= 2, parts[0] != "api", parts[0] != "docs" {
                return "\(parts[0])/\(parts[1])"
            }
        }

        return trimmed
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        algorithmID = Self.normalizedAlgorithmID(
            try c.decodeIfPresent(String.self, forKey: .algorithmID) ?? Self.defaultAlgorithmID
        )
        promptProfileID = try c.decodeIfPresent(String.self, forKey: .promptProfileID) ?? Self.defaultPromptProfileID
        pipelineProfileID = try c.decodeIfPresent(String.self, forKey: .pipelineProfileID) ?? Self.defaultPipelineProfileID
        runtimeProfileID = try c.decodeIfPresent(String.self, forKey: .runtimeProfileID) ?? Self.defaultRuntimeProfileID
        inferenceBackend = try c.decodeIfPresent(MonitoringInferenceBackend.self, forKey: .inferenceBackend) ?? Self.defaultInferenceBackend
        selectionMode = try c.decodeIfPresent(MonitoringSelectionMode.self, forKey: .selectionMode) ?? .fixed
        experimentArmOverride = try c.decodeIfPresent(String.self, forKey: .experimentArmOverride)
        modelOverride = try c.decodeIfPresent(String.self, forKey: .modelOverride)
        onlineModelIdentifier = Self.normalizedOnlineModelIdentifier(
            try c.decodeIfPresent(String.self, forKey: .onlineModelIdentifier) ?? Self.defaultOnlineModelIdentifier
        )
        thinkingEnabled = try c.decodeIfPresent(Bool.self, forKey: .thinkingEnabled) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Self.normalizedAlgorithmID(algorithmID), forKey: .algorithmID)
        try c.encode(promptProfileID, forKey: .promptProfileID)
        try c.encode(pipelineProfileID, forKey: .pipelineProfileID)
        try c.encode(runtimeProfileID, forKey: .runtimeProfileID)
        try c.encode(inferenceBackend, forKey: .inferenceBackend)
        try c.encode(selectionMode, forKey: .selectionMode)
        try c.encodeIfPresent(experimentArmOverride, forKey: .experimentArmOverride)
        try c.encodeIfPresent(modelOverride, forKey: .modelOverride)
        try c.encode(onlineModelIdentifier, forKey: .onlineModelIdentifier)
        try c.encode(thinkingEnabled, forKey: .thinkingEnabled)
    }
}

struct MonitoringAlgorithmDescriptor: Hashable, Sendable {
    var id: String
    var version: String
    var displayName: String
    var summary: String
}

struct MonitoringPromptProfileDescriptor: Hashable, Sendable {
    var id: String
    var version: String
    var displayName: String
    var summary: String
}

struct MonitoringPipelineProfileDescriptor: Hashable, Sendable {
    var id: String
    var displayName: String
    var summary: String
    var requiresScreenshot: Bool
}

struct MonitoringRuntimeProfileDescriptor: Hashable, Sendable {
    var id: String
    var displayName: String
    var summary: String
    var modelIdentifier: String
}

struct MonitoringExecutionMetadata: Hashable, Sendable {
    var algorithmID: String
    var algorithmVersion: String
    var promptProfileID: String
    var pipelineProfileID: String?
    var runtimeProfileID: String?
    var experimentArm: String?
}

struct LLMFocusAlgorithmState: Codable, Sendable, Equatable {
    var distraction = DistractionMetadata()
    var lastVisualCheckByContext: [String: Date] = [:]
}

struct LLMPolicyAlgorithmState: Codable, Sendable, Equatable {
    var distraction = DistractionMetadata()
    var currentContextKey: String?
    var currentContextEnteredAt: Date?
    var lastInterventionAt: Date?
    var lastNudgeAt: Date?
    var lastOverlayAt: Date?
    var recentNudgeMessages: [String] = []
    var activeAppeal: MonitoringAppealSession?
}

struct AlgorithmStateEnvelope: Codable, Sendable, Equatable {
    // Each algorithm owns its own state slice. Adding a new algorithm = add a new property here.
    var llmFocus = LLMFocusAlgorithmState()
    var llmPolicy = LLMPolicyAlgorithmState()
    var banditFocus = BanditFocusAlgorithmState()

    // MARK: - Codable (with migration from old "legacyFocus" key)

    enum CodingKeys: String, CodingKey {
        case llmFocus
        case legacyFocus // read-only migration key for state.json files written before the rename
        case llmPolicy
        case banditFocus
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        llmFocus = try c.decodeIfPresent(LLMFocusAlgorithmState.self, forKey: .llmFocus)
               ?? c.decodeIfPresent(LLMFocusAlgorithmState.self, forKey: .legacyFocus)
               ?? LLMFocusAlgorithmState()
        llmPolicy = try c.decodeIfPresent(LLMPolicyAlgorithmState.self, forKey: .llmPolicy)
               ?? LLMPolicyAlgorithmState()
        banditFocus = try c.decodeIfPresent(BanditFocusAlgorithmState.self, forKey: .banditFocus)
               ?? BanditFocusAlgorithmState()
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(llmFocus, forKey: .llmFocus)
        try c.encode(llmPolicy, forKey: .llmPolicy)
        try c.encode(banditFocus, forKey: .banditFocus)
    }
}

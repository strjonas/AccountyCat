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
    static let legacyLLMAlgorithmID = "legacy_focus_v1"
    static let llmAlgorithmID = "llm_focus_v1"
    static let llmPolicyAlgorithmID = "llm_policy_v1"
    static let defaultAlgorithmID = llmPolicyAlgorithmID
    static let defaultPromptProfileID = "focus_default_v2"
    static let defaultPipelineProfileID = "vision_split_default"
    static let defaultRuntimeProfileID = "gemma_balanced_v1"
    static let banditAlgorithmID = "bandit_focus_v1"

    var algorithmID: String
    var promptProfileID: String
    var pipelineProfileID: String
    var runtimeProfileID: String
    var selectionMode: MonitoringSelectionMode
    var experimentArmOverride: String?

    enum CodingKeys: String, CodingKey {
        case algorithmID
        case promptProfileID
        case pipelineProfileID
        case runtimeProfileID
        case selectionMode
        case experimentArmOverride
    }

    init(
        algorithmID: String = Self.defaultAlgorithmID,
        promptProfileID: String = Self.defaultPromptProfileID,
        pipelineProfileID: String = Self.defaultPipelineProfileID,
        runtimeProfileID: String = Self.defaultRuntimeProfileID,
        selectionMode: MonitoringSelectionMode = .fixed,
        experimentArmOverride: String? = nil
    ) {
        self.algorithmID = Self.normalizedAlgorithmID(algorithmID)
        self.promptProfileID = promptProfileID
        self.pipelineProfileID = pipelineProfileID
        self.runtimeProfileID = runtimeProfileID
        self.selectionMode = selectionMode
        self.experimentArmOverride = experimentArmOverride
    }

    static func normalizedAlgorithmID(_ id: String) -> String {
        switch id {
        case legacyLLMAlgorithmID:
            return llmAlgorithmID
        default:
            return id
        }
    }

    var experimentArm: String {
        experimentArmOverride ?? [
            selectionMode.rawValue,
            Self.normalizedAlgorithmID(algorithmID),
            pipelineProfileID,
            runtimeProfileID,
            promptProfileID,
        ].joined(separator: ":")
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        algorithmID = Self.normalizedAlgorithmID(
            try c.decodeIfPresent(String.self, forKey: .algorithmID) ?? Self.defaultAlgorithmID
        )
        promptProfileID = try c.decodeIfPresent(String.self, forKey: .promptProfileID) ?? Self.defaultPromptProfileID
        pipelineProfileID = try c.decodeIfPresent(String.self, forKey: .pipelineProfileID) ?? Self.defaultPipelineProfileID
        runtimeProfileID = try c.decodeIfPresent(String.self, forKey: .runtimeProfileID) ?? Self.defaultRuntimeProfileID
        selectionMode = try c.decodeIfPresent(MonitoringSelectionMode.self, forKey: .selectionMode) ?? .fixed
        experimentArmOverride = try c.decodeIfPresent(String.self, forKey: .experimentArmOverride)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Self.normalizedAlgorithmID(algorithmID), forKey: .algorithmID)
        try c.encode(promptProfileID, forKey: .promptProfileID)
        try c.encode(pipelineProfileID, forKey: .pipelineProfileID)
        try c.encode(runtimeProfileID, forKey: .runtimeProfileID)
        try c.encode(selectionMode, forKey: .selectionMode)
        try c.encodeIfPresent(experimentArmOverride, forKey: .experimentArmOverride)
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

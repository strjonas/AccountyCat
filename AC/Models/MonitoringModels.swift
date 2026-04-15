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
    static let defaultAlgorithmID = "legacy_focus_v1"
    static let defaultPromptProfileID = "focus_default_v2"
    static let banditAlgorithmID = "bandit_focus_v1"

    var algorithmID: String = Self.defaultAlgorithmID
    var promptProfileID: String = Self.defaultPromptProfileID
    var selectionMode: MonitoringSelectionMode = .fixed
    var experimentArmOverride: String?

    var experimentArm: String {
        experimentArmOverride ?? [
            selectionMode.rawValue,
            algorithmID,
            promptProfileID,
        ].joined(separator: ":")
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

struct MonitoringExecutionMetadata: Hashable, Sendable {
    var algorithmID: String
    var algorithmVersion: String
    var promptProfileID: String
    var experimentArm: String?
}

struct LLMFocusAlgorithmState: Codable, Sendable, Equatable {
    var distraction = DistractionMetadata()
    var lastVisualCheckByContext: [String: Date] = [:]
}

struct AlgorithmStateEnvelope: Codable, Sendable, Equatable {
    // Each algorithm owns its own state slice. Adding a new algorithm = add a new property here.
    var llmFocus = LLMFocusAlgorithmState()
    var banditFocus = BanditFocusAlgorithmState()

    // MARK: - Codable (with migration from old "legacyFocus" key)

    enum CodingKeys: String, CodingKey {
        case llmFocus
        case legacyFocus // read-only migration key for state.json files written before the rename
        case banditFocus
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        llmFocus = try c.decodeIfPresent(LLMFocusAlgorithmState.self, forKey: .llmFocus)
               ?? c.decodeIfPresent(LLMFocusAlgorithmState.self, forKey: .legacyFocus)
               ?? LLMFocusAlgorithmState()
        banditFocus = try c.decodeIfPresent(BanditFocusAlgorithmState.self, forKey: .banditFocus)
               ?? BanditFocusAlgorithmState()
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(llmFocus, forKey: .llmFocus)
        try c.encode(banditFocus, forKey: .banditFocus)
    }
}

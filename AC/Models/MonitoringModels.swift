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

struct LegacyFocusAlgorithmState: Codable, Sendable, Equatable {
    var distraction = DistractionMetadata()
    var lastVisualCheckByContext: [String: Date] = [:]
}

struct AlgorithmStateEnvelope: Codable, Sendable, Equatable {
    // Future algorithms should add their own state slices here instead of
    // extending ACState directly.
    var legacyFocus = LegacyFocusAlgorithmState()
}

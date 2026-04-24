//
//  DevelopmentModelConfiguration.swift
//  ACShared
//
//  Created by Codex on 24.04.26.
//

import Foundation

enum DevelopmentModelConfiguration {
    nonisolated static let overrideEnvironmentKey = "unsloth/Qwen3-4B-GGUF:Q4_0"
    nonisolated static let fallbackModelIdentifier = "unsloth/gemma-4-E2B-it-GGUF:Q4_0"

    nonisolated static var defaultModelIdentifier: String {
        if
            let override = ProcessInfo.processInfo.environment[overrideEnvironmentKey]?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !override.isEmpty
        {
            return override
        }

        return fallbackModelIdentifier
    }

    nonisolated static func repositoryIdentifier(
        for modelIdentifier: String = defaultModelIdentifier
    ) -> String {
        String(
            modelIdentifier
                .split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
                .first ?? ""
        )
    }

    nonisolated static func cacheRelativePath(
        for modelIdentifier: String = defaultModelIdentifier
    ) -> String {
        let repositoryIdentifier = repositoryIdentifier(for: modelIdentifier)
        return "\(repositoryIdentifier)/models--\(repositoryIdentifier.replacingOccurrences(of: "/", with: "--"))"
    }
}

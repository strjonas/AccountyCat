//
//  DevelopmentModelConfiguration.swift
//  ACShared
//
//  Created by Codex on 24.04.26.
//

import Foundation

enum DevelopmentModelConfiguration {
    nonisolated static let overrideEnvironmentKey = "AC_MODEL_IDENTIFIER"
    // Swap via AC_MODEL_IDENTIFIER env var for evaluation: ( can be done in GUI - overwrites from there in runtime)
    //   unsloth/gemma-4-E2B-it-GGUF:Q4_0       (multimodal, default)
    //   unsloth/Qwen3-4B-GGUF:Q4_0              (text-only;  groundwork blocks stripped automatically)
    //   unsloth/Phi-4-mini-instruct-GGUF:Q4_K_M (text-only; vision gracefully downgraded to text)
    nonisolated static let fallbackModelIdentifier = "unsloth/gemma-4-E4B-it-GGUF:Q4_K_M"
 
    

    /// Returns false for models that are text-only and cannot process images.
    nonisolated static func supportsVision(for modelIdentifier: String) -> Bool {
        let lower = modelIdentifier.lowercased()
        if lower.contains("qwen") && !lower.contains("vl") { return false }
        if lower.contains("phi") && !lower.contains("vision") && !lower.contains("multimodal") { return false }
        return true
    }

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

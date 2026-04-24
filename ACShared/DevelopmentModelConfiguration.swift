//
//  DevelopmentModelConfiguration.swift
//  ACShared
//
//  Created by Codex on 24.04.26.
//

import Foundation

enum DevelopmentModelConfiguration {
    nonisolated static let overrideEnvironmentKey = "AC_MODEL_IDENTIFIER"
    nonisolated static let fallbackModelIdentifier = "unsloth/gemma-4-E2B-it-GGUF:Q4_0"  
    // works with gemma 
    // qwen (and phi) parsing isn't working. So they need their own logic... this is still to fix. 
    // phi error for image, parameters adjust or not multimodal version maybe
    // unsloth/Qwen3-4B-GGUF:Q4_0" "unsloth/gemma-4-E2B-it-GGUF:Q4_0" "unsloth/Phi-4-mini-instruct-GGUF:Q4_K_M" 
 
    

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

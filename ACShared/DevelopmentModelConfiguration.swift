//
//  DevelopmentModelConfiguration.swift
//  ACShared
//
//  Created by Codex on 24.04.26.
//

import Foundation

enum DevelopmentModelConfiguration {
    nonisolated static let overrideEnvironmentKey = "AC_MODEL_IDENTIFIER"

    /// Returns false for models that are text-only and cannot process images.
    nonisolated static func supportsVision(for modelIdentifier: String) -> Bool {
        let lower = modelIdentifier.lowercased()
        if lower.contains("phi") && !lower.contains("vision") && !lower.contains("multimodal") { return false }
        return true
    }

    nonisolated static func repositoryIdentifier(
        for modelIdentifier: String
    ) -> String {
        String(
            modelIdentifier
                .split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
                .first ?? ""
        )
    }

    nonisolated static func cacheRelativePath(
        for modelIdentifier: String
    ) -> String {
        let repositoryIdentifier = repositoryIdentifier(for: modelIdentifier)
        return "\(repositoryIdentifier)/models--\(repositoryIdentifier.replacingOccurrences(of: "/", with: "--"))"
    }
}

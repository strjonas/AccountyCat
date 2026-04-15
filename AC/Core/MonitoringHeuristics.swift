//
//  MonitoringHeuristics.swift
//  AC
//
//  Created by Codex on 12.04.26.
//

import Foundation

enum MonitoringHeuristics {
    static let periodicVisualCheckInterval: TimeInterval = 120

    private static let clearlyProductiveBundleIdentifiers: Set<String> = [
        "com.apple.dt.Xcode",
        "com.microsoft.VSCode",
        "com.jetbrains.intellij",
        "com.jetbrains.PyCharm",
        "com.jetbrains.WebStorm",
        "com.jetbrains.CLion",
        "com.jetbrains.rubymine"
    ]

    private static let browserBundleIdentifiers: Set<String> = [
        "com.apple.Safari",
        "com.google.Chrome",
        "org.chromium.Chromium",
        "com.brave.Browser",
        "company.thebrowser.Browser",
        "com.microsoft.edgemac",
        "com.operasoftware.Opera"
    ]

    static func isClearlyProductive(bundleIdentifier: String?, appName: String) -> Bool {
        if let bundleIdentifier, clearlyProductiveBundleIdentifiers.contains(bundleIdentifier) {
            return true
        }

        let lowercasedName = appName.cleanedSingleLine.lowercased()
        return lowercasedName == "xcode" ||
            lowercasedName == "visual studio code" ||
            lowercasedName == "code"
    }

    static func isBrowser(bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier else {
            return false
        }
        return browserBundleIdentifiers.contains(bundleIdentifier)
    }

    static func isUnhelpfulWindowTitle(_ title: String, appName: String) -> Bool {
        let normalizedTitle = title.cleanedSingleLine.lowercased()
        let normalizedAppName = appName.cleanedSingleLine.lowercased()
        guard !normalizedTitle.isEmpty, !normalizedAppName.isEmpty else {
            return true
        }

        if normalizedTitle == normalizedAppName {
            return true
        }

        let separators = CharacterSet(charactersIn: "-—")
        let parts = normalizedTitle
            .components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !parts.isEmpty else {
            return true
        }

        return parts.allSatisfy { $0 == normalizedAppName }
    }

    static func visualCheckReason(for context: FrontmostContext) -> String? {
        if isClearlyProductive(bundleIdentifier: context.bundleIdentifier, appName: context.appName) {
            return nil
        }

        if isBrowser(bundleIdentifier: context.bundleIdentifier) {
            return "browser"
        }

        guard let title = context.windowTitle else {
            return "missing-window-title"
        }

        if isUnhelpfulWindowTitle(title, appName: context.appName) {
            return "generic-window-title"
        }

        return nil
    }
}
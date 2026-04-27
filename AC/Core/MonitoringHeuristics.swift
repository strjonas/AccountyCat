//
//  MonitoringHeuristics.swift
//  AC
//
//  Created by Codex on 12.04.26.
//

import Foundation

/// Derives a stable "site-ish" signature from a browser window title so that the auto-safelist can
/// scope by `titleContains` (e.g. matching every Google Doc) rather than by the bare browser bundle
/// identifier (which would whitelist every URL in Chrome).
enum BrowserTitleSignature {
    /// Trailing-segment patterns we trust to identify a productive context.
    nonisolated private static let knownTrailingSites: [String] = [
        "Google Docs", "Google Sheets", "Google Slides", "Google Drive",
        "Google Calendar", "Google Meet", "Google Keep",
        "GitHub", "GitLab", "Bitbucket",
        "Notion", "Linear", "Jira", "Confluence", "Asana", "Trello",
        "Figma", "FigJam", "Miro",
        "Stack Overflow", "MDN Web Docs",
        "Overleaf", "ReadCube Papers", "Zotero",
        "Loom", "ChatGPT", "Claude", "Perplexity", "Cursor"
    ]

    /// Returns a signature suitable for `PolicyRuleScope.titleContains`, or nil if the title
    /// doesn't end with a recognized productive-site suffix. Conservative on purpose — never
    /// auto-safelist arbitrary trailing segments (e.g. "YouTube", "Netflix") that aren't
    /// pre-vetted as productive.
    nonisolated static func derive(from title: String?) -> String? {
        guard let title = title?.cleanedSingleLine, !title.isEmpty else { return nil }

        for site in knownTrailingSites {
            if title.range(of: site, options: [.caseInsensitive, .backwards]) != nil {
                return site
            }
        }
        return nil
    }
}

enum MonitoringHeuristics {
    nonisolated static let periodicVisualCheckInterval: TimeInterval = 120

    nonisolated private static let clearlyProductiveBundleIdentifiers: Set<String> = [
        "com.apple.dt.Xcode",
        "com.microsoft.VSCode",
        "com.jetbrains.intellij",
        "com.jetbrains.PyCharm",
        "com.jetbrains.WebStorm",
        "com.jetbrains.CLion",
        "com.jetbrains.rubymine"
    ]

    nonisolated private static let browserBundleIdentifiers: Set<String> = [
        "com.apple.Safari",
        "com.google.Chrome",
        "org.chromium.Chromium",
        "com.brave.Browser",
        "company.thebrowser.Browser",
        "com.microsoft.edgemac",
        "com.operasoftware.Opera"
    ]

    /// Apps where the on-screen content is the only reliable productivity signal.
    /// Window titles for these apps may name a specific item but cannot be trusted to imply intent
    /// (a productive lecture and a cat compilation can show similarly innocuous-looking titles in
    /// the native YouTube app, etc.). For all of these we always keep the screenshot.
    nonisolated static let ambiguousContentBundleIdentifiers: Set<String> = [
        // Video / media
        "com.google.ios.youtube",
        "com.google.android.youtube",
        "com.apple.TV",
        "com.netflix.Netflix",
        "tv.twitch.desktop.app",
        // Music
        "com.apple.Music",
        "com.spotify.client",
        // Social
        "com.twitter.twitter-mac",
        "com.atebits.Tweetie2",
        "com.tapbots.Tweetbot3Mac",
        "com.reddit.reddit-mac",
        "com.burbn.instagram",
        "com.zhiliaoapp.musically",
        "com.facebook.Facebook",
        // Chat (could be DMing personal stuff or doing real work)
        "com.tinyspeck.slackmacgap",
        "com.hnc.Discord",
        "ru.keepcoder.Telegram",
        "WhatsApp",
        "net.whatsapp.WhatsApp",
        "com.apple.MobileSMS"
    ]

    nonisolated static func isClearlyProductive(bundleIdentifier: String?, appName: String) -> Bool {
        if let bundleIdentifier, clearlyProductiveBundleIdentifiers.contains(bundleIdentifier) {
            return true
        }

        let lowercasedName = appName.cleanedSingleLine.lowercased()
        return lowercasedName == "xcode" ||
            lowercasedName == "visual studio code" ||
            lowercasedName == "code"
    }

    nonisolated static func isBrowser(bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier else {
            return false
        }
        return browserBundleIdentifiers.contains(bundleIdentifier)
    }

    nonisolated static func isUnhelpfulWindowTitle(_ title: String, appName: String) -> Bool {
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

    nonisolated static func isAmbiguousContent(bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier else { return false }
        return ambiguousContentBundleIdentifiers.contains(bundleIdentifier)
    }

    /// True when the title structurally proves it carries the actual content signal —
    /// looks like an editor / document / issue-tracker title, not a media or generic app title.
    /// Conservative on purpose: we'd rather pay for an unnecessary screenshot than miss intent.
    nonisolated static func titleHasStructuralContentMarker(_ title: String) -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 12 else { return false }

        if trimmed.contains("/") { return true }

        // File extension like `.swift`, `.md`, `.tsx`, `.py`, `.png`, etc.
        let extensionPattern = #"\.[A-Za-z0-9]{1,5}(\b|$)"#
        if trimmed.range(of: extensionPattern, options: .regularExpression) != nil {
            return true
        }

        // Issue / PR identifiers like `AC-123` or `#456`.
        if trimmed.range(of: #"\b[A-Z]{2,}-\d+\b"#, options: .regularExpression) != nil { return true }
        if trimmed.range(of: #"#\d+\b"#, options: .regularExpression) != nil { return true }

        // Hyphen / em-dash separator with non-trivial content on both sides.
        let separatorChars = CharacterSet(charactersIn: "-—–")
        let parts = trimmed
            .components(separatedBy: separatorChars)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if parts.count >= 2, parts.allSatisfy({ $0.count >= 3 }) {
            return true
        }

        return false
    }

    /// The screenshot can be skipped only when the title is strong enough on its own AND the app
    /// is not in a category where content (not title) is the real signal. Default bias: keep the
    /// screenshot.
    nonisolated static func canRelyOnTitleAlone(
        bundleIdentifier: String?,
        appName: String,
        windowTitle: String?,
        isBrowser: Bool
    ) -> Bool {
        if isBrowser { return false }
        if isAmbiguousContent(bundleIdentifier: bundleIdentifier) { return false }

        guard let title = windowTitle?.cleanedSingleLine, !title.isEmpty else { return false }
        if isUnhelpfulWindowTitle(title, appName: appName) { return false }

        // For known IDEs the title is reliably a filename — relax the structural-marker rule.
        if isClearlyProductive(bundleIdentifier: bundleIdentifier, appName: appName) {
            return title.count >= 4
        }

        return titleHasStructuralContentMarker(title)
    }

    nonisolated static func visualCheckReason(for context: FrontmostContext) -> String? {
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

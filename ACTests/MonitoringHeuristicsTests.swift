//
//  MonitoringHeuristicsTests.swift
//  ACTests
//
//  Created by Codex on 12.04.26.
//

import Testing
@testable import AC

struct MonitoringHeuristicsTests {

    @Test
    func browserContextsAlwaysRequestVisualChecks() {
        let context = FrontmostContext(
            bundleIdentifier: "com.google.Chrome",
            appName: "Google Chrome",
            windowTitle: "AC.md - GitHub - Google Chrome"
        )

        #expect(MonitoringHeuristics.visualCheckReason(for: context) == "browser")
    }

    @Test
    func xcodeIsExemptFromPeriodicVisualChecks() {
        let context = FrontmostContext(
            bundleIdentifier: "com.apple.dt.Xcode",
            appName: "Xcode",
            windowTitle: "AC - ContentView.swift"
        )

        #expect(MonitoringHeuristics.visualCheckReason(for: context) == nil)
    }

    @Test
    func missingWindowTitleTriggersVisualChecksForNonProductiveApps() {
        let context = FrontmostContext(
            bundleIdentifier: "com.apple.TextEdit",
            appName: "TextEdit",
            windowTitle: nil
        )

        #expect(MonitoringHeuristics.visualCheckReason(for: context) == "missing-window-title")
    }

    @Test
    func detectsUnhelpfulWindowTitlesMatchingAppName() {
        #expect(MonitoringHeuristics.isUnhelpfulWindowTitle("Google Chrome", appName: "Google Chrome"))
        #expect(MonitoringHeuristics.isUnhelpfulWindowTitle("Google Chrome - Google Chrome", appName: "Google Chrome"))
    }

    @Test
    func keepsHelpfulWindowTitles() {
        #expect(MonitoringHeuristics.isUnhelpfulWindowTitle("Inbox - Gmail - Google Chrome", appName: "Google Chrome") == false)
    }

    @Test
    func titleRelatesToFocusReturnsNilWhenNoTitleOrGoal() {
        #expect(MonitoringHeuristics.titleRelatesToFocus(nil, focusGoal: "Writing essay on machines") == nil)
        #expect(MonitoringHeuristics.titleRelatesToFocus("", focusGoal: "Writing essay on machines") == nil)
        #expect(MonitoringHeuristics.titleRelatesToFocus("Some Title", focusGoal: nil) == nil)
        #expect(MonitoringHeuristics.titleRelatesToFocus("Some Title", focusGoal: "") == nil)
    }

    @Test
    func titleRelatesToFocusReturnsTrueOnSubstantiveOverlap() {
        // "interpretability" appears in both — substantive token (>= 4 chars, not a stopword).
        #expect(
            MonitoringHeuristics.titleRelatesToFocus(
                "On the Biology of a Large Language Model — interpretability",
                focusGoal: "Mechanistic interpretability research for thesis"
            ) == true
        )
    }

    @Test
    func titleRelatesToFocusReturnsFalseOnNoSubstantiveOverlap() {
        #expect(
            MonitoringHeuristics.titleRelatesToFocus(
                "TikTok — kittens compilation",
                focusGoal: "Drafting a Q3 marketing plan"
            ) == false
        )
    }

    @Test
    func titleRelatesToFocusIgnoresStopwordsAndShortTokens() {
        // Both sides are only stopwords / sub-4-char tokens → no signal.
        #expect(
            MonitoringHeuristics.titleRelatesToFocus(
                "the for and AC",
                focusGoal: "the for and AC"
            ) == nil
        )
        // AC-meta vocabulary ("focus", "session", "profile", "mode") is filtered, so a
        // shared "session" alone does not count as overlap.
        #expect(
            MonitoringHeuristics.titleRelatesToFocus(
                "Focus Session — AC",
                focusGoal: "Focus session active"
            ) == nil
        )
        // Real user vocabulary ("writing") survives the filter and produces overlap.
        #expect(
            MonitoringHeuristics.titleRelatesToFocus(
                "writing notes",
                focusGoal: "writing my essay"
            ) == true
        )
    }

    @Test
    func telemetrySnapshotPropagatesTitleRelatesField() {
        let context = FrontmostContext(
            bundleIdentifier: "com.apple.TextEdit",
            appName: "TextEdit",
            windowTitle: "Notes on machine consciousness draft"
        )
        let snapshot = MonitoringHeuristics.telemetrySnapshot(
            for: context,
            focusGoal: "Essay on machine consciousness"
        )
        #expect(snapshot.titleRelatesToDeclaredFocus == true)
    }

    @Test
    func telemetrySnapshotLeavesTitleRelatesNilWithoutGoal() {
        let context = FrontmostContext(
            bundleIdentifier: "com.apple.TextEdit",
            appName: "TextEdit",
            windowTitle: "Anything"
        )
        let snapshot = MonitoringHeuristics.telemetrySnapshot(for: context)
        #expect(snapshot.titleRelatesToDeclaredFocus == nil)
    }

    @Test
    func longDescriptiveTitlesCanSkipVisionAtConfiguredThreshold() {
        let title = "Draft Phase 4 monitoring threshold notes"

        #expect(
            MonitoringHeuristics.canRelyOnTitleAlone(
                bundleIdentifier: "com.apple.TextEdit",
                appName: "TextEdit",
                windowTitle: title,
                isBrowser: false,
                titleLengthThreshold: 30
            )
        )
        #expect(
            MonitoringHeuristics.canRelyOnTitleAlone(
                bundleIdentifier: "com.apple.TextEdit",
                appName: "TextEdit",
                windowTitle: title,
                isBrowser: false,
                titleLengthThreshold: 50
            ) == false
        )
    }
}

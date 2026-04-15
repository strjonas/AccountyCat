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
}
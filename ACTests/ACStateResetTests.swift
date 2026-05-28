//
//  ACStateResetTests.swift
//  ACTests
//
//  Created by Codex on 15.04.26.
//

import Foundation
import Testing
@testable import AC

@MainActor
struct ACStateResetTests {

    @Test
    func resetAlgorithmProfileClearsModelFacingState() {
        var state = ACState()
        state.monitoringConfiguration = MonitoringConfiguration(
            algorithmID: MonitoringConfiguration.deprecatedLegacyLLMAlgorithmID,
            selectionMode: .fixed,
            experimentArmOverride: "manual:test"
        )
        state.goalsText = "Temporary experiment goal"
        state.recentActions = [
            ActionRecord(kind: .nudge, message: "test", timestamp: Date(timeIntervalSince1970: 1))
        ]
        state.recentSwitches = [
            AppSwitchRecord(fromAppName: "Xcode", toAppName: "Chrome", toWindowTitle: "YouTube", timestamp: Date(timeIntervalSince1970: 2))
        ]
        state.usageByDay = [
            "2026-04-15": ["Google Chrome": 120]
        ]
        state.distraction = DistractionMetadata(
            contextKey: "com.google.Chrome|youtube",
            stableSince: Date(timeIntervalSince1970: 3),
            lastAssessment: .distracted,
            consecutiveDistractedCount: 2,
            nextEvaluationAt: Date(timeIntervalSince1970: 4)
        )
        state.memoryEntries = [MemoryEntry(text: "User disliked YouTube nudges.")]
        state.appMonitoringScopeMode = .allowlist
        state.appMonitoringAllowlist = [
            AppMonitoringSelection(bundleIdentifier: "com.apple.dt.Xcode", appName: "Xcode")
        ]
        state.appMonitoringBlocklist = [
            AppMonitoringSelection(bundleIdentifier: "com.google.Chrome", appName: "Google Chrome")
        ]

        state.resetAlgorithmProfile()

        #expect(state.goalsText == ACState.defaultGoalsText)
        #expect(state.recentActions.isEmpty)
        #expect(state.recentSwitches.isEmpty)
        #expect(state.usageByDay.isEmpty)
        #expect(state.algorithmState == AlgorithmStateEnvelope())
        #expect(state.distraction == DistractionMetadata())
        #expect(state.memoryEntries.isEmpty)
        #expect(state.appMonitoringScopeMode == .disabled)
        #expect(state.appMonitoringAllowlist.isEmpty)
        #expect(state.appMonitoringBlocklist.isEmpty)
        #expect(state.monitoringConfiguration.algorithmID == MonitoringConfiguration.defaultAlgorithmID)
        #expect(state.monitoringConfiguration.pipelineProfileID == MonitoringConfiguration.defaultPipelineProfileID)
        #expect(state.monitoringConfiguration.runtimeProfileID == MonitoringConfiguration.defaultRuntimeProfileID)
        #expect(state.monitoringConfiguration.experimentArm == "manual:test")
        #expect(state.policyMemory == PolicyMemory())
    }

    @Test
    func appMonitoringScopeSkipsAppsAccordingToMode() {
        var state = ACState()
        let xcodeSelection = [
            AppMonitoringSelection(bundleIdentifier: "com.apple.dt.Xcode", appName: "Xcode")
        ]
        state.appMonitoringAllowlist = xcodeSelection
        state.appMonitoringBlocklist = xcodeSelection

        let xcode = FrontmostContext(
            bundleIdentifier: "com.apple.dt.Xcode",
            appName: "Xcode",
            windowTitle: "AC"
        )
        let chrome = FrontmostContext(
            bundleIdentifier: "com.google.Chrome",
            appName: "Google Chrome",
            windowTitle: "Docs"
        )

        state.appMonitoringScopeMode = .allowlist
        #expect(state.shouldSkipMonitoring(for: xcode) == false)
        #expect(state.shouldSkipMonitoring(for: chrome))

        state.appMonitoringScopeMode = .blocklist
        #expect(state.shouldSkipMonitoring(for: xcode))
        #expect(state.shouldSkipMonitoring(for: chrome) == false)
    }

    @Test
    func separateAllowAndBlockListsAreIndependent() {
        var state = ACState()
        state.appMonitoringAllowlist = [
            AppMonitoringSelection(bundleIdentifier: "com.apple.dt.Xcode", appName: "Xcode")
        ]
        state.appMonitoringBlocklist = [
            AppMonitoringSelection(bundleIdentifier: "com.google.Chrome", appName: "Google Chrome")
        ]

        state.appMonitoringScopeMode = .allowlist
        #expect(state.activeAppMonitoringSelections.map(\.bundleIdentifier) == ["com.apple.dt.Xcode"])

        state.appMonitoringScopeMode = .blocklist
        #expect(state.activeAppMonitoringSelections.map(\.bundleIdentifier) == ["com.google.Chrome"])
    }

    @Test
    func decodesLegacySharedSelectionListIntoBothLists() throws {
        let legacyJSON = """
        {
            "appMonitoringScopeMode": "allowlist",
            "appMonitoringSelections": [
                { "bundleIdentifier": "com.apple.dt.Xcode", "appName": "Xcode" }
            ]
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(ACState.self, from: legacyJSON)
        #expect(decoded.appMonitoringAllowlist.map(\.bundleIdentifier) == ["com.apple.dt.Xcode"])
        #expect(decoded.appMonitoringBlocklist.map(\.bundleIdentifier) == ["com.apple.dt.Xcode"])
    }
}

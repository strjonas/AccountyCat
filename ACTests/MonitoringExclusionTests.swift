//
//  MonitoringExclusionTests.swift
//  ACTests
//
//  Covers the two deterministic "don't evaluate" gates added for v1.04:
//  - AC never monitors itself, in any profile (structural self-exclusion).
//  - AC waits instead of re-evaluating while an intervention overlay is open.
//

import Foundation
import Testing

@testable import AC

@MainActor
struct MonitoringExclusionTests {

    @Test
    func ownApplicationIsSkippedRegardlessOfProfile() {
        var state = ACState()
        // Put the user in a strict named profile — the self-exclusion must hold here too,
        // not only in Everyday where the legacy self-allow rule happened to be seeded.
        let focusProfile = FocusProfile(name: "Deep Work", isDefault: false)
        state.profiles.append(focusProfile)
        state.activeProfileID = focusProfile.id

        let acContext = FrontmostContext(
            bundleIdentifier: "dev.jon.AC",
            appName: "AccountyCat",
            windowTitle: "Chat"
        )
        #expect(state.monitoringScopeSkipReason(for: acContext) == .ownApplication)

        let inspectorContext = FrontmostContext(
            bundleIdentifier: "dev.jon.ACInspector",
            appName: "ACInspector",
            windowTitle: "Telemetry"
        )
        #expect(state.monitoringScopeSkipReason(for: inspectorContext) == .ownApplication)

        // Control: an unrelated app is not self-excluded.
        let otherContext = FrontmostContext(
            bundleIdentifier: "com.example.app",
            appName: "Example",
            windowTitle: "Something"
        )
        #expect(state.monitoringScopeSkipReason(for: otherContext) != .ownApplication)
    }

    @Test
    func brainServiceWaitsWhileOverlayActive() async {
        let store = TelemetryStore(
            rootURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("ac-overlay-gate-\(UUID().uuidString)", isDirectory: true)
        )
        let runtime = LocalModelRuntime()
        let registry = MonitoringAlgorithmRegistry(
            runtime: runtime,
            onlineModelService: OnlineModelService(),
            policyMemoryService: PolicyMemoryService(
                runtime: runtime,
                onlineModelService: OnlineModelService()
            )
        )

        var nudgeShown = false
        var overlayShown = false
        let arm = ExecutiveArm(
            showNudge: { _ in nudgeShown = true },
            showOverlay: { _ in overlayShown = true },
            hideOverlay: {},
            minimizeApp: { _ in }
        )

        let brainService = BrainService(
            monitoringAlgorithmRegistry: registry,
            executiveArm: arm,
            runtime: runtime,
            storageService: StorageService.temporary(),
            telemetryStore: store
        )

        var state = ACState()
        state.setupStatus = .ready
        state.permissions = PermissionsSnapshot(screenRecording: .granted, accessibility: .granted)

        var latestStatus = ""
        var contextRead = false
        brainService.stateProvider = { state }
        brainService.stateSink = { _, updatedState in state = updatedState }
        brainService.statusSink = { latestStatus = $0 }
        brainService.contextProvider = {
            contextRead = true
            return FrontmostContext(
                bundleIdentifier: "com.example.app", appName: "Example", windowTitle: "Focus")
        }
        brainService.idleSecondsProvider = { 0 }
        brainService.overlayActiveProvider = { true }

        await brainService.tick()

        #expect(latestStatus.contains("Overlay is open"))
        // The gate returns before any context read or intervention.
        #expect(contextRead == false)
        #expect(nudgeShown == false)
        #expect(overlayShown == false)
    }
}

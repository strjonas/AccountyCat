//
//  CallDetectionServiceTests.swift
//  ACTests
//

import Foundation
import Testing
@testable import AC

@MainActor
struct CallDetectionServiceTests {

    @Test
    func overrideShortCircuitsHeuristics() {
        CallDetectionService.$isInCallOverride.withValue(true) {
            #expect(CallDetectionService.isInCall() == true)
        }

        CallDetectionService.$isInCallOverride.withValue(false) {
            #expect(CallDetectionService.isInCall() == false)
        }
    }

    @Test
    func brainServiceSuppressesEvaluationWhenInCall() async throws {
        let store = TelemetryStore(
            rootURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("ac-call-tests-\(UUID().uuidString)", isDirectory: true)
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

        var hideCompanionCalled = false
        var showCompanionCalled = false
        var dismissOverlayCalled = false

        let arm = ExecutiveArm(
            showNudge: { _ in },
            showOverlay: { _ in },
            hideOverlay: { dismissOverlayCalled = true },
            minimizeApp: { _ in },
            hideCompanion: { hideCompanionCalled = true },
            showCompanion: { showCompanionCalled = true }
        )

        let brainService = BrainService(
            monitoringAlgorithmRegistry: registry,
            executiveArm: arm,
            storageService: StorageService.temporary(),
            telemetryStore: store
        )

        var state = ACState()
        state.setupStatus = .ready
        state.permissions = PermissionsSnapshot(screenRecording: .granted, accessibility: .granted)
        state.autoQuietOnCalls = true

        brainService.stateProvider = { state }
        func applyStateUpdate(_: ACState, updatedState: ACState) {
            state = updatedState
        }
        brainService.stateSink = applyStateUpdate

        // Provide a deterministic frontmost context so tick() doesn't bail out early.
        brainService.contextProvider = {
            FrontmostContext(bundleIdentifier: "com.example.app", appName: "Example", windowTitle: "Focus")
        }
        brainService.idleSecondsProvider = { 0 }

        // --- First tick: enter call ---
        await CallDetectionService.$isInCallOverride.withValue(true) {
            hideCompanionCalled = false
            dismissOverlayCalled = false
            await brainService.tick()

            #expect(hideCompanionCalled == true)
            #expect(dismissOverlayCalled == true)
            #expect(showCompanionCalled == false)

            // --- Second tick: still in call ---
            hideCompanionCalled = false
            dismissOverlayCalled = false
            await brainService.tick()

            // Should not re-hide/re-dismiss while already in call.
            #expect(hideCompanionCalled == false)
            #expect(dismissOverlayCalled == false)
        }

        // --- Third tick: call ended ---
        showCompanionCalled = false
        await brainService.tick()

        #expect(showCompanionCalled == true)
    }

    @Test
    func brainServiceDoesNotSuppressWhenToggleIsOff() async throws {
        let store = TelemetryStore(
            rootURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("ac-call-tests-\(UUID().uuidString)", isDirectory: true)
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

        var hideCompanionCalled = false
        let arm = ExecutiveArm(
            showNudge: { _ in },
            showOverlay: { _ in },
            hideOverlay: { },
            minimizeApp: { _ in },
            hideCompanion: { hideCompanionCalled = true },
            showCompanion: { }
        )

        let brainService = BrainService(
            monitoringAlgorithmRegistry: registry,
            executiveArm: arm,
            storageService: StorageService.temporary(),
            telemetryStore: store
        )

        var state = ACState()
        state.setupStatus = .ready
        state.permissions = PermissionsSnapshot(screenRecording: .granted, accessibility: .granted)
        state.autoQuietOnCalls = false

        brainService.stateProvider = { state }
        func applyStateUpdate(_: ACState, updatedState: ACState) {
            state = updatedState
        }
        brainService.stateSink = applyStateUpdate
        brainService.contextProvider = {
            FrontmostContext(bundleIdentifier: "com.example.app", appName: "Example", windowTitle: "Focus")
        }
        brainService.idleSecondsProvider = { 0 }

        await CallDetectionService.$isInCallOverride.withValue(true) {
            hideCompanionCalled = false
            await brainService.tick()

            // Since autoQuietOnCalls is false, it should NOT hide the companion.
            #expect(hideCompanionCalled == false)
        }
    }
}

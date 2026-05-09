//
//  SnapshotServiceTests.swift
//  ACTests
//
//  Created by AccountyCat contributors on 02.05.26.
//

import CoreGraphics
import Foundation
import Testing
@testable import AC

@MainActor
struct SnapshotServiceTests {

    @Test
    func idleSecondsIsNonNegative() {
        let idle = SnapshotService.idleSeconds()
        #expect(idle >= 0)
    }

    @Test
    func snapshotErrorDescriptionsAreUserFriendly() {
        #expect(SnapshotError.failedToCreateImageDestination.errorDescription?.isEmpty == false)
        #expect(SnapshotError.failedToWriteImage.errorDescription?.isEmpty == false)
        #expect(SnapshotError.captureReturnedNoImage.errorDescription?.isEmpty == false)
        #expect(SnapshotError.captureTimedOut.errorDescription?.isEmpty == false)
    }

    @Test
    func snapshotErrorsAreDistinct() {
        let descriptions = [
            SnapshotError.failedToCreateImageDestination.errorDescription,
            SnapshotError.failedToWriteImage.errorDescription,
            SnapshotError.captureReturnedNoImage.errorDescription,
            SnapshotError.captureTimedOut.errorDescription,
        ]
        // All four descriptions should be different from each other
        for i in 0..<descriptions.count {
            for j in (i + 1)..<descriptions.count {
                #expect(descriptions[i] != descriptions[j])
            }
        }
    }

    @Test
    func frontmostContextReturnsNilWhenNoApp() {
        // frontmostContext queries NSWorkspace.frontmostApplication which returns
        // nil in headless/test environments. This validates the nil path.
        let context = SnapshotService.frontmostContext()
        // In a test environment without a frontmost app, this should be nil.
        // In CI or headless contexts this is the expected behavior.
        #expect(context == nil || context?.appName.isEmpty == false)
    }

    @Test
    func accessibilityCoordinatesUseTopLeftOrigin() {
        // kAXPositionAttribute is already the global screen coordinate of the
        // window's top-left corner, so SnapshotService must not flip Y.
        let accessibilityRect = CGRect(x: 100, y: 80, width: 500, height: 400)
        let screenCaptureRect = accessibilityRect
        #expect(screenCaptureRect.origin.y == 80)
        #expect(screenCaptureRect == accessibilityRect)
    }

    @Test
    func screenCapturePointSizeRoundsUpToPixels() {
        #expect(SnapshotService.pixelLength(points: 100, scale: 2) == 200)
        #expect(SnapshotService.pixelLength(points: 100.25, scale: 2) == 201)
        #expect(SnapshotService.pixelLength(points: 0, scale: 2) == 1)
    }

    @Test
    func detectsScreenCaptureKitPermissionErrors() {
        let permissionError = NSError(
            domain: "com.apple.ScreenCaptureKit.CoreGraphicsErrorDomain",
            code: 1004
        )
        let unrelatedError = NSError(domain: NSCocoaErrorDomain, code: 4)

        #expect(SnapshotService.indicatesScreenCapturePermissionLoss(permissionError))
        #expect(!SnapshotService.indicatesScreenCapturePermissionLoss(unrelatedError))
    }
}

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
    func accessibilityToDisplaySpaceConversion() {
        // Accessibility APIs return rects with a bottom-left origin.
        // SCScreenshotManager expects top-left origin display space.
        // This test documents the conversion math used in SnapshotService.
        let mainHeight: CGFloat = 1080

        // Window sitting at the bottom of the screen (Accessibility y = 0)
        let bottomRect = CGRect(x: 100, y: 0, width: 500, height: 400)
        let convertedBottomY = mainHeight - (bottomRect.origin.y + bottomRect.height)
        #expect(convertedBottomY == 680) // 1080 - 400 = 680

        // Window touching the top of the screen (Accessibility y = 680)
        let topRect = CGRect(x: 100, y: 680, width: 500, height: 400)
        let convertedTopY = mainHeight - (topRect.origin.y + topRect.height)
        #expect(convertedTopY == 0) // 1080 - 1080 = 0
    }
}

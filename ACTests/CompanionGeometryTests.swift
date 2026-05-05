//
//  CompanionGeometryTests.swift
//  ACTests
//
//  Created by Codex on 05.05.26.
//

import AppKit
import Testing
@testable import AC

struct CompanionGeometryTests {

    @Test
    func popoverPrefersAboveAndShiftsAnchorHorizontallyToStayVisible() {
        let visibleFrame = NSRect(x: 0, y: 0, width: 1000, height: 800)
        let anchor = NSRect(x: 32, y: 100, width: 72, height: 72)

        let placement = CompanionGeometry.popoverPlacement(
            for: anchor,
            in: visibleFrame,
            popoverSize: NSSize(width: 400, height: 460)
        )

        #expect(placement.preferredEdge == .maxY)
        #expect(placement.adjustedAnchorRect.minX > anchor.minX)
    }

    @Test
    func popoverChoosesSideWhenVerticalSpaceIsUnavailable() {
        let visibleFrame = NSRect(x: 0, y: 0, width: 900, height: 320)
        let anchor = NSRect(x: 100, y: 120, width: 72, height: 72)

        let placement = CompanionGeometry.popoverPlacement(
            for: anchor,
            in: visibleFrame,
            popoverSize: NSSize(width: 260, height: 260)
        )

        #expect(placement.preferredEdge == .maxX)
    }

    @Test
    func popoverUsesLowerEdgeWhenBelowHasMoreSpace() {
        let visibleFrame = NSRect(x: 0, y: 0, width: 1000, height: 900)
        let anchor = NSRect(x: 420, y: 680, width: 72, height: 72)

        let placement = CompanionGeometry.popoverPlacement(
            for: anchor,
            in: visibleFrame,
            popoverSize: NSSize(width: 320, height: 180)
        )

        #expect(placement.preferredEdge == .minY)
    }

    @Test
    func clampedPanelFrameKeepsExpandedNudgeWithinVisibleFrame() {
        let visibleFrame = NSRect(x: 0, y: 30, width: 800, height: 600)
        let frame = NSRect(x: -40, y: 10, width: 200, height: 560)

        let clamped = CompanionGeometry.clampedPanelFrame(frame, within: visibleFrame)

        #expect(clamped.minX >= visibleFrame.minX + CompanionGeometry.presentationMargin)
        #expect(clamped.minY >= visibleFrame.minY + CompanionGeometry.presentationMargin)
        #expect(clamped.maxX <= visibleFrame.maxX - CompanionGeometry.presentationMargin)
        #expect(clamped.maxY <= visibleFrame.maxY - CompanionGeometry.presentationMargin)
    }
}

//
//  CompanionGeometry.swift
//  AC
//
//  Shared geometry helpers for the floating companion, nudge bubble,
//  and orb-anchored popover placement.
//

import AppKit

struct CompanionPopoverPlacement {
    let preferredEdge: NSRectEdge
    let adjustedAnchorRect: NSRect
}

enum CompanionGeometry {
    static let orbBottomPadding: CGFloat = 14
    static let presentationMargin: CGFloat = 12
    static let popoverGap: CGFloat = 8

    static func orbCenter(forPanelFrame panelFrame: NSRect) -> NSPoint {
        NSPoint(
            x: panelFrame.midX,
            y: panelFrame.minY + orbBottomPadding + ACD.orbDiameter / 2
        )
    }

    static func clampedPanelFrame(
        _ frame: NSRect,
        within visibleFrame: NSRect,
        margin: CGFloat = presentationMargin
    ) -> NSRect {
        let minX = visibleFrame.minX + margin
        let maxX = max(minX, visibleFrame.maxX - frame.width - margin)
        let minY = visibleFrame.minY + margin
        let maxY = max(minY, visibleFrame.maxY - frame.height - margin)

        return NSRect(
            x: frame.origin.x.acClamped(to: minX ... maxX),
            y: frame.origin.y.acClamped(to: minY ... maxY),
            width: frame.width,
            height: frame.height
        )
    }

    static func popoverPlacement(
        for anchorRect: NSRect,
        in visibleFrame: NSRect,
        popoverSize: NSSize,
        margin: CGFloat = presentationMargin,
        gap: CGFloat = popoverGap
    ) -> CompanionPopoverPlacement {
        let spaceAbove = visibleFrame.maxY - anchorRect.maxY
        let spaceBelow = anchorRect.minY - visibleFrame.minY
        let spaceRight = visibleFrame.maxX - anchorRect.maxX
        let spaceLeft = anchorRect.minX - visibleFrame.minX

        let aboveFits = spaceAbove >= popoverSize.height + gap + margin
        let belowFits = spaceBelow >= popoverSize.height + gap + margin
        let rightFits = spaceRight >= popoverSize.width + gap + margin
        let leftFits = spaceLeft >= popoverSize.width + gap + margin

        let preferredVerticalEdge: NSRectEdge = spaceAbove >= spaceBelow ? .maxY : .minY
        let preferredHorizontalEdge: NSRectEdge = spaceRight >= spaceLeft ? .maxX : .minX

        if aboveFits || belowFits {
            let edge: NSRectEdge
            if preferredVerticalEdge == .maxY {
                edge = aboveFits ? .maxY : .minY
            } else {
                edge = belowFits ? .minY : .maxY
            }
            return placement(
                for: edge,
                anchorRect: anchorRect,
                visibleFrame: visibleFrame,
                popoverSize: popoverSize,
                margin: margin
            )
        }

        if rightFits || leftFits {
            let edge: NSRectEdge
            if preferredHorizontalEdge == .maxX {
                edge = rightFits ? .maxX : .minX
            } else {
                edge = leftFits ? .minX : .maxX
            }
            return placement(
                for: edge,
                anchorRect: anchorRect,
                visibleFrame: visibleFrame,
                popoverSize: popoverSize,
                margin: margin
            )
        }

        let candidates: [CompanionPopoverPlacement] = [.maxY, .minY, .maxX, .minX].map {
            placement(
                for: $0,
                anchorRect: anchorRect,
                visibleFrame: visibleFrame,
                popoverSize: popoverSize,
                margin: margin
            )
        }

        return candidates.min {
            overflow(of: $0, popoverSize: popoverSize, visibleFrame: visibleFrame)
                < overflow(of: $1, popoverSize: popoverSize, visibleFrame: visibleFrame)
        } ?? placement(
            for: .maxY,
            anchorRect: anchorRect,
            visibleFrame: visibleFrame,
            popoverSize: popoverSize,
            margin: margin
        )
    }

    private static func placement(
        for edge: NSRectEdge,
        anchorRect: NSRect,
        visibleFrame: NSRect,
        popoverSize: NSSize,
        margin: CGFloat
    ) -> CompanionPopoverPlacement {
        var adjusted = anchorRect

        switch edge {
        case .maxY, .minY:
            let popoverX = anchorRect.midX - popoverSize.width / 2
            let clampedX = popoverX.acClamped(
                to: (visibleFrame.minX + margin) ... max(visibleFrame.minX + margin, visibleFrame.maxX - popoverSize.width - margin)
            )
            adjusted.origin.x += clampedX - popoverX

        case .maxX, .minX:
            let popoverY = anchorRect.midY - popoverSize.height / 2
            let clampedY = popoverY.acClamped(
                to: (visibleFrame.minY + margin) ... max(visibleFrame.minY + margin, visibleFrame.maxY - popoverSize.height - margin)
            )
            adjusted.origin.y += clampedY - popoverY

        @unknown default:
            break
        }

        return CompanionPopoverPlacement(
            preferredEdge: edge,
            adjustedAnchorRect: adjusted
        )
    }

    private static func overflow(
        of placement: CompanionPopoverPlacement,
        popoverSize: NSSize,
        visibleFrame: NSRect
    ) -> CGFloat {
        let rect = popoverRect(
            for: placement.preferredEdge,
            anchorRect: placement.adjustedAnchorRect,
            popoverSize: popoverSize
        )
        let left = max(0, visibleFrame.minX - rect.minX)
        let right = max(0, rect.maxX - visibleFrame.maxX)
        let bottom = max(0, visibleFrame.minY - rect.minY)
        let top = max(0, rect.maxY - visibleFrame.maxY)
        return left + right + bottom + top
    }

    private static func popoverRect(
        for edge: NSRectEdge,
        anchorRect: NSRect,
        popoverSize: NSSize
    ) -> NSRect {
        switch edge {
        case .maxY:
            return NSRect(
                x: anchorRect.midX - popoverSize.width / 2,
                y: anchorRect.maxY + popoverGap,
                width: popoverSize.width,
                height: popoverSize.height
            )
        case .minY:
            return NSRect(
                x: anchorRect.midX - popoverSize.width / 2,
                y: anchorRect.minY - popoverGap - popoverSize.height,
                width: popoverSize.width,
                height: popoverSize.height
            )
        case .maxX:
            return NSRect(
                x: anchorRect.maxX + popoverGap,
                y: anchorRect.midY - popoverSize.height / 2,
                width: popoverSize.width,
                height: popoverSize.height
            )
        case .minX:
            return NSRect(
                x: anchorRect.minX - popoverGap - popoverSize.width,
                y: anchorRect.midY - popoverSize.height / 2,
                width: popoverSize.width,
                height: popoverSize.height
            )
        @unknown default:
            return NSRect(origin: .zero, size: popoverSize)
        }
    }
}

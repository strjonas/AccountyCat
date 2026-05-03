//
//  PixelCatGrid.swift
//  AC
//
//  Static grid definitions for the pixel-art cat face.  Each mood is a set
//  of (row, col) coordinates in a 16×16 grid.  A cell is simply a filled
//  rounded-square; the grid pattern is the same across all personalities —
//  only the fill color and animation timing change per character.
//

import Foundation

enum PixelCatMood: String, CaseIterable {
    case idle
    case watching
    case nudging
    case escalated
    case escalatedHard
    case paused
    case setup
}

struct PixelCatGrid {

    static let gridSize = 16

    // MARK: - Idle / default pattern

    static let idle: Set<GridPoint> = [
        // Left ear
        GridPoint(1, 3), GridPoint(1, 4),
        GridPoint(2, 2), GridPoint(2, 3), GridPoint(2, 4),
        GridPoint(3, 2), GridPoint(3, 3),
        // Right ear
        GridPoint(1, 11), GridPoint(1, 12),
        GridPoint(2, 11), GridPoint(2, 12), GridPoint(2, 13),
        GridPoint(3, 12), GridPoint(3, 13),
        // Head — rows 4–12, cols 3–12
        GridPoint(4, 3),  GridPoint(4, 4),  GridPoint(4, 5),  GridPoint(4, 6),
        GridPoint(4, 7),  GridPoint(4, 8),  GridPoint(4, 9),  GridPoint(4, 10),
        GridPoint(4, 11), GridPoint(4, 12),
        GridPoint(5, 2),  GridPoint(5, 3),  GridPoint(5, 4),  GridPoint(5, 5),
        GridPoint(5, 6),  GridPoint(5, 7),  GridPoint(5, 8),  GridPoint(5, 9),
        GridPoint(5, 10), GridPoint(5, 11), GridPoint(5, 12), GridPoint(5, 13),
        GridPoint(6, 2),  GridPoint(6, 3),  GridPoint(6, 4),  GridPoint(6, 5),
        GridPoint(6, 6),  GridPoint(6, 7),  GridPoint(6, 8),  GridPoint(6, 9),
        GridPoint(6, 10), GridPoint(6, 11), GridPoint(6, 12), GridPoint(6, 13),
        GridPoint(7, 2),  GridPoint(7, 3),  GridPoint(7, 4),  GridPoint(7, 5),
        GridPoint(7, 6),  GridPoint(7, 7),  GridPoint(7, 8),  GridPoint(7, 9),
        GridPoint(7, 10), GridPoint(7, 11), GridPoint(7, 12), GridPoint(7, 13),
        GridPoint(8, 2),  GridPoint(8, 3),  GridPoint(8, 4),  GridPoint(8, 5),
        GridPoint(8, 6),  GridPoint(8, 7),  GridPoint(8, 8),  GridPoint(8, 9),
        GridPoint(8, 10), GridPoint(8, 11), GridPoint(8, 12), GridPoint(8, 13),
        GridPoint(9, 2),  GridPoint(9, 3),  GridPoint(9, 4),  GridPoint(9, 5),
        GridPoint(9, 6),  GridPoint(9, 7),  GridPoint(9, 8),  GridPoint(9, 9),
        GridPoint(9, 10), GridPoint(9, 11), GridPoint(9, 12), GridPoint(9, 13),
        GridPoint(10, 3), GridPoint(10, 4),  GridPoint(10, 5), GridPoint(10, 6),
        GridPoint(10, 7), GridPoint(10, 8),  GridPoint(10, 9), GridPoint(10, 10),
        GridPoint(10, 11), GridPoint(10, 12),
        GridPoint(11, 4), GridPoint(11, 5),  GridPoint(11, 6), GridPoint(11, 7),
        GridPoint(11, 8), GridPoint(11, 9),  GridPoint(11, 10), GridPoint(11, 11),
        GridPoint(12, 5), GridPoint(12, 6), GridPoint(12, 7),
        GridPoint(12, 8), GridPoint(12, 9), GridPoint(12, 10),
    ]

    // MARK: - Eyes — single cell each for idle

    static let idleEyes: Set<GridPoint> = [
        GridPoint(6, 5),  // left eye
        GridPoint(6, 10), // right eye
    ]

    // MARK: - Nose

    static let nose: Set<GridPoint> = [
        GridPoint(8, 7), GridPoint(8, 8),
    ]

    // MARK: - Mouth (idle: small smile)

    static let idleMouth: Set<GridPoint> = [
        GridPoint(10, 6), GridPoint(10, 7),
        GridPoint(10, 8), GridPoint(10, 9),
    ]

    // MARK: - Nudging — wider eyes

    static let nudgeEyes: Set<GridPoint> = [
        GridPoint(5, 5),  GridPoint(6, 5),  // left eye (2 cells tall)
        GridPoint(5, 10), GridPoint(6, 10), // right eye (2 cells tall)
    ]

    static let nudgeExclamation: Set<GridPoint> = [
        GridPoint(3, 14),
        GridPoint(4, 14),
        GridPoint(5, 14),
        GridPoint(7, 14),
    ]

    // MARK: - Escalated — narrow eyes

    static let escalatedEyes: Set<GridPoint> = [
        GridPoint(6, 4),  GridPoint(6, 5),  GridPoint(6, 6),   // left eye (horizontal line)
        GridPoint(6, 9),  GridPoint(6, 10), GridPoint(6, 11),  // right eye
    ]

    // MARK: - Escalated hard — bigger exclamation + flatter ears

    static let escalatedHardEyes: Set<GridPoint> = [
        GridPoint(6, 4),  GridPoint(6, 5),  GridPoint(6, 6),
        GridPoint(6, 9),  GridPoint(6, 10), GridPoint(6, 11),
    ]

    // MARK: - Paused — dimmed, "Z" pattern

    static let pausedZ: Set<GridPoint> = [
        GridPoint(2, 14),
        GridPoint(3, 13), GridPoint(3, 14),
        GridPoint(4, 12), GridPoint(4, 14),
        GridPoint(5, 11), GridPoint(5, 12),
    ]

    // MARK: - Full pattern per mood

    static func cells(for mood: PixelCatMood) -> Set<GridPoint> {
        let base = Self.idle
        let eyes: Set<GridPoint>
        let extras: Set<GridPoint>

        switch mood {
        case .idle, .watching:
            eyes = Self.idleEyes
            extras = Self.nose.union(Self.idleMouth)
        case .nudging:
            eyes = Self.nudgeEyes
            extras = Self.nose.union(Self.idleMouth).union(Self.nudgeExclamation)
        case .escalated:
            eyes = Self.escalatedEyes
            extras = Self.nose.union(Self.idleMouth)
        case .escalatedHard:
            eyes = Self.escalatedHardEyes
            extras = Self.nose.union(Self.idleMouth)
        case .paused:
            eyes = Self.idleEyes
            extras = Self.nose.union(Self.idleMouth).union(Self.pausedZ)
        case .setup:
            eyes = Self.idleEyes
            extras = Self.nose.union(Self.idleMouth)
        }

        return base.union(eyes).union(extras)
    }

    // MARK: - Accent cells (eye colour override)

    static func accentCells(for mood: PixelCatMood) -> Set<GridPoint> {
        switch mood {
        case .idle, .watching, .setup:
            return Self.idleEyes.union(Self.nose)
        case .nudging:
            return Self.nudgeEyes.union(Self.nose).union(Self.nudgeExclamation)
        case .escalated, .escalatedHard:
            return Self.escalatedEyes.union(Self.nose)
        case .paused:
            return Self.idleEyes.union(Self.nose)
        }
    }
}

struct GridPoint: Hashable {
    let row: Int
    let col: Int

    init(_ row: Int, _ col: Int) {
        self.row = row
        self.col = col
    }
}
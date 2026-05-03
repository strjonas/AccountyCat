//
//  PixelCatView.swift
//  AC
//
//  Geometric pixel-grid cat face.  A 16×16 grid of rounded squares forms the
//  cat silhouette; each cell is independently filled and can animate per-mood.
//  The pattern is the same across all personalities — only colour and timing
//  differ.  Designed for use both inside the floating orb and as a small
//  header icon.
//

import SwiftUI

struct PixelCatView: View {
    let mood: PixelCatMood
    let character: ACCharacter
    var diameter: CGFloat = 72
    var animating: Bool = true

    @State private var isBlinking = false
    @State private var blinkTask: Task<Void, Never>?

    private let gridSize = PixelCatGrid.gridSize

    var body: some View {
        let cellSize = diameter / CGFloat(gridSize)
        let cellRadius = character.pixelCornerRadius * (diameter / 72.0)
        let currentCells = PixelCatGrid.cells(for: mood)
        let accentCells = PixelCatGrid.accentCells(for: mood)
        let bodyColor: Color = character.accentColor.opacity(mood == .paused ? 0.30 : 1.0)
        let accentColor: Color = .white.opacity(mood == .paused ? 0.25 : 0.95)
        let showingEyes = !(isBlinking && (mood == .idle || mood == .watching || mood == .setup))
        let eyesForBlink = showingEyes
            ? accentCells
            : accentCells.subtracting(PixelCatGrid.idleEyes).subtracting(PixelCatGrid.nudgeEyes)

        ZStack {
            ForEach(Array(currentCells), id: \.self) { point in
                RoundedRectangle(cornerRadius: cellRadius, style: .continuous)
                    .fill(eyesForBlink.contains(point) ? accentColor : bodyColor)
                    .frame(width: cellSize - 1, height: cellSize - 1)
                    .position(
                        x: CGFloat(point.col) * cellSize + cellSize / 2,
                        y: CGFloat(point.row) * cellSize + cellSize / 2
                    )
                    .transition(.opacity.combined(with: .scale(scale: 0.5)))
            }
        }
        .frame(width: diameter, height: diameter)
        .clipped()
        .onAppear { startBlinking() }
        .onChange(of: mood) { _, _ in
            isBlinking = false
            startBlinking()
        }
    }

    private func startBlinking() {
        guard animating else { return }
        blinkTask?.cancel()
        let intervalRange = character.blinkIntervalRange
        blinkTask = Task { @MainActor in
            while !Task.isCancelled {
                let interval = Double.random(in: intervalRange.lowerBound...intervalRange.upperBound)
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard !Task.isCancelled else { return }
                withAnimation(.easeInOut(duration: 0.08)) { isBlinking = true }
                try? await Task.sleep(nanoseconds: 120_000_000)
                guard !Task.isCancelled else { return }
                withAnimation(.easeInOut(duration: 0.08)) { isBlinking = false }
                if Bool.random() {
                    try? await Task.sleep(nanoseconds: 150_000_000)
                    guard !Task.isCancelled else { return }
                    withAnimation(.easeInOut(duration: 0.08)) { isBlinking = true }
                    try? await Task.sleep(nanoseconds: 120_000_000)
                    guard !Task.isCancelled else { return }
                    withAnimation(.easeInOut(duration: 0.08)) { isBlinking = false }
                }
            }
        }
    }
}

// MARK: - Character pixel parameters

extension ACCharacter {
    /// Corner radius for each pixel cell, varying slightly per personality.
    var pixelCornerRadius: CGFloat {
        switch self {
        case .mochi: return 2.0
        case .nova:  return 1.2
        case .sage:  return 2.0
        }
    }

    /// Range of seconds between blinks, per personality.
    var blinkIntervalRange: ClosedRange<Double> {
        switch self {
        case .mochi: return 5.0...13.0
        case .nova:  return 4.0...10.0
        case .sage:  return 7.0...16.0
        }
    }
}

// MARK: - CompanionMood → PixelCatMood

extension CompanionMood {
    var pixelMood: PixelCatMood {
        switch self {
        case .idle:       return .idle
        case .watching:   return .watching
        case .nudging:    return .nudging
        case .escalated:  return .escalated
        case .escalatedHard: return .escalatedHard
        case .paused:     return .paused
        case .setup:      return .setup
        }
    }
}

// MARK: - Menu bar icon helper

extension PixelCatView {
    /// Render a monochrome template NSImage for the menu bar.
    /// Uses the idle grid by default; pass a specific mood for reactive states.
    @MainActor
    static func menuBarTemplateImage(size: CGFloat = 18, mood: PixelCatMood = .idle) -> NSImage {
        let content = PixelCatView(
                mood: mood,
                character: .mochi,
                diameter: size,
                animating: false
            )
            .colorInvert()
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2.0
        guard let image = renderer.nsImage else {
            return NSImage(systemSymbolName: "pawprint.fill", accessibilityDescription: "AC")!
        }
        image.isTemplate = true
        return image
    }
}
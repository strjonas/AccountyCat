//
//  CatView.swift
//  AC
//
//  The single companion-cat view. Renders a character portrait at the
//  requested expression, owns its own breathing + blink animations, and
//  crossfades between expressions when the mood changes.
//

import SwiftUI

struct CatView: View {
    let character: ACCharacter
    let expression: ACCatExpression
    var size: CGFloat = 72
    var animating: Bool = true

    @State private var breath: CGFloat = 1.0
    @State private var isBlinking: Bool = false
    @State private var blinkTask: Task<Void, Never>?

    var body: some View {
        // Crossfade between expression assets so mood changes feel smooth.
        // While idle on .neutral, briefly swap to the blink frame.
        let visible: ACCatExpression = {
            if expression == .neutral && isBlinking { return .blink }
            return expression
        }()

        Image(character.portraitAssetName(for: visible))
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
            .scaleEffect(breath)
            .animation(.easeInOut(duration: 0.22), value: visible)
            .onAppear {
                startBreathing()
                startBlinking()
            }
            .onDisappear { stopAnimations() }
            .onChange(of: expression) { _, _ in
                // Restart blink scheduling when leaving / entering neutral.
                isBlinking = false
                startBlinking()
            }
    }

    // MARK: - Breathing
    //
    // Subtle 1.0 ↔ 1.03 oscillation, ~3s period. Disabled when `animating`
    // is false (settings previews, menu bar). Idle expression only — keeps
    // the orb feeling alive without making nudge / overlay states wobble.

    private func startBreathing() {
        guard animating else { return }
        withAnimation(.easeInOut(duration: 3.0).repeatForever(autoreverses: true)) {
            breath = 1.03
        }
    }

    // MARK: - Blink
    //
    // Random 4–7s jittered interval. ~140ms hold. Hard swap (no fade) reads
    // as a real blink. Only fires when the underlying expression is `.neutral`.

    private func startBlinking() {
        blinkTask?.cancel()
        guard animating, expression == .neutral else { return }
        blinkTask = Task { @MainActor in
            while !Task.isCancelled {
                let wait = Double.random(in: 4.0...7.0)
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                guard !Task.isCancelled, expression == .neutral else { return }
                isBlinking = true
                try? await Task.sleep(nanoseconds: 140_000_000)
                guard !Task.isCancelled else { return }
                isBlinking = false
            }
        }
    }

    private func stopAnimations() {
        blinkTask?.cancel()
        blinkTask = nil
    }
}

// MARK: - Menu bar icon helper

extension CatView {
    /// Produce a flat template image for the menu bar. The cat portraits are
    /// photographic, so the menu-bar variant renders the neutral pose tinted
    /// dark and flagged as a template — macOS will recolor it for light/dark
    /// menu bars automatically.
    @MainActor
    static func menuBarTemplateImage(
        size: CGFloat = 18,
        character: ACCharacter = .mochi,
        expression: ACCatExpression = .neutral
    ) -> NSImage {
        let content = Image(character.portraitAssetName(for: expression))
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
            .colorMultiply(.black) // collapse to silhouette for template rendering
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2.0
        guard let image = renderer.nsImage else {
            return NSImage(systemSymbolName: "pawprint.fill", accessibilityDescription: "AC")!
        }
        image.isTemplate = true
        return image
    }
}

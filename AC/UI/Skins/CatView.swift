//
//  CatView.swift
//  AC
//
//  The single companion-cat view. Renders a character portrait at the
//  requested expression and owns its own gentle pulsating animation
//  that keeps the orb feeling alive without any image-swap jitter.
//

import SwiftUI

struct CatView: View {
    let character: ACCharacter
    let expression: ACCatExpression
    var size: CGFloat = 72
    var animating: Bool = true

    @State private var pulse: CGFloat = 1.0

    var body: some View {
        Image(character.portraitAssetName(for: expression))
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
            .scaleEffect(pulse)
            .onAppear { startPulsating() }
            .onDisappear { stopAnimations() }
    }

    // MARK: - Pulsating
    //
    // Gentle 1.0 ↔ 1.05 oscillation, ~2s period. Disabled when `animating`
    // is false (settings previews, menu bar). Keeps the orb feeling alive
    // without any image-swap transitions.

    private func startPulsating() {
        guard animating else { return }
        withAnimation(.easeInOut(duration: 2.0).repeatForever(autoreverses: true)) {
            pulse = 1.05
        }
    }

    private func stopAnimations() {
        pulse = 1.0
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

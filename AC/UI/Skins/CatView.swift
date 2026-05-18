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

    var body: some View {
        Image(character.portraitAssetName(for: expression))
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
            // Keep the orb at true rest by default. Continuous idle animation
            // was a measurable steady-state CPU cost even when AC was otherwise
            // inactive or hidden.
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

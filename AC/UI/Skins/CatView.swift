//
//  CatView.swift
//  AC
//
//  The single companion-portrait view. Renders the active character at the
//  requested expression. Despite the name (kept for call-site stability) it is
//  character-agnostic: it resolves the portrait source and renders the right
//  thing —
//
//    • .asset      → bundled imageset (the original cats; the dog once art lands)
//    • .files      → offline PNGs the user supplied for a custom character
//    • .procedural → drawn in SwiftUI (the abstract Orb)
//
//  Missing art never crashes: a built-in without its assets yet (e.g. the dog
//  before its portraits are added) and custom characters missing a pose both
//  fall back gracefully.
//

import SwiftUI

struct CatView: View {
    let character: ACCharacter
    let expression: ACCatExpression
    var size: CGFloat = 72
    var animating: Bool = true

    var body: some View {
        switch character.portrait {
        case .procedural(.orb):
            OrbCharacterView(
                expression: expression,
                palette: character.palette,
                size: size,
                animating: animating
            )
        case .asset(let prefix):
            assetOrPlaceholder(prefix: prefix)
        case .files(let directory):
            fileOrPlaceholder(directory: directory)
        }
    }

    // MARK: - Asset (built-in cats + dog)

    @ViewBuilder
    private func assetOrPlaceholder(prefix: String) -> some View {
        let name = "\(prefix)_\(expression.rawValue)"
        if NSImage(named: NSImage.Name(name)) != nil {
            // Built-in cats are transparent free-form art — render as-is.
            portraitImage(Image(name), circular: false)
        } else {
            // Built-in whose art hasn't shipped yet (the dog) — friendly stand-in.
            CharacterPlaceholderView(
                palette: character.palette,
                symbol: "pawprint.fill",
                expression: expression,
                size: size
            )
        }
    }

    // MARK: - Files (custom, offline)

    @ViewBuilder
    private func fileOrPlaceholder(directory: String) -> some View {
        if let image = Self.loadCustomImage(directory: directory, expression: expression) {
            // Custom photos are opaque squares — clip to a circle so they sit
            // like a bead in the floating companion, matching the orb/cats.
            portraitImage(Image(nsImage: image), circular: true)
        } else {
            CharacterPlaceholderView(
                palette: character.palette,
                symbol: "person.fill",
                expression: expression,
                size: size
            )
        }
    }

    /// Resolve a custom character's pose, falling back to its `neutral` image
    /// when a specific expression hasn't been provided.
    static func loadCustomImage(directory: String, expression: ACCatExpression) -> NSImage? {
        let dir = URL(fileURLWithPath: directory, isDirectory: true)
        let candidates = [expression.rawValue, ACCatExpression.neutral.rawValue]
        for name in candidates {
            let url = dir.appendingPathComponent("\(name).png")
            if let image = NSImage(contentsOf: url) { return image }
        }
        return nil
    }

    @ViewBuilder
    private func portraitImage(_ image: Image, circular: Bool) -> some View {
        let base = image
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: circular ? .fill : .fit)
            .frame(width: size, height: size)
            .clipShape(circular ? AnyShape(Circle()) : AnyShape(Rectangle()))
            // Circular photos match the transparent cats' visual mass via inset.
            .scaleEffect(circular ? 0.86 : 1.0)
        // Keep the portrait at true rest by default. Continuous idle animation
        // was a measurable steady-state CPU cost even when AC was otherwise
        // inactive.
        if character.animationsEnabled {
            // Opt-in mood FX for single-image characters: discrete transforms
            // keyed to the expression (they animate on mood *changes*, not in a
            // forever-loop), plus floating z's when asleep.
            base
                .scaleEffect(expressionScale)
                .brightness(expression == .sleep ? -0.06 : 0)
                .saturation(expression == .concerned ? 0.55 : 1.0)
                .rotationEffect(.degrees(expression == .concerned ? -3 : 0))
                .overlay(alignment: .topTrailing) {
                    if expression == .sleep {
                        Text("z")
                            .font(.system(size: size * 0.22, weight: .bold, design: .rounded))
                            .foregroundStyle(character.accentColor.opacity(0.7))
                            .offset(x: -size * 0.04, y: size * 0.02)
                    }
                }
                .animation(.acSnap, value: expression)
        } else {
            base
        }
    }

    /// Subtle expression-driven scale for the opt-in animation tier.
    private var expressionScale: CGFloat {
        switch expression {
        case .happy: return 1.05
        case .sleep: return 0.97
        default: return 1.0
        }
    }
}

// MARK: - Placeholder portrait

/// A tasteful stand-in used when a character has no bitmap for the requested
/// pose (a built-in awaiting art, or a custom character missing a file). Uses
/// the character's palette so it still feels on-brand.
private struct CharacterPlaceholderView: View {
    let palette: CharacterPalette
    let symbol: String
    let expression: ACCatExpression
    var size: CGFloat = 72

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [palette.orbTop, palette.orbBottom],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .overlay(Circle().stroke(palette.accent.opacity(0.25), lineWidth: max(1, size * 0.02)))
            Image(systemName: expression == .sleep ? "moon.zzz.fill" : symbol)
                .font(.system(size: size * 0.42, weight: .medium))
                .foregroundStyle(palette.accent)
                .opacity(expression == .concerned ? 0.7 : 0.9)
        }
        .frame(width: size, height: size)
        // Match the transparent cats' visual mass (they have built-in margin).
        .scaleEffect(0.86)
    }
}

// MARK: - Menu bar icon helper

extension CatView {
    /// Produce a flat template image for the menu bar. Photographic portraits
    /// render as a tinted silhouette; procedural / not-yet-arted characters fall
    /// back to a clean SF Symbol so the menu bar always shows something sharp.
    @MainActor
    static func menuBarTemplateImage(
        size: CGFloat = 18,
        character: ACCharacter = .mochi,
        expression: ACCatExpression = .neutral
    ) -> NSImage {
        if case .asset(let prefix) = character.portrait,
            NSImage(named: NSImage.Name("\(prefix)_\(expression.rawValue)")) != nil
        {
            let content = Image("\(prefix)_\(expression.rawValue)")
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
                .colorMultiply(.black) // collapse to silhouette for template rendering
            let renderer = ImageRenderer(content: content)
            renderer.scale = 2.0
            if let image = renderer.nsImage {
                image.isTemplate = true
                return image
            }
        }

        // Procedural / placeholder fallback: a crisp template symbol.
        let symbolName: String
        switch character.portrait {
        case .procedural(.orb): symbolName = "circle.fill"
        case .files: symbolName = "person.fill"
        case .asset: symbolName = "pawprint.fill"
        }
        let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: "AC")
            ?? NSImage(systemSymbolName: "pawprint.fill", accessibilityDescription: "AC")!
        symbol.isTemplate = true
        return symbol
    }
}

//
//  CatView.swift
//  AC
//
//  Dispatches to the correct skin renderer. Reads the user's accent color
//  from the environment so all three skins respond to character / custom
//  accent changes in a single place.
//

import SwiftUI

struct CatView: View {
    let character: ACCharacter
    let skin: ACSkin
    let expression: ACCatExpression
    var size: CGFloat = 72
    var animating: Bool = true
    /// Optional explicit override; nil = use environment accent (or character's).
    var accentOverride: Color? = nil

    @Environment(\.acAccent) private var envAccent

    var body: some View {
        let accent = accentOverride ?? envAccent
        Canvas { ctx, canvasSize in
            let renderer: CatRenderer = {
                switch skin {
                case .mono:   return CatRendererMono()
                case .bubble: return CatRendererBubble()
                case .plush:  return CatRendererPlush()
                }
            }()
            renderer.render(in: ctx, size: canvasSize, character: character, expression: expression, accent: accent)
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Menu bar icon helper

extension CatView {
    @MainActor
    static func menuBarTemplateImage(
        size: CGFloat = 18,
        character: ACCharacter = .mochi,
        skin: ACSkin = .bubble,
        expression: ACCatExpression = .neutral
    ) -> NSImage {
        let content = CatView(
            character: character,
            skin: skin,
            expression: expression,
            size: size,
            animating: false,
            accentOverride: skin.defaultAccentColor
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

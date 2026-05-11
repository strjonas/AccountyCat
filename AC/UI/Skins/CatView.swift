//
//  CatView.swift
//  AC
//
//  Dispatches to the correct skin renderer and caches the resulting CGImage
//  for performance.
//

import SwiftUI

struct CatView: View {
    let character: ACCharacter
    let skin: ACSkin
    let expression: ACCatExpression
    var size: CGFloat = 72
    var animating: Bool = true

    /// Cache keyed by (character, skin, expression, size bucket)
    @State private var cachedImage: CGImage?

    private var cacheKey: String {
        "\(character.rawValue)-\(skin.rawValue)-\(expression.rawValue)-\(Int(size))"
    }

    var body: some View {
        Canvas { ctx, canvasSize in
            let renderer: CatRenderer = {
                switch skin {
                case .mono:   return CatRendererMono()
                case .bubble: return CatRendererBubble()
                case .plush:  return CatRendererPlush()
                }
            }()
            renderer.render(in: ctx, size: canvasSize, character: character, expression: expression)
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

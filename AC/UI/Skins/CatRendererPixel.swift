//
//  CatRendererPixel.swift
//  AC
//
//  Pixel skin: explicit 16x16 handoff-style sprite. Character still controls
//  palette, but the shape remains the same across characters.
//

import SwiftUI

struct CatRendererPixel: CatRenderer {
    func render(
        in context: GraphicsContext,
        size: CGSize,
        character: ACCharacter,
        expression: ACCatExpression
    ) {
        let cell = min(size.width, size.height) / 16
        let ox = (size.width - cell * 16) / 2
        let oy = (size.height - cell * 16) / 2
        let p = PixelPalette(character)

        func draw(_ x: Int, _ y: Int, _ w: Int = 1, _ h: Int = 1, _ color: Color) {
            let rect = CGRect(
                x: ox + CGFloat(x) * cell,
                y: oy + CGFloat(y) * cell,
                width: CGFloat(w) * cell,
                height: CGFloat(h) * cell
            )
            context.fill(Path(rect), with: .color(color))
        }

        // Ears.
        draw(3, 2, 1, 2, p.body)
        draw(4, 1, 1, 2, p.body)
        draw(4, 3, 1, 1, p.accent)
        draw(11, 1, 1, 2, p.body)
        draw(12, 2, 1, 2, p.body)
        draw(11, 3, 1, 1, p.accent)

        // Head and lower shade.
        draw(3, 4, 10, 8, p.body)
        draw(3, 11, 10, 1, p.shadow)

        // Eyes.
        switch expression {
        case .sleep, .happy:
            draw(5, 7, 2, 1, p.eye)
            draw(9, 7, 2, 1, p.eye)
        case .celebrate:
            draw(5, 6, 1, 1, p.eye)
            draw(4, 7, 3, 1, p.eye)
            draw(5, 8, 1, 1, p.eye)
            draw(10, 6, 1, 1, p.eye)
            draw(9, 7, 3, 1, p.eye)
            draw(10, 8, 1, 1, p.eye)
        case .drift:
            draw(6, 6, 1, 2, p.eye)
            draw(11, 6, 1, 2, p.eye)
        case .alert:
            draw(5, 6, 1, 2, p.eye)
            draw(10, 6, 1, 2, p.eye)
            draw(5, 5, 1, 1, p.eye)
            draw(10, 5, 1, 1, p.eye)
        default:
            draw(5, 6, 1, 2, p.eye)
            draw(10, 6, 1, 2, p.eye)
        }

        // Nose.
        draw(7, 8, 2, 1, p.nose)

        // Mouth.
        switch expression {
        case .happy, .celebrate:
            draw(6, 9, 1, 1, p.nose)
            draw(7, 10, 2, 1, p.nose)
            draw(9, 9, 1, 1, p.nose)
        case .concern:
            draw(6, 10, 1, 1, p.nose)
            draw(7, 9, 2, 1, p.nose)
            draw(9, 10, 1, 1, p.nose)
        case .drift:
            draw(6, 9, 4, 1, p.nose)
        default:
            draw(7, 9, 2, 1, p.nose)
        }

        if expression == .celebrate {
            draw(13, 4, 1, 1, p.accent)
            draw(2, 5, 1, 1, p.accent)
        }

        if expression == .sleep {
            let text = Text("z").font(.system(size: cell * 1.9, weight: .bold, design: .monospaced))
                .foregroundStyle(p.shadow.opacity(0.74))
            context.draw(text, at: CGPoint(x: ox + cell * 13.5, y: oy + cell * 2.0))
        }
    }
}

private struct PixelPalette {
    let body: Color
    let shadow: Color
    let accent: Color
    let nose: Color
    let eye: Color

    init(_ character: ACCharacter) {
        switch character {
        case .mochi:
            body = Color(hex: 0xF4D9B8)
            shadow = Color(hex: 0xD9B188)
            accent = Color(hex: 0xE89B7A)
            nose = Color(hex: 0xC77A5A)
            eye = Color(hex: 0x2A1B12)
        case .nova:
            body = Color(hex: 0x7A6FA0)
            shadow = Color(hex: 0x574E78)
            accent = Color(hex: 0xC7B6FF)
            nose = Color(hex: 0x3A3252)
            eye = Color(hex: 0xF4FF8B)
        case .sage:
            body = Color(hex: 0xA8B58E)
            shadow = Color(hex: 0x7E8C68)
            accent = Color(hex: 0xD9C48E)
            nose = Color(hex: 0x5A5238)
            eye = Color(hex: 0x2A2418)
        }
    }
}

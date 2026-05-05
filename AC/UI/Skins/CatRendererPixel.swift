//
//  CatRendererPixel.swift
//  AC
//
//  Pixel skin: 24×24 sprite. Higher grid resolution than the original 16×16,
//  with proper outline, body shading, ear pink, and eye highlight — keeps the
//  retro feel while reading sharply at orb (72px) and avatar sizes.
//

import SwiftUI

struct CatRendererPixel: CatRenderer {
    func render(
        in context: GraphicsContext,
        size: CGSize,
        character: ACCharacter,
        expression: ACCatExpression
    ) {
        let grid: CGFloat = 24
        let cell = min(size.width, size.height) / grid
        let ox = (size.width - cell * grid) / 2
        let oy = (size.height - cell * grid) / 2
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

        // ── Ears (outline + body + inner pink) ──
        // Left
        draw(4, 4, 1, 1, p.outline)
        draw(4, 5, 1, 3, p.body)
        draw(5, 3, 1, 1, p.outline)
        draw(5, 4, 1, 4, p.body)
        draw(6, 4, 1, 4, p.body)
        draw(6, 4, 1, 1, p.accent)   // inner pink top
        draw(6, 5, 1, 1, p.accent)
        draw(7, 5, 1, 1, p.body)

        // Right
        draw(19, 4, 1, 1, p.outline)
        draw(19, 5, 1, 3, p.body)
        draw(18, 3, 1, 1, p.outline)
        draw(18, 4, 1, 4, p.body)
        draw(17, 4, 1, 4, p.body)
        draw(17, 4, 1, 1, p.accent)
        draw(17, 5, 1, 1, p.accent)
        draw(16, 5, 1, 1, p.body)

        // ── Head outline (cell-walking the silhouette so corners read crisp) ──
        // Top edge of head between the ears
        draw(7, 6, 10, 1, p.outline)
        // Side edges
        draw(6, 7, 1, 10, p.outline)
        draw(17, 7, 1, 10, p.outline)
        // Bottom edge — gently rounded with notched corners
        draw(7, 17, 1, 1, p.outline)
        draw(8, 18, 8, 1, p.outline)
        draw(16, 17, 1, 1, p.outline)

        // ── Head body fill ──
        draw(7, 7, 10, 10, p.body)
        // Bottom-row body inset (matches the rounded corners above)
        draw(8, 17, 8, 1, p.body)

        // ── Body shading: 1px inner rim on the bottom + side darken ──
        draw(7, 16, 10, 1, p.shadow)
        draw(7, 7, 1, 9, p.shadow)
        draw(16, 7, 1, 9, p.shadow)
        // Restore body fill where cheek highlights belong
        draw(8, 8, 8, 7, p.body)

        // ── Soft cheek highlight (lighter strip below eyes) ──
        draw(8, 13, 8, 1, p.highlight)

        // ── Eyes ──
        switch expression {
        case .sleep, .happy:
            // Closed-eye smile arcs (each 3 cells wide, dipping down by 1)
            draw(8, 11, 1, 1, p.eye)
            draw(9, 12, 2, 1, p.eye)
            draw(10, 11, 1, 1, p.eye)
            draw(13, 11, 1, 1, p.eye)
            draw(14, 12, 2, 1, p.eye)
            draw(15, 11, 1, 1, p.eye)
        case .celebrate:
            // Sparkle eyes (plus shape)
            draw(9, 10, 1, 1, p.eye)
            draw(8, 11, 3, 1, p.eye)
            draw(9, 12, 1, 1, p.eye)
            draw(14, 10, 1, 1, p.eye)
            draw(13, 11, 3, 1, p.eye)
            draw(14, 12, 1, 1, p.eye)
        case .drift:
            // Eyes shifted slightly to one side (bored / distracted)
            draw(10, 10, 1, 2, p.eye)
            draw(15, 10, 1, 2, p.eye)
        case .concern:
            // Worried — eyes higher with a small "brow" pixel above
            draw(8, 9, 1, 1, p.shadow)
            draw(15, 9, 1, 1, p.shadow)
            draw(9, 10, 1, 2, p.eye)
            draw(14, 10, 1, 2, p.eye)
            draw(9, 10, 1, 1, p.eyeHighlight)
            draw(14, 10, 1, 1, p.eyeHighlight)
        case .alert:
            // Wider, more intense eyes — but not surprised
            draw(9, 10, 1, 2, p.eye)
            draw(14, 10, 1, 2, p.eye)
            draw(9, 10, 1, 1, p.eyeHighlight)
            draw(14, 10, 1, 1, p.eyeHighlight)
        default: // .neutral
            // Tall ovals with a single highlight — friendly, calm, "buddy".
            draw(9, 10, 1, 3, p.eye)
            draw(14, 10, 1, 3, p.eye)
            draw(9, 10, 1, 1, p.eyeHighlight)
            draw(14, 10, 1, 1, p.eyeHighlight)
        }

        // ── Nose ──
        draw(11, 13, 2, 1, p.nose)

        // ── Mouth ──
        switch expression {
        case .happy, .celebrate:
            // Wide smile
            draw(10, 14, 1, 1, p.nose)
            draw(11, 15, 2, 1, p.nose)
            draw(13, 14, 1, 1, p.nose)
        case .concern:
            // Inverted curve
            draw(10, 15, 1, 1, p.nose)
            draw(11, 14, 2, 1, p.nose)
            draw(13, 15, 1, 1, p.nose)
        case .drift:
            // Flat line
            draw(10, 15, 4, 1, p.nose)
        default: // neutral / alert / sleep
            // Gentle smile — slightly wider than a single pixel, reads as friendly
            draw(10, 14, 1, 1, p.nose)
            draw(11, 15, 2, 1, p.nose)
            draw(13, 14, 1, 1, p.nose)
        }

        // ── Whiskers (faint, single-cell ticks) ──
        draw(5, 13, 1, 1, p.shadow.opacity(0.55))
        draw(18, 13, 1, 1, p.shadow.opacity(0.55))
        draw(5, 15, 1, 1, p.shadow.opacity(0.40))
        draw(18, 15, 1, 1, p.shadow.opacity(0.40))

        // ── Cheek blush (small accent dots, only on positive expressions) ──
        if expression == .neutral || expression == .happy || expression == .celebrate || expression == .alert {
            draw(7, 14, 1, 1, p.accent.opacity(0.60))
            draw(16, 14, 1, 1, p.accent.opacity(0.60))
        }

        // ── Decorations ──
        if expression == .celebrate {
            draw(20, 6, 1, 1, p.accent)
            draw(3, 7, 1, 1, p.accent)
            draw(21, 9, 1, 1, p.accent.opacity(0.6))
        }
        if expression == .sleep {
            let text = Text("z").font(.system(size: cell * 2.8, weight: .bold, design: .monospaced))
                .foregroundStyle(p.shadow.opacity(0.74))
            context.draw(text, at: CGPoint(x: ox + cell * 20.5, y: oy + cell * 4.5))
        }
    }
}

private struct PixelPalette {
    let body: Color
    let shadow: Color
    let highlight: Color
    let outline: Color
    let accent: Color
    let nose: Color
    let eye: Color
    let eyeHighlight: Color

    init(_ character: ACCharacter) {
        switch character {
        case .mochi:
            body = Color(hex: 0xF4D9B8)
            shadow = Color(hex: 0xD9B188)
            highlight = Color(hex: 0xFCEDD8)
            outline = Color(hex: 0xA17855)
            accent = Color(hex: 0xE89B7A)
            nose = Color(hex: 0xC77A5A)
            eye = Color(hex: 0x2A1B12)
            eyeHighlight = Color.white.opacity(0.95)
        case .nova:
            body = Color(hex: 0x9A8FC8)
            shadow = Color(hex: 0x6E5F94)
            highlight = Color(hex: 0xC0B5E5)
            outline = Color(hex: 0x453963)
            accent = Color(hex: 0xC7B6FF)
            nose = Color(hex: 0x3A3252)
            eye = Color(hex: 0x1B142E)
            eyeHighlight = Color(hex: 0xF4FF8B)
        case .sage:
            body = Color(hex: 0xB8C49E)
            shadow = Color(hex: 0x86936D)
            highlight = Color(hex: 0xD7DFC0)
            outline = Color(hex: 0x4F5A3C)
            accent = Color(hex: 0xD9C48E)
            nose = Color(hex: 0x5A5238)
            eye = Color(hex: 0x1F1B12)
            eyeHighlight = Color.white.opacity(0.95)
        }
    }
}

//
//  CatRendererBubble.swift
//  AC
//
//  Bubble skin: a warm, refined soft cat — the daily-driver slot. Sits
//  between Mono's minimalism and Plush's expressiveness. Uses a subtle
//  vertical body gradient for depth (read as "soft paper", not gloss),
//  delicate strokes, and small features so it never tips into sticker-pack
//  territory.
//

import SwiftUI

struct CatRendererBubble: CatRenderer {
    func render(
        in context: GraphicsContext,
        size: CGSize,
        character: ACCharacter,
        expression: ACCatExpression
    ) {
        let s = min(size.width, size.height) / 64
        let ox = size.width / 2 - 32 * s
        let oy = size.height / 2 - 32 * s
        let p = CatPalette(character)

        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: ox + x * s, y: oy + y * s)
        }
        func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
            CGRect(x: ox + x * s, y: oy + y * s, width: w * s, height: h * s)
        }

        let stroke = StrokeStyle(lineWidth: 0.9 * s, lineCap: .round, lineJoin: .round)
        let thin = StrokeStyle(lineWidth: 1.2 * s, lineCap: .round, lineJoin: .round)

        // Soft contact shadow.
        context.fill(Path(ellipseIn: rect(20, 52.6, 24, 3.4)), with: .color(p.shadow.opacity(0.24)))

        // ─── Ears (delicate stroke, softer triangles) ───
        let leftEar = softEar(points: [pt(14.5, 22), pt(22, 9), pt(26, 22)])
        let rightEar = softEar(points: [pt(49.5, 22), pt(42, 9), pt(38, 22)])
        context.fill(leftEar, with: .linearGradient(
            Gradient(colors: [p.bodyTop, p.bodyBottom]),
            startPoint: pt(22, 9),
            endPoint: pt(22, 22)
        ))
        context.fill(rightEar, with: .linearGradient(
            Gradient(colors: [p.bodyTop, p.bodyBottom]),
            startPoint: pt(42, 9),
            endPoint: pt(42, 22)
        ))
        context.stroke(leftEar, with: .color(p.outline), style: stroke)
        context.stroke(rightEar, with: .color(p.outline), style: stroke)

        // Inner ear — small, low-contrast triangles. Whisper, don't shout.
        context.fill(softEar(points: [pt(18.5, 18), pt(21, 13), pt(23, 19)]), with: .color(p.innerEar))
        context.fill(softEar(points: [pt(45.5, 18), pt(43, 13), pt(41, 19)]), with: .color(p.innerEar))

        // ─── Head silhouette ───
        var head = Path()
        head.move(to: pt(12, 34))
        head.addQuadCurve(to: pt(32, 18), control: pt(12, 18))
        head.addQuadCurve(to: pt(52, 34), control: pt(52, 18))
        head.addQuadCurve(to: pt(32, 50), control: pt(52, 50))
        head.addQuadCurve(to: pt(12, 34), control: pt(12, 50))
        head.closeSubpath()

        // Subtle vertical gradient — depth without gloss. Read as "soft paper".
        context.fill(head, with: .linearGradient(
            Gradient(colors: [p.bodyTop, p.bodyBottom]),
            startPoint: pt(32, 18),
            endPoint: pt(32, 50)
        ))
        context.stroke(head, with: .color(p.outline), style: stroke)

        // Very faint top catch-light — adds a hint of dimension, kept minimal.
        context.fill(Path(ellipseIn: rect(18, 22, 14, 3.2)), with: .color(.white.opacity(0.24)))

        drawEyes(context, pt: pt, rect: rect, scale: s, palette: p, expression: expression)

        if expression == .happy || expression == .celebrate || expression == .neutral || expression == .alert {
            // Refined cheek blush — smaller, more transparent, lower on the face.
            context.fill(Path(ellipseIn: rect(18, 38, 4.0, 2.2)), with: .color(p.accent.opacity(0.42)))
            context.fill(Path(ellipseIn: rect(42, 38, 4.0, 2.2)), with: .color(p.accent.opacity(0.42)))
        }

        // Nose — small filled triangle, slightly tighter than before.
        var nose = Path()
        nose.move(to: pt(30.6, 38))
        nose.addLine(to: pt(33.4, 38))
        nose.addLine(to: pt(32, 40.0))
        nose.closeSubpath()
        context.fill(nose, with: .color(p.nose))

        drawMouth(context, pt: pt, scale: s, palette: p, expression: expression)

        if expression == .celebrate {
            drawSpark(context, center: pt(8, 13), scale: s * 0.95, color: p.accent)
            drawSpark(context, center: pt(56, 12), scale: s * 0.65, color: p.accent.opacity(0.85))
        }
        if expression == .sleep {
            drawCrescent(context, center: pt(54, 12), scale: s, color: p.shadow.opacity(0.62))
        }
    }
}

private extension CatRendererBubble {
    struct CatPalette {
        let bodyTop: Color       // top of the head gradient (lighter)
        let bodyBottom: Color    // bottom (slightly warmer / more saturated)
        let outline: Color
        let shadow: Color
        let accent: Color
        let innerEar: Color
        let nose: Color
        let eye: Color

        init(_ character: ACCharacter) {
            switch character {
            case .mochi:
                bodyTop = Color(hex: 0xF8E3C4)
                bodyBottom = Color(hex: 0xECCB9B)
                outline = Color(hex: 0xB8916A)   // softer than the old shadow stroke
                shadow = Color(hex: 0xD9B188)
                accent = Color(hex: 0xE89B7A)
                innerEar = Color(hex: 0xE6B099)
                nose = Color(hex: 0xC07959)
                eye = Color(hex: 0x2A1B12)
            case .nova:
                bodyTop = Color(hex: 0x8A7FB0)
                bodyBottom = Color(hex: 0x6C6394)
                outline = Color(hex: 0x4B4366)
                shadow = Color(hex: 0x574E78)
                accent = Color(hex: 0xC7B6FF)
                innerEar = Color(hex: 0xA294C0)
                nose = Color(hex: 0x352E4A)
                eye = Color(hex: 0xF4FF8B)
            case .sage:
                bodyTop = Color(hex: 0xB4C198)
                bodyBottom = Color(hex: 0x96A479)
                outline = Color(hex: 0x6F7C5C)
                shadow = Color(hex: 0x7E8C68)
                accent = Color(hex: 0xD9C48E)
                innerEar = Color(hex: 0xBEC598)
                nose = Color(hex: 0x534B31)
                eye = Color(hex: 0x2A2418)
            }
        }
    }

    func softEar(points: [CGPoint]) -> Path {
        var path = Path()
        guard points.count == 3 else { return path }
        path.move(to: points[0])
        path.addQuadCurve(to: points[1], control: midpoint(points[0], points[1]))
        path.addQuadCurve(to: points[2], control: midpoint(points[1], points[2]))
        path.addQuadCurve(to: points[0], control: midpoint(points[2], points[0]))
        path.closeSubpath()
        return path
    }

    func drawEyes(
        _ context: GraphicsContext,
        pt: (CGFloat, CGFloat) -> CGPoint,
        rect: (CGFloat, CGFloat, CGFloat, CGFloat) -> CGRect,
        scale s: CGFloat,
        palette p: CatPalette,
        expression: ACCatExpression
    ) {
        if expression == .sleep || expression == .happy {
            // Smaller, more delicate closed-arc eyes.
            var left = Path()
            left.move(to: pt(23, 32.6))
            left.addQuadCurve(to: pt(28, 32.6), control: pt(25.5, 35.6))
            var right = Path()
            right.move(to: pt(36, 32.6))
            right.addQuadCurve(to: pt(41, 32.6), control: pt(38.5, 35.6))
            let style = StrokeStyle(lineWidth: 1.5 * s, lineCap: .round)
            context.stroke(left, with: .color(p.eye), style: style)
            context.stroke(right, with: .color(p.eye), style: style)
            return
        }

        if expression == .celebrate {
            drawSpark(context, center: pt(25.5, 33), scale: s * 1.05, color: p.eye)
            drawSpark(context, center: pt(38.5, 33), scale: s * 1.05, color: p.eye)
            return
        }

        // Refined open eyes — ~12% smaller than before, with a tighter catch-light.
        let y: CGFloat = expression == .concern ? 31.8 : 33
        let offset: CGFloat = expression == .drift ? 1.2 : 0
        let w: CGFloat = 4.2
        context.fill(Path(ellipseIn: rect(23.8 + offset, y - 2.1, w, w)), with: .color(p.eye))
        context.fill(Path(ellipseIn: rect(36.0 + offset, y - 2.1, w, w)), with: .color(p.eye))
        // Single tight catch-light — modest sheen.
        context.fill(Path(ellipseIn: rect(25.2 + offset, y - 1.5, 1.4, 1.4)), with: .color(p.bodyTop))
        context.fill(Path(ellipseIn: rect(37.4 + offset, y - 1.5, 1.4, 1.4)), with: .color(p.bodyTop))

        if expression == .concern {
            var browL = Path()
            browL.move(to: pt(22, 28))
            browL.addQuadCurve(to: pt(29, 29), control: pt(25.5, 24.5))
            var browR = Path()
            browR.move(to: pt(42, 28))
            browR.addQuadCurve(to: pt(35, 29), control: pt(38.5, 24.5))
            let style = StrokeStyle(lineWidth: 1.05 * s, lineCap: .round)
            context.stroke(browL, with: .color(p.eye), style: style)
            context.stroke(browR, with: .color(p.eye), style: style)
        }
    }

    func drawMouth(
        _ context: GraphicsContext,
        pt: (CGFloat, CGFloat) -> CGPoint,
        scale s: CGFloat,
        palette p: CatPalette,
        expression: ACCatExpression
    ) {
        var mouth = Path()
        switch expression {
        case .happy, .celebrate:
            mouth.move(to: pt(27, 42))
            mouth.addQuadCurve(to: pt(37, 42), control: pt(32, 46.6))
        case .concern:
            mouth.move(to: pt(29.5, 43))
            mouth.addQuadCurve(to: pt(34.5, 43), control: pt(32, 41.5))
        case .drift:
            mouth.move(to: pt(29, 43))
            mouth.addLine(to: pt(35, 43))
        default:
            // Delicate "ω" — gentler than before so it doesn't dominate the face.
            mouth.move(to: pt(29, 42))
            mouth.addQuadCurve(to: pt(35, 42), control: pt(32, 44.2))
        }
        let style = StrokeStyle(lineWidth: 1.15 * s, lineCap: .round)
        context.stroke(mouth, with: .color(p.nose), style: style)
    }

    func drawSpark(_ context: GraphicsContext, center: CGPoint, scale s: CGFloat, color: Color) {
        var path = Path()
        path.move(to: CGPoint(x: center.x, y: center.y - 4 * s))
        path.addLine(to: CGPoint(x: center.x + 1.2 * s, y: center.y - 1.1 * s))
        path.addLine(to: CGPoint(x: center.x + 4 * s, y: center.y))
        path.addLine(to: CGPoint(x: center.x + 1.2 * s, y: center.y + 1.1 * s))
        path.addLine(to: CGPoint(x: center.x, y: center.y + 4 * s))
        path.addLine(to: CGPoint(x: center.x - 1.2 * s, y: center.y + 1.1 * s))
        path.addLine(to: CGPoint(x: center.x - 4 * s, y: center.y))
        path.addLine(to: CGPoint(x: center.x - 1.2 * s, y: center.y - 1.1 * s))
        path.closeSubpath()
        context.fill(path, with: .color(color))
    }

    func drawCrescent(_ context: GraphicsContext, center: CGPoint, scale s: CGFloat, color: Color) {
        let r = 3.0 * s
        let outer = Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2))
        let inner = Path(ellipseIn: CGRect(x: center.x - r + 1.4 * s, y: center.y - r - 0.4 * s, width: r * 2, height: r * 2))
        var crescent = outer
        crescent.addPath(inner)
        context.fill(crescent, with: .color(color), style: FillStyle(eoFill: true))
    }

    func midpoint(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
        CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
    }
}

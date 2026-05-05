//
//  CatRendererBubble.swift
//  AC
//
//  Bubble skin: handoff-style soft sticker cat, not an abstract orb.
//

import SwiftUI

struct CatRendererBubble: CatRenderer {
    func render(
        in context: GraphicsContext,
        size: CGSize,
        character: ACCharacter,
        expression: ACCatExpression
    ) {
        let box = CGRect(origin: .zero, size: size)
        let s = min(size.width, size.height) / 64
        let ox = box.midX - 32 * s
        let oy = box.midY - 32 * s
        let p = CatPalette(character)

        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: ox + x * s, y: oy + y * s)
        }
        func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
            CGRect(x: ox + x * s, y: oy + y * s, width: w * s, height: h * s)
        }

        context.fill(Path(ellipseIn: rect(18, 52, 28, 4.4)), with: .color(p.shadow.opacity(0.34)))

        let leftEar = softEar(points: [pt(14, 22), pt(22, 8), pt(26, 22)])
        let rightEar = softEar(points: [pt(50, 22), pt(42, 8), pt(38, 22)])
        context.fill(leftEar, with: .color(p.body))
        context.fill(rightEar, with: .color(p.body))
        context.stroke(leftEar, with: .color(p.shadow), lineWidth: 1.2 * s)
        context.stroke(rightEar, with: .color(p.shadow), lineWidth: 1.2 * s)

        context.fill(softEar(points: [pt(18, 18), pt(21, 12), pt(23, 19)]), with: .color(p.accent))
        context.fill(softEar(points: [pt(46, 18), pt(43, 12), pt(41, 19)]), with: .color(p.accent))

        var head = Path()
        head.move(to: pt(12, 34))
        head.addQuadCurve(to: pt(32, 18), control: pt(12, 18))
        head.addQuadCurve(to: pt(52, 34), control: pt(52, 18))
        head.addQuadCurve(to: pt(32, 50), control: pt(52, 50))
        head.addQuadCurve(to: pt(12, 34), control: pt(12, 50))
        head.closeSubpath()
        context.fill(head, with: .color(p.body))
        context.stroke(head, with: .color(p.shadow), lineWidth: 1.2 * s)

        context.fill(Path(ellipseIn: rect(18, 36, 28, 12)), with: .color(p.inner.opacity(0.62)))
        context.fill(Path(ellipseIn: rect(17, 24, 10, 4)), with: .color(Color.white.opacity(0.46)))

        drawEyes(context, pt: pt, rect: rect, scale: s, palette: p, expression: expression)

        if expression == .happy || expression == .celebrate || expression == .neutral || expression == .alert {
            // Cheek blush — slightly larger and warmer than the previous pass
            // so the cat reads as expressive even at small sizes.
            context.fill(Path(ellipseIn: rect(16.8, 36.4, 6.0, 3.2)), with: .color(p.accent.opacity(0.78)))
            context.fill(Path(ellipseIn: rect(41.2, 36.4, 6.0, 3.2)), with: .color(p.accent.opacity(0.78)))
        }

        var nose = Path()
        nose.move(to: pt(30, 38))
        nose.addLine(to: pt(34, 38))
        nose.addLine(to: pt(32, 41))
        nose.closeSubpath()
        context.fill(nose, with: .color(p.nose))

        drawMouth(context, pt: pt, scale: s, palette: p, expression: expression)

        if expression == .celebrate {
            drawSpark(context, center: pt(8, 15), scale: s, color: p.accent)
            drawSpark(context, center: pt(56, 14), scale: s * 0.72, color: p.accent)
        }
        if expression == .sleep {
            let text = Text("z").font(.system(size: 9 * s, weight: .bold, design: .monospaced))
                .foregroundStyle(p.shadow.opacity(0.74))
            context.draw(text, at: pt(53, 10))
        }
    }
}

private extension CatRendererBubble {
    struct CatPalette {
        let body: Color
        let inner: Color
        let shadow: Color
        let accent: Color
        let nose: Color
        let eye: Color

        init(_ character: ACCharacter) {
            switch character {
            case .mochi:
                body = Color(hex: 0xF4D9B8)
                inner = Color(hex: 0xFCEDD8)
                shadow = Color(hex: 0xD9B188)
                accent = Color(hex: 0xE89B7A)
                nose = Color(hex: 0xC77A5A)
                eye = Color(hex: 0x2A1B12)
            case .nova:
                body = Color(hex: 0x7A6FA0)
                inner = Color(hex: 0xA99CD0)
                shadow = Color(hex: 0x574E78)
                accent = Color(hex: 0xC7B6FF)
                nose = Color(hex: 0x3A3252)
                eye = Color(hex: 0xF4FF8B)
            case .sage:
                body = Color(hex: 0xA8B58E)
                inner = Color(hex: 0xCFD8B6)
                shadow = Color(hex: 0x7E8C68)
                accent = Color(hex: 0xD9C48E)
                nose = Color(hex: 0x5A5238)
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
            var left = Path()
            left.move(to: pt(23, 32))
            left.addQuadCurve(to: pt(29, 32), control: pt(26, 36))
            var right = Path()
            right.move(to: pt(35, 32))
            right.addQuadCurve(to: pt(41, 32), control: pt(38, 36))
            context.stroke(left, with: .color(p.eye), lineWidth: 2 * s)
            context.stroke(right, with: .color(p.eye), lineWidth: 2 * s)
            return
        }

        if expression == .celebrate {
            drawSpark(context, center: pt(26, 33), scale: s * 1.15, color: p.eye)
            drawSpark(context, center: pt(38, 33), scale: s * 1.15, color: p.eye)
            return
        }

        let y: CGFloat = expression == .concern ? 31.5 : 33
        let offset: CGFloat = expression == .drift ? 1.4 : 0
        // Slightly smaller, rounder eyes — looks like a friendly buddy, not surprised.
        context.fill(Path(ellipseIn: rect(23.6 + offset, y - 2.4, 4.8, 4.8)), with: .color(p.eye))
        context.fill(Path(ellipseIn: rect(35.6 + offset, y - 2.4, 4.8, 4.8)), with: .color(p.eye))
        // Single soft catch-light per eye — adds life without making the cat look wide-eyed.
        context.fill(Path(ellipseIn: rect(25.6 + offset, y - 1.6, 1.8, 1.8)), with: .color(Color.white.opacity(0.92)))
        context.fill(Path(ellipseIn: rect(37.6 + offset, y - 1.6, 1.8, 1.8)), with: .color(Color.white.opacity(0.92)))

        if expression == .concern {
            var browL = Path()
            browL.move(to: pt(22, 28))
            browL.addQuadCurve(to: pt(29, 29), control: pt(25.5, 24))
            var browR = Path()
            browR.move(to: pt(42, 28))
            browR.addQuadCurve(to: pt(35, 29), control: pt(38.5, 24))
            context.stroke(browL, with: .color(p.eye), lineWidth: 1.2 * s)
            context.stroke(browR, with: .color(p.eye), lineWidth: 1.2 * s)
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
            mouth.move(to: pt(26, 42))
            mouth.addQuadCurve(to: pt(38, 42), control: pt(32, 47.5))
        case .concern:
            mouth.move(to: pt(29, 43))
            mouth.addQuadCurve(to: pt(35, 43), control: pt(32, 41.5))
        case .drift:
            mouth.move(to: pt(28.5, 43))
            mouth.addLine(to: pt(35.5, 43))
        default:
            // Gentle "buddy" smile — wider and a touch curlier than the old hairline.
            mouth.move(to: pt(28.5, 42))
            mouth.addQuadCurve(to: pt(35.5, 42), control: pt(32, 45.2))
        }
        context.stroke(mouth, with: .color(p.nose), lineWidth: 1.55 * s)
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

    func midpoint(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
        CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
    }
}

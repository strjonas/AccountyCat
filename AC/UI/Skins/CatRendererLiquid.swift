//
//  CatRendererLiquid.swift
//  AC
//
//  Liquid skin: clear macOS-glass cat. Simplified silhouette with specular
//  highlights and a subtle accent tint — reads as glass on both light and
//  dark backgrounds.
//

import SwiftUI

struct CatRendererLiquid: CatRenderer {
    func render(
        in context: GraphicsContext,
        size: CGSize,
        character: ACCharacter,
        expression: ACCatExpression
    ) {
        let s = min(size.width, size.height) / 64
        let ox = size.width / 2 - 32 * s
        let oy = size.height / 2 - 32 * s
        let tint = character.accentColor
        let ink = character == .nova ? Color(hex: 0xF4FF8B) : Color.acInk1.opacity(0.78)

        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: ox + x * s, y: oy + y * s)
        }
        func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
            CGRect(x: ox + x * s, y: oy + y * s, width: w * s, height: h * s)
        }

        // Soft shadow under the cat
        context.fill(Path(ellipseIn: rect(16, 50, 32, 5)), with: .color(tint.opacity(0.10)))

        // Glass gradient — cleaner: white → clear tint → subtle shadow
        let glass = Gradient(colors: [
            Color.white.opacity(0.90),
            Color.white.opacity(0.45),
            tint.opacity(0.18),
            tint.opacity(0.08)
        ])

        // Ears (small glassy triangles)
        let leftEar = softTriangle(pt(16, 22), pt(20, 10), pt(26, 20))
        let rightEar = softTriangle(pt(48, 22), pt(44, 10), pt(38, 20))
        fillGlass(leftEar, context: context, gradient: glass, start: pt(20, 10), end: pt(20, 24), stroke: tint, scale: s)
        fillGlass(rightEar, context: context, gradient: glass, start: pt(44, 10), end: pt(44, 24), stroke: tint, scale: s)

        // Head — glassy blob, simpler shape
        var head = Path()
        head.move(to: pt(14, 32))
        head.addQuadCurve(to: pt(32, 18), control: pt(14, 18))
        head.addQuadCurve(to: pt(50, 32), control: pt(50, 18))
        head.addQuadCurve(to: pt(32, 50), control: pt(50, 50))
        head.addQuadCurve(to: pt(14, 32), control: pt(14, 50))
        head.closeSubpath()
        context.fill(head, with: .radialGradient(
            glass,
            center: pt(28, 26),
            startRadius: 4 * s,
            endRadius: 30 * s
        ))
        context.stroke(head, with: .color(Color.white.opacity(0.55)), lineWidth: 1.1 * s)
        context.stroke(head, with: .color(tint.opacity(0.18)), lineWidth: 0.6 * s)

        // Specular highlights (top-left)
        context.fill(Path(ellipseIn: rect(18, 22, 14, 5.5)), with: .color(Color.white.opacity(0.58)))
        context.fill(Path(ellipseIn: rect(40, 20, 7, 3)), with: .color(Color.white.opacity(0.38)))
        context.fill(Path(ellipseIn: rect(20, 36, 26, 8)), with: .color(Color.white.opacity(0.14)))

        drawEyes(context, pt: pt, rect: rect, scale: s, color: ink, expression: expression)

        // Tiny nose
        var nose = Path()
        nose.move(to: pt(31, 38))
        nose.addLine(to: pt(33, 38))
        nose.addLine(to: pt(32, 40))
        nose.closeSubpath()
        context.fill(nose, with: .color(tint.opacity(0.55)))

        drawMouth(context, pt: pt, scale: s, color: ink.opacity(0.62), expression: expression)

        if expression == .celebrate {
            drawSpark(context, center: pt(8, 15), scale: s, color: tint.opacity(0.86))
            drawSpark(context, center: pt(56, 14), scale: s * 0.72, color: tint.opacity(0.86))
        }
    }
}

private extension CatRendererLiquid {
    func fillGlass(
        _ path: Path,
        context: GraphicsContext,
        gradient: Gradient,
        start: CGPoint,
        end: CGPoint,
        stroke: Color,
        scale: CGFloat
    ) {
        context.fill(path, with: .linearGradient(gradient, startPoint: start, endPoint: end))
        context.stroke(path, with: .color(Color.white.opacity(0.50)), lineWidth: 0.8 * scale)
        context.stroke(path, with: .color(stroke.opacity(0.14)), lineWidth: 0.4 * scale)
    }

    func drawEyes(
        _ context: GraphicsContext,
        pt: (CGFloat, CGFloat) -> CGPoint,
        rect: (CGFloat, CGFloat, CGFloat, CGFloat) -> CGRect,
        scale s: CGFloat,
        color: Color,
        expression: ACCatExpression
    ) {
        if expression == .sleep || expression == .happy {
            var left = Path()
            left.move(to: pt(23, 31))
            left.addQuadCurve(to: pt(29, 31), control: pt(26, 34))
            var right = Path()
            right.move(to: pt(35, 31))
            right.addQuadCurve(to: pt(41, 31), control: pt(38, 34))
            context.stroke(left, with: .color(color), lineWidth: 1.6 * s)
            context.stroke(right, with: .color(color), lineWidth: 1.6 * s)
            return
        }
        if expression == .celebrate {
            drawSpark(context, center: pt(26, 32), scale: s * 1.0, color: color)
            drawSpark(context, center: pt(38, 32), scale: s * 1.0, color: color)
            return
        }
        let offset: CGFloat = expression == .drift ? 1.2 : 0
        context.fill(Path(ellipseIn: rect(23.6 + offset, 29.2, 4.8, 6.0)), with: .color(color))
        context.fill(Path(ellipseIn: rect(35.6 + offset, 29.2, 4.8, 6.0)), with: .color(color))
        context.fill(Path(ellipseIn: rect(26.4 + offset, 30.0, 1.8, 1.8)), with: .color(Color.white.opacity(0.86)))
        context.fill(Path(ellipseIn: rect(38.4 + offset, 30.0, 1.8, 1.8)), with: .color(Color.white.opacity(0.86)))
    }

    func drawMouth(
        _ context: GraphicsContext,
        pt: (CGFloat, CGFloat) -> CGPoint,
        scale s: CGFloat,
        color: Color,
        expression: ACCatExpression
    ) {
        var path = Path()
        switch expression {
        case .happy, .celebrate:
            path.move(to: pt(28, 41))
            path.addQuadCurve(to: pt(36, 41), control: pt(32, 44))
        case .concern:
            path.move(to: pt(28, 42))
            path.addQuadCurve(to: pt(36, 42), control: pt(32, 40))
        case .drift:
            path.move(to: pt(29, 42))
            path.addLine(to: pt(35, 42))
        default:
            path.move(to: pt(30, 41))
            path.addQuadCurve(to: pt(34, 41), control: pt(32, 42.5))
        }
        context.stroke(path, with: .color(color), lineWidth: 1.35 * s)
    }

    func softTriangle(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint) -> Path {
        var path = Path()
        path.move(to: a)
        path.addQuadCurve(to: b, control: midpoint(a, b))
        path.addQuadCurve(to: c, control: midpoint(b, c))
        path.addQuadCurve(to: a, control: midpoint(c, a))
        path.closeSubpath()
        return path
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

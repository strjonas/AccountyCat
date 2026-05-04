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
        let ink = Color(hex: 0x34445F).opacity(0.88)
        let rim = Color(hex: 0xDCE8F7)

        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: ox + x * s, y: oy + y * s)
        }
        func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
            CGRect(x: ox + x * s, y: oy + y * s, width: w * s, height: h * s)
        }

        // Soft contact shadow plus a cool halo keeps the clear cat readable on
        // both the white settings cards and darker desktop surfaces.
        context.fill(Path(ellipseIn: rect(14, 51, 36, 5.5)), with: .color(Color(hex: 0x5B7192).opacity(0.14)))
        context.fill(Path(ellipseIn: rect(8, 9, 48, 48)), with: .color(rim.opacity(0.12)))

        // Frosted glass: mostly white/blue with only a small accent tint.
        let glass = Gradient(colors: [
            Color.white.opacity(0.88),
            rim.opacity(0.54),
            tint.opacity(0.12),
            Color.white.opacity(0.20)
        ])

        // Compact glass body behind the head, visible in larger placements but
        // quiet enough to remain icon-like in the top bar.
        var body = Path()
        body.move(to: pt(20, 43))
        body.addQuadCurve(to: pt(32, 33), control: pt(21, 34))
        body.addQuadCurve(to: pt(44, 43), control: pt(43, 34))
        body.addQuadCurve(to: pt(38, 54), control: pt(45, 53))
        body.addLine(to: pt(26, 54))
        body.addQuadCurve(to: pt(20, 43), control: pt(19, 53))
        body.closeSubpath()
        context.fill(body, with: .linearGradient(glass, startPoint: pt(24, 34), endPoint: pt(40, 55)))
        context.stroke(body, with: .color(rim.opacity(0.58)), lineWidth: 1.0 * s)
        context.stroke(body, with: .color(ink.opacity(0.18)), lineWidth: 0.5 * s)

        // Ears: part of the same outline language, with a soft inner facet.
        let leftEar = softTriangle(pt(15.5, 23), pt(19.5, 9.5), pt(27, 20.5))
        let rightEar = softTriangle(pt(48.5, 23), pt(44.5, 9.5), pt(37, 20.5))
        fillGlass(leftEar, context: context, gradient: glass, start: pt(19, 10), end: pt(22, 25), stroke: ink, scale: s)
        fillGlass(rightEar, context: context, gradient: glass, start: pt(45, 10), end: pt(42, 25), stroke: ink, scale: s)
        context.stroke(innerEarPath(left: true, pt: pt), with: .color(ink.opacity(0.20)), lineWidth: 0.8 * s)
        context.stroke(innerEarPath(left: false, pt: pt), with: .color(ink.opacity(0.20)), lineWidth: 0.8 * s)

        // Head — simple rounded icon silhouette.
        var head = Path()
        head.move(to: pt(14, 32))
        head.addQuadCurve(to: pt(20, 22), control: pt(14, 24))
        head.addQuadCurve(to: pt(32, 18.5), control: pt(25, 18))
        head.addQuadCurve(to: pt(44, 22), control: pt(39, 18))
        head.addQuadCurve(to: pt(50, 32), control: pt(50, 24))
        head.addQuadCurve(to: pt(32, 49.5), control: pt(50, 50.5))
        head.addQuadCurve(to: pt(14, 32), control: pt(14, 50.5))
        head.closeSubpath()
        context.fill(head, with: .radialGradient(
            glass,
            center: pt(28, 26),
            startRadius: 4 * s,
            endRadius: 30 * s
        ))
        context.stroke(head, with: .color(Color.white.opacity(0.72)), lineWidth: 1.35 * s)
        context.stroke(head, with: .color(ink.opacity(0.46)), lineWidth: 0.85 * s)

        // Specular highlights: crisp, not glossy-button heavy.
        context.stroke(highlightPath(pt: pt), with: .color(Color.white.opacity(0.76)), lineWidth: 1.2 * s)
        context.fill(Path(ellipseIn: rect(38, 21, 7, 3)), with: .color(Color.white.opacity(0.42)))
        context.fill(Path(ellipseIn: rect(20, 37, 25, 7)), with: .color(Color.white.opacity(0.13)))

        drawEyes(context, pt: pt, rect: rect, scale: s, color: ink, expression: expression)

        // Tiny nose
        var nose = Path()
        nose.move(to: pt(31, 38))
        nose.addLine(to: pt(33, 38))
        nose.addLine(to: pt(32, 40))
        nose.closeSubpath()
        context.fill(nose, with: .color(ink.opacity(0.52)))

        drawMouth(context, pt: pt, scale: s, color: ink.opacity(0.62), expression: expression)

        if expression == .celebrate {
            drawSpark(context, center: pt(8, 15), scale: s, color: tint.opacity(0.78))
            drawSpark(context, center: pt(56, 14), scale: s * 0.72, color: tint.opacity(0.78))
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
        context.stroke(path, with: .color(Color.white.opacity(0.66)), lineWidth: 1.0 * scale)
        context.stroke(path, with: .color(stroke.opacity(0.40)), lineWidth: 0.55 * scale)
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

    func innerEarPath(left: Bool, pt: (CGFloat, CGFloat) -> CGPoint) -> Path {
        var path = Path()
        if left {
            path.move(to: pt(19.8, 16.2))
            path.addLine(to: pt(22.8, 21.1))
            path.addLine(to: pt(17.7, 21.8))
        } else {
            path.move(to: pt(44.2, 16.2))
            path.addLine(to: pt(41.2, 21.1))
            path.addLine(to: pt(46.3, 21.8))
        }
        return path
    }

    func highlightPath(pt: (CGFloat, CGFloat) -> CGPoint) -> Path {
        var path = Path()
        path.move(to: pt(20, 25))
        path.addQuadCurve(to: pt(30, 21.6), control: pt(23.5, 21.7))
        return path
    }

    func midpoint(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
        CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
    }
}

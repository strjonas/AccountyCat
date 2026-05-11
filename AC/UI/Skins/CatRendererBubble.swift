//
//  CatRendererBubble.swift
//  AC
//
//  Bubble skin — reinvented as a fill-based "modern app icon" cat. No
//  outlines (outlines reveal every imperfect curve and read as hand-drawn);
//  the body is a single confident shape with a subtle vertical gradient, a
//  soft outer shadow for separation, and a faint top sheen for dimension.
//
//  The body tints from the user's accent: warm accents read peachy, cool
//  accents read lavender, green accents read sage. Reads like a Things-3 /
//  Setapp icon rather than a sticker.
//

import SwiftUI

struct CatRendererBubble: CatRenderer {
    func render(
        in context: GraphicsContext,
        size: CGSize,
        character: ACCharacter,
        expression: ACCatExpression,
        accent: Color
    ) {
        let s = min(size.width, size.height) / 64
        let ox = size.width / 2 - 32 * s
        let oy = size.height / 2 - 32 * s
        let p = BubblePalette(accent: accent)

        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: ox + x * s, y: oy + y * s)
        }
        func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
            CGRect(x: ox + x * s, y: oy + y * s, width: w * s, height: h * s)
        }

        // ─── Soft outer shadow (sells "object floating on a surface", a macOS
        //     icon cue). Three faint passes at decreasing opacity / increasing
        //     spread → cheap but convincing penumbra. ───
        for (spread, alpha) in [(2.0, 0.06), (4.0, 0.05), (7.0, 0.04)] {
            let r = CGRect(
                x: ox + (12 - spread) * s,
                y: oy + (52 - spread / 2) * s,
                width: (40 + spread * 2) * s,
                height: (5 + spread) * s
            )
            context.fill(Path(ellipseIn: r), with: .color(p.shadow.opacity(alpha)))
        }

        // ─── Ears (drawn first so the head sits on top and hides the ear bases) ───
        let leftEar = softTri(pt(13.5, 19), pt(21, 6.5), pt(27, 19))
        let rightEar = softTri(pt(50.5, 19), pt(43, 6.5), pt(37, 19))
        context.fill(leftEar, with: .linearGradient(
            Gradient(colors: [p.bodyTop, p.bodyBottom]),
            startPoint: pt(21, 6.5),
            endPoint: pt(21, 19)
        ))
        context.fill(rightEar, with: .linearGradient(
            Gradient(colors: [p.bodyTop, p.bodyBottom]),
            startPoint: pt(43, 6.5),
            endPoint: pt(43, 19)
        ))
        // Inner ear: a darker shade of the body — no extra hue, just depth.
        context.fill(softTri(pt(17.5, 14), pt(21, 8.5), pt(24.5, 16)), with: .color(p.earInner))
        context.fill(softTri(pt(46.5, 14), pt(43, 8.5), pt(39.5, 16)), with: .color(p.earInner))

        // ─── Head: a near-circle, slightly squashed. Single confident shape. ───
        var head = Path()
        head.move(to: pt(10, 32))
        head.addQuadCurve(to: pt(32, 14), control: pt(10, 16))   // up-left to brow
        head.addQuadCurve(to: pt(54, 32), control: pt(54, 16))   // brow to right cheek
        head.addQuadCurve(to: pt(32, 53), control: pt(54, 52))   // right cheek to chin
        head.addQuadCurve(to: pt(10, 32), control: pt(10, 52))   // chin to left cheek
        head.closeSubpath()
        context.fill(head, with: .linearGradient(
            Gradient(colors: [p.bodyTop, p.bodyBottom]),
            startPoint: pt(32, 14),
            endPoint: pt(32, 53)
        ))

        // ─── Top sheen (the gloss highlight every Mac icon has). Soft, subtle. ───
        context.fill(Path(ellipseIn: rect(16, 17, 32, 6)), with: .color(.white.opacity(0.30)))
        context.fill(Path(ellipseIn: rect(22, 18, 20, 3.2)), with: .color(.white.opacity(0.22)))

        let rim = StrokeStyle(lineWidth: 0.65 * s, lineCap: .round, lineJoin: .round)
        context.stroke(leftEar, with: .color(p.rim.opacity(0.52)), style: rim)
        context.stroke(rightEar, with: .color(p.rim.opacity(0.52)), style: rim)
        context.stroke(head, with: .color(p.rim.opacity(0.58)), style: rim)

        // ─── Eyes — sit slightly above center, small enough to feel mature ───
        drawEyes(context, pt: pt, rect: rect, scale: s, palette: p, expression: expression)

        // ─── Cheek blush — fades softly into the body, never a hard sticker dot ───
        if expression == .happy || expression == .celebrate || expression == .neutral || expression == .alert {
            context.fill(Path(ellipseIn: rect(15, 37, 7, 3.2)), with: .color(p.blush.opacity(0.55)))
            context.fill(Path(ellipseIn: rect(42, 37, 7, 3.2)), with: .color(p.blush.opacity(0.55)))
        }

        // ─── Nose (small filled triangle, color is darker accent — feels intentional) ───
        var nose = Path()
        nose.move(to: pt(30.5, 38.6))
        nose.addLine(to: pt(33.5, 38.6))
        nose.addLine(to: pt(32, 40.5))
        nose.closeSubpath()
        context.fill(nose, with: .color(p.nose))

        // ─── Mouth ───
        drawMouth(context, pt: pt, scale: s, palette: p, expression: expression)

        if expression == .celebrate {
            drawSpark(context, center: pt(6, 13), scale: s * 1.0, color: p.spark)
            drawSpark(context, center: pt(58, 12), scale: s * 0.72, color: p.spark.opacity(0.78))
        }
        if expression == .sleep {
            drawCrescent(context, center: pt(56, 12), scale: s, color: p.eye.opacity(0.55))
        }
    }
}

// MARK: - Palette derived from accent

private struct BubblePalette {
    let bodyTop: Color
    let bodyBottom: Color
    let earInner: Color
    let blush: Color
    let eye: Color
    let nose: Color
    let shadow: Color
    let spark: Color
    let rim: Color
    let highlight: Color

    init(accent: Color) {
        let rgb = accent.acRGB

        // Light body: 25% accent + 75% warm cream. Reads as "warm pastel" for
        // any accent — orange becomes peach, blue becomes lavender-tinged blue.
        let cream = (r: 0.985, g: 0.945, b: 0.870)
        let topR = cream.r * 0.75 + rgb.r * 0.25
        let topG = cream.g * 0.75 + rgb.g * 0.25
        let topB = cream.b * 0.75 + rgb.b * 0.25
        let bodyTopColor = Color(.sRGB, red: topR, green: topG, blue: topB, opacity: 1)
        bodyTop = bodyTopColor

        // Body bottom: a touch more saturated than top, slightly darker. Gives
        // genuine depth without needing a glossy specular.
        let botR = topR * 0.86 + rgb.r * 0.10
        let botG = topG * 0.86 + rgb.g * 0.10
        let botB = topB * 0.86 + rgb.b * 0.10
        bodyBottom = Color(.sRGB, red: botR, green: botG, blue: botB, opacity: 1)

        // Inner ear: darker variant of body bottom, slight accent push for warmth.
        earInner = Color(.sRGB, red: botR * 0.82 + rgb.r * 0.12,
                         green: botG * 0.82 + rgb.g * 0.12,
                         blue: botB * 0.82 + rgb.b * 0.12, opacity: 1)

        // Blush: pure-ish accent blended with pink — works for cool accents too.
        let pink = (r: 0.949, g: 0.659, b: 0.627)
        blush = Color(.sRGB,
                      red: rgb.r * 0.55 + pink.r * 0.45,
                      green: rgb.g * 0.55 + pink.g * 0.45,
                      blue: rgb.b * 0.55 + pink.b * 0.45,
                      opacity: 1)

        // Eye: deep slate from the accent — never pure black (looks crude).
        eye = Color(.sRGB,
                    red: rgb.r * 0.18 + 0.08,
                    green: rgb.g * 0.18 + 0.10,
                    blue: rgb.b * 0.18 + 0.15,
                    opacity: 1)

        // Nose: 60% darken of accent, biased toward warm.
        nose = Color(.sRGB,
                     red: rgb.r * 0.65,
                     green: rgb.g * 0.55,
                     blue: rgb.b * 0.50,
                     opacity: 1)

        shadow = Color(.sRGB,
                       red: rgb.r * 0.28,
                       green: rgb.g * 0.28,
                       blue: rgb.b * 0.32,
                       opacity: 1)

        spark = Color(.sRGB,
                      red: min(1.0, rgb.r * 1.05),
                      green: min(1.0, rgb.g * 1.05),
                      blue: min(1.0, rgb.b * 1.05),
                      opacity: 1)

        rim = Color(.sRGB,
                    red: rgb.r * 0.32 + 0.36,
                    green: rgb.g * 0.32 + 0.28,
                    blue: rgb.b * 0.32 + 0.22,
                    opacity: 1)

        highlight = bodyTopColor.acMixed(with: .white, amount: 0.78)
    }
}

// MARK: - Face

private extension CatRendererBubble {
    func drawEyes(
        _ context: GraphicsContext,
        pt: (CGFloat, CGFloat) -> CGPoint,
        rect: (CGFloat, CGFloat, CGFloat, CGFloat) -> CGRect,
        scale s: CGFloat,
        palette p: BubblePalette,
        expression: ACCatExpression
    ) {
        func openEye(centerX: CGFloat, centerY: CGFloat, width: CGFloat, height: CGFloat, lookX: CGFloat = 0) {
            let x = centerX - width / 2 + lookX
            let y = centerY - height / 2
            context.fill(Path(ellipseIn: rect(x, y, width, height)), with: .color(p.eye))
            context.fill(Path(ellipseIn: rect(x + width * 0.30, y + height * 0.18, 1.15, 1.15)), with: .color(p.highlight.opacity(0.96)))
            context.fill(Path(ellipseIn: rect(x + width * 0.60, y + height * 0.64, 0.55, 0.55)), with: .color(p.highlight.opacity(0.62)))

            var lower = Path()
            lower.move(to: pt(centerX - width * 0.44 + lookX, centerY + height * 0.62))
            lower.addQuadCurve(
                to: pt(centerX + width * 0.44 + lookX, centerY + height * 0.62),
                control: pt(centerX + lookX, centerY + height * 0.84)
            )
            context.stroke(lower, with: .color(p.eye.opacity(0.16)), style: StrokeStyle(lineWidth: 0.7 * s, lineCap: .round))
        }

        switch expression {
        case .happy:
            let style = StrokeStyle(lineWidth: 1.75 * s, lineCap: .round)
            var left = Path()
            left.move(to: pt(21.7, 31.4))
            left.addQuadCurve(to: pt(28.3, 31.4), control: pt(25, 35.0))
            var right = Path()
            right.move(to: pt(35.7, 31.4))
            right.addQuadCurve(to: pt(42.3, 31.4), control: pt(39, 35.0))
            context.stroke(left, with: .color(p.eye), style: style)
            context.stroke(right, with: .color(p.eye), style: style)

        case .sleep:
            let style = StrokeStyle(lineWidth: 1.55 * s, lineCap: .round)
            var left = Path()
            left.move(to: pt(21.8, 32.0))
            left.addQuadCurve(to: pt(28.2, 32.0), control: pt(25, 33.0))
            var right = Path()
            right.move(to: pt(35.8, 32.0))
            right.addQuadCurve(to: pt(42.2, 32.0), control: pt(39, 33.0))
            context.stroke(left, with: .color(p.eye.opacity(0.82)), style: style)
            context.stroke(right, with: .color(p.eye.opacity(0.82)), style: style)

        case .celebrate:
            drawSpark(context, center: pt(25, 31.5), scale: s * 1.15, color: p.eye)
            drawSpark(context, center: pt(39, 31.5), scale: s * 1.15, color: p.eye)

        case .drift:
            openEye(centerX: 25.3, centerY: 32.2, width: 3.2, height: 3.0, lookX: 0.8)
            openEye(centerX: 39.3, centerY: 32.2, width: 3.2, height: 3.0, lookX: 0.8)
            let style = StrokeStyle(lineWidth: 1.15 * s, lineCap: .round)
            var lidL = Path(); lidL.move(to: pt(22.3, 30.6)); lidL.addQuadCurve(to: pt(28.3, 30.7), control: pt(25.3, 29.8))
            var lidR = Path(); lidR.move(to: pt(36.3, 30.6)); lidR.addQuadCurve(to: pt(42.3, 30.7), control: pt(39.3, 29.8))
            context.stroke(lidL, with: .color(p.eye.opacity(0.82)), style: style)
            context.stroke(lidR, with: .color(p.eye.opacity(0.82)), style: style)

        case .concern:
            openEye(centerX: 25.0, centerY: 30.9, width: 3.4, height: 4.2)
            openEye(centerX: 39.0, centerY: 30.9, width: 3.4, height: 4.2)
            let style = StrokeStyle(lineWidth: 1.1 * s, lineCap: .round)
            var browL = Path(); browL.move(to: pt(21, 25)); browL.addQuadCurve(to: pt(28, 26.5), control: pt(24.5, 22.5))
            var browR = Path(); browR.move(to: pt(43, 25)); browR.addQuadCurve(to: pt(36, 26.5), control: pt(39.5, 22.5))
            context.stroke(browL, with: .color(p.eye), style: style)
            context.stroke(browR, with: .color(p.eye), style: style)

        case .alert:
            openEye(centerX: 25.0, centerY: 31.4, width: 4.2, height: 5.0)
            openEye(centerX: 39.0, centerY: 31.4, width: 4.2, height: 5.0)

        case .neutral:
            openEye(centerX: 25.0, centerY: 31.6, width: 3.8, height: 4.6)
            openEye(centerX: 39.0, centerY: 31.6, width: 3.8, height: 4.6)
        }
    }

    func drawMouth(
        _ context: GraphicsContext,
        pt: (CGFloat, CGFloat) -> CGPoint,
        scale s: CGFloat,
        palette p: BubblePalette,
        expression: ACCatExpression
    ) {
        let style = StrokeStyle(lineWidth: 1.3 * s, lineCap: .round)
        switch expression {
        case .happy, .celebrate:
            var smile = Path()
            smile.move(to: pt(28, 42.2))
            smile.addQuadCurve(to: pt(36, 42.2), control: pt(32, 46.4))
            context.stroke(smile, with: .color(p.nose), style: style)
        case .concern:
            var path = Path()
            path.move(to: pt(29.5, 43.4))
            path.addQuadCurve(to: pt(34.5, 43.4), control: pt(32, 42))
            context.stroke(path, with: .color(p.nose), style: style)
        case .drift:
            var path = Path()
            path.move(to: pt(29.5, 43.4))
            path.addLine(to: pt(34.5, 43.4))
            context.stroke(path, with: .color(p.nose), style: style)
        default:
            // Gentle "ω".
            var left = Path()
            left.move(to: pt(29, 41.6))
            left.addQuadCurve(to: pt(32, 43.4), control: pt(30.5, 43.6))
            var right = Path()
            right.move(to: pt(32, 43.4))
            right.addQuadCurve(to: pt(35, 41.6), control: pt(33.5, 43.6))
            context.stroke(left, with: .color(p.nose), style: style)
            context.stroke(right, with: .color(p.nose), style: style)
        }
    }

    func softTri(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint) -> Path {
        var path = Path()
        path.move(to: a)
        path.addQuadCurve(to: b, control: CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2))
        path.addQuadCurve(to: c, control: CGPoint(x: (b.x + c.x) / 2, y: (b.y + c.y) / 2))
        path.addQuadCurve(to: a, control: CGPoint(x: (c.x + a.x) / 2, y: (c.y + a.y) / 2))
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

    func drawCrescent(_ context: GraphicsContext, center: CGPoint, scale s: CGFloat, color: Color) {
        let r = 3.0 * s
        let outer = Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2))
        let inner = Path(ellipseIn: CGRect(x: center.x - r + 1.4 * s, y: center.y - r - 0.4 * s, width: r * 2, height: r * 2))
        var crescent = outer
        crescent.addPath(inner)
        context.fill(crescent, with: .color(color), style: FillStyle(eoFill: true))
    }
}

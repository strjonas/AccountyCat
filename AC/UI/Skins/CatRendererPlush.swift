//
//  CatRendererPlush.swift
//  AC
//
//  Plush skin: a soft, glossy toy-cat. The expressive slot — squashed
//  egg-shaped silhouette (intentionally distinct from Bubble's round head),
//  bold pink ear interiors, large sticker-clean eyes with a single bright
//  catch-light, and a small character-specific charm (heart / star / leaf)
//  that gives Mochi / Nova / Sage their own visual signature.
//

import SwiftUI

struct CatRendererPlush: CatRenderer {
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
        let p = PlushPalette(character)

        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: ox + x * s, y: oy + y * s)
        }
        func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
            CGRect(x: ox + x * s, y: oy + y * s, width: w * s, height: h * s)
        }

        // Soft contact shadow, anchored under the squashed chin.
        context.fill(Path(ellipseIn: rect(15, 53.5, 34, 3.6)), with: .color(p.outline.opacity(0.16)))

        // ─── Ears — small, rounded, leaning slightly outward ───
        let leftEar = softTriangle(pt(11, 26), pt(17, 9), pt(26, 24))
        let rightEar = softTriangle(pt(53, 26), pt(47, 9), pt(38, 24))
        context.fill(leftEar, with: .color(p.body))
        context.fill(rightEar, with: .color(p.body))

        // Bold pink inner ear — fills more of the ear than Bubble's accent flick.
        context.fill(softTriangle(pt(14.5, 22), pt(18, 13), pt(23, 23)), with: .color(p.innerEar))
        context.fill(softTriangle(pt(49.5, 22), pt(46, 13), pt(41, 23)), with: .color(p.innerEar))

        // ─── Head silhouette — wider than tall, intentionally egg-shaped ───
        var head = Path()
        head.move(to: pt(7, 33))                                                     // far left, low
        head.addQuadCurve(to: pt(22, 18), control: pt(7, 20))                        // up over left cheek
        head.addQuadCurve(to: pt(32, 16.5), control: pt(27, 15.5))                   // brow
        head.addQuadCurve(to: pt(42, 18), control: pt(37, 15.5))                     // brow right
        head.addQuadCurve(to: pt(57, 33), control: pt(57, 20))                       // down over right cheek
        head.addQuadCurve(to: pt(48, 52), control: pt(58, 47))                       // chin right
        head.addQuadCurve(to: pt(32, 56), control: pt(43, 56))                       // chin bottom
        head.addQuadCurve(to: pt(16, 52), control: pt(21, 56))                       // chin left
        head.addQuadCurve(to: pt(7, 33), control: pt(6, 47))                         // back to start
        head.closeSubpath()
        context.fill(head, with: .color(p.body))

        // Cell-shaded under-shadow: hard-edged crescent, clipped to head.
        if size.width >= 36 {
            var underShadow = Path()
            underShadow.move(to: pt(10, 42))
            underShadow.addQuadCurve(to: pt(32, 56.5), control: pt(12, 58))
            underShadow.addQuadCurve(to: pt(54, 42), control: pt(52, 58))
            underShadow.addQuadCurve(to: pt(46, 47), control: pt(53, 46))
            underShadow.addQuadCurve(to: pt(32, 50), control: pt(40, 50))
            underShadow.addQuadCurve(to: pt(18, 47), control: pt(24, 50))
            underShadow.addQuadCurve(to: pt(10, 42), control: pt(11, 46))
            underShadow.closeSubpath()
            context.drawLayer { layer in
                layer.clip(to: head)
                layer.fill(underShadow, with: .color(p.shadow))
            }
        }

        // Top sheen — a single soft highlight strip that sells the "plush gloss".
        context.fill(Path(ellipseIn: rect(16, 19, 28, 5)), with: .color(.white.opacity(0.32)))

        // Outline last so it sits on top of the shading.
        let outline = StrokeStyle(lineWidth: 1.15 * s, lineCap: .round, lineJoin: .round)
        context.stroke(head, with: .color(p.outline), style: outline)
        context.stroke(leftEar, with: .color(p.outline), style: outline)
        context.stroke(rightEar, with: .color(p.outline), style: outline)

        // ─── Cheek blush — large, soft-edged, well below the eyes ───
        if expression != .concern && expression != .sleep {
            context.fill(Path(ellipseIn: rect(12, 39.5, 9.5, 4.4)), with: .color(p.blush.opacity(0.85)))
            context.fill(Path(ellipseIn: rect(42.5, 39.5, 9.5, 4.4)), with: .color(p.blush.opacity(0.85)))
        }

        // ─── Eyes — clean sticker style: one dark oval + one big sparkle ───
        drawEyes(context, pt: pt, rect: rect, scale: s, palette: p, expression: expression, outline: outline)

        // ─── Tiny mouth ───
        drawMouth(context, pt: pt, scale: s, palette: p, expression: expression, outline: outline)

        // ─── Character-specific charm in the upper-right (only on positive
        //     expressions and when there's room to render it cleanly) ───
        if size.width >= 44 && (expression == .neutral || expression == .happy || expression == .celebrate || expression == .alert) {
            drawCharm(context, rect: rect, pt: pt, scale: s, character: character, palette: p)
        }

        // ─── Decorations ───
        if expression == .celebrate {
            drawSpark(context, center: pt(6, 14), scale: s * 1.0, color: p.blush)
            drawSpark(context, center: pt(5, 30), scale: s * 0.6, color: p.charm.opacity(0.85))
        }
        if expression == .sleep {
            drawCrescent(context, center: pt(55, 12), scale: s, color: p.outline.opacity(0.62))
        }
    }
}

// MARK: - Palette

private struct PlushPalette {
    let body: Color
    let shadow: Color
    let outline: Color
    let innerEar: Color
    let blush: Color
    let charm: Color
    let eye: Color
    let nose: Color

    init(_ character: ACCharacter) {
        switch character {
        case .mochi:
            body = Color(hex: 0xFAE0BC)
            shadow = Color(hex: 0xEDC18F)
            outline = Color(hex: 0x6E4427)
            innerEar = Color(hex: 0xF0A38A)
            blush = Color(hex: 0xF09A82)
            charm = Color(hex: 0xE26B6B)     // heart red
            eye = Color(hex: 0x2A1B0E)
            nose = Color(hex: 0xB36A4D)
        case .nova:
            body = Color(hex: 0xCFC0EE)
            shadow = Color(hex: 0xA593CE)
            outline = Color(hex: 0x2F2552)
            innerEar = Color(hex: 0xDDB2DA)
            blush = Color(hex: 0xE0A0CC)
            charm = Color(hex: 0xF4E15C)     // star yellow
            eye = Color(hex: 0x1B132E)
            nose = Color(hex: 0x4A3868)
        case .sage:
            body = Color(hex: 0xD3DBB4)
            shadow = Color(hex: 0xA8B486)
            outline = Color(hex: 0x394726)
            innerEar = Color(hex: 0xE5C7A3)
            blush = Color(hex: 0xE8A48A)
            charm = Color(hex: 0x5F9A4A)     // leaf green
            eye = Color(hex: 0x1B1F10)
            nose = Color(hex: 0x5A4632)
        }
    }
}

// MARK: - Face

private extension CatRendererPlush {
    func drawEyes(
        _ context: GraphicsContext,
        pt: (CGFloat, CGFloat) -> CGPoint,
        rect: (CGFloat, CGFloat, CGFloat, CGFloat) -> CGRect,
        scale s: CGFloat,
        palette p: PlushPalette,
        expression: ACCatExpression,
        outline: StrokeStyle
    ) {
        // One sticker-clean eye: dark oval + one big top-left catch-light.
        func eye(_ x: CGFloat, _ y: CGFloat, w: CGFloat = 5.4, h: CGFloat = 6.6) {
            context.fill(Path(ellipseIn: CGRect(x: pt(x, y).x, y: pt(x, y).y, width: w * s, height: h * s)),
                         with: .color(p.eye))
            // Big sparkle highlight (the defining "wow shine") — sized ~40% of the eye.
            let hx = x + 0.7
            let hy = y + 0.6
            context.fill(Path(ellipseIn: CGRect(x: pt(hx, hy).x, y: pt(hx, hy).y, width: 2.4 * s, height: 2.4 * s)),
                         with: .color(.white))
            // Tiny secondary glint, bottom-right of pupil.
            let sx = x + w - 1.8
            let sy = y + h - 1.6
            context.fill(Path(ellipseIn: CGRect(x: pt(sx, sy).x, y: pt(sx, sy).y, width: 0.9 * s, height: 0.9 * s)),
                         with: .color(.white.opacity(0.85)))
        }

        switch expression {
        case .sleep, .happy:
            // Long closed-arc eyes, slight lash flick at the outer corner.
            let lashStroke = StrokeStyle(lineWidth: 1.5 * s, lineCap: .round)
            var left = Path()
            left.move(to: pt(20, 33))
            left.addQuadCurve(to: pt(28, 33), control: pt(24, 37.5))
            var right = Path()
            right.move(to: pt(36, 33))
            right.addQuadCurve(to: pt(44, 33), control: pt(40, 37.5))
            context.stroke(left, with: .color(p.eye), style: lashStroke)
            context.stroke(right, with: .color(p.eye), style: lashStroke)
            var flickL = Path(); flickL.move(to: pt(20, 33)); flickL.addLine(to: pt(18.5, 31.8))
            var flickR = Path(); flickR.move(to: pt(44, 33)); flickR.addLine(to: pt(45.5, 31.8))
            context.stroke(flickL, with: .color(p.eye), style: lashStroke)
            context.stroke(flickR, with: .color(p.eye), style: lashStroke)

        case .celebrate:
            // Star eyes — five-point stars in place of pupils. Pure sticker joy.
            drawStar(context, center: pt(23.5, 32.8), scale: s * 3.0, color: p.eye)
            drawStar(context, center: pt(40.5, 32.8), scale: s * 3.0, color: p.eye)

        case .drift:
            // Half-lidded — small pupils, heavy upper lid line.
            let lidStroke = StrokeStyle(lineWidth: 1.5 * s, lineCap: .round)
            var leftLid = Path(); leftLid.move(to: pt(20.5, 31.5)); leftLid.addQuadCurve(to: pt(27.5, 31.5), control: pt(24, 30.2))
            var rightLid = Path(); rightLid.move(to: pt(36.5, 31.5)); rightLid.addQuadCurve(to: pt(43.5, 31.5), control: pt(40, 30.2))
            context.stroke(leftLid, with: .color(p.eye), style: lidStroke)
            context.stroke(rightLid, with: .color(p.eye), style: lidStroke)
            context.fill(Path(ellipseIn: rect(22.6, 33.0, 2.2, 2.2)), with: .color(p.eye))
            context.fill(Path(ellipseIn: rect(38.6, 33.0, 2.2, 2.2)), with: .color(p.eye))

        case .concern:
            // Slightly smaller eyes shifted down + slanted brows.
            eye(21, 31.5, w: 4.8, h: 5.4)
            eye(38, 31.5, w: 4.8, h: 5.4)
            let browStroke = StrokeStyle(lineWidth: 1.2 * s, lineCap: .round)
            var browL = Path(); browL.move(to: pt(19, 28)); browL.addQuadCurve(to: pt(27, 29.5), control: pt(23, 26))
            var browR = Path(); browR.move(to: pt(45, 28)); browR.addQuadCurve(to: pt(37, 29.5), control: pt(41, 26))
            context.stroke(browL, with: .color(p.eye), style: browStroke)
            context.stroke(browR, with: .color(p.eye), style: browStroke)

        case .alert, .neutral:
            eye(20.5, 30.5)
            eye(38.1, 30.5)
        }
    }

    func drawMouth(
        _ context: GraphicsContext,
        pt: (CGFloat, CGFloat) -> CGPoint,
        scale s: CGFloat,
        palette p: PlushPalette,
        expression: ACCatExpression,
        outline: StrokeStyle
    ) {
        // Tiny nose triangle.
        var nose = Path()
        nose.move(to: pt(30.8, 41.4))
        nose.addLine(to: pt(33.2, 41.4))
        nose.addLine(to: pt(32, 43.0))
        nose.closeSubpath()
        context.fill(nose, with: .color(p.nose))

        let style = StrokeStyle(lineWidth: 1.15 * s, lineCap: .round)
        switch expression {
        case .happy, .celebrate:
            // Open mouth: small filled curve — shows joy without going cartoony.
            var open = Path()
            open.move(to: pt(29, 44.4))
            open.addQuadCurve(to: pt(35, 44.4), control: pt(32, 49.2))
            open.addLine(to: pt(29, 44.4))
            open.closeSubpath()
            context.fill(open, with: .color(p.nose.opacity(0.75)))
            context.stroke(open, with: .color(p.outline), style: style)
        case .concern:
            var path = Path()
            path.move(to: pt(30, 46))
            path.addQuadCurve(to: pt(34, 46), control: pt(32, 44.4))
            context.stroke(path, with: .color(p.outline), style: style)
        case .drift:
            var path = Path()
            path.move(to: pt(30, 45.2))
            path.addLine(to: pt(34, 45.2))
            context.stroke(path, with: .color(p.outline), style: style)
        default:
            // Tiny "ω" cat-mouth.
            var left = Path()
            left.move(to: pt(29.5, 43.6))
            left.addQuadCurve(to: pt(32, 45.4), control: pt(30.8, 45.4))
            var right = Path()
            right.move(to: pt(32, 45.4))
            right.addQuadCurve(to: pt(34.5, 43.6), control: pt(33.2, 45.4))
            context.stroke(left, with: .color(p.outline), style: style)
            context.stroke(right, with: .color(p.outline), style: style)
        }
    }

    func drawCharm(
        _ context: GraphicsContext,
        rect: (CGFloat, CGFloat, CGFloat, CGFloat) -> CGRect,
        pt: (CGFloat, CGFloat) -> CGPoint,
        scale s: CGFloat,
        character: ACCharacter,
        palette p: PlushPalette
    ) {
        switch character {
        case .mochi:
            // Tiny heart at the top-right.
            drawHeart(context, center: pt(50, 14), scale: s * 1.4, color: p.charm)
        case .nova:
            // Tiny star at the top-right.
            drawStar(context, center: pt(50, 14), scale: s * 1.6, color: p.charm)
        case .sage:
            // Tiny leaf at the top-right.
            drawLeaf(context, center: pt(50, 14), scale: s * 1.4, color: p.charm, outline: p.outline)
        }
    }

    func drawHeart(_ context: GraphicsContext, center: CGPoint, scale: CGFloat, color: Color) {
        var path = Path()
        let cx = center.x
        let cy = center.y
        path.move(to: CGPoint(x: cx, y: cy + 2.2 * scale))
        path.addCurve(
            to: CGPoint(x: cx - 2.6 * scale, y: cy - 0.5 * scale),
            control1: CGPoint(x: cx - 1.6 * scale, y: cy + 1.1 * scale),
            control2: CGPoint(x: cx - 2.6 * scale, y: cy + 0.6 * scale)
        )
        path.addArc(
            center: CGPoint(x: cx - 1.3 * scale, y: cy - 0.9 * scale),
            radius: 1.3 * scale,
            startAngle: .degrees(180),
            endAngle: .degrees(0),
            clockwise: false
        )
        path.addArc(
            center: CGPoint(x: cx + 1.3 * scale, y: cy - 0.9 * scale),
            radius: 1.3 * scale,
            startAngle: .degrees(180),
            endAngle: .degrees(0),
            clockwise: false
        )
        path.addCurve(
            to: CGPoint(x: cx, y: cy + 2.2 * scale),
            control1: CGPoint(x: cx + 2.6 * scale, y: cy + 0.6 * scale),
            control2: CGPoint(x: cx + 1.6 * scale, y: cy + 1.1 * scale)
        )
        path.closeSubpath()
        context.fill(path, with: .color(color))
    }

    func drawStar(_ context: GraphicsContext, center: CGPoint, scale: CGFloat, color: Color) {
        var path = Path()
        let cx = center.x
        let cy = center.y
        let outer = scale
        let inner = scale * 0.42
        let pointCount = 5
        for i in 0..<(pointCount * 2) {
            let r = i.isMultiple(of: 2) ? outer : inner
            let angle = -CGFloat.pi / 2 + CGFloat(i) * .pi / CGFloat(pointCount)
            let x = cx + r * cos(angle)
            let y = cy + r * sin(angle)
            if i == 0 {
                path.move(to: CGPoint(x: x, y: y))
            } else {
                path.addLine(to: CGPoint(x: x, y: y))
            }
        }
        path.closeSubpath()
        context.fill(path, with: .color(color))
    }

    func drawLeaf(_ context: GraphicsContext, center: CGPoint, scale: CGFloat, color: Color, outline: Color) {
        var path = Path()
        let cx = center.x
        let cy = center.y
        path.move(to: CGPoint(x: cx - 1.8 * scale, y: cy + 1.4 * scale))
        path.addQuadCurve(
            to: CGPoint(x: cx + 1.8 * scale, y: cy - 1.4 * scale),
            control: CGPoint(x: cx - 1.4 * scale, y: cy - 2.0 * scale)
        )
        path.addQuadCurve(
            to: CGPoint(x: cx - 1.8 * scale, y: cy + 1.4 * scale),
            control: CGPoint(x: cx + 1.4 * scale, y: cy + 2.0 * scale)
        )
        path.closeSubpath()
        context.fill(path, with: .color(color))
        // Mid-vein
        var vein = Path()
        vein.move(to: CGPoint(x: cx - 1.4 * scale, y: cy + 1.0 * scale))
        vein.addQuadCurve(
            to: CGPoint(x: cx + 1.4 * scale, y: cy - 1.0 * scale),
            control: CGPoint(x: cx, y: cy)
        )
        context.stroke(vein, with: .color(outline.opacity(0.6)), lineWidth: 0.6 * scale)
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

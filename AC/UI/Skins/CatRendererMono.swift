//
//  CatRendererMono.swift
//  AC
//
//  Mono skin — a faithful translation of the AC AppIcon into vector code.
//  Wider-than-tall "pillow" head, small rounded ears, visible body
//  silhouette below the chin. The line color is a slate-tinted version of
//  the user's accent (so the cat reads as the logo, but the user's selected
//  palette comes through); fill is a warm cream; accent itself drives the
//  cheek dots and inner-ear color.
//

import SwiftUI

struct CatRendererMono: CatRenderer {
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
        let ink = slateInk(from: accent)              // slate-tinted accent → line
        let fillTop = creamFill(from: accent, dark: false)
        let fillBottom = creamFill(from: accent, dark: true)
        let blush = blushTint(from: accent)
        let innerEar = blush.opacity(0.55)

        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: ox + x * s, y: oy + y * s)
        }
        func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
            CGRect(x: ox + x * s, y: oy + y * s, width: w * s, height: h * s)
        }

        // Logo lineweight is bold and uniform — measured against the AppIcon it
        // sits around 2.2/64. We keep that so the cat reads at a glance.
        let stroke = StrokeStyle(lineWidth: 2.2 * s, lineCap: .round, lineJoin: .round)
        let thin = StrokeStyle(lineWidth: 1.4 * s, lineCap: .round, lineJoin: .round)
        let hair = StrokeStyle(lineWidth: 1.1 * s, lineCap: .round, lineJoin: .round)

        // ─── Body silhouette (drawn first so the chin line sits on top) ───
        var body = Path()
        body.move(to: pt(16, 40))
        body.addQuadCurve(to: pt(10, 47), control: pt(11, 42))
        body.addQuadCurve(to: pt(13, 56), control: pt(8, 53))
        body.addQuadCurve(to: pt(32, 59), control: pt(18, 60))
        body.addQuadCurve(to: pt(51, 56), control: pt(46, 60))
        body.addQuadCurve(to: pt(54, 47), control: pt(56, 53))
        body.addQuadCurve(to: pt(48, 40), control: pt(53, 42))
        body.closeSubpath()
        context.fill(body, with: .linearGradient(
            Gradient(colors: [fillTop, fillBottom]),
            startPoint: pt(32, 40),
            endPoint: pt(32, 58)
        ))
        context.stroke(body, with: .color(ink), style: stroke)

        // ─── Head silhouette: a wide pillow with two rounded ears ───
        var head = Path()
        head.move(to: pt(8, 30))                                                     // left cheek outer
        head.addQuadCurve(to: pt(12, 22), control: pt(8, 25))                        // up-left curve
        head.addQuadCurve(to: pt(20, 7), control: pt(12, 12))                        // up to left ear tip
        head.addQuadCurve(to: pt(28, 21), control: pt(26, 13))                       // down inner ear
        head.addQuadCurve(to: pt(36, 21), control: pt(32, 25))                       // valley between ears
        head.addQuadCurve(to: pt(44, 7), control: pt(38, 13))                        // up right ear tip
        head.addQuadCurve(to: pt(52, 22), control: pt(52, 12))                       // down right ear
        head.addQuadCurve(to: pt(56, 30), control: pt(56, 25))                       // right cheek outer
        head.addQuadCurve(to: pt(52, 41), control: pt(56, 38))                       // right chin
        head.addQuadCurve(to: pt(32, 44), control: pt(48, 45))                       // chin center (slight bow)
        head.addQuadCurve(to: pt(12, 41), control: pt(16, 45))                       // chin left
        head.addQuadCurve(to: pt(8, 30), control: pt(8, 38))                         // back to start
        head.closeSubpath()
        context.fill(head, with: .linearGradient(
            Gradient(colors: [fillTop, fillBottom]),
            startPoint: pt(32, 8),
            endPoint: pt(32, 44)
        ))
        context.stroke(head, with: .color(ink), style: stroke)

        // ─── Inner ear curves (the small concave dips from the AppIcon) ───
        var innerL = Path()
        innerL.move(to: pt(18, 13))
        innerL.addQuadCurve(to: pt(25, 20), control: pt(22, 16))
        var innerR = Path()
        innerR.move(to: pt(46, 13))
        innerR.addQuadCurve(to: pt(39, 20), control: pt(42, 16))
        context.stroke(innerL, with: .color(ink.opacity(0.62)), style: thin)
        context.stroke(innerR, with: .color(ink.opacity(0.62)), style: thin)

        // Soft inner-ear blush fill — the small pink dots inside the ears.
        context.fill(softTri(pt(20, 15), pt(22, 19), pt(24, 16)), with: .color(innerEar))
        context.fill(softTri(pt(44, 15), pt(42, 19), pt(40, 16)), with: .color(innerEar))

        // ─── Forehead "M" wisp (two tiny inverted curves between the ears) ───
        var tuft = Path()
        tuft.move(to: pt(29, 22))
        tuft.addQuadCurve(to: pt(32, 25.5), control: pt(30.5, 25))
        tuft.addQuadCurve(to: pt(35, 22), control: pt(33.5, 25))
        context.stroke(tuft, with: .color(ink.opacity(0.62)), style: hair)

        // ─── Whiskers (two per side, fade out below 36px) ───
        if size.width >= 36 {
            var wl = Path(); wl.move(to: pt(3, 32)); wl.addLine(to: pt(10, 32.5))
            var wl2 = Path(); wl2.move(to: pt(3.5, 36)); wl2.addLine(to: pt(10, 35.5))
            var wr = Path(); wr.move(to: pt(61, 32)); wr.addLine(to: pt(54, 32.5))
            var wr2 = Path(); wr2.move(to: pt(60.5, 36)); wr2.addLine(to: pt(54, 35.5))
            context.stroke(wl, with: .color(ink.opacity(0.42)), style: hair)
            context.stroke(wl2, with: .color(ink.opacity(0.32)), style: hair)
            context.stroke(wr, with: .color(ink.opacity(0.42)), style: hair)
            context.stroke(wr2, with: .color(ink.opacity(0.32)), style: hair)
        }

        // ─── Cheek blush dots ───
        if expression == .happy || expression == .celebrate || expression == .neutral || expression == .alert {
            context.fill(Path(ellipseIn: rect(16, 33, 4, 2.4)), with: .color(blush.opacity(0.72)))
            context.fill(Path(ellipseIn: rect(44, 33, 4, 2.4)), with: .color(blush.opacity(0.72)))
        }

        // ─── Eyes ───
        drawEyes(context, pt: pt, rect: rect, scale: s, ink: ink, fillHi: fillTop, blush: blush, expression: expression, stroke: stroke, thin: thin)

        // ─── Nose (small filled triangle, centered) ───
        var nose = Path()
        nose.move(to: pt(30.6, 33))
        nose.addLine(to: pt(33.4, 33))
        nose.addLine(to: pt(32, 34.8))
        nose.closeSubpath()
        context.fill(nose, with: .color(ink))

        // ─── Mouth ───
        drawMouth(context, pt: pt, scale: s, ink: ink, expression: expression, thin: thin)

        // ─── Decorations ───
        if expression == .celebrate {
            drawSpark(context, center: pt(6, 12), scale: s * 1.0, color: ink.opacity(0.75))
            drawSpark(context, center: pt(58, 11), scale: s * 0.7, color: ink.opacity(0.58))
            drawSpark(context, center: pt(58, 30), scale: s * 0.55, color: blush.opacity(0.75))
        }
        if expression == .sleep {
            drawCrescent(context, center: pt(56, 12), scale: s, color: ink.opacity(0.5))
        }
    }
}

// MARK: - Accent → palette derivation

private extension CatRendererMono {
    /// Slate-tinted version of the accent: pulls the hue toward a logo-style
    /// muted blue-gray, but keeps a hint of the user's accent so each accent
    /// produces a distinct line color rather than every cat looking identical.
    func slateInk(from accent: Color) -> Color {
        let rgb = accent.acRGB
        // Blend 70% slate-base + 30% accent. Slate base = #6F84A8 (logo line).
        let base = (r: 0.435, g: 0.518, b: 0.659)
        let r = base.r * 0.70 + rgb.r * 0.30
        let g = base.g * 0.70 + rgb.g * 0.30
        let b = base.b * 0.70 + rgb.b * 0.30
        // Slight darken to give the line presence.
        return Color(.sRGB, red: r * 0.92, green: g * 0.92, blue: b * 0.92, opacity: 1)
    }

    /// Warm cream fill, faintly tinted toward the accent so the body picks up
    /// the user's palette without going saturated. `dark` returns the gradient
    /// bottom (slightly more saturated than top).
    func creamFill(from accent: Color, dark: Bool) -> Color {
        let rgb = accent.acRGB
        // Cream base = #FAF1DC.
        let cream = (r: 0.980, g: 0.945, b: 0.863)
        // 88% cream + 12% accent — barely tints, just adds warmth/coolness.
        let r = cream.r * 0.88 + rgb.r * 0.12
        let g = cream.g * 0.88 + rgb.g * 0.12
        let b = cream.b * 0.88 + rgb.b * 0.12
        let darken: Double = dark ? 0.93 : 1.0
        return Color(.sRGB, red: r * darken, green: g * darken, blue: b * darken, opacity: 1)
    }

    /// Cheek/inner-ear blush — a softer, lighter version of the accent so it
    /// reads as "fresh pink" rather than a saturated tint.
    func blushTint(from accent: Color) -> Color {
        let rgb = accent.acRGB
        // Blend 50% accent + 50% soft pink (#F2A8A0) so cool accents still get a
        // pinkish cheek instead of a green / blue cheek that reads weird.
        let pink = (r: 0.949, g: 0.659, b: 0.627)
        let r = rgb.r * 0.50 + pink.r * 0.50
        let g = rgb.g * 0.50 + pink.g * 0.50
        let b = rgb.b * 0.50 + pink.b * 0.50
        return Color(.sRGB, red: r, green: g, blue: b, opacity: 1)
    }
}

// MARK: - Face

private extension CatRendererMono {
    func drawEyes(
        _ context: GraphicsContext,
        pt: (CGFloat, CGFloat) -> CGPoint,
        rect: (CGFloat, CGFloat, CGFloat, CGFloat) -> CGRect,
        scale s: CGFloat,
        ink: Color,
        fillHi: Color,
        blush: Color,
        expression: ACCatExpression,
        stroke: StrokeStyle,
        thin: StrokeStyle
    ) {
        switch expression {
        case .neutral, .alert:
            // Open dot eyes — AppIcon signature, with a tiny catch-light.
            let w: CGFloat = expression == .alert ? 3.2 : 2.8
            let h: CGFloat = expression == .alert ? 3.4 : 3.0
            context.fill(Path(ellipseIn: rect(21.4, 28.0, w, h)), with: .color(ink))
            context.fill(Path(ellipseIn: rect(39.4, 28.0, w, h)), with: .color(ink))
            context.fill(Path(ellipseIn: rect(22.6, 28.4, 1.0, 1.0)), with: .color(fillHi))
            context.fill(Path(ellipseIn: rect(40.6, 28.4, 1.0, 1.0)), with: .color(fillHi))

        case .happy:
            // Closed-arc smile-eyes (happier than the AppIcon's calm neutral).
            var left = Path()
            left.move(to: pt(20, 30))
            left.addQuadCurve(to: pt(25, 30), control: pt(22.5, 26.6))
            var right = Path()
            right.move(to: pt(39, 30))
            right.addQuadCurve(to: pt(44, 30), control: pt(41.5, 26.6))
            context.stroke(left, with: .color(ink), style: stroke)
            context.stroke(right, with: .color(ink), style: stroke)

        case .sleep:
            // Flat horizontal eyelid lines — fully closed.
            var left = Path()
            left.move(to: pt(20, 29.6))
            left.addLine(to: pt(25, 29.6))
            var right = Path()
            right.move(to: pt(39, 29.6))
            right.addLine(to: pt(44, 29.6))
            context.stroke(left, with: .color(ink), style: stroke)
            context.stroke(right, with: .color(ink), style: stroke)

        case .celebrate:
            // Sparkle-arc eyes + a tiny vertical shine tick above each.
            var left = Path()
            left.move(to: pt(20, 30))
            left.addQuadCurve(to: pt(25, 30), control: pt(22.5, 26.4))
            var right = Path()
            right.move(to: pt(39, 30))
            right.addQuadCurve(to: pt(44, 30), control: pt(41.5, 26.4))
            context.stroke(left, with: .color(ink), style: stroke)
            context.stroke(right, with: .color(ink), style: stroke)
            var tickL = Path(); tickL.move(to: pt(22.5, 24)); tickL.addLine(to: pt(22.5, 25.5))
            var tickR = Path(); tickR.move(to: pt(41.5, 24)); tickR.addLine(to: pt(41.5, 25.5))
            context.stroke(tickL, with: .color(ink.opacity(0.78)), style: thin)
            context.stroke(tickR, with: .color(ink.opacity(0.78)), style: thin)

        case .drift:
            // Small offset dots — bored / distracted.
            context.fill(Path(ellipseIn: rect(23, 29.5, 2.0, 2.0)), with: .color(ink))
            context.fill(Path(ellipseIn: rect(41, 29.5, 2.0, 2.0)), with: .color(ink))

        case .concern:
            // Slim ovals + slanted brows.
            context.fill(Path(ellipseIn: rect(21.4, 28.8, 2.4, 3.2)), with: .color(ink))
            context.fill(Path(ellipseIn: rect(40.2, 28.8, 2.4, 3.2)), with: .color(ink))
            var browL = Path(); browL.move(to: pt(19.5, 25)); browL.addLine(to: pt(25, 27))
            var browR = Path(); browR.move(to: pt(44.5, 25)); browR.addLine(to: pt(39, 27))
            context.stroke(browL, with: .color(ink), style: thin)
            context.stroke(browR, with: .color(ink), style: thin)
        }
    }

    func drawMouth(
        _ context: GraphicsContext,
        pt: (CGFloat, CGFloat) -> CGPoint,
        scale s: CGFloat,
        ink: Color,
        expression: ACCatExpression,
        thin: StrokeStyle
    ) {
        switch expression {
        case .happy, .celebrate:
            // Open-mouth smile: small filled curve below the nose.
            var smile = Path()
            smile.move(to: pt(29.5, 35.6))
            smile.addQuadCurve(to: pt(34.5, 35.6), control: pt(32, 39.4))
            smile.addLine(to: pt(29.5, 35.6))
            smile.closeSubpath()
            context.fill(smile, with: .color(ink.opacity(0.85)))
            context.stroke(smile, with: .color(ink), style: thin)
        case .concern:
            var path = Path()
            path.move(to: pt(30, 38))
            path.addQuadCurve(to: pt(34, 38), control: pt(32, 36))
            context.stroke(path, with: .color(ink), style: thin)
        case .drift:
            var path = Path()
            path.move(to: pt(30, 37.4))
            path.addLine(to: pt(34, 37.4))
            context.stroke(path, with: .color(ink), style: thin)
        default:
            // Logo "ω": two short curves meeting under the nose.
            var left = Path()
            left.move(to: pt(28.8, 35.2))
            left.addQuadCurve(to: pt(32, 37.4), control: pt(30.4, 37.6))
            var right = Path()
            right.move(to: pt(32, 37.4))
            right.addQuadCurve(to: pt(35.2, 35.2), control: pt(33.6, 37.6))
            context.stroke(left, with: .color(ink), style: thin)
            context.stroke(right, with: .color(ink), style: thin)
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

// MARK: - Color helpers

extension Color {
    /// Extract sRGB components. Falls back to NSColor on macOS.
    var acRGB: (r: Double, g: Double, b: Double) {
        let ns = NSColor(self).usingColorSpace(.sRGB)
        return (
            Double(ns?.redComponent ?? 0.5),
            Double(ns?.greenComponent ?? 0.5),
            Double(ns?.blueComponent ?? 0.5)
        )
    }
}

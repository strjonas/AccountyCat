//
//  CatRendererMono.swift
//  AC
//
//  Mono skin: the AppIcon language, rendered with care. Unified slate-blue
//  ink across all characters (so it always reads as "the logo"), with
//  character expression carried by warm cream fill tone, cheek blush, and
//  inner-ear color. Open dot eyes by default — the AppIcon's signature.
//

import SwiftUI

struct CatRendererMono: CatRenderer {
    func render(
        in context: GraphicsContext,
        size: CGSize,
        character: ACCharacter,
        expression: ACCatExpression
    ) {
        let s = min(size.width, size.height) / 64
        let ox = size.width / 2 - 32 * s
        let oy = size.height / 2 - 32 * s
        let p = MonoPalette(character)

        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: ox + x * s, y: oy + y * s)
        }
        func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
            CGRect(x: ox + x * s, y: oy + y * s, width: w * s, height: h * s)
        }

        let stroke = StrokeStyle(lineWidth: 1.4 * s, lineCap: .round, lineJoin: .round)
        let thin = StrokeStyle(lineWidth: 1.0 * s, lineCap: .round, lineJoin: .round)
        let hair = StrokeStyle(lineWidth: 0.85 * s, lineCap: .round, lineJoin: .round)

        // Soft ground shadow under the body (very faint, anchors the cat).
        context.fill(Path(ellipseIn: rect(19, 56, 26, 2.6)), with: .color(p.ink.opacity(0.10)))

        // ─── Body silhouette (the wide rounded curve under the chin, AppIcon style) ───
        var body = Path()
        body.move(to: pt(13, 47))
        body.addQuadCurve(to: pt(32, 58), control: pt(13, 60))
        body.addQuadCurve(to: pt(51, 47), control: pt(51, 60))
        body.closeSubpath()
        context.fill(body, with: .linearGradient(
            Gradient(colors: [p.fillTop, p.fillBottom]),
            startPoint: pt(32, 47),
            endPoint: pt(32, 58)
        ))
        context.stroke(body, with: .color(p.ink), style: stroke)

        // ─── Head silhouette (one continuous path matching the AppIcon shape) ───
        var head = Path()
        head.move(to: pt(13, 30))                                                    // left outer cheek
        head.addQuadCurve(to: pt(20, 10), control: pt(13, 15))                       // up the left ear
        head.addQuadCurve(to: pt(27, 24), control: pt(24, 15))                       // back down inner ear
        head.addQuadCurve(to: pt(37, 24), control: pt(32, 28))                       // valley between ears
        head.addQuadCurve(to: pt(44, 10), control: pt(40, 15))                       // up right ear inner
        head.addQuadCurve(to: pt(51, 30), control: pt(51, 15))                       // down right outer
        head.addQuadCurve(to: pt(53, 42), control: pt(54, 34))                       // right cheek
        head.addQuadCurve(to: pt(32, 50), control: pt(52, 50))                       // chin right
        head.addQuadCurve(to: pt(11, 42), control: pt(12, 50))                       // chin left
        head.addQuadCurve(to: pt(13, 30), control: pt(10, 34))                       // back to start
        head.closeSubpath()

        // Subtle vertical gradient — gives the cream fill genuine depth without
        // looking glossy. Read as "soft paper", not "plastic".
        context.fill(head, with: .linearGradient(
            Gradient(colors: [p.fillTop, p.fillBottom]),
            startPoint: pt(32, 10),
            endPoint: pt(32, 52)
        ))
        context.stroke(head, with: .color(p.ink), style: stroke)

        // ─── Inner ear (small soft accent triangles in character color) ───
        var innerL = Path()
        innerL.move(to: pt(20, 14))
        innerL.addQuadCurve(to: pt(25, 22), control: pt(23, 17))
        innerL.addQuadCurve(to: pt(20, 14), control: pt(20, 19))
        innerL.closeSubpath()
        var innerR = Path()
        innerR.move(to: pt(44, 14))
        innerR.addQuadCurve(to: pt(39, 22), control: pt(41, 17))
        innerR.addQuadCurve(to: pt(44, 14), control: pt(44, 19))
        innerR.closeSubpath()
        context.fill(innerL, with: .color(p.innerEar))
        context.fill(innerR, with: .color(p.innerEar))

        // ─── Forehead "M" wisp (the AppIcon's signature fur-tuft) ───
        var tuft = Path()
        tuft.move(to: pt(29, 23))
        tuft.addQuadCurve(to: pt(32, 27), control: pt(30.5, 26))
        tuft.addQuadCurve(to: pt(35, 23), control: pt(33.5, 26))
        context.stroke(tuft, with: .color(p.ink.opacity(0.58)), style: hair)

        // ─── Whiskers (faint, two per side; fade out at small sizes) ───
        if size.width >= 36 {
            var wl = Path(); wl.move(to: pt(6.5, 40)); wl.addLine(to: pt(13.5, 41))
            var wl2 = Path(); wl2.move(to: pt(7, 43.5)); wl2.addLine(to: pt(13.5, 43.2))
            var wr = Path(); wr.move(to: pt(57.5, 40)); wr.addLine(to: pt(50.5, 41))
            var wr2 = Path(); wr2.move(to: pt(57, 43.5)); wr2.addLine(to: pt(50.5, 43.2))
            context.stroke(wl, with: .color(p.ink.opacity(0.38)), style: hair)
            context.stroke(wl2, with: .color(p.ink.opacity(0.28)), style: hair)
            context.stroke(wr, with: .color(p.ink.opacity(0.38)), style: hair)
            context.stroke(wr2, with: .color(p.ink.opacity(0.28)), style: hair)
        }

        // ─── Cheek blush — small soft dots, only on positive expressions ───
        if expression == .happy || expression == .celebrate || expression == .neutral || expression == .alert {
            context.fill(Path(ellipseIn: rect(18, 39.5, 4.2, 2.2)), with: .color(p.blush.opacity(0.62)))
            context.fill(Path(ellipseIn: rect(41.8, 39.5, 4.2, 2.2)), with: .color(p.blush.opacity(0.62)))
        }

        // ─── Eyes ───
        drawEyes(context, pt: pt, rect: rect, scale: s, palette: p, expression: expression, stroke: stroke, thin: thin)

        // ─── Nose (small filled triangle) ───
        var nose = Path()
        nose.move(to: pt(30.6, 38))
        nose.addLine(to: pt(33.4, 38))
        nose.addLine(to: pt(32, 39.8))
        nose.closeSubpath()
        context.fill(nose, with: .color(p.ink))

        // ─── Mouth ───
        drawMouth(context, pt: pt, scale: s, palette: p, expression: expression, thin: thin)

        // ─── Decorations ───
        if expression == .celebrate {
            drawSpark(context, center: pt(8, 13), scale: s * 0.95, color: p.ink.opacity(0.75))
            drawSpark(context, center: pt(56, 12), scale: s * 0.65, color: p.ink.opacity(0.58))
            drawSpark(context, center: pt(55, 30), scale: s * 0.5, color: p.blush.opacity(0.75))
        }
        if expression == .sleep {
            drawCrescent(context, center: pt(54, 12), scale: s, color: p.ink.opacity(0.5))
        }
    }
}

// MARK: - Palette
//
// Unified slate-blue ink across all characters (so Mono *is* the logo).
// Character expression lives only in: fill warmth, inner-ear tint, blush tint.

private struct MonoPalette {
    let ink: Color           // line color — slate blue, unified
    let fillTop: Color       // top of body gradient (lighter)
    let fillBottom: Color    // bottom of body gradient (warmer)
    let innerEar: Color
    let blush: Color

    init(_ character: ACCharacter) {
        // Logo's slate-blue line, with a barely-perceptible character shift.
        switch character {
        case .mochi:
            ink = Color(hex: 0x7588AE)       // matches AppIcon line, faint warm bias
            fillTop = Color(hex: 0xFCF3E1)   // warm cream, lighter at top
            fillBottom = Color(hex: 0xF3E4C5) // slightly deeper warm cream at bottom
            innerEar = Color(hex: 0xF1B9A1)  // peach inner ear
            blush = Color(hex: 0xE89B7A)
        case .nova:
            ink = Color(hex: 0x7281B3)       // logo slate, faint cool bias
            fillTop = Color(hex: 0xF5F1FA)
            fillBottom = Color(hex: 0xE6DEEE)
            innerEar = Color(hex: 0xD0BFE5)
            blush = Color(hex: 0xB5A8E0)
        case .sage:
            ink = Color(hex: 0x7689AB)       // logo slate, faint neutral bias
            fillTop = Color(hex: 0xF4F6E5)
            fillBottom = Color(hex: 0xE6EBCC)
            innerEar = Color(hex: 0xD7CAA3)
            blush = Color(hex: 0xBFB07A)
        }
    }
}

// MARK: - Face

private extension CatRendererMono {
    func drawEyes(
        _ context: GraphicsContext,
        pt: (CGFloat, CGFloat) -> CGPoint,
        rect: (CGFloat, CGFloat, CGFloat, CGFloat) -> CGRect,
        scale s: CGFloat,
        palette p: MonoPalette,
        expression: ACCatExpression,
        stroke: StrokeStyle,
        thin: StrokeStyle
    ) {
        switch expression {
        case .neutral, .alert:
            // Open dot eyes — the AppIcon expression. Each has a tiny
            // catch-light so the cat looks awake, not flat.
            let w: CGFloat = expression == .alert ? 3.0 : 2.7
            let h: CGFloat = expression == .alert ? 3.4 : 3.0
            context.fill(Path(ellipseIn: rect(23.4, 32.0, w, h)), with: .color(p.ink))
            context.fill(Path(ellipseIn: rect(37.6, 32.0, w, h)), with: .color(p.ink))
            // Catch-lights (tiny ovals, top-right of each pupil).
            context.fill(Path(ellipseIn: rect(24.6, 32.4, 0.9, 0.9)), with: .color(p.fillTop))
            context.fill(Path(ellipseIn: rect(38.8, 32.4, 0.9, 0.9)), with: .color(p.fillTop))

        case .happy:
            // Closed-arc smile-eyes — happier than the AppIcon's calm neutral.
            var left = Path()
            left.move(to: pt(22, 33.6))
            left.addQuadCurve(to: pt(27, 33.6), control: pt(24.5, 30.2))
            var right = Path()
            right.move(to: pt(37, 33.6))
            right.addQuadCurve(to: pt(42, 33.6), control: pt(39.5, 30.2))
            context.stroke(left, with: .color(p.ink), style: stroke)
            context.stroke(right, with: .color(p.ink), style: stroke)

        case .sleep:
            // Flat horizontal eyelid lines — fully closed, calm.
            var left = Path()
            left.move(to: pt(22, 33.2))
            left.addLine(to: pt(27, 33.2))
            var right = Path()
            right.move(to: pt(37, 33.2))
            right.addLine(to: pt(42, 33.2))
            context.stroke(left, with: .color(p.ink), style: stroke)
            context.stroke(right, with: .color(p.ink), style: stroke)

        case .celebrate:
            // Sparkle-shape eyes (closed arcs with tiny radiating ticks).
            var left = Path()
            left.move(to: pt(22, 33.6))
            left.addQuadCurve(to: pt(27, 33.6), control: pt(24.5, 30.0))
            var right = Path()
            right.move(to: pt(37, 33.6))
            right.addQuadCurve(to: pt(42, 33.6), control: pt(39.5, 30.0))
            context.stroke(left, with: .color(p.ink), style: stroke)
            context.stroke(right, with: .color(p.ink), style: stroke)
            // Tiny tick above each eye — "shine" marks.
            var tickL = Path(); tickL.move(to: pt(24.5, 28)); tickL.addLine(to: pt(24.5, 29.5))
            var tickR = Path(); tickR.move(to: pt(39.5, 28)); tickR.addLine(to: pt(39.5, 29.5))
            context.stroke(tickL, with: .color(p.ink.opacity(0.78)), style: thin)
            context.stroke(tickR, with: .color(p.ink.opacity(0.78)), style: thin)

        case .drift:
            // Smaller offset dots — bored / distracted.
            context.fill(Path(ellipseIn: rect(24.6, 33.5, 2.0, 2.0)), with: .color(p.ink))
            context.fill(Path(ellipseIn: rect(39.2, 33.5, 2.0, 2.0)), with: .color(p.ink))

        case .concern:
            // Slim ovals shifted down + short slanted brows.
            context.fill(Path(ellipseIn: rect(23.4, 32.8, 2.2, 3.0)), with: .color(p.ink))
            context.fill(Path(ellipseIn: rect(38.4, 32.8, 2.2, 3.0)), with: .color(p.ink))
            var browL = Path(); browL.move(to: pt(22, 29)); browL.addLine(to: pt(27, 30.5))
            var browR = Path(); browR.move(to: pt(42, 29)); browR.addLine(to: pt(37, 30.5))
            context.stroke(browL, with: .color(p.ink), style: thin)
            context.stroke(browR, with: .color(p.ink), style: thin)
        }
    }

    func drawMouth(
        _ context: GraphicsContext,
        pt: (CGFloat, CGFloat) -> CGPoint,
        scale s: CGFloat,
        palette p: MonoPalette,
        expression: ACCatExpression,
        thin: StrokeStyle
    ) {
        switch expression {
        case .happy, .celebrate:
            // Open-mouth smile: small filled curve below the nose.
            var smile = Path()
            smile.move(to: pt(29.5, 41))
            smile.addQuadCurve(to: pt(34.5, 41), control: pt(32, 44.6))
            smile.addLine(to: pt(29.5, 41))
            smile.closeSubpath()
            context.fill(smile, with: .color(p.ink.opacity(0.78)))
            context.stroke(smile, with: .color(p.ink), style: thin)
        case .concern:
            var path = Path()
            path.move(to: pt(30, 43))
            path.addQuadCurve(to: pt(34, 43), control: pt(32, 41.5))
            context.stroke(path, with: .color(p.ink), style: thin)
        case .drift:
            var path = Path()
            path.move(to: pt(30, 42.4))
            path.addLine(to: pt(34, 42.4))
            context.stroke(path, with: .color(p.ink), style: thin)
        default:
            // Logo "ω": two short curves meeting under the nose.
            var left = Path()
            left.move(to: pt(28.8, 40.6))
            left.addQuadCurve(to: pt(32, 42.6), control: pt(30.5, 43.0))
            var right = Path()
            right.move(to: pt(32, 42.6))
            right.addQuadCurve(to: pt(35.2, 40.6), control: pt(33.5, 43.0))
            context.stroke(left, with: .color(p.ink), style: thin)
            context.stroke(right, with: .color(p.ink), style: thin)
        }
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

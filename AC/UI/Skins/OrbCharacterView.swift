//
//  OrbCharacterView.swift
//  AC
//
//  The abstract "Orb" companion, drawn entirely in SwiftUI. Because it is
//  procedural it ships all five expressions with zero bitmap assets — and it is
//  the answer for users who simply don't want an animal face on screen.
//
//  Design intent: a soft, glossy bead with a *minimal* face — two eyes only,
//  no mouth — so it reads as a calm presence rather than a cartoon. Expression
//  lives almost entirely in the eyes plus a gentle palette/scale shift.
//
//  CPU note: like the photographic portraits, the orb stays at true rest. We do
//  not run a continuous idle animation (that was a measured steady-state cost).
//  Liveliness comes from expression *transitions*, which animate when the mood
//  changes, not from a forever-loop.
//

import SwiftUI

struct OrbCharacterView: View {
    let expression: ACCatExpression
    let palette: CharacterPalette
    var size: CGFloat = 72
    var animating: Bool = true

    private var eyeColor: Color { palette.shadow.opacity(0.85) }

    /// The cats are transparent PNGs with built-in margin, so they read smaller
    /// than a full-bleed circle. Inset the orb to match their visual mass.
    private static let visualInset: CGFloat = 0.86

    var body: some View {
        ZStack {
            orbBody
            face
            if expression == .sleep {
                sleepZs
            }
        }
        .frame(width: size, height: size)
        .scaleEffect((expression == .sleep ? 0.96 : 1.0) * Self.visualInset)
        .saturation(expression == .concerned ? 0.7 : 1.0)
        .animation(animating ? .acSnap : nil, value: expression)
    }

    // MARK: - Body

    private var orbBody: some View {
        ZStack {
            baseCoat
            volumeLift
            ambientOcclusion
            rimLight
            primarySpecular
            secondarySparkle
            definingEdge
        }
        .shadow(color: palette.shadow.opacity(0.28), radius: size * 0.07, y: size * 0.04)
    }

    // Vertical light→deep gradient — an obvious light direction.
    private var baseCoat: some View {
        Circle().fill(
            LinearGradient(colors: [palette.orbTop, palette.orbBottom], startPoint: .top, endPoint: .bottom)
        )
    }

    // Radial lift from the upper-left makes the flat disc read as a 3D bead.
    private var volumeLift: some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: [palette.orbTop.opacity(0.9), .clear],
                    center: UnitPoint(x: 0.36, y: 0.32),
                    startRadius: 0,
                    endRadius: size * 0.62
                )
            )
            .blendMode(.softLight)
    }

    // Soft deep crescent hugging the bottom edge.
    private var ambientOcclusion: some View {
        Circle().fill(
            RadialGradient(
                colors: [.clear, palette.shadow.opacity(0.45)],
                center: UnitPoint(x: 0.5, y: 0.72),
                startRadius: size * 0.30,
                endRadius: size * 0.56
            )
        )
    }

    // A thin bright kiss along the lower edge.
    private var rimLight: some View {
        Circle().strokeBorder(
            AngularGradient(
                gradient: Gradient(stops: [
                    .init(color: .clear, location: 0.0),
                    .init(color: Color.white.opacity(0.55), location: 0.58),
                    .init(color: .clear, location: 0.85),
                ]),
                center: .center,
                angle: .degrees(70)
            ),
            lineWidth: max(1, size * 0.03)
        )
    }

    // Crisp, small specular highlight, upper-left.
    private var primarySpecular: some View {
        Ellipse()
            .fill(
                RadialGradient(
                    colors: [Color.white.opacity(0.85), .clear],
                    center: .center,
                    startRadius: 0,
                    endRadius: size * 0.16
                )
            )
            .frame(width: size * 0.30, height: size * 0.22)
            .rotationEffect(.degrees(-24))
            .offset(x: -size * 0.16, y: -size * 0.22)
            .blendMode(.screen)
    }

    private var secondarySparkle: some View {
        Circle()
            .fill(Color.white.opacity(0.7))
            .frame(width: size * 0.05, height: size * 0.05)
            .offset(x: size * 0.02, y: -size * 0.30)
            .blendMode(.screen)
    }

    private var definingEdge: some View {
        Circle().stroke(palette.accent.opacity(0.28), lineWidth: max(0.5, size * 0.012))
    }

    // MARK: - Face (two eyes, symmetric)

    private var face: some View {
        let eyeOffsetX = size * 0.18
        let eyeOffsetY = size * 0.02
        return HStack(spacing: eyeOffsetX * 2 - eyeSize.width) {
            EyeShape(style: eyeStyle)
                .stroke(eyeColor, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .frame(width: eyeSize.width, height: eyeSize.height)
            EyeShape(style: eyeStyle)
                .stroke(eyeColor, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .frame(width: eyeSize.width, height: eyeSize.height)
        }
        .offset(y: eyeOffsetY)
    }

    private var lineWidth: CGFloat { max(2, size * 0.055) }

    private var eyeSize: CGSize {
        switch eyeStyle {
        case .open:
            return CGSize(width: size * 0.07, height: size * 0.20)
        case .closedLine:
            return CGSize(width: size * 0.16, height: size * 0.02)
        case .happyArc, .sleepArc, .concernedArc:
            return CGSize(width: size * 0.18, height: size * 0.11)
        }
    }

    private var eyeStyle: EyeShape.Style {
        switch expression {
        case .neutral:   return .open
        case .blink:     return .closedLine
        case .happy:     return .happyArc
        case .sleep:     return .sleepArc
        case .concerned: return .concernedArc
        }
    }

    // MARK: - Sleep z's

    private var sleepZs: some View {
        Text("z")
            .font(.system(size: size * 0.22, weight: .bold, design: .rounded))
            .foregroundStyle(eyeColor.opacity(0.55))
            .offset(x: size * 0.30, y: -size * 0.30)
    }
}

// MARK: - Eye shape

private struct EyeShape: Shape {
    enum Style {
        case open          // calm vertical capsule
        case closedLine    // blink: a short flat line
        case happyArc      // ∩ — upward smile-eye
        case sleepArc      // ∪ — gentle closed lid
        case concernedArc  // shallow downward tilt
    }

    let style: Style

    func path(in rect: CGRect) -> Path {
        var path = Path()
        switch style {
        case .open:
            path.addRoundedRect(in: rect, cornerSize: CGSize(width: rect.width / 2, height: rect.width / 2))
        case .closedLine:
            path.move(to: CGPoint(x: rect.minX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        case .happyArc:
            // Arc that bows upward in the middle (happy squint ∩).
            path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.addQuadCurve(
                to: CGPoint(x: rect.maxX, y: rect.maxY),
                control: CGPoint(x: rect.midX, y: rect.minY - rect.height * 0.4)
            )
        case .sleepArc:
            // Arc that bows downward (closed eyelid ∪).
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addQuadCurve(
                to: CGPoint(x: rect.maxX, y: rect.minY),
                control: CGPoint(x: rect.midX, y: rect.maxY + rect.height * 0.4)
            )
        case .concernedArc:
            // Shallow, slightly downward — a worried softness.
            path.move(to: CGPoint(x: rect.minX, y: rect.midY))
            path.addQuadCurve(
                to: CGPoint(x: rect.maxX, y: rect.midY),
                control: CGPoint(x: rect.midX, y: rect.maxY)
            )
        }
        return path
    }
}

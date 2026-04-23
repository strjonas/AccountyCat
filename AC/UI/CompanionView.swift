//
//  CompanionView.swift
//  AC
//
//  The floating companion orb. Minimal at rest, alive with micro-animations.
//  Speech bubble appears above it when a nudge fires — no separate panel.
//

import SwiftUI

// MARK: - CompanionView

struct CompanionView: View {
    @EnvironmentObject private var controller: AppController

    /// Called on a clean tap — opens the popover from the orb.
    var onTap: (() -> Void)?

    // Animation state
    @State private var isBlinking = false
    @State private var breathScale: CGFloat = 1.0
    @State private var nudgeScale: CGFloat = 1.0
    @State private var headTilt: Double = 0

    // One-shot tooltip
    @AppStorage("acOrbTooltipShown") private var tooltipShown = false
    @State private var showTooltip = false

    /// Orb diameter scaled to the current screen size so it feels proportional
    /// on everything from a 14" MacBook to a large external display.
    private var orbDiameter: CGFloat {
        let h = NSScreen.main?.frame.height ?? 900
        // ~7 % of screen height, clamped to a comfortable range
        return min(max((h * 0.070).rounded(), 58), 84)
    }

    var body: some View {
        VStack(spacing: 8) {

            // ── Speech bubble (appears only while latestNudge is set) ──
            if let nudge = controller.latestNudge {
                SpeechBubble(text: nudge)
                    .frame(maxWidth: 188)
                    .transition(.asymmetric(
                        insertion: .scale(scale: 0.82, anchor: .bottom)
                            .combined(with: .opacity),
                        removal: .opacity.combined(with: .scale(scale: 0.92, anchor: .bottom))
                    ))
            }

            Spacer(minLength: 0)

            // ── Cat orb ──
            ZStack {
                if controller.companionMood == .nudging || controller.companionMood == .escalated {
                    PulseRing(color: ringColor)
                        .frame(width: orbDiameter, height: orbDiameter)
                }

                Circle()
                    .fill(orbGradient)
                    .overlay(Circle().stroke(Color.white.opacity(0.52), lineWidth: 1))
                    .shadow(color: orbShadow.opacity(0.22), radius: 14, y: 7)

                CatFaceView(mood: controller.companionMood, isBlinking: isBlinking)
                    .rotationEffect(.degrees(headTilt))
                    .padding(10)
            }
            .frame(width: orbDiameter, height: orbDiameter)
            .scaleEffect(breathScale * nudgeScale)
            .opacity(controller.companionMood == .paused ? 0.42 : 1.0)
            .animation(.easeInOut(duration: 0.5), value: controller.companionMood == .paused)
            // Tap opens popover — placed here so speech bubble buttons are NOT intercepted
            .onTapGesture { onTap?() }
            // Edge-peek: clip to the visible half ONLY when snapped to a border.
            // When not peeking, skip clipping entirely so the soft drop shadow
            // around the orb doesn't get sliced at the bounding-box edges
            // (which otherwise produces a faint square halo behind the cat).
            .modifier(ConditionalPeekClip(edge: controller.peekingEdge))
        }
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .overlay(alignment: .bottom) {
            // One-shot hint shown on first launch so users know the orb is tappable
            if showTooltip {
                OrbTooltip()
                    .offset(y: -ACD.orbDiameter - 12)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .scale(scale: 0.88, anchor: .bottom)),
                        removal:   .opacity
                    ))
            }
        }
        .onAppear {
            startBreathing()
            startBlinking()
            maybeShowTooltip()
        }
        .onChange(of: controller.companionMood) { _, mood in
            updateAnimations(for: mood)
        }
        .animation(.acFade, value: controller.latestNudge)
        .animation(.acFade, value: showTooltip)
        .acAccent(for: controller.state.character)
    }

    // MARK: - Mood helpers

    private var orbGradient: LinearGradient {
        let ch = controller.state.character
        switch controller.companionMood {
        case .setup, .idle, .watching:
            return LinearGradient(
                colors: [ch.orbTopColor, ch.orbBottomColor],
                startPoint: .topLeading, endPoint: .bottomTrailing)
        case .nudging:
            return LinearGradient(
                colors: [ch.nudgingOrbTopColor, ch.nudgingOrbBottomColor],
                startPoint: .topLeading, endPoint: .bottomTrailing)
        case .escalated:
            return LinearGradient(
                colors: [ch.nudgingOrbTopColor, ch.escalatedRingColor.opacity(0.80)],
                startPoint: .topLeading, endPoint: .bottomTrailing)
        case .paused:
            return LinearGradient(
                colors: [Color(red: 0.88, green: 0.88, blue: 0.88),
                         Color(red: 0.78, green: 0.78, blue: 0.78)],
                startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }

    private var orbShadow: Color {
        let ch = controller.state.character
        switch controller.companionMood {
        case .nudging:   return ch.ringColor
        case .escalated: return ch.escalatedRingColor
        default:         return ch.shadowColor
        }
    }

    private var ringColor: Color {
        controller.companionMood == .escalated
            ? controller.state.character.escalatedRingColor
            : controller.state.character.ringColor
    }


    // MARK: - Animations

    private func startBreathing() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            withAnimation(.easeInOut(duration: 3.8).repeatForever(autoreverses: true)) {
                breathScale = 1.026
            }
        }
    }

    private func startBlinking() {
        Task { @MainActor in
            while true {
                let delay = Double.random(in: 5...13)
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))

                // Blink
                withAnimation(.linear(duration: 0.07)) { isBlinking = true }
                try? await Task.sleep(nanoseconds: 120_000_000)
                withAnimation(.linear(duration: 0.08)) { isBlinking = false }

                // Occasional double-blink
                if Bool.random() {
                    try? await Task.sleep(nanoseconds: 220_000_000)
                    withAnimation(.linear(duration: 0.07)) { isBlinking = true }
                    try? await Task.sleep(nanoseconds: 110_000_000)
                    withAnimation(.linear(duration: 0.08)) { isBlinking = false }
                }
            }
        }
    }

    private func updateAnimations(for mood: CompanionMood) {
        withAnimation(.acSpring) {
            headTilt  = mood == .nudging ? 5 : 0
            nudgeScale = mood == .nudging ? 1.16 : 1.0
        }
    }

    private func maybeShowTooltip() {
        guard !tooltipShown else { return }
        tooltipShown = true
        // Brief delay so the orb is settled before the hint pops up
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            withAnimation(.acFade) { showTooltip = true }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
            withAnimation(.acFade) { showTooltip = false }
        }
    }
}

// MARK: - Orb Tooltip

/// One-shot hint pill: "Drag me anywhere · tap to open settings"
/// Shown for ~4 seconds on first launch, then never again.
private struct OrbTooltip: View {
    var body: some View {
        Text("Drag me  ·  tap to open")
            .font(.ac(11, weight: .medium))
            .foregroundStyle(Color.acTextPrimary.opacity(0.85))
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(.ultraThinMaterial)
                    .overlay(Capsule().stroke(Color.white.opacity(0.45), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
            )
    }
}

// MARK: - Pulse Ring

private struct PulseRing: View {
    let color: Color
    @State private var scale: CGFloat = 1.0
    @State private var opacity: Double = 0.65

    var body: some View {
        Circle()
            .stroke(color, lineWidth: 2.5)
            .scaleEffect(scale)
            .opacity(opacity)
            .onAppear {
                withAnimation(.easeOut(duration: 1.8).repeatForever(autoreverses: false)) {
                    scale   = 1.60
                    opacity = 0
                }
            }
    }
}

// MARK: - Cat Face

struct CatFaceView: View {
    let mood: CompanionMood
    let isBlinking: Bool

    var body: some View {
        ZStack {
            // ── Ears (behind face circle) ──
            ACEarShape(left: true)
                .fill(Color.acFurDark)
                .frame(width: 26, height: 22)
                .offset(x: -21, y: -28)

            ACEarInner(left: true)
                .fill(Color.acBlush.opacity(0.60))
                .frame(width: 15, height: 13)
                .offset(x: -21, y: -28)

            ACEarShape(left: false)
                .fill(Color.acFurDark)
                .frame(width: 26, height: 22)
                .offset(x: 21, y: -28)

            ACEarInner(left: false)
                .fill(Color.acBlush.opacity(0.60))
                .frame(width: 15, height: 13)
                .offset(x: 21, y: -28)

            // ── Face ──
            Circle()
                .fill(Color.acFur)

            // ── Blush ──
            Ellipse()
                .fill(Color.acBlush.opacity(0.75))
                .frame(width: 15, height: 9)
                .offset(x: -20, y: 9)
                .blur(radius: 0.6)

            Ellipse()
                .fill(Color.acBlush.opacity(0.75))
                .frame(width: 15, height: 9)
                .offset(x: 20, y: 9)
                .blur(radius: 0.6)

            // ── Eyes ──
            HStack(spacing: 17) {
                ACEye(mood: mood, isBlinking: isBlinking, mirrored: false)
                ACEye(mood: mood, isBlinking: isBlinking, mirrored: true)
            }
            .offset(y: -5)

            // ── Nose ──
            ACNose()
                .fill(Color.acNoseColor)
                .frame(width: 8, height: 5.5)
                .offset(y: 8)

            // ── Whiskers ──
            ACWhiskers()
                .stroke(Color.acWhiskerColor, lineWidth: 1.3)

            // ── Mouth ──
            ACMouth(mood: mood)
                .stroke(Color.acWhiskerColor, lineWidth: 1.5)
                .frame(width: 18, height: 10)
                .offset(y: 16)
        }
    }
}

// MARK: - Eye

private struct ACEye: View {
    let mood: CompanionMood
    let isBlinking: Bool
    var mirrored: Bool = false

    private var width: CGFloat { mood == .escalated ? 9.5 : 10.5 }

    private var height: CGFloat {
        if isBlinking { return 1.5 }
        switch mood {
        case .paused:   return 3.5
        case .nudging:  return 13.5
        case .escalated: return 10.5
        default:        return 12.5
        }
    }

    var body: some View {
        ZStack {
            // Iris
            Capsule()
                .frame(width: width, height: height)
                .foregroundStyle(Color.acEyeColor)

            // Sparkle highlight — hidden during blink so the flat line reads cleanly.
            if !isBlinking && mood != .paused {
                Circle()
                    .fill(Color.white.opacity(0.95))
                    .frame(width: 2.6, height: 2.6)
                    .offset(x: mirrored ? 1.6 : -1.6, y: -height / 3.2)
            }
        }
        .animation(.linear(duration: 0.08), value: isBlinking)
    }
}

// MARK: - Shapes

private struct ACEarShape: Shape {
    let left: Bool
    func path(in rect: CGRect) -> Path {
        var p = Path()
        if left {
            p.move(to: CGPoint(x: rect.maxX, y: rect.maxY))
            p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            p.addLine(to: CGPoint(x: rect.midX + 2, y: rect.minY))
        } else {
            p.move(to: CGPoint(x: rect.minX, y: rect.maxY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            p.addLine(to: CGPoint(x: rect.midX - 2, y: rect.minY))
        }
        p.closeSubpath()
        return p
    }
}

private struct ACEarInner: Shape {
    let left: Bool
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let inset: CGFloat = 3
        if left {
            p.move(to: CGPoint(x: rect.maxX - inset, y: rect.maxY))
            p.addLine(to: CGPoint(x: rect.minX + inset, y: rect.maxY))
            p.addLine(to: CGPoint(x: rect.midX + 1, y: rect.minY + 3))
        } else {
            p.move(to: CGPoint(x: rect.minX + inset, y: rect.maxY))
            p.addLine(to: CGPoint(x: rect.maxX - inset, y: rect.maxY))
            p.addLine(to: CGPoint(x: rect.midX - 1, y: rect.minY + 3))
        }
        p.closeSubpath()
        return p
    }
}

private struct ACNose: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.midX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.closeSubpath()
        return p
    }
}

private struct ACWhiskers: Shape {
    func path(in rect: CGRect) -> Path {
        let cx = rect.midX
        let cy = rect.midY
        var p = Path()
        // Left
        p.move(to: CGPoint(x: cx - 10, y: cy + 8));  p.addLine(to: CGPoint(x: cx - 32, y: cy + 4))
        p.move(to: CGPoint(x: cx - 10, y: cy + 13)); p.addLine(to: CGPoint(x: cx - 32, y: cy + 16))
        // Right
        p.move(to: CGPoint(x: cx + 10, y: cy + 8));  p.addLine(to: CGPoint(x: cx + 32, y: cy + 4))
        p.move(to: CGPoint(x: cx + 10, y: cy + 13)); p.addLine(to: CGPoint(x: cx + 32, y: cy + 16))
        return p
    }
}

private struct ACMouth: Shape {
    let mood: CompanionMood
    func path(in rect: CGRect) -> Path {
        var p = Path()
        switch mood {
        case .escalated:
            // Slightly worried frown
            p.move(to: CGPoint(x: rect.minX, y: rect.midY))
            p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.midY),
                           control: CGPoint(x: rect.midX, y: rect.minY - 2))
        case .nudging:
            // Big warm smile
            p.move(to: CGPoint(x: rect.minX, y: rect.midY - 2))
            p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.midY - 2),
                           control: CGPoint(x: rect.midX, y: rect.maxY + 7))
        default:
            // Gentle resting smile
            p.move(to: CGPoint(x: rect.minX, y: rect.midY - 1))
            p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.midY - 1),
                           control: CGPoint(x: rect.midX, y: rect.maxY + 4))
        }
        return p
    }
}

// MARK: - Orb Peek Clip

/// Applies a half-frame clip ONLY when the orb is peeking over a screen edge.
/// When not peeking it adds no clip, which preserves the orb's soft drop shadow.
private struct ConditionalPeekClip: ViewModifier {
    let edge: NSRectEdge?

    func body(content: Content) -> some View {
        if let edge {
            content.clipShape(OrbPeekClip(edge: edge))
        } else {
            content
        }
    }
}

/// Clips the orb to its visible half when it's snapped to a screen edge.
/// `edge` is an NSRectEdge: .minX = left, .maxX = right, .minY = bottom (screen-coords bottom).
private struct OrbPeekClip: Shape {
    var edge: NSRectEdge

    func path(in rect: CGRect) -> Path {
        switch edge {
        case .minX:
            // Left edge — keep only the right half
            return Path(CGRect(x: rect.midX, y: rect.minY, width: rect.width / 2, height: rect.height))
        case .maxX:
            // Right edge — keep only the left half
            return Path(CGRect(x: rect.minX, y: rect.minY, width: rect.width / 2, height: rect.height))
        case .minY:
            // Bottom edge — keep only the top half
            return Path(CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height / 2))
        default:
            return Path(rect)
        }
    }
}

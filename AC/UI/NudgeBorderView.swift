//
//  NudgeBorderView.swift
//  AC
//
//  Full-screen amber glow border that appears when a nudge fires.
//  Inspired by Apple Intelligence's focus ring, but in AC's warm palette.
//  Transparent centre so the user can see their screen; only the edges glow.
//

import SwiftUI

// MARK: - NudgeBorderView

struct NudgeBorderView: View {
    /// Drives the entrance/exit animation — true = visible.
    let visible: Bool
    /// Color the glow border should adopt. Falls back to Mochi caramel.
    var tint: Color = Color(red: 0.97, green: 0.68, blue: 0.22)
    var ringTint: Color = Color(red: 0.98, green: 0.76, blue: 0.35)

    @State private var pulse: CGFloat = 0.0

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // Outer accent glow — fills the whole window but is clipped to a thick border
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [
                                ringTint.opacity(0.90),
                                tint.opacity(0.80),
                                ringTint.opacity(0.90),
                            ],
                            startPoint: UnitPoint(x: 0.5 + 0.5 * cos(pulse * .pi * 2),
                                                  y: 0.5 + 0.5 * sin(pulse * .pi * 2)),
                            endPoint: UnitPoint(x: 0.5 - 0.5 * cos(pulse * .pi * 2),
                                                y: 0.5 - 0.5 * sin(pulse * .pi * 2))
                        ),
                        lineWidth: 6
                    )
                    .padding(3)
                    // soft glow bloom outside
                    .shadow(color: tint.opacity(0.55), radius: 18)
                    .shadow(color: tint.opacity(0.25), radius: 40)

                // Inner faint vignette on edges only — clear in centre
                Rectangle()
                    .fill(
                        RadialGradient(
                            colors: [
                                Color.clear,
                                tint.opacity(0.08),
                            ],
                            center: .center,
                            startRadius: min(geo.size.width, geo.size.height) * 0.30,
                            endRadius: max(geo.size.width, geo.size.height) * 0.72
                        )
                    )
                    .allowsHitTesting(false)
            }
        }
        .ignoresSafeArea()
        .opacity(visible ? 1.0 : 0.0)
        .animation(.easeInOut(duration: 0.38), value: visible)
        .onAppear { startPulse() }
    }

    // MARK: - Animation

    private func startPulse() {
        withAnimation(
            .linear(duration: 4.0)
            .repeatForever(autoreverses: false)
        ) {
            pulse = 1.0
        }
    }
}

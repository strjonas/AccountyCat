//
//  CompanionEntranceView.swift
//  AC
//
//  ~1 second stardust burst that plays whenever the companion appears.
//  Draws attention to the orb so users always know where AC is.
//

import SwiftUI

struct CompanionEntranceView: View {
    let accent: Color
    let onComplete: (() -> Void)?

    @State private var startTime = Date()
    @State private var completed = false

    private let particleCount = 40
    private let duration: Double = 1.0

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 60, paused: false)) { timeline in
            Canvas { context, size in
                guard !completed else { return }

                let t = timeline.date.timeIntervalSince(startTime)
                guard t < duration + 0.3 else {
                    DispatchQueue.main.async {
                        if !completed {
                            completed = true
                            onComplete?()
                        }
                    }
                    return
                }

                let center = CGPoint(x: size.width / 2, y: size.height / 2)

                // ── Central glow ──
                let glowProgress = min(1, t / 0.35)
                let glowAlpha = glowProgress < 0.4
                    ? glowProgress / 0.4
                    : max(0, 1 - (glowProgress - 0.4) / 0.6)
                var glow = Path()
                glow.addEllipse(in: CGRect(
                    x: center.x - 35, y: center.y - 35,
                    width: 70, height: 70
                ))
                context.fill(glow, with: .color(accent.opacity(glowAlpha * 0.18)))

                // ── Particles ──
                for i in 0..<particleCount {
                    let stagger = Double(i % 7) * 0.02
                    let progress = max(0, min(1, (t - stagger) / 0.9))
                    if progress <= 0 { continue }

                    let angle = Double(i) * 2.39996 // golden angle
                    let baseDist: CGFloat = 45 + CGFloat(i % 6) * 20
                    let distance = CGFloat(progress) * baseDist
                    let px = center.x + CGFloat(cos(angle)) * distance
                    let py = center.y + CGFloat(sin(angle)) * distance

                    let alpha: Double
                    if progress < 0.12 {
                        alpha = progress / 0.12
                    } else if progress > 0.55 {
                        alpha = max(0, 1 - (progress - 0.55) / 0.45)
                    } else {
                        alpha = 1
                    }

                    let particleSize = 2 + CGFloat(i % 5) * 2.2

                    let color: Color
                    switch i % 5 {
                    case 0: color = accent
                    case 1: color = .white
                    case 2: color = Color.acAmber
                    case 3: color = accent.opacity(0.7)
                    default: color = Color.acBlush
                    }

                    if i % 4 == 0 {
                        drawStar(
                            in: &context,
                            center: CGPoint(x: px, y: py),
                            size: particleSize,
                            color: color.opacity(alpha)
                        )
                    } else {
                        var path = Path()
                        path.addEllipse(in: CGRect(
                            x: px - particleSize / 2,
                            y: py - particleSize / 2,
                            width: particleSize,
                            height: particleSize
                        ))
                        context.fill(path, with: .color(color.opacity(alpha)))
                    }
                }

                // ── Expanding ring 1 ──
                let ringProgress = min(1, t / 0.75)
                let ringRadius = CGFloat(ringProgress) * 95
                let ringAlpha = max(0, 1 - ringProgress)
                var ring = Path()
                ring.addEllipse(in: CGRect(
                    x: center.x - ringRadius,
                    y: center.y - ringRadius,
                    width: ringRadius * 2,
                    height: ringRadius * 2
                ))
                context.stroke(
                    ring,
                    with: .color(accent.opacity(ringAlpha * 0.4)),
                    lineWidth: 2
                )

                // ── Expanding ring 2 (slower, white) ──
                let r2p = min(1, max(0, (t - 0.12) / 0.85))
                let r2r = CGFloat(r2p) * 75
                let r2a = max(0, 1 - r2p)
                var ring2 = Path()
                ring2.addEllipse(in: CGRect(
                    x: center.x - r2r,
                    y: center.y - r2r,
                    width: r2r * 2,
                    height: r2r * 2
                ))
                context.stroke(
                    ring2,
                    with: .color(Color.white.opacity(r2a * 0.25)),
                    lineWidth: 1
                )
            }
        }
        .frame(width: 300, height: 300)
        .onAppear { startTime = Date() }
    }

    private func drawStar(
        in context: inout GraphicsContext,
        center: CGPoint,
        size: CGFloat,
        color: Color
    ) {
        let h = size / 2
        var path = Path()
        path.move(to: CGPoint(x: center.x, y: center.y - h))
        path.addLine(to: CGPoint(x: center.x + h * 0.25, y: center.y - h * 0.25))
        path.addLine(to: CGPoint(x: center.x + h, y: center.y))
        path.addLine(to: CGPoint(x: center.x + h * 0.25, y: center.y + h * 0.25))
        path.addLine(to: CGPoint(x: center.x, y: center.y + h))
        path.addLine(to: CGPoint(x: center.x - h * 0.25, y: center.y + h * 0.25))
        path.addLine(to: CGPoint(x: center.x - h, y: center.y))
        path.addLine(to: CGPoint(x: center.x - h * 0.25, y: center.y - h * 0.25))
        path.closeSubpath()
        context.fill(path, with: .color(color))
    }
}

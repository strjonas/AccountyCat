//
//  NudgeView.swift
//  AC
//
//  Refreshed nudge tooltip — 240pt wide, subtle accent indicator, mini cat avatar,
//  persona name, message, two action buttons. Auto-dismisses after 12s.
//

import SwiftUI

struct SpeechBubble: View {
    let text: String
    @EnvironmentObject private var controller: AppController
    @Environment(\.acAccent) private var accent
    @Environment(\.acAccentLight) private var accentLight
    @Environment(\.colorScheme) private var colorScheme

    /// Counts down from 12; when it hits 0 the bubble auto-dismisses.
    @State private var secondsRemaining = 12
    @State private var timer: Timer? = nil

    var body: some View {
        VStack(spacing: 0) {
            // Body
            VStack(alignment: .leading, spacing: 10) {
                // Header: accent indicator + mini cat + name
                HStack(spacing: 8) {
                    Capsule()
                        .fill(accent)
                        .frame(width: 7, height: 7)

                    CatView(
                        character: controller.state.character,
                        expression: .concerned,
                        size: 24,
                        animating: false
                    )
                    Text(controller.state.character.displayName)
                        .font(.ac(11, weight: .semibold))
                        .foregroundStyle(accent)
                    Spacer()
                }

                // Message
                Text(text)
                    .font(.ac(13, weight: .medium))
                    .foregroundStyle(bubbleTextColor)
                    .shadow(
                        color: colorScheme == .dark
                            ? .black.opacity(0.35)
                            : .white.opacity(0.55),
                        radius: 1, x: 0, y: 0.5
                    )
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel("Nudge message")

                // Action buttons
                HStack(spacing: 8) {
                    Button {
                        stopTimer()
                        controller.rateNudge(positive: true, nudgeText: text)
                        controller.latestNudge = nil
                    } label: {
                        Text("back to work")
                            .font(.ac(11, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(
                                        LinearGradient(
                                            colors: [accentLight, accent.opacity(0.92)],
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        )
                                    )
                                    .overlay(
                                        Capsule(style: .continuous)
                                            .stroke(Color.white.opacity(0.28), lineWidth: 0.5)
                                    )
                                    .shadow(color: accent.opacity(0.20), radius: 5, y: 1.5)
                            )
                    }
                    .buttonStyle(.plain)

                    Button {
                        stopTimer()
                        controller.rateNudge(positive: false, nudgeText: text)
                        controller.latestNudge = nil
                    } label: {
                        Text("it's fine")
                            .font(.ac(11, weight: .medium))
                            .foregroundStyle(Color.acTextPrimary.opacity(0.72))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(Color.acSurface)
                                    .overlay(Capsule(style: .continuous).stroke(Color.acHairline, lineWidth: 1))
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(bubbleBackground)

            // Downward tail — rotated square for a clean diamond point
            DiamondTail()
                .fill(tailColor)
                .frame(width: 12, height: 12)
                .rotationEffect(.degrees(45))
                .offset(y: -6)
                .overlay(
                    DiamondTail()
                        .stroke(Color.acHairline.opacity(0.4), lineWidth: 0.5)
                        .frame(width: 12, height: 12)
                        .rotationEffect(.degrees(45))
                        .offset(y: -6)
                )
        }
        .frame(maxWidth: 240)
        .onAppear { startAutoDismiss() }
        .onDisappear { stopTimer() }
        .onChange(of: text) { _, _ in
            stopTimer()
            secondsRemaining = 12
            startAutoDismiss()
        }
    }

    // MARK: - Auto-dismiss timer

    private func startAutoDismiss() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            Task { @MainActor in
                if self.secondsRemaining > 1 {
                    self.secondsRemaining -= 1
                } else {
                    self.stopTimer()
                    withAnimation(.acFade) {
                        self.controller.latestNudge = nil
                    }
                }
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - Colors

    private var bubbleTextColor: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.96)
            : Color.black.opacity(0.86)
    }

    private var tailColor: Color {
        colorScheme == .dark
            ? Color(red: 0.16, green: 0.16, blue: 0.18)
            : Color(red: 0.99, green: 0.96, blue: 0.91)
    }

    private var bubbleBackground: some View {
        ZStack {
            if controller.state.glassEffectActive {
                // Opaque backing guarantees text contrast over any wallpaper/app
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(tailColor.opacity(colorScheme == .dark ? 0.45 : 0.55))

                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.thinMaterial)

                // Warm top-edge glow
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                accent.opacity(colorScheme == .dark ? 0.22 : 0.18),
                                accent.opacity(0.04),
                                Color.clear
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )

                // Soft edge stroke
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(accent.opacity(colorScheme == .dark ? 0.25 : 0.18), lineWidth: 0.5)
            } else {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(tailColor.opacity(colorScheme == .dark ? 0.95 : 0.97))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(accent.opacity(colorScheme == .dark ? 0.18 : 0.12), lineWidth: 0.5)
                    )
            }
        }
        .shadow(color: accent.opacity(colorScheme == .dark ? 0.18 : 0.10), radius: 20, y: 6)
    }
}

// MARK: - Status Bar Nudge

/// Non-interactive nudge notification anchored near the menu bar.
/// Used when the orb is hidden (displayMode == .menuBar).
/// Auto-dismisses after 7 seconds; no action buttons — user opens popover to interact.
struct StatusBarNudgeView: View {
    let text: String
    let onRate: ((Bool) -> Void)?
    @EnvironmentObject private var controller: AppController
    @Environment(\.acAccent) private var accent
    @Environment(\.acAccentLight) private var accentLight
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            // Upward tail (points toward status bar)
            DiamondTail()
                .fill(tailColor)
                .frame(width: 12, height: 12)
                .rotationEffect(.degrees(45))
                .offset(y: 6)
                .overlay(
                    DiamondTail()
                        .stroke(Color.acHairline.opacity(0.4), lineWidth: 0.5)
                        .frame(width: 12, height: 12)
                        .rotationEffect(.degrees(45))
                        .offset(y: 6)
                )

            // Body — header, message, action buttons
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Capsule()
                        .fill(accent)
                        .frame(width: 7, height: 7)

                    CatView(
                        character: controller.state.character,
                        expression: .concerned,
                        size: 24,
                        animating: false
                    )
                    Text(controller.state.character.displayName)
                        .font(.ac(11, weight: .semibold))
                        .foregroundStyle(accent)
                    Spacer()
                }

                Text(text)
                    .font(.ac(13, weight: .medium))
                    .foregroundStyle(bubbleTextColor)
                    .shadow(
                        color: colorScheme == .dark
                            ? .black.opacity(0.35)
                            : .white.opacity(0.55),
                        radius: 1, x: 0, y: 0.5
                    )
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if onRate != nil {
                    HStack(spacing: 8) {
                        Button {
                            onRate?(true)
                        } label: {
                            Text("back to work")
                                .font(.ac(11, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(
                                    Capsule(style: .continuous)
                                        .fill(
                                            LinearGradient(
                                                colors: [accentLight, accent.opacity(0.92)],
                                                startPoint: .topLeading,
                                                endPoint: .bottomTrailing
                                            )
                                        )
                                        .overlay(
                                            Capsule(style: .continuous)
                                                .stroke(Color.white.opacity(0.28), lineWidth: 0.5)
                                        )
                                        .shadow(color: accent.opacity(0.20), radius: 5, y: 1.5)
                                )
                        }
                        .buttonStyle(.plain)

                        Button {
                            onRate?(false)
                        } label: {
                            Text("it's fine")
                                .font(.ac(11, weight: .medium))
                                .foregroundStyle(Color.acTextPrimary.opacity(0.72))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(
                                    Capsule(style: .continuous)
                                        .fill(Color.acSurface)
                                        .overlay(Capsule(style: .continuous).stroke(Color.acHairline, lineWidth: 1))
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(bubbleBackground)
        }
        .frame(maxWidth: 320)
    }

    private var bubbleTextColor: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.96)
            : Color.black.opacity(0.86)
    }

    private var tailColor: Color {
        colorScheme == .dark
            ? Color(red: 0.16, green: 0.16, blue: 0.18)
            : Color(red: 0.99, green: 0.96, blue: 0.91)
    }

    private var bubbleBackground: some View {
        ZStack {
            if controller.state.glassEffectActive {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(tailColor.opacity(colorScheme == .dark ? 0.45 : 0.55))
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.thinMaterial)
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                accent.opacity(colorScheme == .dark ? 0.22 : 0.18),
                                accent.opacity(0.04),
                                Color.clear
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(accent.opacity(colorScheme == .dark ? 0.25 : 0.18), lineWidth: 0.5)
            } else {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(tailColor.opacity(colorScheme == .dark ? 0.95 : 0.97))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(accent.opacity(colorScheme == .dark ? 0.18 : 0.12), lineWidth: 0.5)
                    )
            }
        }
        .shadow(color: accent.opacity(colorScheme == .dark ? 0.18 : 0.10), radius: 20, y: 6)
    }
}

// MARK: - Diamond Tail

/// A square shape that, when rotated 45°, creates a diamond arrow point.
struct DiamondTail: Shape {
    func path(in rect: CGRect) -> Path {
        Path(rect)
    }
}

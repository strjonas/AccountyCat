//
//  NudgeView.swift
//  AC
//
//  Speech bubble that emerges from the companion orb when a nudge fires.
//  No longer a separate panel — embedded directly inside CompanionView.
//

import SwiftUI

// MARK: - Speech Bubble

struct SpeechBubble: View {
    let text: String
    @EnvironmentObject private var controller: AppController
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            // Bubble body
            VStack(spacing: 6) {
                Text(text)
                    .font(.ac(13.5, weight: .medium))
                    .foregroundStyle(bubbleTextColor)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel("Nudge message")

                // Thumbs up / down feedback row
                HStack(spacing: 12) {
                    Button {
                        controller.rateNudge(positive: true, nudgeText: text)
                    } label: {
                        Text("👍")
                            .font(.system(size: 15))
                    }
                    .buttonStyle(ThumbFeedbackStyle())
                    .help("This nudge was helpful")

                    Button {
                        controller.rateNudge(positive: false, nudgeText: text)
                    } label: {
                        Text("👎")
                            .font(.system(size: 15))
                    }
                    .buttonStyle(ThumbFeedbackStyle())
                    .help("This nudge was not helpful")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(bubbleBackground)

            // Downward tail pointing at the cat
            BubbleTailShape()
                .fill(tailColor)
                .frame(width: 14, height: 8)
                .offset(y: -1)
        }
    }

    private var bubbleTextColor: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.96)
            : Color.black.opacity(0.86)
    }

    /// Tail fill matches the bubble body surface in both modes.
    private var tailColor: Color {
        colorScheme == .dark
            ? Color(red: 0.16, green: 0.16, blue: 0.18)
            : Color(red: 0.99, green: 0.96, blue: 0.91)
    }

    private var bubbleBackground: some View {
        let accent = controller.state.character.accentColor
        return ZStack {
            RoundedRectangle(cornerRadius: ACRadius.lg, style: .continuous)
                .fill(tailColor.opacity(colorScheme == .dark ? 0.95 : 0.97))
            RoundedRectangle(cornerRadius: ACRadius.lg, style: .continuous)
                .stroke(
                    accent.opacity(colorScheme == .dark ? 0.55 : 0.40),
                    lineWidth: 1
                )
        }
        .shadow(
            color: accent.opacity(colorScheme == .dark ? 0.35 : 0.18),
            radius: 10, y: 3
        )
    }
}

// MARK: - Thumb Feedback Button Style

/// Bouncy emoji scale on press — makes it unambiguous that the tap registered.
private struct ThumbFeedbackStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 1.55 : 1.0)
            .animation(
                configuration.isPressed
                    ? .easeIn(duration: 0.08)
                    : .spring(response: 0.35, dampingFraction: 0.45),
                value: configuration.isPressed
            )
    }
}


// MARK: - Tail Shape

struct BubbleTailShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX - 7, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX + 7, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

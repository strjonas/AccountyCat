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
                    .font(.ac(12.5))
                    .foregroundStyle(Color.primary)
                    .multilineTextAlignment(.center)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)

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
            .padding(.horizontal, 13)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(bubbleBackground)

            // Downward tail pointing at the cat
            BubbleTailShape()
                .fill(tailColor)
                .frame(width: 14, height: 8)
                .offset(y: -1)
        }
    }

    /// Tail fill matches the material surface color closely enough in both modes.
    private var tailColor: Color {
        colorScheme == .dark
            ? Color(red: 0.22, green: 0.22, blue: 0.24)
            : Color(red: 1.0, green: 0.97, blue: 0.92)
    }

    private var bubbleBackground: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.ultraThinMaterial)
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.primary.opacity(colorScheme == .dark ? 0.12 : 0.10), lineWidth: 1)
        }
        .shadow(
            color: Color.black.opacity(colorScheme == .dark ? 0.35 : 0.10),
            radius: 8, y: 3
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

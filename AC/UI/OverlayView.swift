//
//  OverlayView.swift
//  AC
//
//  Escalation overlay — rare, warm, encouraging. Soft amber vignette, sleepy cat,
//  one gentle nudge. Not alarming; more like a cosy tap on the shoulder from a friend.
//

import SwiftUI

struct OverlayView: View {
    @EnvironmentObject private var controller: AppController
    @FocusState private var appealFocused: Bool

    var body: some View {
        let presentation = controller.activeOverlay ?? OverlayPresentation(
            headline: "Psst — come back! 🐾",
            body: "Your focus streak is so close. Ready to hop back into \(controller.state.rescueApp.displayName)?",
            prompt: nil,
            appName: controller.state.rescueApp.displayName,
            evaluationID: nil,
            submitButtonTitle: "Back to work",
            secondaryButtonTitle: "Not yet"
        )

        ZStack {
            // Soft amber edge vignette — clear center so the user can see their work
            RadialGradient(
                colors: [Color.clear, Color.acCaramel.opacity(0.14)],
                center: .center,
                startRadius: 220,
                endRadius: 780
            )
            .ignoresSafeArea()

            VStack(spacing: 26) {
                // Cat avatar with warm gradient halo
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [Color.acCream, Color.acCaramelLight],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .shadow(color: Color.acCaramel.opacity(0.30), radius: 26, y: 10)

                    CatFaceView(mood: .paused, isBlinking: false)
                        .padding(16)
                }
                .frame(width: 128, height: 128)

                // Headline + body
                VStack(spacing: 8) {
                    Text(presentation.headline)
                        .font(.ac(24, weight: .semibold))
                        .foregroundStyle(Color.acTextPrimary)
                        .multilineTextAlignment(.center)

                    Text(presentation.body)
                        .font(.ac(14))
                        .foregroundStyle(Color.secondary)
                        .multilineTextAlignment(.center)
                        .lineSpacing(2)
                }

                // Optional appeal input (shown when AI asks the user to explain)
                if let prompt = presentation.prompt {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(prompt)
                            .font(.ac(13, weight: .medium))
                            .foregroundStyle(Color.acTextPrimary)

                        TextField(
                            "Explain why this is actually helping…",
                            text: $controller.overlayAppealDraft,
                            axis: .vertical
                        )
                        .font(.ac(13))
                        .lineLimit(2...5)
                        .textFieldStyle(.plain)
                        .focused($appealFocused)
                        .disabled(controller.sendingOverlayAppeal)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(Color(nsColor: .textBackgroundColor))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .stroke(
                                            appealFocused
                                                ? Color.acCaramel.opacity(0.55)
                                                : Color.secondary.opacity(0.20),
                                            lineWidth: 1
                                        )
                                )
                        )
                        .animation(.acSnap, value: appealFocused)
                    }
                    .onAppear { appealFocused = true }
                }

                // Actions
                VStack(spacing: 12) {
                    if presentation.prompt == nil {
                        Button(presentation.submitButtonTitle) {
                            controller.handleBackToWork()
                        }
                        .buttonStyle(OverlayPrimaryButton())
                    } else {
                        Button(controller.sendingOverlayAppeal ? "Thinking…" : presentation.submitButtonTitle) {
                            controller.submitOverlayAppeal()
                        }
                        .buttonStyle(OverlayPrimaryButton())
                        .disabled(controller.sendingOverlayAppeal || controller.overlayAppealDraft.cleanedSingleLine.isEmpty)
                    }

                    Button(presentation.secondaryButtonTitle) {
                        controller.dismissOverlay()
                    }
                    .font(.ac(13))
                    .foregroundStyle(Color.secondary)
                    .buttonStyle(.plain)
                }
            }
            .padding(36)
            .frame(maxWidth: 420)
            .background(
                RoundedRectangle(cornerRadius: 32, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 32, style: .continuous)
                            .stroke(Color.white.opacity(0.45), lineWidth: 1)
                    )
                    .shadow(color: Color.black.opacity(0.12), radius: 32, y: 16)
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Button style

private struct OverlayPrimaryButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.ac(15, weight: .semibold))
            .foregroundStyle(Color(red: 0.18, green: 0.10, blue: 0.04))
            .padding(.horizontal, 28)
            .padding(.vertical, 12)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.acCaramelLight)
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(Color.white.opacity(0.50), lineWidth: 1)
                    )
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.acSnap, value: configuration.isPressed)
    }
}

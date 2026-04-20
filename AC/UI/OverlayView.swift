//
//  OverlayView.swift
//  AC
//
//  Escalation overlay — rare, warm, encouraging. Edge vignette, big sleepy cat,
//  one friendly message. Not alarming; more like a gentle tap on the shoulder.
//

import SwiftUI

struct OverlayView: View {
    @EnvironmentObject private var controller: AppController

    var body: some View {
        let presentation = controller.activeOverlay ?? OverlayPresentation(
            headline: "Hey… come back for a second.",
            body: "Ready to hop back into \(controller.state.rescueApp.displayName)?",
            prompt: nil,
            appName: controller.state.rescueApp.displayName,
            evaluationID: nil,
            submitButtonTitle: "Back to work",
            secondaryButtonTitle: "Dismiss"
        )

        ZStack {
            // Subtle amber edge vignette — clear center so user can see their work
            RadialGradient(
                colors: [
                    Color.clear,
                    Color(red: 0.90, green: 0.55, blue: 0.20).opacity(0.18),
                ],
                center: .center,
                startRadius: 180,
                endRadius: 700
            )
            .ignoresSafeArea()

            // Centre card
            VStack(spacing: 22) {
                // Big cat — sleepy/apologetic mood
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color(red: 1.00, green: 0.96, blue: 0.86),
                                    Color(red: 0.98, green: 0.85, blue: 0.62),
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .shadow(color: Color(red: 0.85, green: 0.65, blue: 0.35).opacity(0.22),
                                radius: 22, y: 10)

                    CatFaceView(mood: .paused, isBlinking: false)
                        .padding(18)
                }
                .frame(width: 120, height: 120)

                VStack(spacing: 10) {
                    Text(presentation.headline)
                        .font(.ac(26, weight: .semibold))
                        .foregroundStyle(Color.primary)

                    Text(presentation.body)
                        .font(.ac(15))
                        .foregroundStyle(Color.secondary)
                        .multilineTextAlignment(.center)
                }

                if let prompt = presentation.prompt {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(prompt)
                            .font(.ac(14, weight: .medium))
                            .foregroundStyle(Color.acTextPrimary)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        TextField(
                            "Tell AC why this helps your goals",
                            text: $controller.overlayAppealDraft,
                            axis: .vertical
                        )
                        .font(.ac(14))
                        .textFieldStyle(.roundedBorder)
                        .disabled(controller.sendingOverlayAppeal)
                    }
                }

                HStack(spacing: 14) {
                    if presentation.prompt == nil {
                        Button(presentation.submitButtonTitle) {
                            controller.handleBackToWork()
                        }
                        .buttonStyle(OverlayPrimaryButton())
                    } else {
                        Button(controller.sendingOverlayAppeal ? "Reviewing…" : presentation.submitButtonTitle) {
                            controller.submitOverlayAppeal()
                        }
                        .buttonStyle(OverlayPrimaryButton())
                        .disabled(controller.sendingOverlayAppeal || controller.overlayAppealDraft.cleanedSingleLine.isEmpty)
                    }

                    Button(presentation.secondaryButtonTitle) {
                        controller.dismissOverlay()
                    }
                    .font(.ac(14))
                    .foregroundStyle(Color.secondary)
                    .buttonStyle(.plain)
                }
            }
            .padding(36)
            .frame(maxWidth: 460)
            .background(
                RoundedRectangle(cornerRadius: 32, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 32, style: .continuous)
                            .stroke(Color.white.opacity(0.45), lineWidth: 1)
                    )
                    .shadow(color: Color.black.opacity(0.14), radius: 28, y: 14)
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Overlay button style

private struct OverlayPrimaryButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.ac(15, weight: .semibold))
            .foregroundStyle(Color(red: 0.18, green: 0.10, blue: 0.04))
            .padding(.horizontal, 22)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.acCaramelLight)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(Color.white.opacity(0.45), lineWidth: 1)
                    )
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.acSnap, value: configuration.isPressed)
    }
}

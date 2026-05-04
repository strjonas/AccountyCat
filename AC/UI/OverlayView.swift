//
//  OverlayView.swift
//  AC
//
//  Refreshed escalation overlay — visual-novel layout.
//  Large cat portrait left, vibrancy dialog right.
//  Reason chips, free-text appeal, snooze / back-to-work actions, quiet ×.
//

import SwiftUI

struct OverlayView: View {
    @EnvironmentObject private var controller: AppController
    @Environment(\.acAccent) private var accent
    @FocusState private var appealFocused: Bool

    var body: some View {
        let presentation = controller.activeOverlay ?? OverlayPresentation(
            headline: "Psst — come back! 🐾",
            body: "Your focus streak is so close. Ready to hop back into \(controller.state.rescueApp.displayName)?",
            prompt: nil,
            appName: controller.state.rescueApp.displayName,
            evaluationID: nil,
            submitButtonTitle: "Back to work",
            secondaryButtonTitle: "Not yet",
            isHardEscalation: false
        )

        let character = controller.state.character

        GeometryReader { proxy in
            ZStack {
                // Dim + vignette
                Color.black.opacity(0.18)
                    .ignoresSafeArea()

                RadialGradient(
                    colors: [Color.clear, accent.opacity(0.12)],
                    center: .center,
                    startRadius: 240,
                    endRadius: 900
                )
                .ignoresSafeArea()

                // Main card — visual-novel layout
                HStack(spacing: 0) {
                    // Left: large cat portrait
                    catPortrait(character: character)
                        .frame(width: min(proxy.size.width * 0.35, 220))

                    // Right: dialog content
                    dialogContent(presentation: presentation, character: character)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(maxWidth: min(proxy.size.width - 80, 720), maxHeight: min(proxy.size.height - 80, 420))
                .background(
                    RoundedRectangle(cornerRadius: ACRadius.xxl, style: .continuous)
                        .fill(.ultraThinMaterial)
                        .overlay(
                            RoundedRectangle(cornerRadius: ACRadius.xxl, style: .continuous)
                                .stroke(Color.white.opacity(0.40), lineWidth: 1)
                        )
                        .shadow(color: accent.opacity(0.18), radius: 36, y: 14)
                )

                // Quiet × dismiss
                VStack {
                    HStack {
                        Spacer()
                        Button {
                            controller.dismissOverlay()
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(Color.acTextPrimary.opacity(0.55))
                                .padding(10)
                                .background(
                                    Circle()
                                        .fill(Color.acSurface)
                                        .overlay(Circle().stroke(Color.acHairline, lineWidth: 1))
                                )
                        }
                        .buttonStyle(.plain)
                        .help("Dismiss")
                        .padding(.top, 20)
                        .padding(.trailing, 28)
                    }
                    Spacer()
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
            }
        }
        .acAccent(for: character)
    }

    // MARK: - Cat portrait (left side)

    private func catPortrait(character: ACCharacter) -> some View {
        ZStack {
            // Warm gradient halo
            Circle()
                .fill(
                    LinearGradient(
                        colors: [character.orbTopColor, character.orbBottomColor],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .shadow(color: character.accentColor.opacity(0.30), radius: 24, y: 8)
                .overlay(Circle().stroke(Color.white.opacity(0.40), lineWidth: 1))

            CatView(
                character: character,
                skin: controller.state.selectedSkin,
                expression: .concern,
                size: 140,
                animating: false
            )
            .padding(20)

            Text(character.displayName.lowercased())
                .font(.ac(14, weight: .semibold))
                .foregroundStyle(character.accentColor)
        }
        .padding(24)
        .frame(maxHeight: .infinity)
    }

    // MARK: - Dialog content (right side)

    private func dialogContent(presentation: OverlayPresentation, character: ACCharacter) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                // Headline + body
                VStack(alignment: .leading, spacing: 6) {
                    Text(presentation.headline)
                        .font(.ac(20, weight: .semibold))
                        .foregroundStyle(Color.acTextPrimary)

                    Text(presentation.body)
                        .font(.ac(13))
                        .foregroundStyle(Color.acTextPrimary.opacity(0.72))
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // Optional appeal input
                if let prompt = presentation.prompt {
                    appealSection(prompt: prompt)
                }

                Spacer(minLength: 0)

                // Actions
                HStack(spacing: 10) {
                    Button {
                        controller.dismissOverlay()
                    } label: {
                        Text("snooze 5 min")
                            .font(.ac(12, weight: .medium))
                            .foregroundStyle(Color.acTextPrimary.opacity(0.72))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(Color.acSurface)
                                    .overlay(Capsule(style: .continuous).stroke(Color.acHairline, lineWidth: 1))
                            )
                    }
                    .buttonStyle(.plain)

                    Spacer(minLength: 4)

                    if presentation.prompt == nil {
                        Button("back to work") {
                            controller.handleBackToWork()
                        }
                        .buttonStyle(OverlayPrimaryButton())
                    } else {
                        let canSubmit = !controller.sendingOverlayAppeal && !controller.overlayAppealDraft.cleanedSingleLine.isEmpty
                        Button(controller.sendingOverlayAppeal ? "thinking…" : (canSubmit ? "got it — back to work" : "back to work")) {
                            controller.submitOverlayAppeal()
                        }
                        .buttonStyle(OverlayPrimaryButton())
                        .disabled(controller.sendingOverlayAppeal || controller.overlayAppealDraft.cleanedSingleLine.isEmpty)
                    }
                }
            }
            .padding(28)
        }
    }

    // MARK: - Appeal section

    private func appealSection(prompt: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(prompt)
                .font(.ac(12, weight: .medium))
                .foregroundStyle(Color.acTextPrimary)

            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: ACRadius.lg, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor))
                    .overlay(
                        RoundedRectangle(cornerRadius: ACRadius.lg, style: .continuous)
                            .stroke(
                                appealFocused ? accent.opacity(0.60) : Color.acHairline.opacity(0.5),
                                lineWidth: 1.5
                            )
                    )

                TextField(
                    "Explain why this is actually helping…",
                    text: $controller.overlayAppealDraft,
                    axis: .vertical
                )
                .font(.ac(12))
                .lineLimit(2...5)
                .textFieldStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .focused($appealFocused)
                .opacity(controller.sendingOverlayAppeal ? 0.6 : 1.0)
            }
            .frame(maxWidth: .infinity, minHeight: 60)
            .animation(.acSnap, value: appealFocused)

            OverlayReasonChips { reason in
                controller.overlayAppealDraft = reason
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    controller.submitOverlayAppeal()
                }
            }
            .disabled(controller.sendingOverlayAppeal)
        }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                appealFocused = true
            }
        }
    }
}

// MARK: - Reason chips

private struct OverlayReasonChips: View {
    let onSelect: (String) -> Void

    private let reasons: [(String, String)] = [
        ("magnifyingglass", "actually working — leave me"),
        ("cup.and.saucer.fill", "research, related to my work"),
        ("questionmark.bubble.fill", "5 minute break, on purpose"),
        ("paperclip", "you're right, going back"),
    ]

    var body: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 110), spacing: 6)],
            alignment: .leading,
            spacing: 6
        ) {
            ForEach(reasons, id: \.1) { icon, label in
                Button {
                    onSelect(label)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: icon)
                            .font(.system(size: 10, weight: .semibold))
                        Text(label)
                            .font(.ac(10, weight: .medium))
                    }
                    .foregroundStyle(Color.acTextPrimary.opacity(0.78))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Color.acSurface)
                            .overlay(Capsule(style: .continuous).stroke(Color.acHairline, lineWidth: 1))
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Button style

private struct OverlayPrimaryButton: ButtonStyle {
    @Environment(\.acAccent) private var accent
    @Environment(\.acAccentLight) private var accentLight

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.ac(13, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 22)
            .padding(.vertical, 10)
            .background(
                Capsule(style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [accentLight, accent.opacity(0.90)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(Color.white.opacity(0.50), lineWidth: 1)
                    )
                    .shadow(color: accent.opacity(0.30), radius: 8, y: 3)
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.acSnap, value: configuration.isPressed)
    }
}

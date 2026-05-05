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
    @Environment(\.colorScheme) private var colorScheme
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
                // Warm vignette + dim
                Color.black.opacity(0.55)
                    .ignoresSafeArea()

                RadialGradient(
                    colors: [
                        Color.orange.opacity(colorScheme == .dark ? 0.12 : 0.18),
                        Color.clear
                    ],
                    center: .init(x: 0.30, y: 0.50),
                    startRadius: 120,
                    endRadius: 700
                )
                .ignoresSafeArea()

                // Main stage — visual-novel layout
                HStack(spacing: 0) {
                    // Left: large cat portrait with soft glow
                    catPortrait(character: character)
                        .frame(width: min(proxy.size.width * 0.38, 260))

                    // Right: dialog content (overlaps portrait slightly)
                    dialogContent(presentation: presentation, character: character)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(.leading, -30)
                }
                .frame(maxWidth: min(proxy.size.width - 80, 820), maxHeight: min(proxy.size.height - 80, 420))

                // Quiet × dismiss
                VStack {
                    HStack {
                        Spacer()
                        Button {
                            controller.dismissOverlay()
                        } label: {
                            Text("×")
                                .font(.system(size: 18, weight: .light))
                                .foregroundStyle(Color.white.opacity(0.45))
                                .frame(width: 28, height: 28)
                                .background(Circle().fill(Color.white.opacity(0.08)))
                        }
                        .buttonStyle(.plain)
                        .help("Dismiss")
                        .padding(.top, 28)
                        .padding(.trailing, 32)
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
            // Soft circular shadow / glow
            Circle()
                .fill(character.accentColor.opacity(0.18))
                .frame(width: 200, height: 200)
                .blur(radius: 40)

            CatView(
                character: character,
                skin: controller.state.selectedSkin,
                expression: .concern,
                size: 160,
                animating: false
            )
            .padding(16)

            // Name below cat, serif-style
            Text(character.displayName.lowercased())
                .font(.system(size: 14, weight: .medium, design: .serif))
                .foregroundStyle(character.accentColor)
                .offset(y: 100)
        }
        .padding(20)
        .frame(maxHeight: .infinity)
    }

    // MARK: - Dialog content (right side)

    private func dialogContent(presentation: OverlayPresentation, character: ACCharacter) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Name + text
                VStack(alignment: .leading, spacing: 8) {
                    if !presentation.headline.isEmpty {
                        Text(presentation.headline)
                            .font(.ac(18, weight: .semibold))
                            .foregroundStyle(Color.acTextPrimary)
                    }

                    Text(character.displayName.lowercased())
                        .font(.system(size: 16, weight: .semibold, design: .serif))
                        .foregroundStyle(accent)

                    Text(presentation.body)
                        .font(.ac(15))
                        .foregroundStyle(Color.acTextPrimary.opacity(0.90))
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)

                    if let prompt = presentation.prompt {
                        Text(prompt)
                            .font(.ac(12.5))
                            .foregroundStyle(Color.acTextPrimary.opacity(0.60))
                            .lineSpacing(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                // Optional appeal input
                if presentation.prompt != nil {
                    appealSection()
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
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .fill(Color.acSurface)
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
            .padding(26)
            .background(dialogBackground)
        }
    }

    // MARK: - Dialog background

    private var dialogBackground: some View {
        ZStack {
            if controller.state.useLiquidGlass {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .stroke(Color.white.opacity(0.35), lineWidth: 0.5)
                    )
                    .shadow(color: accent.opacity(0.15), radius: 36, y: 14)

                // Specular highlights
                VStack {
                    LinearGradient(
                        colors: [Color.white.opacity(0.35), Color.clear],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: 80)
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    Spacer()
                }
            } else {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color.acSurface)
                    .overlay(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .stroke(Color.white.opacity(0.35), lineWidth: 0.5)
                    )
                    .shadow(color: accent.opacity(0.15), radius: 36, y: 14)
            }
        }
    }

    // MARK: - Appeal section

    private func appealSection() -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor))
                    .overlay(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
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
                    .padding(.horizontal, 10)
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
            .font(.ac(12.5, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [accentLight, accent.opacity(0.90)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .stroke(Color.white.opacity(0.45), lineWidth: 0.5)
                    )
                    .shadow(color: accent.opacity(0.28), radius: 10, y: 3)
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.acSnap, value: configuration.isPressed)
    }
}

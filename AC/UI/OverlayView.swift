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
            let usesCompactLayout = proxy.size.width < 860

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
                HStack(spacing: usesCompactLayout ? 12 : 0) {
                    // Left: large cat portrait with soft glow
                    catPortrait(character: character)
                        .frame(width: usesCompactLayout ? 180 : min(proxy.size.width * 0.34, 250))

                    // Right: dialog content (overlaps portrait slightly)
                    dialogContent(presentation: presentation, character: character)
                        .frame(maxWidth: min(max(proxy.size.width * 0.58, 460), 620), maxHeight: .infinity)
                        .padding(.leading, usesCompactLayout ? 0 : -24)
                }
                .frame(maxWidth: min(proxy.size.width - 48, 900), maxHeight: min(proxy.size.height - 56, 460))

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
                            .shadow(color: colorScheme == .dark ? .black.opacity(0.45) : .white.opacity(0.55), radius: 1, x: 0, y: 0.5)
                    }

                    Text(character.displayName.lowercased())
                        .font(.system(size: 16, weight: .semibold, design: .serif))
                        .foregroundStyle(accent)

                    Text(presentation.body)
                        .font(.ac(15))
                        .foregroundStyle(Color.acTextPrimary.opacity(0.90))
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .shadow(color: colorScheme == .dark ? .black.opacity(0.45) : .white.opacity(0.55), radius: 1, x: 0, y: 0.5)

                    if let prompt = presentation.prompt {
                        Text(prompt)
                            .font(.ac(12.5))
                            .foregroundStyle(Color.acTextPrimary.opacity(0.60))
                            .lineSpacing(2)
                            .fixedSize(horizontal: false, vertical: true)
                            .shadow(color: colorScheme == .dark ? .black.opacity(0.45) : .white.opacity(0.55), radius: 1, x: 0, y: 0.5)
                    }
                }

                // Optional appeal input
                if presentation.prompt != nil {
                    appealSection(character: character)
                }

                Spacer(minLength: 0)

                // Actions
                HStack(alignment: .center, spacing: 10) {
                    Button {
                        controller.dismissOverlay()
                    } label: {
                        Text("Snooze 5 min")
                            .font(.ac(12, weight: .medium))
                            .foregroundStyle(Color.acTextPrimary.opacity(0.82))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                            .background(
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .fill(colorScheme == .dark
                                        ? Color(white: 1.0, opacity: 0.10)
                                        : Color(white: 0.0, opacity: 0.06)
                                    )
                            )
                    }
                    .buttonStyle(.plain)

                    Spacer(minLength: 4)

                    if presentation.prompt == nil {
                        Button(presentation.submitButtonTitle) {
                            controller.handleBackToWork()
                        }
                        .buttonStyle(OverlayPrimaryButton())
                    } else {
                        let canSubmit = !controller.sendingOverlayAppeal && !controller.overlayAppealDraft.cleanedSingleLine.isEmpty
                        Button(presentation.secondaryButtonTitle) {
                            controller.handleBackToWork()
                        }
                        .buttonStyle(OverlaySecondaryActionButton())

                        Button(controller.sendingOverlayAppeal ? "\(character.displayName) is thinking…" : appealButtonTitle(for: character, fallback: presentation.submitButtonTitle)) {
                            controller.submitOverlayAppeal()
                        }
                        .buttonStyle(OverlayPrimaryButton())
                        .disabled(!canSubmit)
                    }
                }
            }
            .padding(26)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(dialogBackground)
        }
    }

    // MARK: - Dialog background

    private var dialogBackground: some View {
        ZStack {
            // Solid backing guarantees contrast over any wallpaper colour
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(dialogSolidBacking)

            if controller.state.useLiquidGlass {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(.thinMaterial)

                // Specular highlights
                VStack {
                    LinearGradient(
                        colors: [Color.white.opacity(0.30), Color.clear],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: 80)
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    Spacer()
                }
            } else {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color.acSurface.opacity(colorScheme == .dark ? 0.55 : 0.45))
            }

            // Hairline rim light
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.white.opacity(0.25), lineWidth: 0.5)
        }
        .shadow(color: accent.opacity(0.15), radius: 36, y: 14)
    }

    private var dialogSolidBacking: Color {
        colorScheme == .dark
            ? Color(white: 0.08, opacity: 0.82)
            : Color(white: 0.96, opacity: 0.82)
    }

    // MARK: - Appeal section

    private func appealSection(character: ACCharacter) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text("If this is helping, tell \(character.displayName) why.")
                    .font(.ac(12.5, weight: .semibold))
                    .foregroundStyle(Color.acTextPrimary.opacity(0.82))

                Text("Write a quick explanation, head back to work, or snooze this reminder.")
                    .font(.ac(11.5))
                    .foregroundStyle(Color.acTextPrimary.opacity(0.62))
                    .fixedSize(horizontal: false, vertical: true)
            }

            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor).opacity(0.92))
                    .overlay(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .stroke(
                                appealFocused ? accent.opacity(0.60) : Color.acHairline.opacity(0.5),
                                lineWidth: 1.5
                            )
                    )

                if controller.overlayAppealDraft.isEmpty {
                    Text("What are you doing here, and how does it help?")
                        .font(.ac(12))
                        .foregroundStyle(Color.acTextPrimary.opacity(0.38))
                        .padding(.horizontal, 18)
                        .padding(.vertical, 15)
                        .allowsHitTesting(false)
                }

                TextEditor(text: $controller.overlayAppealDraft)
                    .font(.ac(12))
                    .foregroundStyle(Color.acTextPrimary)
                    .textEditorStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, minHeight: 92, maxHeight: 132, alignment: .topLeading)
                    .focused($appealFocused)
                    .opacity(controller.sendingOverlayAppeal ? 0.6 : 1.0)
            }
            .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
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

    private func appealButtonTitle(for character: ACCharacter, fallback: String) -> String {
        let cleanedFallback = fallback.cleanedSingleLine.lowercased()
        let genericTitles = [
            "submit",
            "explain",
            "let me explain",
            "make your case",
            "reflect"
        ]

        if genericTitles.contains(cleanedFallback) {
            return "Let \(character.displayName) think about it"
        }

        return fallback
    }
}

// MARK: - Reason chips

private struct OverlayReasonChips: View {
    let onSelect: (String) -> Void

    private let reasons: [(String, String)] = [
        ("magnifyingglass", "This is part of the task"),
        ("cup.and.saucer.fill", "I am researching something relevant"),
        ("questionmark.bubble.fill", "This is an intentional short break"),
        ("paperplane", "Let me wrap this up, then I will switch back"),
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

private struct OverlaySecondaryActionButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.ac(12, weight: .medium))
            .foregroundStyle(Color.acTextPrimary.opacity(0.90))
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.acSurface.opacity(0.85))
                    .overlay(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .stroke(Color.acHairline.opacity(0.8), lineWidth: 1)
                    )
            )
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
            .animation(.acSnap, value: configuration.isPressed)
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

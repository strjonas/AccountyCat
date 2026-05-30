//
//  LookTab.swift
//  AC
//
//  Character picker (paired portrait + personality + palette) plus glass
//  mode control and an expression preview strip. Replaces the previous
//  Look + Persona tabs — visual identity and personality are inseparable.
//

import SwiftUI

struct LookTab: View {
    @EnvironmentObject private var controller: AppController
    @Environment(\.acAccent) private var accent

    @State private var previewExpression: ACCatExpression = .neutral

    private var characters: [ACCharacter] {
        // Mochi + Orb, then the user's custom partners. A previously-selected
        // legacy cat (misty/onyx) stays visible so it isn't orphaned.
        var list = ACCharacter.pickerBuiltIns
        let active = controller.state.character
        if active.origin == .builtIn, !list.contains(where: { $0.id == active.id }) {
            list.append(active)
        }
        return list + controller.state.customCharacters
    }
    private let expressions: [ACCatExpression] = [.neutral, .blink, .happy, .sleep, .concerned]
    private let cardColumns = [GridItem(.adaptive(minimum: 96), spacing: 10)]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            sectionLabel("accountability partner")
            Text("pick who keeps you on track. each one ships its own voice and palette.")
                .font(.acCaption)
                .foregroundStyle(.secondary)
                .padding(.top, -12)

            characterGrid

            sectionLabel("preview expression")
            Text("see how your partner looks across moods.")
                .font(.acCaption)
                .foregroundStyle(.secondary)
                .padding(.top, -12)
            expressionRow

            Divider().opacity(0.3)

            sectionLabel("on-screen")
            Text("don't want a character floating on screen? AC can stay menu-bar only and keep watching just the same.")
                .font(.acCaption)
                .foregroundStyle(.secondary)
                .padding(.top, -12)
            displayModePicker

            Divider().opacity(0.3)

            sectionLabel("glass")
            Text("translucent panels with specular highlights. auto follows your macOS Reduce Transparency setting.")
                .font(.acCaption)
                .foregroundStyle(.secondary)
                .padding(.top, -12)
            glassPicker
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Character grid

    private var characterGrid: some View {
        VStack(spacing: 10) {
            LazyVGrid(columns: cardColumns, spacing: 10) {
                ForEach(characters, id: \.self) { character in
                    characterCard(character)
                }
            }
            createBar
        }
    }

    /// The "+ create your own" entry. A full-width bar rather than a grid card so
    /// it stays space-efficient no matter how many partners fill the rows above.
    private var createBar: some View {
        Button {
            NotificationCenter.default.post(name: .acOpenPartnerCreator, object: nil)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(accent.opacity(0.85))
                Text("create your own")
                    .font(.ac(12, weight: .medium))
                    .foregroundStyle(Color.acTextPrimary)
                Text("bring your own partner")
                    .font(.ac(11))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: ACRadius.md, style: .continuous)
                    .fill(Color.acSurface)
                    .overlay(
                        RoundedRectangle(cornerRadius: ACRadius.md, style: .continuous)
                            .stroke(Color.acHairline, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    )
            )
        }
        .buttonStyle(.plain)
    }

    private func characterCard(_ character: ACCharacter) -> some View {
        let isSelected = controller.state.character == character
        let cardAccent = character.accentColor
        return Button {
            controller.updateCharacter(character)
        } label: {
            VStack(spacing: 10) {
                CatView(
                    character: character,
                    expression: previewExpression,
                    size: 64,
                    animating: false
                )

                VStack(spacing: 2) {
                    Text(character.displayName)
                        .font(.ac(13, weight: isSelected ? .semibold : .medium))
                        .foregroundStyle(isSelected ? cardAccent : Color.acTextPrimary)
                    Text(character.moodLabel)
                        .font(.ac(10))
                        .foregroundStyle(Color.acTextPrimary.opacity(0.55))
                    Text(character.tagline)
                        .font(.ac(10))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .padding(.top, 2)
                }
            }
            .padding(.vertical, 14)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: ACRadius.md, style: .continuous)
                    .fill(isSelected ? cardAccent.opacity(0.08) : Color.acSurface)
                    .overlay(
                        RoundedRectangle(cornerRadius: ACRadius.md, style: .continuous)
                            .stroke(isSelected ? cardAccent.opacity(0.45) : Color.acHairline, lineWidth: isSelected ? 1.5 : 1)
                    )
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            if character.origin == .custom {
                Button("Edit…") {
                    NotificationCenter.default.post(name: .acOpenPartnerCreator, object: character)
                }
                Button("Delete", role: .destructive) {
                    controller.deleteCustomCharacter(id: character.id)
                }
            }
        }
    }

    // MARK: - Expression row

    private var expressionRow: some View {
        ACFlowLayout(spacing: 8) {
            ForEach(expressions, id: \.self) { expr in
                let isSelected = previewExpression == expr
                Button {
                    withAnimation(.acSnap) { previewExpression = expr }
                } label: {
                    Text(expr.displayName)
                        .font(.ac(11, weight: isSelected ? .semibold : .medium))
                        .foregroundStyle(isSelected ? accent : Color.acTextPrimary.opacity(0.7))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            Capsule(style: .continuous)
                                .fill(isSelected ? accent.opacity(0.12) : Color.acSurface)
                                .overlay(
                                    Capsule(style: .continuous)
                                        .stroke(isSelected ? accent.opacity(0.4) : Color.acHairline, lineWidth: 1)
                                )
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Display mode picker (orb / menu bar / both)

    private var displayModePicker: some View {
        HStack(spacing: 8) {
            ForEach(ACDisplayMode.allCases, id: \.self) { mode in
                let isSelected = controller.state.displayMode == mode
                Button {
                    controller.updateDisplayMode(mode)
                } label: {
                    VStack(spacing: 3) {
                        Text(mode.displayName)
                            .font(.ac(12, weight: isSelected ? .semibold : .medium))
                            .foregroundStyle(isSelected ? accent : Color.acTextPrimary.opacity(0.78))
                        Text(displayModeBlurb(mode))
                            .font(.ac(10))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity)
                    .background(
                        RoundedRectangle(cornerRadius: ACRadius.md, style: .continuous)
                            .fill(isSelected ? accent.opacity(0.10) : Color.acSurface)
                            .overlay(
                                RoundedRectangle(cornerRadius: ACRadius.md, style: .continuous)
                                    .stroke(isSelected ? accent.opacity(0.35) : Color.acHairline, lineWidth: 1)
                            )
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func displayModeBlurb(_ mode: ACDisplayMode) -> String {
        switch mode {
        case .both: return "orb + menu bar"
        case .orb: return "floating orb only"
        case .menuBar: return "menu bar only"
        }
    }

    // MARK: - Glass picker

    private var glassPicker: some View {
        HStack(spacing: 8) {
            ForEach(ACGlassMode.allCases, id: \.self) { mode in
                let isSelected = controller.state.glassMode == mode
                Button {
                    controller.updateGlassMode(mode)
                } label: {
                    VStack(spacing: 3) {
                        Text(mode.displayName)
                            .font(.ac(12, weight: isSelected ? .semibold : .medium))
                            .foregroundStyle(isSelected ? accent : Color.acTextPrimary.opacity(0.78))
                        Text(mode.blurb)
                            .font(.ac(10))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity)
                    .background(
                        RoundedRectangle(cornerRadius: ACRadius.md, style: .continuous)
                            .fill(isSelected ? accent.opacity(0.10) : Color.acSurface)
                            .overlay(
                                RoundedRectangle(cornerRadius: ACRadius.md, style: .continuous)
                                    .stroke(isSelected ? accent.opacity(0.35) : Color.acHairline, lineWidth: 1)
                            )
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .tracking(0.06)
            .foregroundStyle(Color.acTextPrimary.opacity(0.45))
            .textCase(.uppercase)
    }
}

// MARK: - Flow layout helper

struct ACFlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = FlowResult(in: proposal.replacingUnspecifiedDimensions().width, subviews: subviews, spacing: spacing)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = FlowResult(in: bounds.width, subviews: subviews, spacing: spacing)
        for (index, subview) in subviews.enumerated() {
            subview.place(at: CGPoint(x: bounds.minX + result.frames[index].minX,
                                      y: bounds.minY + result.frames[index].minY),
                         proposal: .unspecified)
        }
    }

    private struct FlowResult {
        var size: CGSize = .zero
        var frames: [CGRect] = []

        init(in maxWidth: CGFloat, subviews: Subviews, spacing: CGFloat) {
            var x: CGFloat = 0
            var y: CGFloat = 0
            var lineHeight: CGFloat = 0
            for subview in subviews {
                let size = subview.sizeThatFits(.unspecified)
                if x + size.width > maxWidth && x > 0 {
                    x = 0
                    y += lineHeight + spacing
                    lineHeight = 0
                }
                frames.append(CGRect(x: x, y: y, width: size.width, height: size.height))
                x += size.width + spacing
                lineHeight = max(lineHeight, size.height)
            }
            self.size = CGSize(width: maxWidth, height: y + lineHeight)
        }
    }
}

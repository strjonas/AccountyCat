//
//  LookTab.swift
//  AC
//
//  Skin grid + expression preview + accent note.
//

import SwiftUI

struct LookTab: View {
    @EnvironmentObject private var controller: AppController
    @Environment(\.acAccent) private var accent

    @State private var previewExpression: ACCatExpression = .neutral

    private let skins: [ACSkin] = [.bubble, .pixel, .liquid]
    private let expressions: [ACCatExpression] = [.neutral, .happy, .celebrate, .concern, .drift, .sleep, .alert]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            sectionLabel("cat style")
            Text("style is separate from character — mix and match any combo.")
                .font(.acCaption)
                .foregroundStyle(.secondary)
                .padding(.top, -12)

            skinGrid

            sectionLabel("preview expression")
            expressionRow

            Divider().opacity(0.3)

            sectionLabel("accent")
            Text("follow the character palette, or pin the whole UI to a custom accent.")
                .font(.acCaption)
                .foregroundStyle(.secondary)
                .padding(.top, -12)
            accentControls
        }
    }

    // MARK: - Skin grid

    private var skinGrid: some View {
        HStack(spacing: 10) {
            ForEach(skins, id: \.self) { skin in
                let isSelected = controller.state.selectedSkin == skin
                Button {
                    controller.updateSkin(skin)
                } label: {
                    VStack(spacing: 10) {
                        CatView(
                            character: controller.state.character,
                            skin: skin,
                            expression: previewExpression,
                            size: 64,
                            animating: false
                        )

                        VStack(spacing: 2) {
                            Text(skin.displayName)
                                .font(.ac(12, weight: isSelected ? .semibold : .medium))
                                .foregroundStyle(isSelected ? accent : Color.acTextPrimary)
                            Text(skin.blurb)
                                .font(.ac(10))
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .lineLimit(2)
                        }
                    }
                    .padding(.vertical, 14)
                    .padding(.horizontal, 10)
                    .frame(maxWidth: .infinity)
                    .background(
                        RoundedRectangle(cornerRadius: ACRadius.md, style: .continuous)
                            .fill(isSelected ? accent.opacity(0.08) : Color.acSurface)
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

    // MARK: - Expression row

    private var expressionRow: some View {
        ACFlowLayout(spacing: 8) {
            ForEach(expressions, id: \.self) { expr in
                let isSelected = previewExpression == expr
                Button {
                    withAnimation(.acSnap) { previewExpression = expr }
                } label: {
                    Text(expr.rawValue)
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

    // MARK: - Accent

    private var accentControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Toggle("follow character", isOn: Binding(
                    get: { controller.state.accentFollowsCharacter },
                    set: { controller.updateAccent(followsCharacter: $0) }
                ))
                .toggleStyle(.switch)
                .font(.ac(12, weight: .medium))

                Spacer()

                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(accent)
                    .frame(width: 30, height: 20)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(Color.white.opacity(0.5), lineWidth: 0.5)
                    )
            }

            HStack(spacing: 8) {
                ForEach(accentSwatches, id: \.self) { hex in
                    let color = Color(acHexString: hex) ?? accent
                    let selected = !controller.state.accentFollowsCharacter
                        && controller.state.customAccentHex.uppercased() == hex
                    Button {
                        controller.updateAccent(followsCharacter: false, customHex: hex)
                    } label: {
                        Circle()
                            .fill(color)
                            .frame(width: 24, height: 24)
                            .overlay(
                                Circle()
                                    .stroke(selected ? Color.acTextPrimary.opacity(0.62) : Color.white.opacity(0.56), lineWidth: selected ? 2 : 0.5)
                            )
                            .shadow(color: selected ? color.opacity(0.26) : .clear, radius: 5, y: 2)
                    }
                    .buttonStyle(.plain)
                    .help("Use \(hex)")
                }
            }
            .disabled(controller.state.accentFollowsCharacter)
            .opacity(controller.state.accentFollowsCharacter ? 0.45 : 1)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: ACRadius.md, style: .continuous)
                .fill(Color.acSurface)
                .overlay(
                    RoundedRectangle(cornerRadius: ACRadius.md, style: .continuous)
                        .stroke(Color.acHairline, lineWidth: 1)
                )
        )
    }

    private var accentSwatches: [String] {
        ["#7BA3D9", "#A88BFF", "#E89B7A", "#A8B58E", "#D9A8C7", "#111827"]
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.ac(11, weight: .semibold))
            .foregroundStyle(Color.acTextPrimary.opacity(0.7))
            .textCase(.lowercase)
    }
}

// MARK: - Flow layout helper

struct ACFlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = FlowResult(in: proposal.width ?? 0, subviews: subviews, spacing: spacing)
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

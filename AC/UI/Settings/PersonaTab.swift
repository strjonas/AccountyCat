//
//  PersonaTab.swift
//  AC
//
//  Three character cards with blurbs. Character selection lives here;
//  look (skin) is in the Look tab.
//

import SwiftUI

struct PersonaTab: View {
    @EnvironmentObject private var controller: AppController
    @Environment(\.acAccent) private var accent

    private let blurbs: [ACCharacter: String] = [
        .mochi: "warm, rooting for you. uses 🥺 occasionally.",
        .nova:  "sharp co-pilot. concise, no hand-holding.",
        .sage:  "calm, reflective. mirrors back what you said.",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            sectionLabel("character (voice & personality)")
            Text("character changes voice only — style and color stay controlled by look.")
                .font(.acCaption)
                .foregroundStyle(.secondary)
                .padding(.top, -12)

            HStack(spacing: 10) {
                ForEach(ACCharacter.allCases, id: \.self) { character in
                    characterCard(character)
                }
            }
        }
    }

    private func characterCard(_ character: ACCharacter) -> some View {
        let isSelected = controller.state.character == character
        return Button {
            controller.updateCharacter(character)
        } label: {
            VStack(spacing: 10) {
                CatView(
                    character: character,
                    skin: controller.state.selectedSkin,
                    expression: .happy,
                    size: 72,
                    animating: false
                )

                VStack(spacing: 2) {
                    Text(character.displayName)
                        .font(.ac(13, weight: isSelected ? .semibold : .medium))
                        .foregroundStyle(isSelected ? accent : Color.acTextPrimary)
                    Text(blurbs[character] ?? "")
                        .font(.ac(10))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
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

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .tracking(0.06)
            .foregroundStyle(Color.acTextPrimary.opacity(0.45))
            .textCase(.uppercase)
    }
}

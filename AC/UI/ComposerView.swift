//
//  ComposerView.swift
//  AC
//
//  Pill-style composer: text input + accent send button.
//

import SwiftUI

struct ComposerView: View {
    @EnvironmentObject private var controller: AppController
    @Environment(\.acAccent) private var accent
    @State private var draft = ""
    @FocusState private var inputFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            // Pill input
            TextField("tell \(controller.state.character.displayName.lowercased()) what you're working on…", text: $draft, axis: .vertical)
                .font(.ac(13))
                .lineLimit(1...4)
                .textFieldStyle(.plain)
                .focused($inputFocused)
                .onSubmit { sendDraft() }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)

            // Send button
            Button(action: sendDraft) {
                Image(systemName: controller.sendingChatMessage ? "ellipsis" : "arrow.up")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(canSend ? Color.white : Color.acTextPrimary.opacity(0.5))
                    .frame(width: 30, height: 30)
                    .background(
                        Circle()
                            .fill(canSend ? accent : Color.acSurface)
                            .shadow(color: canSend ? accent.opacity(0.35) : .clear, radius: 4, y: 2)
                    )
                    .symbolEffect(.bounce, value: controller.sendingChatMessage)
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .padding(.trailing, 4)
        }
        .background(
            RoundedRectangle(cornerRadius: ACRadius.xl, style: .continuous)
                .fill(Color.acSurface)
                .overlay(
                    RoundedRectangle(cornerRadius: ACRadius.xl, style: .continuous)
                        .stroke(inputFocused ? accent.opacity(0.50) : Color.acHairline, lineWidth: 1)
                )
                .shadow(color: inputFocused ? accent.opacity(0.12) : .clear, radius: 6, y: 2)
        )
        .animation(.acSnap, value: inputFocused)
        .padding(.horizontal, 14)
    }

    private var canSend: Bool {
        controller.shouldPresentChatAsAvailable
            && !controller.sendingChatMessage
            && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func sendDraft() {
        guard canSend else { return }
        let text = draft
        draft = ""
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
        controller.sendChatMessage(text)
    }
}

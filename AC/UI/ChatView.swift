//
//  ChatView.swift
//  AC
//
//  Compact chat embedded in the popover Home tab.
//  No longer a separate window — fits within 472pt popover width.
//

import AppKit
import SwiftUI

private enum ChatClearAction: String, Identifiable {
    case history
    case memory

    var id: String { rawValue }
}

struct ChatView: View {
    @EnvironmentObject private var controller: AppController
    @State private var draft = ""
    @State private var pendingClearAction: ChatClearAction?
    @State private var successMessage: String?
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Label + clear buttons row
            HStack {
                Label("Chat", systemImage: "bubble.left.and.bubble.right")
                    .font(.ac(13, weight: .semibold))
                    .foregroundStyle(.secondary)

                Spacer()

                Button {
                    pendingClearAction = .history
                } label: {
                    Label("Clear history", systemImage: "trash")
                        .font(.ac(11))
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Clear chat history (memory is kept)")

                Button {
                    pendingClearAction = .memory
                } label: {
                    Label("Clear memory", systemImage: "brain")
                        .font(.ac(11))
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Clear persistent memory")
            }
            .padding(.bottom, 8)

            if !controller.shouldPresentChatAsAvailable {
                Text("Finish setup to start chatting.")
                    .font(.ac(12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                // Message history
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(controller.chatMessages) { message in
                                CompactBubble(message: message)
                                    .id(message.id)
                            }
                        }
                        .padding(10)
                    }
                    .frame(height: 160)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color(nsColor: .underPageBackgroundColor))
                    )
                    .onChange(of: controller.chatMessages.count) { _, _ in
                        if let last = controller.chatMessages.last {
                            withAnimation(.acFade) { proxy.scrollTo(last.id, anchor: .bottom) }
                        }
                    }
                }

                // Input row
                HStack(alignment: .bottom, spacing: 8) {
                    TextField("Ask AccountyCat…", text: $draft, axis: .vertical)
                        .font(.ac(13))
                        .lineLimit(1...4)
                        .textFieldStyle(.roundedBorder)
                        .focused($inputFocused)
                        .onSubmit { sendDraft() }
                        .disabled(controller.sendingChatMessage)

                    Button(action: sendDraft) {
                        Image(systemName: controller.sendingChatMessage
                              ? "ellipsis.circle.fill"
                              : "arrow.up.circle.fill")
                            .font(.system(size: 24, weight: .medium))
                            .foregroundStyle(canSend ? Color.acCaramel : Color.secondary.opacity(0.4))
                            .symbolEffect(.bounce, value: controller.sendingChatMessage)
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSend)
                }
                .padding(.top, 8)
            }
        }
        .alert("Are you sure?", isPresented: Binding(
            get: { pendingClearAction != nil },
            set: { isPresented in
                if !isPresented {
                    pendingClearAction = nil
                }
            }
        )) {
            if pendingClearAction == .history {
                Button("Clear History", role: .destructive) {
                    controller.clearChatHistory()
                    successMessage = "Chat history was cleared."
                    pendingClearAction = nil
                }
            }

            if pendingClearAction == .memory {
                Button("Clear Memory", role: .destructive) {
                    controller.clearMemory()
                    successMessage = "Persistent memory was cleared."
                    pendingClearAction = nil
                }
            }

            Button("Cancel", role: .cancel) {
                pendingClearAction = nil
            }
        } message: {
            switch pendingClearAction {
            case .history:
                Text("This removes the saved conversation history across app restarts.")
            case .memory:
                Text("This removes the saved user memory and preferences AC uses in prompts.")
            case .none:
                Text("")
            }
        }
        .alert("Done", isPresented: Binding(
            get: { successMessage != nil },
            set: { isPresented in
                if !isPresented {
                    successMessage = nil
                }
            }
        )) {
            Button("OK", role: .cancel) { successMessage = nil }
        } message: {
            Text(successMessage ?? "")
        }
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
        controller.sendChatMessage(text)
    }
}

// MARK: - Compact Bubble

private struct CompactBubble: View {
    let message: ChatMessage

    var body: some View {
        if message.role == .system {
            Text(message.text)
                .font(.ac(12))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 4)
        } else {
            HStack {
                if message.role == .user { Spacer(minLength: 32) }

                Text(message.text)
                    .font(.ac(13))
                    .foregroundStyle(message.role == .user
                                     ? Color(red: 0.20, green: 0.12, blue: 0.04)
                                     : Color.primary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(message.role == .user
                                  ? Color.acCaramelSoft
                                  : Color(nsColor: .controlBackgroundColor))
                    )

                if message.role == .assistant { Spacer(minLength: 32) }
            }
        }
    }
}

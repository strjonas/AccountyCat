//
//  ChatView.swift
//  AC
//
//  Embedded chat on the Home tab. Auto-scrolls to the latest message when it
//  first appears and when a new reply arrives. Input is a pill-style field
//  with an inline send button — feels like a modern messaging app without
//  stealing focus from the rest of the popover.
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
        VStack(alignment: .leading, spacing: 10) {
            header

            if !controller.shouldPresentChatAsAvailable {
                Text("Finish setup to start chatting.")
                    .font(.ac(12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 24)
            } else {
                messageList
                inputRow
            }
        }
        .alert("Are you sure?", isPresented: Binding(
            get: { pendingClearAction != nil },
            set: { isPresented in
                if !isPresented { pendingClearAction = nil }
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

            Button("Cancel", role: .cancel) { pendingClearAction = nil }
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
                if !isPresented { successMessage = nil }
            }
        )) {
            Button("OK", role: .cancel) { successMessage = nil }
        } message: {
            Text(successMessage ?? "")
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .font(.system(size: 12))
                .foregroundStyle(Color.acCaramel)
            Text("Chat")
                .font(.ac(13, weight: .semibold))
                .foregroundStyle(Color.acTextPrimary)

            Spacer()

            Menu {
                Button {
                    pendingClearAction = .history
                } label: {
                    Label("Clear chat history", systemImage: "trash")
                }
                Button {
                    pendingClearAction = .memory
                } label: {
                    Label("Clear memory", systemImage: "brain")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 22, height: 22)
        }
    }

    // MARK: - Messages

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(controller.chatMessages) { message in
                        CompactBubble(message: message)
                            .id(message.id)
                    }
                    if controller.sendingChatMessage {
                        TypingIndicator()
                            .id("typing-indicator")
                    }
                    // Sentinel used to always scroll to the very bottom
                    Color.clear
                        .frame(height: 1)
                        .id("chat-bottom-sentinel")
                }
                .padding(10)
            }
            .frame(height: 220)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(nsColor: .underPageBackgroundColor).opacity(0.6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(Color.secondary.opacity(0.12), lineWidth: 1)
                    )
            )
            .onAppear {
                // Jump straight to the bottom — no animation — so the user lands
                // on the most recent exchange the moment the popover opens.
                DispatchQueue.main.async {
                    proxy.scrollTo("chat-bottom-sentinel", anchor: .bottom)
                }
            }
            .onChange(of: controller.chatMessages.count) { _, _ in
                withAnimation(.acFade) {
                    proxy.scrollTo("chat-bottom-sentinel", anchor: .bottom)
                }
            }
            .onChange(of: controller.sendingChatMessage) { _, _ in
                withAnimation(.acFade) {
                    proxy.scrollTo("chat-bottom-sentinel", anchor: .bottom)
                }
            }
        }
    }

    // MARK: - Input

    private var inputRow: some View {
        HStack(alignment: .center, spacing: 6) {
            TextField("Ask AccountyCat…", text: $draft, axis: .vertical)
                .font(.ac(13))
                .lineLimit(1...4)
                .textFieldStyle(.plain)
                .focused($inputFocused)
                .onSubmit { sendDraft() }
                .disabled(controller.sendingChatMessage)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)

            Button(action: sendDraft) {
                Image(systemName: controller.sendingChatMessage
                      ? "ellipsis"
                      : "arrow.up")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(canSend ? Color.white : Color.secondary.opacity(0.65))
                    .frame(width: 28, height: 28)
                    .background(
                        Circle().fill(canSend
                                      ? Color.acCaramel
                                      : Color.secondary.opacity(0.18))
                    )
                    .symbolEffect(.bounce, value: controller.sendingChatMessage)
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .padding(.trailing, 5)
        }
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(inputFocused
                                ? Color.acCaramel.opacity(0.55)
                                : Color.secondary.opacity(0.22),
                                lineWidth: 1)
                )
        )
        .animation(.acSnap, value: inputFocused)
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
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 4)
        } else {
            HStack {
                if message.role == .user { Spacer(minLength: 40) }

                Text(message.text)
                    .font(.ac(13))
                    .foregroundStyle(message.role == .user
                                     ? Color(red: 0.20, green: 0.12, blue: 0.04)
                                     : Color.primary)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(bubbleBackground)

                if message.role == .assistant { Spacer(minLength: 40) }
            }
        }
    }

    @ViewBuilder
    private var bubbleBackground: some View {
        if message.role == .user {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color.acCaramelLight, Color.acCaramelSoft],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        } else {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.secondary.opacity(0.12), lineWidth: 1)
                )
        }
    }
}

// MARK: - Typing indicator

private struct TypingIndicator: View {
    @State private var phase: Int = 0

    var body: some View {
        HStack {
            HStack(spacing: 4) {
                ForEach(0..<3) { i in
                    Circle()
                        .fill(Color.secondary.opacity(phase == i ? 0.85 : 0.35))
                        .frame(width: 5, height: 5)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(Color.secondary.opacity(0.12), lineWidth: 1)
                    )
            )
            Spacer(minLength: 40)
        }
        .onAppear {
            Task { @MainActor in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 320_000_000)
                    withAnimation(.easeInOut(duration: 0.18)) {
                        phase = (phase + 1) % 3
                    }
                }
            }
        }
    }
}

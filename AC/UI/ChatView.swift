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

private let chatSuggestions = [
    "Don't let me use Instagram today",
    "I'm taking a break — social apps are fine",
    "What does the 'limit' rule mean?",
    "Please help me stick to making my presentation, don't even let me code",
]

struct ChatView: View {
    @EnvironmentObject private var controller: AppController
    @Environment(\.acAccent) private var accent
    @State private var draft = ""
    @State private var pendingClearAction: ChatClearAction?
    @State private var successMessage: String?
    @State private var pendingUndoToast: DeletedChatToast?
    @FocusState private var inputFocused: Bool

    var body: some View {
        ZStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                header

                if !controller.shouldPresentChatAsAvailable {
                    Text("Finish setup to start chatting.")
                        .font(.ac(12))
                        .foregroundStyle(Color.acTextPrimary.opacity(0.68))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 24)
                } else {
                    messageList
                    inputRow
                        .background {
                            Button {
                                sendDraft()
                            } label: { EmptyView() }
                            .keyboardShortcut(.return, modifiers: .command)
                            .opacity(0)
                            .frame(width: 0, height: 0)
                        }
                }
            }

            if let toast = pendingUndoToast {
                undoToast(toast)
            }
        }
        .onAppear {
            if controller.shouldPresentChatAsAvailable {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    inputFocused = true
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .acFocusChatInput)) { _ in
            if controller.shouldPresentChatAsAvailable {
                inputFocused = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .acUnfocusChatInput)) { _ in
            inputFocused = false
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
        HStack(spacing: 8) {
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(accent)
                .frame(width: 18, height: 18)
                .background(Circle().fill(accent.opacity(0.13)))
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
                Image(systemName: "ellipsis")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.acTextPrimary.opacity(0.68))
                    .frame(width: 24, height: 22)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }

    // MARK: - Messages

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if hasConversationMessages {
                        ForEach(conversationMessages) { message in
                            CompactBubble(message: message, accent: accent) {
                                handleDelete(message)
                            }
                                .id(message.id)
                                .contextMenu {
                                    Button(message.style == .nudge ? "Delete nudge" : "Delete message",
                                           role: .destructive) {
                                        handleDelete(message)
                                    }
                                }
                        }
                    } else if !controller.sendingChatMessage {
                        EmptyChatState(suggestions: chatSuggestions) { suggestion in
                            draft = suggestion
                            inputFocused = true
                        }
                        .padding(.top, 8)
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
                RoundedRectangle(cornerRadius: ACRadius.lg, style: .continuous)
                    .fill(Color(nsColor: .underPageBackgroundColor).opacity(0.55))
                    .overlay(
                        RoundedRectangle(cornerRadius: ACRadius.lg, style: .continuous)
                            .stroke(Color.acHairline, lineWidth: 1)
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

    private var conversationMessages: [ChatMessage] {
        controller.chatMessages.filter { $0.role != .system }
    }

    private var hasConversationMessages: Bool {
        !conversationMessages.isEmpty
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
                .padding(.horizontal, 14)
                .padding(.vertical, 10)

            Button(action: sendDraft) {
                Image(systemName: controller.sendingChatMessage
                      ? "ellipsis"
                      : "arrow.up")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(canSend ? Color.white : Color.acTextPrimary.opacity(0.5))
                    .frame(width: 28, height: 28)
                    .background(
                        Circle()
                            .fill(canSend ? accent : Color.acSurface)
                            .shadow(color: canSend ? accent.opacity(0.35) : .clear, radius: 4, y: 2)
                    )
                    .symbolEffect(.bounce, value: controller.sendingChatMessage)
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .padding(.trailing, 5)
            .animation(.acSnap, value: canSend)
        }
        .background(
            RoundedRectangle(cornerRadius: ACRadius.xl, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: ACRadius.xl, style: .continuous)
                        .stroke(inputFocused
                                ? accent.opacity(0.55)
                                : Color.acHairline,
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

    private func handleDelete(_ message: ChatMessage) {
        guard let removed = controller.deleteChatMessage(id: message.id) else { return }
        showUndoToast(message: removed.message, index: removed.index)
    }

    private func showUndoToast(message: ChatMessage, index: Int) {
        let toast = DeletedChatToast(message: message, index: index)
        pendingUndoToast = toast
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if pendingUndoToast?.id == toast.id {
                pendingUndoToast = nil
            }
        }
    }

    @ViewBuilder
    private func undoToast(_ toast: DeletedChatToast) -> some View {
        HStack(spacing: 10) {
            Text("Message deleted")
                .font(.ac(12, weight: .semibold))
                .foregroundStyle(Color.acTextPrimary)

            Button("Undo") {
                controller.restoreChatMessage(toast.message, at: toast.index)
                pendingUndoToast = nil
            }
            .buttonStyle(.plain)
            .font(.ac(12, weight: .semibold))
            .foregroundStyle(accent)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            Capsule(style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor))
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(Color.acHairline, lineWidth: 1)
                )
                .shadow(color: Color.black.opacity(0.12), radius: 8, y: 4)
        )
        .padding(.bottom, 6)
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .animation(.acSnap, value: pendingUndoToast?.id)
    }


private struct DeletedChatToast: Identifiable, Equatable {
    let id = UUID()
    let message: ChatMessage
    let index: Int
}
    private func sendDraft() {
        guard canSend else { return }
        let text = draft
        draft = ""
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
        controller.sendChatMessage(text)
    }
}

// MARK: - Suggestion Chips

private struct EmptyChatState: View {
    let suggestions: [String]
    let onSelect: (String) -> Void
    @Environment(\.acAccent) private var accent

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: "sparkles")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(accent)
                Text("How can I help?")
                    .font(.ac(13, weight: .semibold))
                    .foregroundStyle(Color.acTextPrimary)
            }

            Text("Try one of these quick prompts to start the conversation.")
                .font(.ac(11))
                .foregroundStyle(Color.acTextPrimary.opacity(0.72))

            SuggestionChips(suggestions: suggestions, onSelect: onSelect)
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: ACRadius.md, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor).opacity(0.65))
                .overlay(
                    RoundedRectangle(cornerRadius: ACRadius.md, style: .continuous)
                        .stroke(Color.acHairline, lineWidth: 1)
                )
        )
    }
}

private struct SuggestionChips: View {
    let suggestions: [String]
    let onSelect: (String) -> Void

    var body: some View {
        FlowLayout(spacing: 8) {
            ForEach(suggestions, id: \.self) { suggestion in
                Button(suggestion) { onSelect(suggestion) }
                    .buttonStyle(SuggestionChipStyle())
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SuggestionChipStyle: ButtonStyle {
    @Environment(\.acAccent) private var accent

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.ac(12))
            .foregroundStyle(Color.acTextPrimary)
            .lineLimit(1)
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(
                Capsule(style: .continuous)
                    .fill(configuration.isPressed
                          ? accent.opacity(0.20)
                          : Color(nsColor: .windowBackgroundColor).opacity(0.85))
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(configuration.isPressed
                                    ? accent.opacity(0.45)
                                    : Color.acHairline,
                                    lineWidth: 1)
                    )
            )
            .animation(.acSnap, value: configuration.isPressed)
    }
}

private struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > width && x > 0 {
                y += rowHeight + spacing
                x = 0
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        var rowViews: [(subview: LayoutSubview, size: CGSize)] = []

        func flushRow() {
            var rx = bounds.minX
            for (subview, size) in rowViews {
                subview.place(at: CGPoint(x: rx, y: y), proposal: .unspecified)
                rx += size.width + spacing
            }
        }

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX && !rowViews.isEmpty {
                flushRow()
                y += rowHeight + spacing
                x = bounds.minX
                rowHeight = 0
                rowViews = []
            }
            rowViews.append((subview, size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        flushRow()
    }
}

// MARK: - Compact Bubble

private struct CompactBubble: View {
    let message: ChatMessage
    let accent: Color
    let onDelete: () -> Void
    @State private var isHovering = false

    var body: some View {
        if message.role == .system {
            Text(message.text)
                .font(.ac(12))
                .foregroundStyle(Color.acTextPrimary.opacity(0.72))
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 4)
        } else {
            HStack {
                if message.role == .user { Spacer(minLength: 40) }

                ZStack(alignment: .topTrailing) {
                    VStack(alignment: .leading, spacing: 5) {
                        if message.style == .nudge || message.style == .celebration {
                            Label(
                                message.style == .celebration ? "Win" : "Nudge",
                                systemImage: message.style == .celebration ? "sparkles" : "pawprint.fill"
                            )
                                .font(.ac(10, weight: .semibold))
                                .foregroundStyle(accent.opacity(0.85))
                        }

                        Text(message.text)
                            .font(.ac(13))
                            .foregroundStyle(message.role == .user ? Color.white : Color.acTextPrimary)
                            .textSelection(.enabled)
                    }
                    .padding(.horizontal, 13)
                    .padding(.vertical, 9)
                    .background(bubbleBackground)

                    Button {
                        onDelete()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(message.role == .user ? Color.white : Color.acTextPrimary)
                            .frame(width: 18, height: 18)
                            .background(
                                Circle()
                                    .fill(message.role == .user
                                          ? Color.white.opacity(0.22)
                                          : Color.acSurface)
                            )
                    }
                    .buttonStyle(.plain)
                    .padding(6)
                    .opacity(isHovering ? 1 : 0)
                    .animation(.acSnap, value: isHovering)
                    .accessibilityLabel(message.style == .nudge ? "Delete nudge" : "Delete message")
                }
                .onHover { hovering in
                    isHovering = hovering
                }

                if message.role == .assistant { Spacer(minLength: 40) }
            }
        }
    }

    @ViewBuilder
    private var bubbleBackground: some View {
        if message.role == .user {
            RoundedRectangle(cornerRadius: ACRadius.lg, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [accent.opacity(0.45), accent.opacity(0.25)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: ACRadius.lg, style: .continuous)
                        .stroke(accent.opacity(0.30), lineWidth: 0.5)
                )
        } else {
            RoundedRectangle(cornerRadius: ACRadius.lg, style: .continuous)
                .fill(
                    message.style == .nudge || message.style == .celebration
                        ? accent.opacity(message.style == .celebration ? 0.15 : 0.10)
                        : Color(nsColor: .controlBackgroundColor)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: ACRadius.lg, style: .continuous)
                        .stroke(
                            message.style == .nudge || message.style == .celebration
                                ? accent.opacity(0.28)
                                : Color.acHairline,
                            lineWidth: 1
                        )
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
                        .fill(Color.acTextPrimary.opacity(phase == i ? 0.75 : 0.45))
                        .frame(width: 5, height: 5)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: ACRadius.lg, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .overlay(
                        RoundedRectangle(cornerRadius: ACRadius.lg, style: .continuous)
                            .stroke(Color.acHairline, lineWidth: 1)
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

//
//  ChatScrollView.swift
//  AC
//
//  Native v2 chat surface: day separators, cat/user bubbles, and inline
//  nudge/win/context cards matching the design handoff.
//

import SwiftUI

struct ChatScrollView: View {
    @EnvironmentObject private var controller: AppController
    @Environment(\.acAccent) private var accent

    private var messages: [ChatMessage] {
        controller.chatMessages.filter { $0.role != .system }
    }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 10) {
            if messages.isEmpty && !controller.sendingChatMessage {
                EmptyV2ChatState()
                    .environmentObject(controller)
            } else {
                ForEach(Array(messages.enumerated()), id: \.element.id) { index, message in
                    if shouldShowDaySeparator(before: index) {
                        DaySeparator(label: dayLabel(for: message.timestamp))
                    }
                    ChatMessageRow(message: message)
                        .environmentObject(controller)
                }
            }

            if controller.sendingChatMessage {
                TypingRow()
            }

            Color.clear
                .frame(height: 1)
                .id("chat-bottom-sentinel")
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 6)
    }

    private func shouldShowDaySeparator(before index: Int) -> Bool {
        guard index > 0 else { return true }
        let current = messages[index].timestamp
        let previous = messages[index - 1].timestamp
        return !Calendar.current.isDate(current, inSameDayAs: previous)
    }

    private func dayLabel(for date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return "Today" }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d"
        return formatter.string(from: date)
    }
}

private struct DaySeparator: View {
    let label: String

    var body: some View {
        HStack(spacing: 10) {
            Rectangle().fill(Color.acHairline).frame(height: 0.5)
            Text(label.uppercased())
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(Color.acTextPrimary.opacity(0.42))
            Rectangle().fill(Color.acHairline).frame(height: 0.5)
        }
        .padding(.vertical, 2)
    }
}

private struct ChatMessageRow: View {
    @EnvironmentObject private var controller: AppController
    @Environment(\.acAccent) private var accent
    let message: ChatMessage
    @State private var isHovering = false

    private var isUser: Bool { message.role == .user }

    var body: some View {
        Group {
            switch message.style {
            case .celebration:
                WinCard(message: message)
            case .nudge:
                NudgeCard(message: message)
            case .suggestion:
                ContextCard(message: message)
            case .standard:
                bubbleRow
            }
        }
        .contextMenu {
            Button("Delete message", role: .destructive) {
                _ = controller.deleteChatMessage(id: message.id)
            }
        }
    }

    private var bubbleRow: some View {
        HStack(alignment: .top, spacing: 8) {
            if isUser { Spacer(minLength: 76) } else { avatar }

            VStack(alignment: isUser ? .trailing : .leading, spacing: 3) {
                ZStack(alignment: .topTrailing) {
                    Text(message.text)
                        .font(.ac(13))
                        .lineSpacing(2)
                        .foregroundStyle(isUser ? Color.white.opacity(0.96) : Color.acTextPrimary)
                        .textSelection(.enabled)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(bubbleBackground)

                    Button {
                        _ = controller.deleteChatMessage(id: message.id)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(
                                isUser
                                    ? Color.white.opacity(0.8) : Color.acTextPrimary.opacity(0.55)
                            )
                            .frame(width: 16, height: 16)
                            .background(
                                Circle().fill(
                                    isUser ? Color.white.opacity(0.18) : Color.acSurfaceElevated))
                    }
                    .buttonStyle(.plain)
                    .padding(5)
                    .opacity(isHovering ? 1 : 0)
                }

                Text(timeLabel)
                    .font(.system(size: 9.5, weight: .regular, design: .monospaced))
                    .foregroundStyle(Color.acTextPrimary.opacity(0.38))
                    .padding(.horizontal, 4)
            }
            .frame(maxWidth: 260, alignment: isUser ? .trailing : .leading)
            .onHover { isHovering = $0 }

            if !isUser { Spacer(minLength: 44) }
        }
    }

    private var avatar: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.acBubbleFill)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.acBubbleStroke, lineWidth: 0.5)
                )
            CatView(
                character: controller.state.character,
                expression: .neutral,
                size: 29,
                animating: false
            )
        }
        .frame(width: 34, height: 34)
    }

    private var bubbleBackground: some View {
        UnevenRoundedRectangle(
            topLeadingRadius: isUser ? ACRadius.bubble : 4,
            bottomLeadingRadius: ACRadius.bubble,
            bottomTrailingRadius: ACRadius.bubble,
            topTrailingRadius: isUser ? 4 : ACRadius.bubble,
            style: .continuous
        )
        .fill(isUser ? accent.opacity(0.58) : Color.acBubbleFill)
        .overlay(
            UnevenRoundedRectangle(
                topLeadingRadius: isUser ? ACRadius.bubble : 4,
                bottomLeadingRadius: ACRadius.bubble,
                bottomTrailingRadius: ACRadius.bubble,
                topTrailingRadius: isUser ? 4 : ACRadius.bubble,
                style: .continuous
            )
            .stroke(isUser ? accent.opacity(0.28) : Color.acBubbleStroke, lineWidth: 0.5)
        )
    }

    private var timeLabel: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "h:mm a"
        return formatter.string(from: message.timestamp)
    }
}

private struct WinCard: View {
    @Environment(\.acAccent) private var accent
    let message: ChatMessage

    var body: some View {
        HStack(spacing: 12) {
            Text("✦")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(accent)
            VStack(alignment: .leading, spacing: 3) {
                Text(message.text)
                    .font(.ac(13, weight: .semibold))
                    .foregroundStyle(Color.acTextPrimary)
                    .lineLimit(3)
                Text("focus win")
                    .font(.ac(11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(accent.opacity(0.10))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(accent.opacity(0.32), lineWidth: 0.5)
                )
        )
    }
}

private struct NudgeCard: View {
    @EnvironmentObject private var controller: AppController
    @Environment(\.acAccent) private var accent
    @Environment(\.colorScheme) private var colorScheme
    let message: ChatMessage

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            // Left accent bar
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(accent)
                .frame(width: 3)
                .padding(.vertical, 12)
                .padding(.leading, 12)

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("drift detected")
                            .font(.ac(11.5, weight: .semibold))
                            .foregroundStyle(accent)
                        Text(message.text)
                            .font(.ac(11))
                            .foregroundStyle(Color.acTextPrimary.opacity(0.80))
                            .lineLimit(3)
                    }
                    Spacer()
                }


            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .background(nudgeCardBackground)
    }

    private var nudgeCardBackground: some View {
        ZStack {
            if controller.state.glassEffectActive {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.ultraThinMaterial)

                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                accent.opacity(colorScheme == .dark ? 0.10 : 0.08),
                                accent.opacity(0.02),
                                Color.clear,
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )

                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(accent.opacity(colorScheme == .dark ? 0.18 : 0.12), lineWidth: 0.5)
            } else {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.acNudgeSurface)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(Color.acNudgeStroke, lineWidth: 0.5)
                    )
            }
        }
    }
}

private struct ContextCard: View {
    let message: ChatMessage

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "scope")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.acTextPrimary.opacity(0.38))
            Text(message.text)
                .font(.ac(11.5))
                .italic()
                .foregroundStyle(Color.acTextPrimary.opacity(0.72))
                .lineLimit(3)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.acContextSurface)
        )
    }
}

private struct EmptyV2ChatState: View {
    @EnvironmentObject private var controller: AppController
    @Environment(\.acAccent) private var accent

    private let suggestions = [
        "I want to focus on coding for an hour",
        "Don't let me scroll Instagram today",
        "Help me stay off social media this afternoon",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                CatView(
                    character: controller.state.character,
                    expression: .happy,
                    size: 29,
                    animating: false
                )
                .frame(width: 34, height: 34)

                Text(
                    "Hey — I'm AC. I look over your shoulder and gently nudge you when you drift. Tell me what you're focusing on, what you want to avoid, or just say hi."
                )
                .font(.ac(13))
                .lineSpacing(2)
                .foregroundStyle(Color.acTextPrimary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    UnevenRoundedRectangle(
                        topLeadingRadius: 4,
                        bottomLeadingRadius: ACRadius.bubble,
                        bottomTrailingRadius: ACRadius.bubble,
                        topTrailingRadius: ACRadius.bubble,
                        style: .continuous
                    )
                    .fill(Color.acBubbleFill)
                    .overlay(
                        UnevenRoundedRectangle(
                            topLeadingRadius: 4,
                            bottomLeadingRadius: ACRadius.bubble,
                            bottomTrailingRadius: ACRadius.bubble,
                            topTrailingRadius: ACRadius.bubble,
                            style: .continuous
                        )
                        .stroke(Color.acBubbleStroke, lineWidth: 0.5)
                    )
                )
                Spacer(minLength: 44)
            }

            VStack(alignment: .trailing, spacing: 6) {
                ForEach(suggestions, id: \.self) { text in
                    Button {
                        controller.sendChatMessage(text)
                    } label: {
                        HStack(spacing: 6) {
                            Text(text)
                                .font(.ac(12, weight: .medium))
                                .lineSpacing(2)
                                .multilineTextAlignment(.trailing)
                            Image(systemName: "arrow.up.circle.fill")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(accent.opacity(0.85))
                        }
                        .foregroundStyle(Color.acTextPrimary.opacity(0.85))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(
                            UnevenRoundedRectangle(
                                topLeadingRadius: ACRadius.bubble,
                                bottomLeadingRadius: ACRadius.bubble,
                                bottomTrailingRadius: 4,
                                topTrailingRadius: ACRadius.bubble,
                                style: .continuous
                            )
                            .fill(Color.acSurface)
                            .overlay(
                                UnevenRoundedRectangle(
                                    topLeadingRadius: ACRadius.bubble,
                                    bottomLeadingRadius: ACRadius.bubble,
                                    bottomTrailingRadius: 4,
                                    topTrailingRadius: ACRadius.bubble,
                                    style: .continuous
                                )
                                .stroke(accent.opacity(0.22), lineWidth: 0.5)
                            )
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.leading, 44)
        }
    }
}

private struct TypingRow: View {
    @State private var phase = 0

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                ForEach(0..<3) { i in
                    Circle()
                        .fill(Color.acTextPrimary.opacity(phase == i ? 0.72 : 0.35))
                        .frame(width: 5, height: 5)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: ACRadius.bubble, style: .continuous)
                    .fill(Color.acBubbleFill)
                    .overlay(
                        RoundedRectangle(cornerRadius: ACRadius.bubble, style: .continuous)
                            .stroke(Color.acBubbleStroke, lineWidth: 0.5)
                    )
            )
            Spacer(minLength: 44)
        }
        .onAppear {
            Timer.scheduledTimer(withTimeInterval: 0.35, repeats: true) { _ in
                phase = (phase + 1) % 3
            }
        }
    }
}

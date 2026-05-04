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
                            .foregroundStyle(isUser ? Color.white.opacity(0.8) : Color.acTextPrimary.opacity(0.55))
                            .frame(width: 16, height: 16)
                            .background(Circle().fill(isUser ? Color.white.opacity(0.18) : Color.acSurface))
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
                .fill(Color.white.opacity(0.42))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.white.opacity(0.46), lineWidth: 0.5)
                )
            CatView(
                character: controller.state.character,
                skin: controller.state.selectedSkin,
                expression: .neutral,
                size: 25,
                animating: false
            )
        }
        .frame(width: 32, height: 32)
    }

    private var bubbleBackground: some View {
        UnevenRoundedRectangle(
            topLeadingRadius: isUser ? ACRadius.bubble : 4,
            bottomLeadingRadius: ACRadius.bubble,
            bottomTrailingRadius: ACRadius.bubble,
            topTrailingRadius: isUser ? 4 : ACRadius.bubble,
            style: .continuous
        )
        .fill(isUser ? accent.opacity(0.58) : Color.white.opacity(0.56))
        .overlay(
            UnevenRoundedRectangle(
                topLeadingRadius: isUser ? ACRadius.bubble : 4,
                bottomLeadingRadius: ACRadius.bubble,
                bottomTrailingRadius: ACRadius.bubble,
                topTrailingRadius: isUser ? 4 : ACRadius.bubble,
                style: .continuous
            )
            .stroke(isUser ? accent.opacity(0.28) : Color.white.opacity(0.42), lineWidth: 0.5)
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
    let message: ChatMessage

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Circle()
                    .fill(Color(red: 0.91, green: 0.61, blue: 0.48))
                    .frame(width: 8, height: 8)
                    .padding(.top, 4)
                VStack(alignment: .leading, spacing: 2) {
                    Text("drift detected")
                        .font(.ac(11.5, weight: .semibold))
                        .foregroundStyle(Color(red: 0.55, green: 0.35, blue: 0.23))
                    Text(message.text)
                        .font(.ac(11))
                        .foregroundStyle(Color(red: 0.55, green: 0.35, blue: 0.23).opacity(0.72))
                        .lineLimit(3)
                }
            }

            HStack(spacing: 6) {
                Text("back to work")
                    .font(.ac(11, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule(style: .continuous).fill(Color(red: 0.55, green: 0.35, blue: 0.23).opacity(0.86)))
                Text("it's research")
                    .font(.ac(11, weight: .medium))
                    .foregroundStyle(Color.acTextPrimary.opacity(0.7))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule(style: .continuous).fill(Color.black.opacity(0.05)))
            }
            .padding(.leading, 18)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Color(red: 1.0, green: 0.94, blue: 0.86).opacity(0.55))
                .overlay(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .stroke(Color(red: 0.91, green: 0.61, blue: 0.48).opacity(0.35), lineWidth: 0.5)
                )
        )
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
                .fill(Color.black.opacity(0.04))
        )
    }
}

private struct EmptyV2ChatState: View {
    @EnvironmentObject private var controller: AppController

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            CatView(
                character: controller.state.character,
                skin: controller.state.selectedSkin,
                expression: .neutral,
                size: 25,
                animating: false
            )
            .frame(width: 32, height: 32)

            Text("morning. no focus active — i'm watching but won't nudge unless you want me to. start a profile when you're ready.")
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
                    .fill(Color.white.opacity(0.56))
                )
            Spacer(minLength: 44)
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
                    .fill(Color.white.opacity(0.56))
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

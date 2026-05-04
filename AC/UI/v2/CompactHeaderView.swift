//
//  CompactHeaderView.swift
//  AC
//
//  Compact header for the new main panel: mini cat avatar + character name +
//  status dot + status text. Gear → settings, × → close. DEBUG-only hammer.
//

import SwiftUI

struct CompactHeaderView: View {
    @EnvironmentObject private var controller: AppController
    @Environment(\.acAccent) private var accent

    var onShowSettings: () -> Void
    var onBackToChat: () -> Void = {}
    var onClose: () -> Void
    var isShowingSettings = false

    var body: some View {
        HStack(spacing: 10) {
            // Left: mini cat + meta
            HStack(spacing: 8) {
                miniCatAvatar

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(controller.state.character.displayName)
                            .font(.ac(13, weight: .semibold))
                            .foregroundStyle(Color.acTextPrimary)
                        statusDot
                        Text(statusTitle)
                            .font(.ac(10, weight: .medium))
                            .foregroundStyle(.secondary)
                    }

                    if let subtitle = statusSubtitle {
                        Text(subtitle)
                            .font(.ac(10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }

            Spacer(minLength: 4)

            if isShowingSettings {
                Button {
                    onBackToChat()
                } label: {
                    Text("← back")
                        .font(.ac(12, weight: .semibold))
                        .foregroundStyle(accent)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(
                            Capsule(style: .continuous)
                                .fill(accent.opacity(0.10))
                                .overlay(Capsule(style: .continuous).stroke(accent.opacity(0.24), lineWidth: 0.5))
                        )
                }
                .buttonStyle(.plain)
                .help("Back to chat")
            } else {
                Button {
                    onShowSettings()
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.secondary.opacity(0.75))
                }
                .buttonStyle(.plain)
                .help("Settings (⌘,)")
            }

            Button {
                onClose()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color.secondary.opacity(0.75))
                    .padding(4)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Close (Esc)")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Mini cat avatar

    private var miniCatAvatar: some View {
        let isPaused = controller.state.isPaused
        let isSetup = controller.state.setupStatus != .ready
        return ZStack {
            CatView(
                character: controller.state.character,
                skin: controller.state.selectedSkin,
                expression: controller.companionMood.catExpression,
                size: 24,
                animating: false
            )
            .saturation(isPaused ? 0.15 : 1.0)
            .brightness(isPaused ? 0.12 : 0)

            if isSetup {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white.opacity(0.9))
                    .shadow(color: .black.opacity(0.3), radius: 1, y: 0.5)
            }
        }
        .frame(width: 24, height: 20)
    }

    // MARK: - Status dot

    @State private var healthPulse: CGFloat = 0

    private var statusDot: some View {
        ZStack {
            Circle()
                .fill(healthColor.opacity(0.28))
                .frame(width: 10, height: 10)
                .scaleEffect(1 + healthPulse)
                .opacity(0.8 - healthPulse * 0.7)
            Circle()
                .fill(healthColor)
                .frame(width: 5, height: 5)
        }
        .frame(width: 10, height: 10)
        .onAppear {
            if controller.state.setupStatus == .ready && !controller.state.isPaused {
                withAnimation(.easeOut(duration: 1.6).repeatForever(autoreverses: false)) {
                    healthPulse = 0.9
                }
            }
        }
    }

    private var healthColor: Color {
        guard controller.state.setupStatus == .ready else { return .red.opacity(0.7) }
        if controller.state.isPaused { return Color.acAmber }
        if controller.hasUnreadChatMessages { return accent }
        return .green
    }

    // MARK: - Status text

    private var statusTitle: String {
        switch controller.state.setupStatus {
        case .ready:
            return controller.state.isPaused ? "on break" : "with you"
        case .needsPermissions, .needsRuntime, .blocked, .checking, .installing, .failed:
            return "Needs setup"
        }
    }

    private var statusSubtitle: String? {
        switch controller.state.setupStatus {
        case .ready:
            let model = controller.activeModelShortName
            let profile = controller.state.activeProfile.name
            if controller.state.isPaused {
                return "Monitoring is paused · \(model)"
            }
            return profile == "General" ? model : "\(profile) · \(model)"
        case .checking:
            return "Checking system setup…"
        case .needsPermissions:
            return "Grant screen recording permission"
        case .needsRuntime:
            return "Download a model to begin monitoring"
        case .blocked:
            return "Setup is blocked — check Settings"
        case .installing:
            return "Installing runtime…"
        case .failed:
            return "Setup failed — try again in Settings"
        }
    }
}

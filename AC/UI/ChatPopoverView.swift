//
//  ChatPopoverView.swift
//  AC
//
//  Chat-first main popover — the primary surface for interacting with AC.
//  No tabs; the conversation fills the view.  Context, settings, and
//  developer tools are one click away through the header and bottom bar.
//

import SwiftUI

struct ChatPopoverView: View {
    @EnvironmentObject private var controller: AppController
    @Environment(\.acAccent) private var accent
    @Environment(\.colorScheme) private var colorScheme

    @State private var showSettings = false
    @State private var statsExpanded = false
    @State private var healthPulse: CGFloat = 0

    #if DEBUG
        @State private var showDebug = false
    #endif

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        if !controller.hasCompletedOnboardingWizard
                            && controller.state.setupStatus != .ready
                        {
                            OnboardingWizardView()
                                .environmentObject(controller)
                                .padding(18)
                        } else if controller.state.setupStatus != .ready
                            || controller.showingOnboardingCompletion
                        {
                            OnboardingDialogView(showModeChooser: false)
                                .environmentObject(controller)
                                .padding(18)
                        } else {
                            statsInlineCard
                                .padding(.horizontal, 14)
                                .padding(.top, 12)

                            ChatView()
                                .environmentObject(controller)
                                .padding(.horizontal, 14)
                                .padding(.top, 4)
                        }
                    }
                }
                .onChange(of: controller.chatMessages.count) { _, _ in
                    withAnimation(.acFade) {
                        proxy.scrollTo("chat-bottom-sentinel", anchor: .bottom)
                    }
                }
            }

            Divider().opacity(0.5)
            ContextBar()
                .environmentObject(controller)
        }
        .frame(width: ACD.popoverWidth)
        .background(Color(nsColor: .windowBackgroundColor))
        .acAccent(for: controller.state.character)
        .animation(.acFade, value: controller.state.character)
        .onAppear { controller.refreshSystemState() }
        .onReceive(NotificationCenter.default.publisher(for: .acOpenSettings)) { _ in
            showSettings = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .acDismissSheet)) { _ in
            if showSettings {
                showSettings = false
            } else if controller.showRulesSheetFromContextBar {
                controller.showRulesSheetFromContextBar = false
            }
            #if DEBUG
            if showDebug { showDebug = false }
            #endif
        }
        .onChange(of: statsExpanded) { _, expanded in
            let height: CGFloat = expanded ? 580 : 460
            controller.resizePopover?(NSSize(width: ACD.popoverWidth, height: height))
        }
        .sheet(isPresented: $showSettings) {
            SettingsSheet()
                .environmentObject(controller)
        }
        .sheet(isPresented: $controller.showRulesSheetFromContextBar) {
            RulesSheet()
                .environmentObject(controller)
        }
        #if DEBUG
            .sheet(isPresented: $showDebug) {
                DebugSheet()
                .environmentObject(controller)
            }
        #endif
        // Keyboard shortcuts — invisible buttons that fire from the keyboard
        .background {
            VStack {
                Button {
                    NotificationCenter.default.post(name: .acFocusChatInput, object: nil)
                } label: { EmptyView() }
                .keyboardShortcut("k", modifiers: .command)
                .opacity(0)
                .frame(width: 0, height: 0)

                Button {
                    showSettings = true
                } label: { EmptyView() }
                .keyboardShortcut(",", modifiers: .command)
                .opacity(0)
                .frame(width: 0, height: 0)
            }
        }
    }

    // MARK: - Header (44pt)

    private var header: some View {
        HStack(spacing: 10) {
            // Status label + model
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    healthDot

                    Text(statusTitle)
                        .font(.ac(13, weight: .semibold))
                        .foregroundStyle(Color.acTextPrimary)
                }

                if let subtitle = statusSubtitle {
                    Text(subtitle)
                        .font(.ac(10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 4)

            ProfileControlBar()
                .environmentObject(controller)

            #if DEBUG
                debugButton
            #endif

            Button {
                showSettings = true
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.secondary.opacity(0.75))
            }
            .buttonStyle(.plain)
            .help("Settings (⌘,)")

            Button {
                controller.dismissPopover?()
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
        .background(
            headerBackground
                .contentShape(Rectangle())
                .onTapGesture {
                    NotificationCenter.default.post(name: .acUnfocusChatInput, object: nil)
                }
        )
    }

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

    // MARK: - Health dot

    private var healthDot: some View {
        ZStack {
            Circle()
                .fill(healthColor.opacity(0.32))
                .frame(width: 12, height: 12)
                .scaleEffect(1 + healthPulse)
                .opacity(0.8 - healthPulse * 0.7)
            Circle()
                .fill(healthColor)
                .frame(width: 6, height: 6)
        }
        .frame(width: 12, height: 12)
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

    // MARK: - Debug button (DEBUG only)

    #if DEBUG
        private var debugButton: some View {
            Button {
                showDebug = true
            } label: {
                Image(systemName: "hammer.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.orange.opacity(0.7))
            }
            .buttonStyle(ACIconButton(size: 24))
        }
    #endif

    // MARK: - Stats inline card

    private var statsInlineCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.acSnap) { statsExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chart.bar.xaxis")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(accent)
                    Text(statsSummaryText)
                        .font(.acCaption)
                        .foregroundStyle(.secondary)
                    Image(systemName: statsExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.secondary.opacity(0.6))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    Capsule(style: .continuous)
                        .fill(Color.acSurface)
                        .overlay(Capsule(style: .continuous).stroke(Color.acHairline, lineWidth: 1))
                )
            }
            .buttonStyle(.plain)

            if statsExpanded {
                StatsSection(
                    stats: controller.todayStats,
                    accent: controller.state.character.accentColor
                )
                .transition(AnyTransition.opacity.combined(with: AnyTransition.move(edge: .top)))
            }
        }
        .animation(.acSnap, value: statsExpanded)
    }

    private var statsSummaryText: String {
        let s = controller.todayStats
        let focused = formatDuration(s.focusedSeconds)
        let streak = "\(s.streakDays)d"
        return "\(focused) focused · \(streak) streak"
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        if h > 0 { return "\(h)h \(m)m" }
        if m > 0 { return "\(m)m" }
        return "0m"
    }

    // MARK: - Header background

    private var headerBackground: some View {
        let ch = controller.state.character
        if colorScheme == .dark {
            return AnyView(
                LinearGradient(
                    colors: [ch.headerDarkTop, ch.headerDarkBottom],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
        } else {
            return AnyView(
                LinearGradient(
                    colors: [ch.headerLightTop, ch.headerLightBottom],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
        }
    }
}

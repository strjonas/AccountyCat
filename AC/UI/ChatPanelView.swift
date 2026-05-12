//
//  ChatPanelView.swift
//  AC
//
//  Main v2 panel. Settings and the profile picker live inside the panel, so
//  the whole surface reads like one coherent product instead of old sheets.
//

import SwiftUI

struct ChatPanelView: View {
    @EnvironmentObject private var controller: AppController
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.acAccent) private var accent

    @State private var showSettings = false
    @State private var showProfilePicker = false
    @State private var showCelebration = false
    @State private var celebrationSessionName = ""

    #if DEBUG
    @State private var showDebug = false
    #endif

    var body: some View {
        VStack(spacing: 0) {
            ProfileBarView {
                withAnimation(.acSnap) {
                    showProfilePicker.toggle()
                    showSettings = false
                }
            }
            .environmentObject(controller)

            HStack(spacing: 0) {
                CompactHeaderView(
                    onShowSettings: {
                        withAnimation(.acSnap) {
                            showSettings = true
                            showProfilePicker = false
                        }
                    },
                    onBackToChat: {
                        withAnimation(.acSnap) { showSettings = false }
                    },
                    onClose: { controller.dismissPopover?() },
                    isShowingSettings: showSettings
                )
                .environmentObject(controller)

                #if DEBUG
                Button {
                    showDebug = true
                } label: {
                    Image(systemName: "hammer.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.orange.opacity(0.7))
                }
                .buttonStyle(.plain)
                .help("Developer Tools")
                .padding(.trailing, 10)
                #endif
            }

            if showSettings {
                SettingsView(
                    embeddedInPanel: true,
                    onBackToChat: { withAnimation(.acSnap) { showSettings = false } }
                )
                .environmentObject(controller)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .offset(x: 24)),
                        removal: .opacity.combined(with: .offset(x: -24))
                    ))
            } else {
                chatContent
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .offset(x: -24)),
                        removal: .opacity.combined(with: .offset(x: 24))
                    ))
            }

            Divider().opacity(0.5)
            PanelFooterView()
                .environmentObject(controller)
        }
        .frame(width: ACD.popoverWidth)
        .background(panelBackground)
        .overlay(alignment: .topTrailing) {
            if showProfilePicker {
                ProfilePickerView(isPresented: $showProfilePicker)
                    .environmentObject(controller)
                    .padding(.top, 54)
                    .padding(.trailing, 14)
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .topTrailing)))
                    .zIndex(5)
            }
        }
        .overlay(alignment: .bottom) {
            if let toast = controller.learnedToast {
                LearnedToastView(
                    toast: toast,
                    onUndo: { controller.undoLearnedToast() },
                    onDismiss: { controller.dismissLearnedToast() }
                )
                .padding(.horizontal, 12)
                .padding(.bottom, 56)
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .move(edge: .bottom)),
                    removal: .opacity
                ))
                .zIndex(7)
            }
        }
        .animation(.acFade, value: controller.learnedToast?.id)
        .acAccent(for: controller.state)
        .animation(.acFade, value: controller.state.character)
        .onAppear {
            controller.refreshSystemState()
            checkAndShowCelebration()
        }
        .onChange(of: showSettings) { _, isSettings in
            if !isSettings { checkAndShowCelebration() }
        }
        .onChange(of: controller.state.sessionCelebrationPending) { _, isPending in
            if isPending { checkAndShowCelebration() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .acOpenSettings)) { _ in
            withAnimation(.acSnap) { showSettings = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: .acSelectSettingsTab)) { _ in
            withAnimation(.acSnap) {
                showSettings = true
                showProfilePicker = false
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .acDismissSheet)) { _ in
            if showSettings {
                withAnimation(.acSnap) { showSettings = false }
            }
            #if DEBUG
            if showDebug { showDebug = false }
            #endif
        }
        #if DEBUG
        .sheet(isPresented: $showDebug) {
            DebugSheet()
                .environmentObject(controller)
        }
        #endif
        .background(shortcutButtons)
    }

    private func checkAndShowCelebration() {
        guard controller.state.sessionCelebrationPending, !showSettings else { return }
        celebrationSessionName = controller.state.recentlyEndedSession?.name ?? "Focus"
        controller.state.sessionCelebrationPending = false
        withAnimation(.spring(response: 0.45, dampingFraction: 0.72)) { showCelebration = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) {
            withAnimation(.easeOut(duration: 0.5)) { showCelebration = false }
        }
    }

    private var chatContent: some View {
        VStack(spacing: 0) {
            if showCelebration {
                SessionCelebrationCard(sessionName: celebrationSessionName)
                    .environmentObject(controller)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                    .transition(.asymmetric(
                        insertion: .scale(scale: 0.88, anchor: .top).combined(with: .opacity),
                        removal: .opacity
                    ))
            }

            if let problem = controller.connectionProblemNotice {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                    Text(problem)
                        .font(.ac(11, weight: .medium))
                        .foregroundStyle(Color.acTextPrimary.opacity(0.9))
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.orange.opacity(0.08))
            }

            if controller.state.setupStatus == .ready
                && !controller.showingOnboardingCompletion
            {
                StatStripView()
                    .environmentObject(controller)
                    .padding(.top, 4)
                    .padding(.bottom, 2)
            }

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        if controller.state.setupStatus != .ready
                            || controller.showingOnboardingCompletion
                        {
                            OnboardingDialogView(showModeChooser: false)
                                .environmentObject(controller)
                                .padding(18)
                                .background(v2InsetBackground)
                                .padding(.horizontal, 14)
                                .padding(.top, 12)
                        } else {
                            ChatScrollView()
                                .environmentObject(controller)
                        }
                    }
                }
                .frame(maxHeight: needsOnboarding ? nil : 432)
                .onAppear { scrollChatToBottom(proxy, animated: false) }
                .onChange(of: chatScrollKey) { _, _ in
                    scrollChatToBottom(proxy)
                }
            }

            if controller.state.setupStatus == .ready
                && !controller.showingOnboardingCompletion
            {
                ComposerView()
                    .environmentObject(controller)
                    .padding(.top, 8)
                    .padding(.bottom, 8)
            }
        }
        .onChange(of: needsOnboarding) { _, needs in
            let height: CGFloat = needs ? 540 : 460
            controller.resizePopover?(NSSize(width: ACD.popoverWidth, height: height))
        }
    }

    private var needsOnboarding: Bool {
        controller.state.setupStatus != .ready || controller.showingOnboardingCompletion
    }

    private var panelBackground: some View {
        ZStack {
            if controller.state.glassEffectActive {
                Rectangle().fill(.ultraThinMaterial)
                RadialGradient(
                    colors: [
                        Color.white.opacity(colorScheme == .dark ? 0.28 : 0.55),
                        Color.white.opacity(colorScheme == .dark ? 0.12 : 0.22),
                        Color.clear
                    ],
                    center: .topLeading,
                    startRadius: 0,
                    endRadius: 380
                )
                RadialGradient(
                    colors: [
                        accent.opacity(colorScheme == .dark ? 0.18 : 0.14),
                        accent.opacity(colorScheme == .dark ? 0.08 : 0.06),
                        Color.clear
                    ],
                    center: .bottomTrailing,
                    startRadius: 20,
                    endRadius: 360
                )
                LinearGradient(
                    colors: [
                        Color.white.opacity(colorScheme == .dark ? 0.32 : 0.48),
                        Color.white.opacity(colorScheme == .dark ? 0.12 : 0.14),
                        Color.clear
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                LinearGradient(
                    colors: [
                        Color.clear,
                        Color.black.opacity(colorScheme == .dark ? 0.28 : 0.04)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            } else {
                Rectangle().fill(Color(nsColor: NSColor(name: nil) { appearance in
                    appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                        ? NSColor(white: 0.15, alpha: 1.0)
                        : NSColor(white: 0.95, alpha: 1.0)
                }))
            }

            // Flat modern wash — uniform across skins. Skin identity lives in
            // the cat icon itself, not in the chat chrome.
            Color(nsColor: NSColor(name: nil) { appearance in
                appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                    ? NSColor(white: 0.16, alpha: 0.35)
                    : NSColor(white: 1.0, alpha: 0.18)
            })
        }
    }

    private var chatScrollKey: String {
        let visibleMessages = controller.chatMessages.filter { $0.role != .system }
        return [
            visibleMessages.last?.id.uuidString ?? "none",
            String(visibleMessages.count),
            controller.sendingChatMessage ? "sending" : "idle"
        ].joined(separator: ":")
    }

    private func scrollChatToBottom(_ proxy: ScrollViewProxy, animated: Bool = true) {
        let action = {
            proxy.scrollTo("chat-bottom-sentinel", anchor: .bottom)
        }
        if animated {
            DispatchQueue.main.async {
                withAnimation(.easeOut(duration: 0.22)) { action() }
            }
        } else {
            DispatchQueue.main.async { action() }
        }
    }

    private var v2InsetBackground: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(Color(nsColor: NSColor(name: nil) { appearance in
                appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                    ? NSColor(white: 0.18, alpha: 0.55)
                    : NSColor(white: 1.0, alpha: 0.42)
            }))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.acBubbleStroke, lineWidth: 0.5)
            )
    }

    private var shortcutButtons: some View {
        VStack {
            Button {
                NotificationCenter.default.post(name: .acFocusChatInput, object: nil)
            } label: { EmptyView() }
            .keyboardShortcut("k", modifiers: .command)
            .opacity(0)
            .frame(width: 0, height: 0)
            .disabled(showSettings)

            Button {
                withAnimation(.acSnap) { showSettings = true }
            } label: { EmptyView() }
            .keyboardShortcut(",", modifiers: .command)
            .opacity(0)
            .frame(width: 0, height: 0)
        }
    }
}

// MARK: - Session celebration card

private struct SessionCelebrationCard: View {
    let sessionName: String
    @EnvironmentObject private var controller: AppController
    @Environment(\.acAccent) private var accent

    @State private var catScale: CGFloat = 0.5

    var body: some View {
        HStack(spacing: 12) {
            CatView(
                character: controller.state.character,
                expression: .happy,
                size: 50,
                animating: true
            )
            .scaleEffect(catScale)
            .onAppear {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.58)) {
                    catScale = 1.0
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                Text("\(sessionName) complete!")
                    .font(.ac(13, weight: .semibold))
                    .foregroundStyle(Color.acTextPrimary)
                Text("Really proud of you. That's what it takes.")
                    .font(.ac(11))
                    .foregroundStyle(Color.acTextPrimary.opacity(0.6))
                    .lineLimit(2)
            }

            Spacer(minLength: 0)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(accent.opacity(0.10))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(accent.opacity(0.24), lineWidth: 0.5)
                )
        )
    }
}


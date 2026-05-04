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
                        .foregroundStyle(Color.orange.opacity(0.72))
                }
                .buttonStyle(ACIconButton(size: 24))
                .padding(.trailing, 10)
                #endif
            }

            if showSettings {
                SettingsView(embeddedInPanel: true)
                    .environmentObject(controller)
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
            } else {
                chatContent
                    .transition(.opacity.combined(with: .move(edge: .leading)))
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
        .acAccent(for: controller.state)
        .animation(.acFade, value: controller.state.character)
        .animation(.acFade, value: controller.state.customAccentHex)
        .animation(.acFade, value: controller.state.accentFollowsCharacter)
        .onAppear { controller.refreshSystemState() }
        .onReceive(NotificationCenter.default.publisher(for: .acOpenSettings)) { _ in
            withAnimation(.acSnap) { showSettings = true }
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

    private var chatContent: some View {
        VStack(spacing: 0) {
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
                        if !controller.hasCompletedOnboardingWizard
                            && controller.state.setupStatus != .ready
                        {
                            OnboardingWizardView()
                                .environmentObject(controller)
                                .padding(18)
                                .background(v2InsetBackground)
                                .padding(.horizontal, 14)
                                .padding(.top, 12)
                        } else if controller.state.setupStatus != .ready
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
                .frame(maxHeight: 432)
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
    }

    private var panelBackground: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial)

            switch controller.state.selectedSkin {
            case .liquid:
                LinearGradient(
                    colors: [
                        Color.white.opacity(colorScheme == .dark ? 0.12 : 0.62),
                        accent.opacity(colorScheme == .dark ? 0.07 : 0.13),
                        Color(red: 0.58, green: 0.68, blue: 0.82).opacity(colorScheme == .dark ? 0.10 : 0.16)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                LinearGradient(
                    colors: [
                        Color.white.opacity(colorScheme == .dark ? 0.10 : 0.44),
                        Color.clear,
                        Color.black.opacity(colorScheme == .dark ? 0.12 : 0.03)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            case .pixel:
                LinearGradient(
                    colors: [
                        accent.opacity(colorScheme == .dark ? 0.05 : 0.08),
                        Color.white.opacity(colorScheme == .dark ? 0.02 : 0.18)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                PixelPanelTexture()
                    .opacity(colorScheme == .dark ? 0.12 : 0.07)
            case .bubble:
                LinearGradient(
                    colors: [
                        accent.opacity(colorScheme == .dark ? 0.05 : 0.08),
                        Color.white.opacity(colorScheme == .dark ? 0.02 : 0.24)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
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
            .fill(Color.white.opacity(colorScheme == .dark ? 0.07 : 0.38))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.white.opacity(0.32), lineWidth: 0.5)
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

private struct PixelPanelTexture: View {
    var body: some View {
        Canvas { context, size in
            let step: CGFloat = 8
            var path = Path()
            var x: CGFloat = 0
            while x <= size.width {
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height))
                x += step
            }
            var y: CGFloat = 0
            while y <= size.height {
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
                y += step
            }
            context.stroke(path, with: .color(Color.acTextPrimary.opacity(0.35)), lineWidth: 0.5)
        }
    }
}

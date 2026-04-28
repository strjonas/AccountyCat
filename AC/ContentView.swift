//
//  ContentView.swift
//  AC
//
//  Compact popover content. Two tabs in release builds (Home + Settings); a
//  third Logs tab only shows in DEBUG. Home surfaces at-a-glance stats and
//  chat. Settings keeps Goals, primary controls, Rescue App, and Quit visible
//  while tucking the rest under a collapsible Advanced section.
//

import AppKit
import SwiftUI

// MARK: - Tab enum

enum ACPopoverTab: String {
    case home     = "house.fill"
    case brain    = "brain.head.profile"
    case settings = "gearshape.fill"
    case logs     = "scroll.fill"
}

private enum SettingsAlertAction: String, Identifiable {
    case resetAlgorithm

    var id: String { rawValue }
}

// MARK: - ContentView

struct ContentView: View {
    @EnvironmentObject private var controller: AppController
    @Environment(\.colorScheme) private var colorScheme
    @State private var selectedTab: ACPopoverTab = .home
    @State private var pendingSettingsAction: SettingsAlertAction?
    @State private var settingsSuccessMessage: String?
    @AppStorage("acSoundEnabled") private var soundEnabled: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            popoverHeader
            Divider().opacity(0.5)
            tabContent
        }
        .frame(width: ACD.popoverWidth)
        .background(Color(nsColor: .windowBackgroundColor))
        .acAccent(for: controller.state.character)
        .animation(.acFade, value: controller.state.character)
        .onAppear { controller.refreshSystemState() }
        .alert("Are you sure?", isPresented: Binding(
            get: { pendingSettingsAction != nil },
            set: { isPresented in
                if !isPresented { pendingSettingsAction = nil }
            }
        )) {
            if pendingSettingsAction == .resetAlgorithm {
                Button("Reset Algorithm", role: .destructive) {
                    controller.resetAlgorithmProfile()
                    settingsSuccessMessage = "Algorithm profile was reset to defaults."
                    pendingSettingsAction = nil
                }
            }
            Button("Cancel", role: .cancel) { pendingSettingsAction = nil }
        } message: {
            switch pendingSettingsAction {
            case .resetAlgorithm:
                Text("This clears saved chat history, learned memory, recent context, and usage profile.")
            case .none:
                Text("")
            }
        }
        .alert("Done", isPresented: Binding(
            get: { settingsSuccessMessage != nil },
            set: { isPresented in
                if !isPresented { settingsSuccessMessage = nil }
            }
        )) {
            Button("OK", role: .cancel) { settingsSuccessMessage = nil }
        } message: {
            Text(settingsSuccessMessage ?? "")
        }
    }

    // MARK: - Header

    private var popoverHeader: some View {
        HStack(spacing: 12) {
            HStack(spacing: 9) {
                HeaderMark(character: controller.state.character)
                VStack(alignment: .leading, spacing: 2) {
                    Text("AccountyCat")
                        .font(.ac(15, weight: .semibold))
                        .foregroundStyle(Color.acTextPrimary)
                    HStack(spacing: 5) {
                        StatusDot(status: controller.state.setupStatus,
                                  isPaused: controller.state.isPaused)
                        Text(controller.activeModelShortName)
                            .font(.ac(10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }

            Spacer(minLength: 8)

            HStack(spacing: 4) {
                tabButton(.home)
                tabButton(.brain)
                tabButton(.settings)
                if ACBuild.isDebug {
                    tabButton(.logs)
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(headerBackground)
    }

    private func tabButton(_ tab: ACPopoverTab) -> some View {
        Button {
            withAnimation(.acSnap) { selectedTab = tab }
        } label: {
            Image(systemName: tab.rawValue)
                .font(.system(size: 12.5,
                              weight: selectedTab == tab ? .semibold : .regular))
                .foregroundStyle(selectedTab == tab
                                 ? controller.state.character.accentColor
                                 : Color.secondary.opacity(0.65))
                .frame(width: 32, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: ACRadius.sm, style: .continuous)
                        .fill(selectedTab == tab
                              ? controller.state.character.accentSoft.opacity(0.55)
                              : Color.clear)
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Tab content

    @ViewBuilder
    private var tabContent: some View {
        ScrollView {
            switch selectedTab {
            case .home:     homeTab
            case .brain:    BrainView().environmentObject(controller)
            case .settings: settingsTab
            case .logs:     logsTab
            }
        }
        .animation(.acFade, value: selectedTab)
    }

    // MARK: - Home Tab

    private var homeTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !controller.hasCompletedOnboardingWizard && controller.state.setupStatus != .ready {
                // New user: show the multi-screen wizard
                OnboardingWizardView()
                    .environmentObject(controller)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            } else if controller.state.setupStatus != .ready || controller.showingOnboardingCompletion {
                // Wizard done but still setting up (e.g. local download in progress)
                OnboardingDialogView(showModeChooser: false)
                    .environmentObject(controller)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            } else {
                StatsSection(stats: controller.todayStats,
                             accent: controller.state.character.accentColor)
            }

            ChatView()
                .environmentObject(controller)
        }
        .padding(18)
        .padding(.bottom, 8)
    }

    // MARK: - Settings Tab

    private var settingsTab: some View {
        VStack(alignment: .leading, spacing: 24) {
            SettingsSection(title: "Controls", icon: "switch.2") {
                HStack(spacing: 10) {
                    ToggleTile(
                        icon: controller.state.isPaused ? "play.circle.fill" : "pause.circle.fill",
                        title: controller.state.isPaused ? "Paused" : "Watching",
                        subtitle: controller.state.isPaused ? "Tap to resume" : "Tap to pause",
                        isOn: Binding(
                            get: { !controller.state.isPaused },
                            set: { _ in controller.togglePause() }
                        ),
                        tint: controller.state.character.accentColor
                    )

                    ToggleTile(
                        icon: soundEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill",
                        title: "Sound",
                        subtitle: soundEnabled ? "On for nudges" : "Muted",
                        isOn: $soundEnabled,
                        tint: controller.state.character.accentColor
                    )

                    ToggleTile(
                        icon: controller.visionEnabled ? "camera.fill" : "camera.slash.fill",
                        title: "Vision",
                        subtitle: controller.usingOnlineMonitoring
                            ? (controller.visionEnabled ? "Uploads screenshot" : "Text only")
                            : (controller.visionEnabled ? "Screenshot on" : "Title only"),
                        isOn: Binding(
                            get: { controller.visionEnabled },
                            set: { controller.updateVisionEnabled($0) }
                        ),
                        tint: controller.state.character.accentColor
                    )
                }
            }

            // ── Character ──
            CharacterPickerSection(
                selected: controller.state.character,
                onSelect: { controller.updateCharacter($0) }
            )

            AISettingsSection()
                .environmentObject(controller)

            Divider().opacity(0.3)

            CalendarIntelligenceSection()
                .environmentObject(controller)

            SettingsSection(title: "Rescue app", icon: "arrow.uturn.backward.circle",
                            subtitle: "Where AC sends you when you've drifted too far.") {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(controller.state.rescueApp.displayName)
                            .font(.ac(13, weight: .medium))
                            .foregroundStyle(Color.acTextPrimary)
                        Text(controller.state.rescueApp.applicationPath
                             ?? controller.state.rescueApp.bundleIdentifier)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 8)
                    HStack(spacing: 6) {
                        Button("Choose") { controller.chooseRescueApp() }
                            .buttonStyle(ACSecondaryButton())
                        Button("Open") { controller.openRescueApp() }
                            .buttonStyle(ACPrimaryButton())
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: ACRadius.md, style: .continuous)
                        .fill(Color.acSurface)
                        .overlay(
                            RoundedRectangle(cornerRadius: ACRadius.md, style: .continuous)
                                .stroke(Color.acHairline, lineWidth: 1)
                        )
                )
            }

            SettingsSection(title: "Reset monitoring profile",
                            icon: "arrow.counterclockwise",
                            subtitle: "Clears learned memory, recent behavior context, chat history, and usage context.") {
                Button("Reset") { pendingSettingsAction = .resetAlgorithm }
                    .buttonStyle(ACDangerButton())
            }

            if ACBuild.isDebug {
                developerSection
            }

            Divider().opacity(0.3)

            AboutSection()

            Divider().opacity(0.5)

            // ── Quit (always visible) ──
            HStack {
                Spacer()
                Button("Quit AccountyCat") { NSApp.terminate(nil) }
                    .font(.ac(12, weight: .medium))
                    .foregroundStyle(Color.red.opacity(0.78))
                    .buttonStyle(.plain)
            }
        }
        .padding(20)
    }

    // MARK: - Developer (DEBUG only)

    @ViewBuilder
    private var developerSection: some View {
        Divider()
        VStack(alignment: .leading, spacing: 12) {
            Label("Developer", systemImage: "hammer.fill")
                .font(.ac(13, weight: .semibold))
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                Button("Test Nudge") { controller.sendTestNudge() }
                    .buttonStyle(ACPrimaryButton())
                Button("Test Overlay") { controller.showTestOverlay() }
                    .buttonStyle(ACPrimaryButton())
            }

            developerPicker(
                title: "Monitoring prompt profile",
                selection: Binding(
                    get: { controller.state.monitoringConfiguration.promptProfileID },
                    set: { controller.updateMonitoringPromptProfile($0) }
                ),
                options: controller.availableMonitoringPromptProfiles.map { ($0.id, $0.displayName, $0.summary) }
            )

            developerPicker(
                title: "Pipeline profile",
                selection: Binding(
                    get: { controller.state.monitoringConfiguration.pipelineProfileID },
                    set: { controller.updateMonitoringPipelineProfile($0) }
                ),
                options: controller.availablePipelineProfiles.map { ($0.id, $0.displayName, $0.summary) }
            )

            developerPicker(
                title: "Runtime profile",
                selection: Binding(
                    get: { controller.state.monitoringConfiguration.runtimeProfileID },
                    set: { controller.updateMonitoringRuntimeProfile($0) }
                ),
                options: controller.availableRuntimeProfiles.map { ($0.id, $0.displayName, $0.summary) }
            )

            VStack(alignment: .leading, spacing: 6) {
                Text("llama.cpp path override")
                    .font(.ac(11, weight: .semibold))
                    .foregroundStyle(.secondary)
                TextField("Optional custom path", text: Binding(
                    get: { controller.state.runtimePathOverride ?? "" },
                    set: { controller.updateRuntimeOverride($0) }
                ))
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11, design: .monospaced))
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Local model override")
                    .font(.ac(11, weight: .semibold))
                    .foregroundStyle(.secondary)
                TextField(
                    DevelopmentModelConfiguration.fallbackModelIdentifier,
                    text: Binding(
                        get: { controller.state.monitoringConfiguration.modelOverride ?? "" },
                        set: { controller.updateModelOverride($0) }
                    )
                )
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11, design: .monospaced))
                modelQuickPickButtons
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("OpenRouter model")
                    .font(.ac(11, weight: .semibold))
                    .foregroundStyle(.secondary)
                TextField(
                    MonitoringConfiguration.defaultOnlineModelIdentifier,
                    text: Binding(
                        get: { controller.state.monitoringConfiguration.onlineModelIdentifier },
                        set: { controller.updateOnlineModelIdentifier($0) }
                    )
                )
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11, design: .monospaced))
                Text("Model ID (e.g. google/gemma-4-31b-it) or full openrouter.ai URL.")
                    .font(.ac(10))
                    .foregroundStyle(.secondary)
            }

            Toggle(isOn: Binding(
                get: { controller.state.monitoringConfiguration.thinkingEnabled },
                set: { controller.updateThinkingEnabled($0) }
            )) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Thinking / reasoning")
                        .font(.ac(11, weight: .semibold))
                    Text("Enables <think> chain-of-thought output (Qwen3). Off by default.")
                        .font(.ac(10))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var modelQuickPickButtons: some View {
        let activeModel = controller.state.monitoringConfiguration.modelOverride ?? ""
        let knownModels: [(String, String)] = [
            ("Gemma", "unsloth/gemma-4-E2B-it-GGUF:Q4_0"),
            ("Qwen3", "unsloth/Qwen3-4B-GGUF:Q4_0"),
            ("Phi-4", "unsloth/Phi-4-mini-instruct-GGUF:Q4_K_M"),
            ("Gemma 4", "unsloth/gemma-4-E4B-it-GGUF:Q4_K_M"),
        ]
        HStack(spacing: 6) {
            ForEach(knownModels, id: \.0) { name, id in
                modelPickerButton(label: name, modelID: id, activeModel: activeModel)
            }
            modelPickerButton(label: "Clear", modelID: "", activeModel: activeModel)
        }
    }

    @ViewBuilder
    private func modelPickerButton(label: String, modelID: String, activeModel: String) -> some View {
        let isActive = activeModel == modelID
        if isActive {
            Button(label) { controller.updateModelOverride(modelID) }
                .buttonStyle(ACPrimaryButton())
                .font(.ac(10))
        } else {
            Button(label) { controller.updateModelOverride(modelID) }
                .buttonStyle(ACSecondaryButton())
                .font(.ac(10))
        }
    }

    private func developerPicker(
        title: String,
        selection: Binding<String>,
        options: [(id: String, name: String, summary: String)]
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.ac(11, weight: .semibold))
                .foregroundStyle(.secondary)
            Picker(title, selection: selection) {
                ForEach(options, id: \.id) { opt in
                    Text(opt.name).tag(opt.id)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            if let summary = options.first(where: { $0.id == selection.wrappedValue })?.summary {
                Text(summary)
                    .font(.ac(11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Logs Tab (DEBUG only)

    private var logsTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Button("Telemetry root") { controller.openTelemetryRoot() }
                    .buttonStyle(ACPrimaryButton())
                Button("Current session") { controller.openCurrentTelemetrySession() }
                    .buttonStyle(ACSecondaryButton())
                Button("Text log") { controller.openActivityLog() }
                    .buttonStyle(ACSecondaryButton())
                Button("Refresh") { controller.refreshActivityLog() }
                    .buttonStyle(ACSecondaryButton())
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Telemetry session")
                    .font(.ac(12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(controller.telemetrySessionID ?? "No active session")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color.acTextPrimary)
            }

            logConsole(
                title: "Recent text log",
                text: controller.activityLog.isEmpty ? "No recent log tail yet." : controller.activityLog,
                height: 210
            )

            logConsole(
                title: "Installer",
                text: controller.setupLog.isEmpty ? "No setup activity yet." : controller.setupLog,
                height: 130
            )
        }
        .padding(20)
    }

    private func logConsole(title: String, text: String, height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.ac(12, weight: .semibold))
                .foregroundStyle(.secondary)

            ScrollView {
                Text(text)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(10)
            }
            .frame(height: height)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.black.opacity(0.86))
            )
            .foregroundStyle(Color.green.opacity(0.90))
        }
    }

    // MARK: - Visual helpers

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

// MARK: - Status dot

private struct StatusDot: View {
    let status: SetupStatus
    let isPaused: Bool
    @Environment(\.acAccent) private var accent

    @State private var pulse: Double = 0

    var body: some View {
        HStack(spacing: 6) {
            ZStack {
                if status == .ready && !isPaused {
                    Circle()
                        .fill(dotColor.opacity(0.32))
                        .frame(width: 12, height: 12)
                        .scaleEffect(1 + pulse)
                        .opacity(0.8 - pulse * 0.7)
                }
                Circle()
                    .fill(dotColor)
                    .frame(width: 6, height: 6)
            }
            .frame(width: 12, height: 12)

            Text(label)
                .font(.ac(11, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .onAppear {
            if status == .ready && !isPaused {
                withAnimation(.easeOut(duration: 1.6).repeatForever(autoreverses: false)) {
                    pulse = 0.9
                }
            }
        }
    }

    private var dotColor: Color {
        switch status {
        case .ready:
            return isPaused ? Color.acAmber : Color.green
        case .installing:
            return accent
        default:
            return .red.opacity(0.7)
        }
    }

    private var label: String {
        switch status {
        case .ready:       return isPaused ? "Paused" : "Watching"
        case .installing:  return "Installing"
        case .checking:    return "Checking"
        default:           return "Setup needed"
        }
    }
}

// MARK: - Header mark

/// Small character-aware logo glyph used in the popover header. Pairs the AC
/// wordmark with a hint of the active character's accent.
private struct HeaderMark: View {
    let character: ACCharacter

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [character.orbTopColor, character.orbBottomColor],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    Circle().stroke(Color.white.opacity(0.55), lineWidth: 0.6)
                )
                .shadow(color: character.shadowColor.opacity(0.25), radius: 4, y: 1.5)

            Image(systemName: "pawprint.fill")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(character.accentColor.opacity(0.85))
        }
        .frame(width: 24, height: 24)
        .animation(.acFade, value: character)
    }
}

// MARK: - Toggle Tile

/// Compact tap-to-toggle tile used on the Home tab for the primary controls.
/// Reads at a glance and responds with a warm caramel accent when on.
private struct ToggleTile: View {
    let icon: String
    let title: String
    let subtitle: String
    @Binding var isOn: Bool
    let tint: Color

    var body: some View {
        Button { isOn.toggle() } label: {
            HStack(spacing: 11) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(isOn ? tint : Color.secondary.opacity(0.7))
                    .frame(width: 22)
                    .symbolEffect(.bounce, value: isOn)

                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.ac(13, weight: .semibold))
                        .foregroundStyle(Color.acTextPrimary)
                    Text(subtitle)
                        .font(.ac(11))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: ACRadius.md, style: .continuous)
                    .fill(isOn ? tint.opacity(0.10) : Color.acSurface)
                    .overlay(
                        RoundedRectangle(cornerRadius: ACRadius.md, style: .continuous)
                            .stroke(isOn
                                    ? tint.opacity(0.45)
                                    : Color.acHairline,
                                    lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
        .animation(.acSnap, value: isOn)
    }
}

// MARK: - Stats section

private struct StatsSection: View {
    let stats: AppController.TodayStats
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Today")
                .font(.ac(10, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .tracking(0.6)

            HStack(spacing: 8) {
                StatCard(icon: "clock.fill",
                         value: formatDuration(stats.totalTrackedSeconds),
                         label: "Tracked",
                         accent: accent)
                StatCard(icon: "bubble.left.fill",
                         value: "\(stats.nudgeCount)",
                         label: "Nudges",
                         accent: accent)
                StatCard(icon: "arrow.uturn.backward.circle.fill",
                         value: "\(stats.backToWorkCount)",
                         label: "Rescues",
                         accent: accent)
            }
        }
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        if h > 0 { return "\(h)h \(m)m" }
        if m > 0 { return "\(m)m" }
        return "0m"
    }
}

private struct StatCard: View {
    let icon: String
    let value: String
    let label: String
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(accent)
                .frame(width: 22, height: 22)
                .background(
                    Circle().fill(accent.opacity(0.12))
                )

            VStack(alignment: .leading, spacing: 1) {
                Text(value)
                    .font(.ac(17, weight: .semibold))
                    .foregroundStyle(Color.acTextPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(label)
                    .font(.ac(10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: ACRadius.md, style: .continuous)
                .fill(Color.acSurface)
                .overlay(
                    RoundedRectangle(cornerRadius: ACRadius.md, style: .continuous)
                        .stroke(Color.acHairline, lineWidth: 1)
                )
        )
    }
}

// MARK: - Settings Section

/// Standard section header + optional subtitle wrapper used across settings.
private struct SettingsSection<Content: View>: View {
    let title: String
    let icon: String
    var subtitle: String? = nil
    @ViewBuilder let content: () -> Content
    @Environment(\.acAccent) private var accent

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(accent)
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(accent.opacity(0.13)))
                Text(title)
                    .font(.ac(13, weight: .semibold))
                    .foregroundStyle(Color.acTextPrimary)
            }
            if let subtitle {
                Text(subtitle)
                    .font(.ac(11))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 26)
            }
            content()
        }
    }
}

// MARK: - Calendar Intelligence Section

/// Opt-in section in Settings. Collapsed by default with just the toggle + an
/// info tooltip. Once enabled it expands to show permission status, a link to
/// System Settings if the user denied, and a multi-select list of calendars.
///
/// This is deliberately NOT part of onboarding — it's a "hidden gem" feature
/// users discover via Settings or docs. The info button on hover teaches the
/// value prop without another onboarding dialog.
private struct CalendarIntelligenceSection: View {
    @EnvironmentObject private var controller: AppController
    @Environment(\.acAccent) private var accent
    @State private var hoveringInfo = false
    @State private var calendarListExpanded = true

    private var isOn: Bool { controller.state.calendarIntelligenceEnabled }
    private var calendarGranted: Bool { controller.state.permissions.calendar == .granted }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            Toggle(isOn: Binding(
                get: { isOn },
                set: { controller.setCalendarIntelligence(enabled: $0) }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Use my calendar")
                        .font(.ac(13, weight: .medium))
                        .foregroundStyle(Color.acTextPrimary)
                    Text("Read-only. Never leaves your Mac.")
                        .font(.ac(11))
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
            .tint(accent)

            if isOn {
                if calendarGranted {
                    calendarPicker
                } else {
                    permissionPrompt
                }
            }
        }
        .onAppear {
            if isOn && calendarGranted {
                controller.refreshAvailableCalendars()
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "calendar")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(accent)
                .frame(width: 18, height: 18)
                .background(Circle().fill(accent.opacity(0.13)))
            Text("Calendar Intelligence")
                .font(.ac(13, weight: .semibold))
                .foregroundStyle(Color.acTextPrimary)

            // Info button with hover tooltip explaining the value prop.
            Image(systemName: "info.circle")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .help("""
                Let AC read your current calendar event to infer what you want \
                to focus on — so it stays out of the way with less effort \
                from you. Works with any calendar already in Apple Calendar \
                (iCloud, Google, Exchange, Fastmail, …). Events are read \
                locally and never leave your Mac.
                """)
                .onHover { hoveringInfo = $0 }
                .opacity(hoveringInfo ? 1.0 : 0.75)
        }
    }

    private var permissionPrompt: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Calendar access is required. If you denied it earlier, re-enable it in System Settings → Privacy & Security → Calendars.")
                .font(.ac(11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Button("Request access") {
                    controller.setCalendarIntelligence(enabled: false)
                    controller.setCalendarIntelligence(enabled: true)
                }
                .buttonStyle(ACSecondaryButton())

                Button("Open System Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(ACSecondaryButton())
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: ACRadius.md, style: .continuous)
                .fill(Color.acSurface)
                .overlay(
                    RoundedRectangle(cornerRadius: ACRadius.md, style: .continuous)
                        .stroke(Color.acHairline, lineWidth: 1)
                )
        )
    }

    @ViewBuilder
    private var calendarPicker: some View {
        if controller.availableCalendars.isEmpty {
            HStack(spacing: 8) {
                Text("No calendars found in Apple Calendar.")
                    .font(.ac(11))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Refresh") { controller.refreshAvailableCalendars() }
                    .buttonStyle(ACSecondaryButton())
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: ACRadius.md, style: .continuous)
                    .fill(Color.acSurface)
                    .overlay(
                        RoundedRectangle(cornerRadius: ACRadius.md, style: .continuous)
                            .stroke(Color.acHairline, lineWidth: 1)
                    )
            )
        } else {
            let enabledCount = controller.availableCalendars.filter { controller.isCalendarEnabled($0.id) }.count
            VStack(alignment: .leading, spacing: 0) {
                Button {
                    withAnimation(.acSnap) { calendarListExpanded.toggle() }
                } label: {
                    HStack(spacing: 8) {
                        Text("Calendars")
                            .font(.ac(12, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(enabledCount) of \(controller.availableCalendars.count) active")
                            .font(.ac(11))
                            .foregroundStyle(.secondary)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Color.secondary.opacity(0.6))
                            .rotationEffect(.degrees(calendarListExpanded ? 90 : 0))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if calendarListExpanded {
                    Divider().opacity(0.4)
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(Array(controller.availableCalendars.enumerated()), id: \.element.id) { index, cal in
                                Toggle(isOn: Binding(
                                    get: { controller.isCalendarEnabled(cal.id) },
                                    set: { _ in controller.toggleCalendarEnabled(cal.id) }
                                )) {
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(cal.title)
                                            .font(.ac(12, weight: .medium))
                                            .foregroundStyle(Color.acTextPrimary)
                                            .lineLimit(1)
                                        Text(cal.sourceTitle)
                                            .font(.ac(10))
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                                .toggleStyle(.switch)
                                .tint(accent)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 9)

                                if index < controller.availableCalendars.count - 1 {
                                    Divider().opacity(0.3).padding(.leading, 12)
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 180)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .background(
                RoundedRectangle(cornerRadius: ACRadius.md, style: .continuous)
                    .fill(Color.acSurface)
                    .overlay(
                        RoundedRectangle(cornerRadius: ACRadius.md, style: .continuous)
                            .stroke(Color.acHairline, lineWidth: 1)
                    )
            )
            .clipShape(RoundedRectangle(cornerRadius: ACRadius.md, style: .continuous))
        }
    }
}

// MARK: - Character Picker Section

/// Three-card character picker shown in the Settings tab.
/// Selecting a card immediately updates the character and animates the orb palette.
private struct CharacterPickerSection: View {
    let selected: ACCharacter
    let onSelect: (ACCharacter) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "theatermasks.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(selected.accentColor)
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(selected.accentColor.opacity(0.13)))
                Text("Style")
                    .font(.ac(13, weight: .semibold))
                    .foregroundStyle(Color.acTextPrimary)
                Spacer()
                Text(selected.displayName)
                    .font(.ac(11, weight: .medium))
                    .foregroundStyle(selected.accentColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        Capsule().fill(selected.accentColor.opacity(0.12))
                    )
                    .animation(.acFade, value: selected)
            }

            Text("Personalise AC's voice and palette. All styles are warm and supportive.")
                .font(.ac(11))
                .foregroundStyle(.secondary)
                .padding(.leading, 26)

            HStack(spacing: 8) {
                ForEach(ACCharacter.allCases, id: \.self) { character in
                    Button(action: {
                        withAnimation(.acSpring) { onSelect(character) }
                    }) {
                        CharacterCard(character: character, isSelected: selected == character)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

private struct CharacterCard: View {
    let character: ACCharacter
    let isSelected: Bool

    var body: some View {
        VStack(spacing: 9) {
            ZStack {
                if isSelected {
                    Circle()
                        .stroke(character.accentColor.opacity(0.45), lineWidth: 1.5)
                        .scaleEffect(1.22)
                }
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [character.orbTopColor, character.orbBottomColor],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay(
                        Circle()
                            .stroke(
                                isSelected ? character.accentColor.opacity(0.55) : Color.white.opacity(0.45),
                                lineWidth: 1
                            )
                    )
                    .shadow(color: character.shadowColor.opacity(0.25), radius: 6, y: 2)

                MiniCatFace(accentColor: character.accentColor)
                    .padding(8)
            }
            .frame(width: 46, height: 46)

            VStack(spacing: 2) {
                Text(character.displayName)
                    .font(.ac(12, weight: .semibold))
                    .foregroundStyle(isSelected ? character.accentColor : Color.acTextPrimary)
                Text(character.tagline)
                    .font(.ac(9.5))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: ACRadius.md, style: .continuous)
                .fill(isSelected
                      ? character.accentSoft.opacity(0.55)
                      : Color.acSurface)
                .overlay(
                    RoundedRectangle(cornerRadius: ACRadius.md, style: .continuous)
                        .stroke(
                            isSelected ? character.accentColor.opacity(0.55) : Color.acHairline,
                            lineWidth: isSelected ? 1.5 : 1
                        )
                )
        )
        .scaleEffect(isSelected ? 1.02 : 1.0)
        .animation(.acSpring, value: isSelected)
    }
}

/// Simplified cat face used inside the character picker cards.
private struct MiniCatFace: View {
    let accentColor: Color

    var body: some View {
        ZStack {
            // Left ear
            Triangle()
                .fill(Color.acFurDark)
                .frame(width: 10, height: 8)
                .offset(x: -8, y: -10)
            // Right ear
            Triangle()
                .fill(Color.acFurDark)
                .frame(width: 10, height: 8)
                .offset(x: 8, y: -10)
            // Face
            Circle().fill(Color.acFur)
            // Eyes
            HStack(spacing: 6) {
                Capsule().frame(width: 3.5, height: 4.5).foregroundStyle(Color.acEyeColor)
                Capsule().frame(width: 3.5, height: 4.5).foregroundStyle(Color.acEyeColor)
            }
            .offset(y: -2)
            // Nose
            Circle()
                .fill(Color.acNoseColor)
                .frame(width: 2.5, height: 2.5)
                .offset(y: 3)
        }
    }
}

private struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.midX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}

// MARK: - AI Settings Section (Mode + Tier)

/// The AI section in Settings. Adds backend mode, API-key setup, and tier selection.
private struct AISettingsSection: View {
    @EnvironmentObject private var controller: AppController
    @Environment(\.acAccent) private var accent

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Section header
            HStack(spacing: 8) {
                Image(systemName: "cpu")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(accent)
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(accent.opacity(0.13)))
                Text("AI")
                    .font(.ac(13, weight: .semibold))
                    .foregroundStyle(Color.acTextPrimary)
            }

            // Mode picker — 3 options, Managed greyed out
            VStack(alignment: .leading, spacing: 8) {
                Text("Mode")
                    .font(.ac(11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 26)

                SettingsModeRow(
                    current: controller.state.monitoringConfiguration.inferenceBackend,
                    onChange: { controller.updateMonitoringInferenceBackend($0) }
                )
            }

            // BYOK key — only when online
            if controller.usingOnlineMonitoring {
                OpenRouterKeyField(compact: true)
                    .environmentObject(controller)
                    .padding(.leading, 26)
            }

            // Tier picker
            VStack(alignment: .leading, spacing: 8) {
                Text("Tier")
                    .font(.ac(11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 26)

                WizardTierPicker(
                    selectedTier: Binding(
                        get: { controller.currentAITier },
                        set: { controller.updateAITier($0) }
                    ),
                    mode: controller.usingOnlineMonitoring ? .byok : .offline
                )
                .onAppear {
                    // Re-run RAM check (spec: "runs when this section opens")
                    controller.refreshSystemState(persist: false)
                }
            }
        }
    }
}

/// Compact 3-button mode row for the Settings AI section.
private struct SettingsModeRow: View {
    let current: MonitoringInferenceBackend
    let onChange: (MonitoringInferenceBackend) -> Void
    @Environment(\.acAccent) private var accent

    var body: some View {
        HStack(spacing: 8) {
            modeButton(.local,      label: "Local",   icon: "lock.fill",  subtext: "Private")
            modeButton(.openRouter, label: "BYOK",    icon: "key.fill",   subtext: "OpenRouter")
            managedButton
        }
    }

    @ViewBuilder
    private func modeButton(
        _ backend: MonitoringInferenceBackend,
        label: String,
        icon: String,
        subtext: String
    ) -> some View {
        let isSelected = current == backend
        Button { onChange(backend) } label: {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(isSelected ? accent : Color.secondary.opacity(0.65))
                Text(label)
                    .font(.ac(11, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(isSelected ? accent : Color.acTextPrimary.opacity(0.75))
                Text(subtext)
                    .font(.ac(9))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: ACRadius.sm, style: .continuous)
                    .fill(isSelected ? accent.opacity(0.10) : Color.acSurface)
                    .overlay(
                        RoundedRectangle(cornerRadius: ACRadius.sm, style: .continuous)
                            .stroke(isSelected ? accent.opacity(0.45) : Color.acHairline,
                                    lineWidth: isSelected ? 1.5 : 1)
                    )
            )
        }
        .buttonStyle(.plain)
        .animation(.acSnap, value: isSelected)
    }

    private var managedButton: some View {
        VStack(spacing: 4) {
            Image(systemName: "sparkles")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.secondary.opacity(0.30))
            Text("Managed")
                .font(.ac(11, weight: .medium))
                .foregroundStyle(Color.secondary.opacity(0.40))
            Text("Coming soon")
                .font(.ac(9))
                .foregroundStyle(Color.secondary.opacity(0.35))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: ACRadius.sm, style: .continuous)
                .fill(Color.acSurface.opacity(0.5))
                .overlay(
                    RoundedRectangle(cornerRadius: ACRadius.sm, style: .continuous)
                        .stroke(Color.acHairline.opacity(0.5), lineWidth: 1)
                )
        )
    }
}

// MARK: - About Section

private struct AboutSection: View {
    @Environment(\.acAccent) private var accent

    private var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
        return "\(v) (\(b))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "info.circle")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(accent)
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(accent.opacity(0.13)))
                Text("About")
                    .font(.ac(13, weight: .semibold))
                    .foregroundStyle(Color.acTextPrimary)
                Spacer()
                Text("v\(appVersion)")
                    .font(.ac(11))
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 0) {
                aboutLink(icon: "arrow.up.right.square", title: "GitHub — source code") {
                    NSWorkspace.shared.open(URL(string: "https://github.com/strjonas/AC")!)
                }
                Divider().opacity(0.3).padding(.leading, 36)
                aboutLink(icon: "hand.raised.fill", title: "Privacy policy") {
                    NSWorkspace.shared.open(URL(string: "https://accountycat.com/privacy")!)
                }
                Divider().opacity(0.3).padding(.leading, 36)
                aboutLink(icon: "sparkles", title: "Managed mode waitlist") {
                    NSWorkspace.shared.open(URL(string: "https://accountycat.com/waitlist")!)
                }
            }
            .background(
                RoundedRectangle(cornerRadius: ACRadius.md, style: .continuous)
                    .fill(Color.acSurface)
                    .overlay(
                        RoundedRectangle(cornerRadius: ACRadius.md, style: .continuous)
                            .stroke(Color.acHairline, lineWidth: 1)
                    )
            )
            .clipShape(RoundedRectangle(cornerRadius: ACRadius.md, style: .continuous))
        }
    }

    private func aboutLink(icon: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                Text(title)
                    .font(.ac(12))
                    .foregroundStyle(Color.acTextPrimary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color.secondary.opacity(0.5))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

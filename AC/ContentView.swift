//
//  ContentView.swift
//  AC

import AppKit
import SwiftUI

// MARK: - Tab enum

enum ACPopoverTab: String {
    case home = "house.fill"
    case brain = "brain.head.profile"
    case settings = "gearshape.fill"
    #if DEBUG
        case stats = "chart.bar.xaxis"
        case logs = "scroll.fill"
    #endif
}

private enum SettingsAlertAction: String, Identifiable {
    case resetAlgorithm
    case deleteLocalModels

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

            tabContent
        }
        .frame(width: ACD.popoverWidth)
        .background(Color(nsColor: .windowBackgroundColor))
        .acAccent(for: controller.state.character)
        .animation(.acFade, value: controller.state.character)
        .onAppear { controller.refreshSystemState() }
        .alert(
            "Are you sure?",
            isPresented: Binding(
                get: { pendingSettingsAction != nil },
                set: { isPresented in
                    if !isPresented { pendingSettingsAction = nil }
                }
            )
        ) {
            if pendingSettingsAction == .resetAlgorithm {
                Button("Reset Algorithm", role: .destructive) {
                    controller.resetAlgorithmProfile()
                    settingsSuccessMessage = "Algorithm profile was reset to defaults."
                    pendingSettingsAction = nil
                }
            } else if pendingSettingsAction == .deleteLocalModels {
                Button("Delete Models", role: .destructive) {
                    controller.deleteManagedModels()
                    pendingSettingsAction = nil
                }
            }
            Button("Cancel", role: .cancel) { pendingSettingsAction = nil }
        } message: {
            switch pendingSettingsAction {
            case .resetAlgorithm:
                Text(
                    "This clears saved chat history, learned memory, recent context, and usage profile."
                )
            case .deleteLocalModels:
                Text(
                    "This removes the selected AC-downloaded local model from Application Support. The runtime stays installed."
                )
            case .none:
                Text("")
            }
        }
        .alert(
            "Done",
            isPresented: Binding(
                get: { settingsSuccessMessage != nil },
                set: { isPresented in
                    if !isPresented { settingsSuccessMessage = nil }
                }
            )
        ) {
            Button("OK", role: .cancel) { settingsSuccessMessage = nil }
        } message: {
            Text(settingsSuccessMessage ?? "")
        }
        .alert(item: $controller.modelDownloadNotice) { notice in
            Alert(
                title: Text("Download needed"),
                message: Text(
                    "\(notice.modelDisplayName) isn't downloaded yet. AC will keep using \(notice.fallbackDisplayName) until the download finishes, then switch automatically."
                ),
                dismissButton: .default(Text("OK"))
            )
        }
        .sheet(item: $controller.modelDownloadSuccess) { notice in
            ModelDownloadSuccessSheet(modelName: notice.modelDisplayName)
        }
    }

    @ViewBuilder
    private var tabContent: some View {
        ScrollView {
            switch selectedTab {
            case .home: homeTab
            case .brain: BrainView().environmentObject(controller)
            case .settings: settingsTab
            #if DEBUG
                case .stats: StatsView()
                case .logs: logsTab
            #else
                default: EmptyView()
            #endif
            }
        }
        .animation(.acFade, value: selectedTab)
    }

    private var popoverHeader: some View {
        VStack(spacing: 0) {
            // Top Bar
            HStack(alignment: .center, spacing: 8) {
                HeaderMark(character: controller.state.character)
                    .frame(width: 32, height: 32)

                VStack(alignment: .leading, spacing: 2) {
                    Text(controller.state.character.displayName)
                        .font(.ac(14, weight: .semibold))
                        .foregroundStyle(Color.acTextPrimary)

                    HStack(spacing: 5) {
                        StatusDot(
                            status: controller.state.setupStatus,
                            isPaused: controller.state.isPaused
                        )
                        .fixedSize(horizontal: true, vertical: false)

                        if controller.state.setupStatus == .ready && !controller.state.isPaused {
                            Text("·")
                                .font(.ac(10))
                                .foregroundStyle(.secondary.opacity(0.45))
                            Text(controller.activeModelShortName)
                                .font(.ac(10))
                                .foregroundStyle(.secondary.opacity(0.80))
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }

                Spacer(minLength: 4)

                ProfileControlBar()
                    .environmentObject(controller)

                Button {
                    controller.dismissPopover?()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Color.secondary.opacity(0.8))
                        .padding(6)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.leading, 2)
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 10)

            Divider()
                .opacity(0.5)

            // Sleeker Tab Bar
            HStack(spacing: 16) {
                tabButton(.home)
                tabButton(.brain)
                tabButton(.settings)
                if ACBuild.isDebug {
                    tabButton(.stats)
                    tabButton(.logs)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            Divider()
        }
        .background(headerBackground)
    }

    private func tabButton(_ tab: ACPopoverTab) -> some View {
        Button {
            withAnimation(.acSnap) { selectedTab = tab }
        } label: {
            Image(systemName: tab.rawValue)
                .font(
                    .system(
                        size: 12.5,
                        weight: selectedTab == tab ? .semibold : .regular)
                )
                .foregroundStyle(
                    selectedTab == tab
                        ? controller.state.character.accentColor
                        : Color.primary.opacity(0.45)
                )
                .frame(width: 32, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: ACRadius.sm, style: .continuous)
                        .fill(
                            selectedTab == tab
                                ? controller.state.character.accentSoft.opacity(0.68)
                                : Color.clear)
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Home Tab

    private var homeTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !controller.hasCompletedOnboardingWizard && controller.state.setupStatus != .ready {
                // New user: show the multi-screen wizard
                OnboardingWizardView()
                    .environmentObject(controller)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            } else if controller.state.setupStatus != .ready
                || controller.showingOnboardingCompletion
            {
                // Wizard done but still setting up (e.g. local download in progress)
                OnboardingDialogView(showModeChooser: false)
                    .environmentObject(controller)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            } else {
                StatsSection(
                    stats: controller.todayStats,
                    accent: controller.state.character.accentColor)
            }

            ChatView()
                .environmentObject(controller)
        }
        .padding(18)
        .padding(.bottom, 8)
        .onAppear {
            controller.maybeCelebrateFocusProgress()
        }
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

            SettingsSection(
                title: "Rescue app", icon: "arrow.uturn.backward.circle",
                subtitle: "Where AC sends you when you've drifted too far."
            ) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(controller.state.rescueApp.displayName)
                            .font(.ac(13, weight: .medium))
                            .foregroundStyle(Color.acTextPrimary)
                        Text(
                            controller.state.rescueApp.applicationPath
                                ?? controller.state.rescueApp.bundleIdentifier
                        )
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

            SettingsSection(
                title: "Reset monitoring profile",
                icon: "arrow.counterclockwise",
                subtitle:
                    "Clears learned memory, recent behavior context, chat history, and usage context."
            ) {
                Button("Reset") { pendingSettingsAction = .resetAlgorithm }
                    .buttonStyle(ACDangerButton())
            }

            if ACBuild.isDebug {
                developerSection
            }

            Divider().opacity(0.3)

            AboutSection()

            Divider().opacity(0.3)

            LocalModelStorageSection(
                onDelete: { pendingSettingsAction = .deleteLocalModels }
            )
            .environmentObject(controller)

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

    private struct LocalModelStorageSection: View {
        @EnvironmentObject private var controller: AppController
        let onDelete: () -> Void

        var body: some View {
            let installed = controller.installedManagedModels
            let selected = controller.selectedInstalledModel

            SettingsSection(
                title: "Local model storage",
                icon: "externaldrive",
                subtitle: "AC stores downloaded local models in its own Application Support cache."
            ) {
                VStack(alignment: .leading, spacing: 10) {
                    storageRow(
                        title: "AC model cache",
                        value: controller.localModelDiagnostics.managedModelCachePath
                    )

                    if installed.isEmpty {
                        Text("No AC-downloaded local models found yet.")
                            .font(.ac(11))
                            .foregroundStyle(.secondary)
                    } else {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Installed models")
                                .font(.ac(11, weight: .semibold))
                                .foregroundStyle(.secondary)
                            Picker(
                                "Installed models",
                                selection: Binding(
                                    get: {
                                        controller.selectedInstalledModel?.cachePath ?? installed
                                            .first?.cachePath ?? ""
                                    },
                                    set: { controller.selectInstalledModel(cachePath: $0) }
                                )
                            ) {
                                ForEach(installed) { model in
                                    Text(AppController.shortModelName(for: model.modelIdentifier))
                                        .tag(model.cachePath)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                        }

                        if let selected {
                            storageRow(
                                title: "Selected model",
                                value: AppController.shortModelName(for: selected.modelIdentifier)
                            )

                            storageRow(
                                title: "Model identifier",
                                value: selected.modelIdentifier
                            )

                            storageRow(
                                title: "Path to model",
                                value: selected.modelPath
                            )

                            if let projectorPath = selected.projectorPath {
                                storageRow(title: "Projector", value: projectorPath)
                            }
                        }
                    }

                    HStack(spacing: 8) {
                        Button("Reveal") {
                            controller.revealManagedModelLocation()
                        }
                        .buttonStyle(ACSecondaryButton())
                        .disabled(selected == nil)

                        Button(
                            controller.importingModelToOllama ? "Importing…" : "Import to Ollama"
                        ) {
                            controller.importCurrentModelToOllama()
                        }
                        .buttonStyle(ACPrimaryButton())
                        .disabled(
                            controller.importingModelToOllama || selected == nil
                        )

                        Button(controller.deletingManagedModels ? "Deleting…" : "Delete Selected") {
                            onDelete()
                        }
                        .buttonStyle(ACDangerButton())
                        .disabled(controller.deletingManagedModels || selected == nil)
                    }

                    Text(
                        "AC now only uses its Application Support cache for local models. Ollama import creates a separate Ollama-managed copy under an `ac-...` name; it does not reuse Ollama's folder in place."
                    )
                    .font(.ac(10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                    if let error = controller.localModelStorageError, !error.isEmpty {
                        Text(error)
                            .font(.ac(10, weight: .medium))
                            .foregroundStyle(Color.red.opacity(0.82))
                            .fixedSize(horizontal: false, vertical: true)
                    } else if let message = controller.localModelStorageMessage, !message.isEmpty {
                        Text(message)
                            .font(.ac(10, weight: .medium))
                            .foregroundStyle(Color.acTextPrimary.opacity(0.72))
                            .fixedSize(horizontal: false, vertical: true)
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
        }

        @ViewBuilder
        private func storageRow(title: String, value: String) -> some View {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.ac(11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Color.acTextPrimary)
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
        }
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
                title: "Pipeline profile",
                selection: Binding(
                    get: { controller.state.monitoringConfiguration.pipelineProfileID },
                    set: { controller.updateMonitoringPipelineProfile($0) }
                ),
                options: controller.availablePipelineProfiles.map {
                    ($0.id, $0.displayName, $0.summary)
                }
            )

            developerPicker(
                title: "Runtime profile",
                selection: Binding(
                    get: { controller.state.monitoringConfiguration.runtimeProfileID },
                    set: { controller.updateMonitoringRuntimeProfile($0) }
                ),
                options: controller.availableRuntimeProfiles.map {
                    ($0.id, $0.displayName, $0.summary)
                }
            )

            VStack(alignment: .leading, spacing: 6) {
                Text("llama.cpp path override")
                    .font(.ac(11, weight: .semibold))
                    .foregroundStyle(.secondary)
                TextField(
                    "Optional custom path",
                    text: Binding(
                        get: { controller.state.runtimePathOverride ?? "" },
                        set: { controller.updateRuntimeOverride($0) }
                    )
                )
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11, design: .monospaced))
            }

            Toggle(
                isOn: Binding(
                    get: { controller.state.monitoringConfiguration.thinkingEnabled },
                    set: { controller.updateThinkingEnabled($0) }
                )
            ) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Thinking / reasoning")
                        .font(.ac(11, weight: .semibold))
                    Text("Enables <think> chain-of-thought output (Qwen3). Off by default.")
                        .font(.ac(10))
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Log level")
                    .font(.ac(11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Picker("Log level", selection: Binding(
                    get: { controller.state.minimumLogLevel },
                    set: { controller.setMinimumLogLevel($0) }
                )) {
                    ForEach([LogLevel.error, .standard, .more, .verbose], id: \.self) { level in
                        Text(level.displayName).tag(level)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 200)
            }
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
                Button("Reliability") { controller.openOpenRouterHealthStats() }
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
                text: controller.activityLog.isEmpty
                    ? "No recent log tail yet." : controller.activityLog,
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
        case .ready: return isPaused ? "Paused" : "With you"
        case .installing: return "Installing"
        case .checking: return "Checking"
        default: return "Setup needed"
        }
    }
}

private struct ModelDownloadSuccessSheet: View {
    let modelName: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 36, weight: .semibold))
                .foregroundStyle(.green)
            Text("Download complete")
                .font(.ac(16, weight: .semibold))
                .foregroundStyle(Color.acTextPrimary)
            Text("Downloaded \(modelName) successfully. Now using \(modelName).")
                .font(.ac(12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("OK") { dismiss() }
                .buttonStyle(ACPrimaryButton())
                .padding(.top, 4)
        }
        .padding(22)
        .frame(minWidth: 280)
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
        Button {
            isOn.toggle()
        } label: {
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
                            .stroke(
                                isOn
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

            TimelineStrip(
                segments: stats.timelineSegments,
                accent: accent
            )

            HStack(spacing: 8) {
                StatCard(
                    icon: "clock.fill",
                    value: formatDuration(stats.focusedSeconds),
                    label: "Focused",
                    accent: accent)
                StatCard(
                    icon: "bolt.fill",
                    value: formatDuration(stats.longestFocusedBlockSeconds),
                    label: "Best block",
                    accent: accent)
                StatCard(
                    icon: "flame.fill",
                    value: "\(stats.streakDays)d",
                    label: "Streak",
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

private struct TimelineStrip: View {
    let segments: [FocusTimelineSegment]
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Image(systemName: "chart.bar.xaxis")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(accent)
                .frame(width: 22, height: 22)
                .background(Circle().fill(accent.opacity(0.12)))

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule(style: .continuous)
                        .fill(Color.acSurface)
                    ForEach(renderedSegments, id: \.id) { segment in
                        Capsule(style: .continuous)
                            .fill(color(for: segment.assessment))
                            .frame(
                                width: max(2, proxy.size.width * segment.widthFraction),
                                height: proxy.size.height
                            )
                            .offset(x: proxy.size.width * segment.startFraction)
                    }
                }
            }
            .frame(height: 9)

            Text("Timeline")
                .font(.ac(10))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
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

    private struct RenderedSegment: Identifiable {
        let id: UUID
        let assessment: FocusSegmentAssessment
        let startFraction: Double
        let widthFraction: Double
    }

    private var renderedSegments: [RenderedSegment] {
        let cal = Calendar.current
        let now = Date()
        let startOfDay = cal.startOfDay(for: now)
        let endOfDay = cal.date(byAdding: .day, value: 1, to: startOfDay) ?? now
        let total = endOfDay.timeIntervalSince(startOfDay)
        guard total > 0 else { return [] }

        return segments.compactMap { segment in
            let start = max(segment.startAt, startOfDay)
            let end = min(segment.endAt, now)
            let duration = end.timeIntervalSince(start)
            guard duration > 0 else { return nil }
            return RenderedSegment(
                id: segment.id,
                assessment: segment.assessment,
                startFraction: start.timeIntervalSince(startOfDay) / total,
                widthFraction: duration / total
            )
        }
    }

    private func color(for assessment: FocusSegmentAssessment) -> Color {
        switch assessment {
        case .focused: return accent.opacity(0.78)
        case .distracted: return Color.orange.opacity(0.78)
        case .unclear: return Color.gray.opacity(0.42)
        case .idle: return Color.acHairline
        }
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

            Toggle(
                isOn: Binding(
                    get: { isOn },
                    set: { controller.setCalendarIntelligence(enabled: $0) }
                )
            ) {
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
                .help(
                    """
                    Let AC read your current calendar event to infer what you want \
                    to focus on — so it stays out of the way with less effort \
                    from you. Works with any calendar already in Apple Calendar \
                    (iCloud, Google, Exchange, Fastmail, …). Events are read \
                    locally and never leave your Mac.
                    """
                )
                .onHover { hoveringInfo = $0 }
                .opacity(hoveringInfo ? 1.0 : 0.75)
        }
    }

    private var permissionPrompt: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(
                "Calendar access is required. If you denied it earlier, re-enable it in System Settings → Privacy & Security → Calendars."
            )
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
                    if let url = URL(
                        string:
                            "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars"
                    ) {
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
            let enabledCount = controller.availableCalendars.filter {
                controller.isCalendarEnabled($0.id)
            }.count
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
                            ForEach(
                                Array(controller.availableCalendars.enumerated()), id: \.element.id
                            ) { index, cal in
                                Toggle(
                                    isOn: Binding(
                                        get: { controller.isCalendarEnabled(cal.id) },
                                        set: { _ in controller.toggleCalendarEnabled(cal.id) }
                                    )
                                ) {
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
                                isSelected
                                    ? character.accentColor.opacity(0.55)
                                    : Color.white.opacity(0.45),
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
                .fill(
                    isSelected
                        ? character.accentSoft.opacity(0.55)
                        : Color.acSurface
                )
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

                if showLocalModelProgress {
                    localModelProgress
                        .padding(.leading, 26)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Check timing")
                    .font(.ac(11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 26)

                CadencePicker(
                    selected: controller.state.monitoringConfiguration.cadenceMode,
                    usingOnline: controller.usingOnlineMonitoring,
                    onSelect: { controller.updateMonitoringCadenceMode($0) }
                )
                .padding(.leading, 26)
            }

            VisionGateSettingsCard(
                threshold: Binding(
                    get: { controller.state.monitoringConfiguration.titleLengthForTextOnly },
                    set: { controller.updateTitleLengthForTextOnly($0) }
                )
            )
            .padding(.leading, 26)
        }
    }

    private var showLocalModelProgress: Bool {
        !controller.usingOnlineMonitoring
            && (controller.installingRuntime || controller.pendingLocalModelChange != nil)
    }

    @ViewBuilder
    private var localModelProgress: some View {
        let pendingName = controller.pendingLocalModelChange
            .map { AppController.shortModelName(for: $0.modelIdentifier) }
        let fallbackMessage = pendingName.map { "Downloading \($0)…" } ?? "Downloading model…"
        let percentText = controller.setupProgressValue.map { progress -> String in
            let clamped = max(0, min(100, Int((progress * 100).rounded())))
            return "\(clamped)%"
        }

        VStack(alignment: .leading, spacing: 6) {
            if let progress = controller.setupProgressValue {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
            } else {
                ProgressView()
                    .progressViewStyle(.linear)
            }

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(controller.setupProgressMessage ?? fallbackMessage)
                    .lineLimit(2)
                Spacer(minLength: 6)
                if let percentText {
                    Text(percentText)
                }
            }
            .font(.ac(10))
            .foregroundStyle(Color.acTextPrimary.opacity(0.72))
        }
        .padding(.top, 2)
    }
}

private struct CadencePicker: View {
    let selected: MonitoringCadenceMode
    let usingOnline: Bool
    let onSelect: (MonitoringCadenceMode) -> Void
    @Environment(\.acAccent) private var accent

    var body: some View {
        VStack(spacing: 7) {
            ForEach(MonitoringCadenceMode.allCases, id: \.self) { mode in
                Button {
                    onSelect(mode)
                } label: {
                    HStack(alignment: .top, spacing: 9) {
                        Image(systemName: selected == mode ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(
                                selected == mode ? accent : Color.secondary.opacity(0.45)
                            )
                            .padding(.top, 1)

                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(mode.displayName)
                                    .font(.ac(12, weight: .semibold))
                                    .foregroundStyle(Color.acTextPrimary)
                                if usingOnline {
                                    Text(mode.byokCostHint)
                                        .font(.ac(10, weight: .medium))
                                        .foregroundStyle(accent.opacity(0.82))
                                }
                            }
                            Text(mode.description)
                                .font(.ac(10))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Spacer(minLength: 0)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: ACRadius.sm, style: .continuous)
                            .fill(selected == mode ? accent.opacity(0.10) : Color.acSurface)
                            .overlay(
                                RoundedRectangle(cornerRadius: ACRadius.sm, style: .continuous)
                                    .stroke(
                                        selected == mode ? accent.opacity(0.35) : Color.acHairline,
                                        lineWidth: 1)
                            )
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }
}

private struct VisionGateSettingsCard: View {
    @Binding var threshold: Int
    @Environment(\.acAccent) private var accent

    private let presets = [20, 30, 50]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Vision gate")
                    .font(.ac(11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("Longer titles can stay text-only before AC attaches a screenshot.")
                    .font(.ac(10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text("\(threshold) characters")
                        .font(.ac(13, weight: .semibold))
                        .foregroundStyle(Color.acTextPrimary)
                    Spacer(minLength: 8)
                    Text(thresholdLabel)
                        .font(.ac(10, weight: .medium))
                        .foregroundStyle(accent.opacity(0.86))
                }

                Slider(
                    value: Binding(
                        get: { Double(threshold) },
                        set: { threshold = Int($0.rounded()) }
                    ),
                    in: Double(
                        MonitoringConfiguration.minTitleLengthForTextOnly)...Double(
                            MonitoringConfiguration.maxTitleLengthForTextOnly),
                    step: 1
                )

                HStack(spacing: 8) {
                    ForEach(presets, id: \.self) { preset in
                        let isSelected = preset == threshold
                        Button(String(preset)) {
                            threshold = preset
                        }
                        .buttonStyle(
                            isSelected
                                ? AnyButtonStyle(ACPrimaryButton())
                                : AnyButtonStyle(ACSecondaryButton()))
                    }
                    Spacer(minLength: 0)
                }

                Text(
                    "30 is the balanced default. Lower is cheaper but risks more unclear retries; higher keeps vision on longer. Browsers and ambiguous apps still keep screenshots regardless."
                )
                .font(.ac(10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: ACRadius.sm, style: .continuous)
                    .fill(Color.acSurface)
                    .overlay(
                        RoundedRectangle(cornerRadius: ACRadius.sm, style: .continuous)
                            .stroke(Color.acHairline, lineWidth: 1)
                    )
            )
        }
    }

    private var thresholdLabel: String {
        switch threshold {
        case ..<25:
            return "Aggressive"
        case ..<41:
            return "Balanced"
        default:
            return "Conservative"
        }
    }
}

private struct AnyButtonStyle: ButtonStyle {
    private let makeBodyClosure: (Configuration) -> AnyView

    init<S: ButtonStyle>(_ style: S) {
        self.makeBodyClosure = { configuration in
            AnyView(style.makeBody(configuration: configuration))
        }
    }

    func makeBody(configuration: Configuration) -> some View {
        makeBodyClosure(configuration)
    }
}

/// Compact 3-button mode row for the Settings AI section.
private struct SettingsModeRow: View {
    let current: MonitoringInferenceBackend
    let onChange: (MonitoringInferenceBackend) -> Void
    @Environment(\.acAccent) private var accent

    var body: some View {
        HStack(spacing: 8) {
            modeButton(.local, label: "Local", icon: "lock.fill", subtext: "Private")
            modeButton(.openRouter, label: "BYOK", icon: "key.fill", subtext: "OpenRouter")
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
        Button {
            onChange(backend)
        } label: {
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
                            .stroke(
                                isSelected ? accent.opacity(0.45) : Color.acHairline,
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

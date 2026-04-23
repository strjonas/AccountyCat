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
    @State private var advancedExpanded = false
    @AppStorage("acSoundEnabled") private var soundEnabled: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            popoverHeader
            Divider()
            tabContent
        }
        .frame(width: ACD.popoverWidth)
        .background(Color(nsColor: .windowBackgroundColor))
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
        HStack(spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: "pawprint.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.acCaramel)
                Text("AccountyCat")
                    .font(.ac(15, weight: .semibold))
                    .foregroundStyle(Color.acTextPrimary)
            }

            Spacer()

            StatusDot(status: controller.state.setupStatus,
                      isPaused: controller.state.isPaused)

            Spacer()

            HStack(spacing: 2) {
                tabButton(.home)
                tabButton(.settings)
                if ACBuild.isDebug {
                    tabButton(.logs)
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 13)
        .background(headerBackground)
    }

    private func tabButton(_ tab: ACPopoverTab) -> some View {
        Button {
            withAnimation(.acSnap) { selectedTab = tab }
        } label: {
            Image(systemName: tab.rawValue)
                .font(.system(size: 13,
                              weight: selectedTab == tab ? .semibold : .regular))
                .foregroundStyle(selectedTab == tab
                                 ? Color.acCaramel
                                 : Color.secondary.opacity(0.70))
                .frame(width: 34, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(selectedTab == tab
                              ? Color.acCaramelSoft.opacity(0.45)
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
            case .settings: settingsTab
            case .logs:     logsTab
            }
        }
        .animation(.acFade, value: selectedTab)
    }

    // MARK: - Home Tab

    private var homeTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            if controller.state.setupStatus != .ready {
                OnboardingDialogView()
                    .environmentObject(controller)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            } else {
                StatsSection(stats: controller.todayStats)
            }

            Divider()

            ChatView()
                .environmentObject(controller)
        }
        .padding(18)
        .padding(.bottom, 8)
    }

    // MARK: - Settings Tab

    private var settingsTab: some View {
        VStack(alignment: .leading, spacing: 20) {

            // ── Goals (always visible) ──
            VStack(alignment: .leading, spacing: 8) {
                Label("Your goals", systemImage: "target")
                    .font(.ac(14, weight: .semibold))
                    .foregroundStyle(Color.acTextPrimary)

                Text("AC nudges you back to these when you drift. Keep it short and specific.")
                    .font(.ac(11))
                    .foregroundStyle(.secondary)

                TextEditor(text: Binding(
                    get: { controller.state.goalsText },
                    set: { controller.updateGoals($0) }
                ))
                .font(.ac(13))
                .frame(minHeight: 96, maxHeight: 140)
                .padding(8)
                .scrollContentBackground(.hidden)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color(nsColor: .textBackgroundColor))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(Color.secondary.opacity(0.20), lineWidth: 1)
                        )
                )
            }

            VStack(alignment: .leading, spacing: 10) {
                Label("Controls", systemImage: "switch.2")
                    .font(.ac(14, weight: .semibold))
                    .foregroundStyle(Color.acTextPrimary)

                HStack(spacing: 10) {
                    ToggleTile(
                        icon: controller.state.isPaused ? "play.circle.fill" : "pause.circle.fill",
                        title: controller.state.isPaused ? "Paused" : "Watching",
                        subtitle: controller.state.isPaused ? "Tap to resume" : "Tap to pause",
                        isOn: Binding(
                            get: { !controller.state.isPaused },
                            set: { _ in controller.togglePause() }
                        ),
                        tint: .acCaramel
                    )

                    ToggleTile(
                        icon: soundEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill",
                        title: "Sound",
                        subtitle: soundEnabled ? "On for nudges" : "Muted",
                        isOn: $soundEnabled,
                        tint: .acCaramel
                    )
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Label("Rescue app", systemImage: "arrow.uturn.backward.circle")
                    .font(.ac(13, weight: .semibold))
                    .foregroundStyle(Color.acTextPrimary)

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(controller.state.rescueApp.displayName)
                            .font(.ac(13))
                        Text(controller.state.rescueApp.applicationPath
                             ?? controller.state.rescueApp.bundleIdentifier)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer()
                    HStack(spacing: 6) {
                        Button("Choose") { controller.chooseRescueApp() }
                            .buttonStyle(ACSecondaryButton())
                        Button("Open") { controller.openRescueApp() }
                            .buttonStyle(ACPrimaryButton())
                    }
                }
            }

            // ── Advanced (collapsible) ──
            AdvancedDisclosure(expanded: $advancedExpanded) {
                advancedContent
            }

            Divider()

            // ── Quit (always visible) ──
            HStack {
                Spacer()
                Button("Quit AccountyCat") { NSApp.terminate(nil) }
                    .font(.ac(13))
                    .foregroundStyle(Color.red.opacity(0.80))
                    .buttonStyle(.plain)
            }
        }
        .padding(20)
    }

    @ViewBuilder
    private var advancedContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            // Reset
            VStack(alignment: .leading, spacing: 6) {
                Label("Reset algorithm profile", systemImage: "arrow.counterclockwise")
                    .font(.ac(13, weight: .semibold))
                    .foregroundStyle(Color.acTextPrimary)

                Text("Clears learned memory, recent behavior context, chat history, and usage context.")
                    .font(.ac(11))
                    .foregroundStyle(.secondary)

                Button("Reset") { pendingSettingsAction = .resetAlgorithm }
                    .buttonStyle(ACDangerButton())
            }

            if ACBuild.isDebug {
                developerSection
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
                title: "Monitoring algorithm",
                selection: Binding(
                    get: { controller.state.monitoringConfiguration.algorithmID },
                    set: { controller.updateMonitoringAlgorithm($0) }
                ),
                options: controller.availableMonitoringAlgorithms.map { ($0.id, $0.displayName, $0.summary) }
            )

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
        if colorScheme == .dark {
            return AnyView(
                LinearGradient(
                    colors: [
                        Color(red: 0.22, green: 0.18, blue: 0.13),
                        Color(red: 0.18, green: 0.14, blue: 0.09),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
        } else {
            return AnyView(
                LinearGradient(
                    colors: [
                        Color(red: 1.00, green: 0.97, blue: 0.93),
                        Color(red: 0.99, green: 0.94, blue: 0.87),
                    ],
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

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(dotColor)
                .frame(width: 7, height: 7)
            Text(label)
                .font(.ac(11))
                .foregroundStyle(.secondary)
        }
    }

    private var dotColor: Color {
        switch status {
        case .ready:
            return isPaused ? Color.acAmber : .green
        case .installing:
            return .acCaramel
        default:
            return .red.opacity(0.65)
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
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(isOn ? tint : Color.secondary.opacity(0.75))
                    .frame(width: 22)

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
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isOn
                          ? Color.acCaramelSoft.opacity(0.45)
                          : Color(nsColor: .controlBackgroundColor).opacity(0.6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(isOn
                                    ? tint.opacity(0.35)
                                    : Color.secondary.opacity(0.18),
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

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Today")
                .font(.ac(11, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            HStack(spacing: 8) {
                StatCard(
                    icon: "clock.fill",
                    value: formatDuration(stats.totalTrackedSeconds),
                    label: "Tracked"
                )
                StatCard(
                    icon: "bubble.left.fill",
                    value: "\(stats.nudgeCount)",
                    label: "Nudges"
                )
                StatCard(
                    icon: "arrow.uturn.backward.circle.fill",
                    value: "\(stats.backToWorkCount)",
                    label: "Rescues"
                )
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

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.acCaramel)

            VStack(alignment: .leading, spacing: 1) {
                Text(value)
                    .font(.ac(16, weight: .semibold))
                    .foregroundStyle(Color.acTextPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(label)
                    .font(.ac(10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.6))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
                )
        )
    }
}

// MARK: - Advanced disclosure

private struct AdvancedDisclosure<Content: View>: View {
    @Binding var expanded: Bool
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                withAnimation(.acSnap) { expanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.acCaramel)
                    Text("Advanced")
                        .font(.ac(14, weight: .semibold))
                        .foregroundStyle(Color.acTextPrimary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                content()
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}

// MARK: - Danger button

struct ACDangerButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.ac(13, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Capsule().fill(Color.red.opacity(configuration.isPressed ? 0.82 : 0.92)))
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.acSnap, value: configuration.isPressed)
    }
}

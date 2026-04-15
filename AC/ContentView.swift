//
//  ContentView.swift
//  AC
//
//  Compact popover content — replaces the old 900pt settings window.
//  Two tabs: Home (status + setup + chat) and Settings (prefs + debug + quit).
//  A Logs tab appears automatically when debug mode is on.
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
                if !isPresented {
                    pendingSettingsAction = nil
                }
            }
        )) {
            if pendingSettingsAction == .resetAlgorithm {
                Button("Reset Algorithm", role: .destructive) {
                    controller.resetAlgorithmProfile()
                    settingsSuccessMessage = "Algorithm profile was reset to defaults."
                    pendingSettingsAction = nil
                }
            }

            Button("Cancel", role: .cancel) {
                pendingSettingsAction = nil
            }
        } message: {
            switch pendingSettingsAction {
            case .resetAlgorithm:
                Text("This clears saved chat history, learned memory, recent context, and usage profile, but keeps raw telemetry files.")
            case .none:
                Text("")
            }
        }
        .alert("Done", isPresented: Binding(
            get: { settingsSuccessMessage != nil },
            set: { isPresented in
                if !isPresented {
                    settingsSuccessMessage = nil
                }
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
            // Branding
            HStack(spacing: 7) {
                Image(systemName: "pawprint.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.acCaramel)
                Text("AccountyCat")
                    .font(.ac(15, weight: .semibold))
                    .foregroundStyle(Color.acTextPrimary)
            }

            Spacer()

            // Status dot
            StatusDot(status: controller.state.setupStatus,
                      isPaused: controller.state.isPaused)

            Spacer()

            // Tab switcher
            HStack(spacing: 2) {
                tabButton(.home)
                tabButton(.settings)
                if controller.state.debugMode {
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
            // Status summary line
            Text(controller.activityStatusText)
                .font(.ac(12))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            // Pause toggle (always visible, prominent)
            Toggle(isOn: Binding(
                get: { controller.state.isPaused },
                set: { _ in controller.togglePause() }
            )) {
                HStack(spacing: 8) {
                    Image(systemName: controller.state.isPaused
                          ? "play.circle.fill"
                          : "pause.circle.fill")
                        .foregroundStyle(Color.acCaramel)
                    Text(controller.state.isPaused ? "Resume monitoring" : "Pause monitoring")
                        .font(.ac(14))
                }
            }
            .toggleStyle(.switch)

            // Setup card (shown when not fully ready OR dismissed but setup still pending)
            if controller.state.setupStatus != .ready {
                OnboardingDialogView()
                    .environmentObject(controller)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }

            Divider()

            // Chat
            ChatView()
                .environmentObject(controller)
        }
        .padding(18)
        .padding(.bottom, 8)
    }

    // MARK: - Settings Tab

    private var settingsTab: some View {
        VStack(alignment: .leading, spacing: 20) {

            // ── Goals ──
            VStack(alignment: .leading, spacing: 8) {
                Label("Your goals", systemImage: "target")
                    .font(.ac(14, weight: .semibold))
                    .foregroundStyle(Color.acTextPrimary)

                TextEditor(text: Binding(
                    get: { controller.state.goalsText },
                    set: { controller.updateGoals($0) }
                ))
                .font(.ac(13))
                .frame(minHeight: 90, maxHeight: 140)
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color(nsColor: .textBackgroundColor))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(Color.secondary.opacity(0.20), lineWidth: 1)
                        )
                )
            }

            Divider()

            // ── Rescue app ──
            VStack(alignment: .leading, spacing: 10) {
                Label("Rescue app", systemImage: "arrow.uturn.backward.circle")
                    .font(.ac(14, weight: .semibold))
                    .foregroundStyle(Color.acTextPrimary)

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(controller.state.rescueApp.displayName)
                            .font(.ac(14))
                        Text(controller.state.rescueApp.applicationPath
                             ?? controller.state.rescueApp.bundleIdentifier)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    HStack(spacing: 8) {
                        Button("Choose") { controller.chooseRescueApp() }
                            .buttonStyle(ACSecondaryButton())
                        Button("Open") { controller.openRescueApp() }
                            .buttonStyle(ACPrimaryButton())
                    }
                }
            }

            Divider()

            // ── Toggles ──
            VStack(alignment: .leading, spacing: 12) {
                Toggle(isOn: $soundEnabled) {
                    Label("Quiet nudge sound", systemImage: "speaker.wave.1.fill")
                        .font(.ac(14))
                }
                .toggleStyle(.switch)

                Toggle(isOn: Binding(
                    get: { controller.state.debugMode },
                    set: { controller.setDebugMode($0) }
                )) {
                    Label("Debug mode", systemImage: "ladybug")
                        .font(.ac(14))
                }
                .toggleStyle(.switch)
            }

            // ── Debug section ──
            if controller.state.debugMode {
                Divider()

                VStack(alignment: .leading, spacing: 10) {
                    Text("Debug")
                        .font(.ac(12, weight: .semibold))
                        .foregroundStyle(.secondary)

                    HStack(spacing: 10) {
                        Button("Test Nudge") { controller.sendTestNudge() }
                            .buttonStyle(ACPrimaryButton())
                        Button("Test Overlay") { controller.showTestOverlay() }
                            .buttonStyle(ACPrimaryButton())
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("llama.cpp path override")
                            .font(.ac(12, weight: .semibold))
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

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                Label("Algorithm", systemImage: "arrow.counterclockwise")
                    .font(.ac(14, weight: .semibold))
                    .foregroundStyle(Color.acTextPrimary)

                Text("Reset the model-facing profile to defaults. This clears learned memory, recent behavior context, chat history, and usage context without deleting raw telemetry files.")
                    .font(.ac(12))
                    .foregroundStyle(.secondary)

                Button("Reset Algorithm") {
                    pendingSettingsAction = .resetAlgorithm
                }
                .buttonStyle(.plain)
                .font(.ac(13, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.red.opacity(0.92))
                )
            }

            Divider()

            // ── Quit ──
            HStack {
                Spacer()
                Button("Quit AccountyCat") { NSApp.terminate(nil) }
                    .font(.ac(13))
                    .foregroundStyle(Color.red.opacity(0.75))
                    .buttonStyle(.plain)
            }
        }
        .padding(20)
    }

    // MARK: - Logs Tab

    private var logsTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Button("Open telemetry root") { controller.openTelemetryRoot() }
                    .buttonStyle(ACPrimaryButton())
                Button("Open current session") { controller.openCurrentTelemetrySession() }
                    .buttonStyle(ACSecondaryButton())
                Button("Open text log") { controller.openActivityLog() }
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

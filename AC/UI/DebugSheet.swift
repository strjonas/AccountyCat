//
//  DebugSheet.swift
//  AC
//
//  Developer tools sheet — only available in DEBUG builds.  Triggered by
//  Option-clicking the cat icon in the chat popover header (or the gear
//  icon).  Contains the stats dashboard, log console, and developer
//  controls that previously lived in separate tabs.
//

import SwiftUI

struct DebugSheet: View {
    @EnvironmentObject private var controller: AppController
    @Environment(\.dismiss) private var dismiss

    enum Tab: String, CaseIterable {
        case stats = "Stats"
        case logs = "Logs"
        case controls = "Controls"
    }

    @State private var selectedTab: Tab = .stats

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Picker("", selection: $selectedTab) {
                ForEach(Tab.allCases, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.bottom, 12)

            Divider().opacity(0.5)

            ScrollView {
                switch selectedTab {
                case .stats: StatsView()
                case .logs: logsContent
                case .controls: developerControls
                }
            }
        }
        .frame(width: ACD.popoverWidth, height: 560)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "hammer.fill")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Color.orange.opacity(0.85))
            Text("Developer Tools")
                .font(.acTitle)
                .foregroundStyle(Color.acTextPrimary)
            Spacer()
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color.secondary.opacity(0.8))
                    .padding(6)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Logs

    private var logsContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
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
                    .font(.acCaptionStrong)
                    .foregroundStyle(.secondary)
                Text(controller.telemetrySessionID ?? "No active session")
                    .font(.acMono)
                    .foregroundStyle(Color.acTextPrimary)
            }

            logConsole(title: "Recent text log", text: controller.activityLog.isEmpty ? "No recent log tail yet." : controller.activityLog, height: 210)
            logConsole(title: "Installer", text: controller.setupLog.isEmpty ? "No setup activity yet." : controller.setupLog, height: 130)
        }
        .padding(20)
    }

    private func logConsole(title: String, text: String, height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.acCaptionStrong)
                .foregroundStyle(.secondary)

            ScrollView {
                Text(text)
                    .font(.acMono)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(10)
            }
            .frame(height: height)
            .background(
                RoundedRectangle(cornerRadius: ACRadius.md, style: .continuous)
                    .fill(Color.black.opacity(0.86))
            )
            .foregroundStyle(Color.green.opacity(0.90))
        }
    }

    // MARK: - Developer controls

    private var developerControls: some View {
        VStack(alignment: .leading, spacing: 12) {
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
                    .font(.acCaptionStrong)
                    .foregroundStyle(.secondary)
                TextField("Optional custom path", text: Binding(
                    get: { controller.state.runtimePathOverride ?? "" },
                    set: { controller.updateRuntimeOverride($0) }
                ))
                .textFieldStyle(.roundedBorder)
                .font(.acMono)
            }

            Toggle(isOn: Binding(
                get: { controller.state.monitoringConfiguration.thinkingEnabled },
                set: { controller.updateThinkingEnabled($0) }
            )) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Thinking / reasoning")
                        .font(.acCaptionStrong)
                    Text("Enables thinking output (Qwen3). Off by default.")
                        .font(.acCaption)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Log level")
                    .font(.acCaptionStrong)
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
        .padding(20)
    }

    private func developerPicker(
        title: String,
        selection: Binding<String>,
        options: [(id: String, name: String, summary: String)]
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.acCaptionStrong)
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
                    .font(.acCaption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
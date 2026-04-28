//
//  OnboardingDialogView.swift
//  AC
//

import AppKit
import SwiftUI

struct OnboardingDialogView: View {
    @EnvironmentObject private var controller: AppController
    @Environment(\.acAccent) private var accent

    /// When `false` the mode chooser cards are hidden — used after the wizard has
    /// already captured the user's backend choice and only setup steps remain.
    var showModeChooser: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            if controller.showingOnboardingCompletion && controller.state.setupStatus == .ready {
                completionBanner
            } else if controller.installingRuntime {
                downloadExpectationBanner
            }

            // Mode chooser: hidden after wizard completion since the user's choice
            // is already locked in and changeable via Settings → AI.
            if showModeChooser && controller.state.setupStatus != .ready {
                modeChooser
            }

            // Step rows
            VStack(spacing: 4) {
                SetupStepRow(
                    title: "Screen Recording",
                    state: permissionRequirements.requiresScreenRecording == false
                        ? .done
                        : (controller.state.permissions.screenRecording == .granted ? .done : .needed)
                )
                SetupStepRow(
                    title: "Accessibility",
                    state: permissionRequirements.requiresAccessibility == false
                        ? .done
                        : (controller.state.permissions.accessibility == .granted ? .done : .needed)
                )
                if controller.usingOnlineMonitoring {
                    SetupStepRow(
                        title: "OpenRouter API key",
                        state: controller.hasOnlineAPIKeyConfigured ? .done : .needed
                    )
                } else {
                    SetupStepRow(
                        title: "Build tools",
                        state: controller.setupDiagnostics.missingTools.isEmpty ? .done : .needed
                    )
                    SetupStepRow(
                        title: "Local model",
                        state: runtimeState
                    )
                }
            }
            .padding(.vertical, 2)

            if controller.usingOnlineMonitoring,
               controller.state.setupStatus != .ready {
                openRouterKeyPanel
            }

            // Error
            if let err = controller.setupErrorMessage {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.red.opacity(0.85))
                    Text(err)
                        .font(.ac(11))
                        .foregroundStyle(.red.opacity(0.9))
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: ACRadius.sm, style: .continuous)
                        .fill(Color.red.opacity(0.08))
                )
            }

            if controller.installingRuntime,
               let progress = controller.setupProgressValue {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)

                    let percent = max(0, min(100, Int((progress * 100).rounded())))
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(controller.setupProgressMessage ?? "Downloading model…")
                            .lineLimit(2)
                        Spacer(minLength: 6)
                        Text("\(percent)%")
                    }
                    .font(.ac(10))
                    .foregroundStyle(Color.acTextPrimary.opacity(0.72))
                }
                .padding(.top, 2)
            } else if controller.installingRuntime {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView()
                        .progressViewStyle(.linear)

                    Text(controller.setupProgressMessage ?? "Downloading model…")
                        .font(.ac(10))
                        .foregroundStyle(Color.acTextPrimary.opacity(0.72))
                        .lineLimit(2)
                }
                .padding(.top, 2)
            }

            // Action buttons
            if controller.state.setupStatus != .ready {
                actionButtons
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: ACRadius.lg, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.7))
                .overlay(
                    RoundedRectangle(cornerRadius: ACRadius.lg, style: .continuous)
                        .stroke(Color.acHairline, lineWidth: 1)
                )
        )
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: controller.state.setupStatus == .ready
                  ? "checkmark.seal.fill"
                  : "wand.and.stars")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(accent)
                .frame(width: 26, height: 26)
                .background(Circle().fill(accent.opacity(0.14)))

            VStack(alignment: .leading, spacing: 2) {
                Text(controller.state.setupStatus == .ready
                     ? "AccountyCat is ready"
                     : "Pick how AC monitors")
                    .font(.ac(15, weight: .semibold))
                    .foregroundStyle(Color.acTextPrimary)

                Text(subtitle)
                    .font(.ac(12))
                    .foregroundStyle(Color.acTextPrimary.opacity(0.72))
            }
            Spacer(minLength: 8)
            Button(action: { controller.refreshSystemState() }) {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(ACIconButton())
            .help("Refresh status")
        }
    }

    // MARK: - Mode chooser

    private var modeChooser: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Two ways to run AC — both work great.")
                .font(.ac(11, weight: .medium))
                .foregroundStyle(Color.acTextPrimary.opacity(0.7))

            HStack(alignment: .top, spacing: 8) {
                ModeCard(
                    title: "Local",
                    tagline: "Fully private",
                    bullets: [
                        "Runs on your Mac — nothing leaves it",
                        "~4.5 GB one-time download",
                        "No API costs, slower & smaller model"
                    ],
                    isSelected: !controller.usingOnlineMonitoring,
                    accent: accent,
                    onSelect: { controller.updateMonitoringInferenceBackend(.local) }
                )
                ModeCard(
                    title: "Online",
                    tagline: "Smarter, lighter",
                    bullets: [
                        "Low-cost models like Gemma available",
                        "No download — just an API key",
                        "Open source: only sends what AI tools usually see"
                    ],
                    isSelected: controller.usingOnlineMonitoring,
                    accent: accent,
                    onSelect: { controller.updateMonitoringInferenceBackend(.openRouter) }
                )
            }

            Text("You can switch any time in Settings.")
                .font(.ac(10))
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: ACRadius.md, style: .continuous)
                .fill(Color.acSurface)
        )
    }

    // MARK: - OpenRouter key panel (inline during onboarding)

    private var openRouterKeyPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            OpenRouterKeyField()
                .environmentObject(controller)

            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("AccountyCat is open source. With Vision off, only the active app and window title are sent. With Vision on, a screenshot is also sent — same as you'd paste into ChatGPT.")
                    .font(.ac(10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: ACRadius.md, style: .continuous)
                .fill(Color.acSurface)
        )
    }

    // MARK: - Banners

    private var completionBanner: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.green)
            Text("Setup complete — AC is now watching.")
                .font(.ac(12, weight: .medium))
                .foregroundStyle(Color.acTextPrimary)
            Spacer(minLength: 0)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: ACRadius.sm, style: .continuous)
                .fill(Color.green.opacity(0.12))
        )
        .transition(.opacity)
    }

    private var downloadExpectationBanner: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.acTextPrimary.opacity(0.68))
            Text("First-time setup downloads ~4.5 GB. Depending on your connection this can take 5–20 minutes. You can keep using your Mac — AC will notify you here when it's ready.")
                .font(.ac(11))
                .foregroundStyle(Color.acTextPrimary.opacity(0.72))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: ACRadius.sm, style: .continuous)
                .fill(Color.acSurface)
        )
    }

    // MARK: - Action Buttons

    private var actionButtons: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if permissionRequirements.requiresScreenRecording &&
                    controller.state.permissions.screenRecording != .granted {
                    Button("Screen Recording") {
                        controller.requestScreenRecordingPermission()
                    }
                    .buttonStyle(ACPrimaryButton())
                }

                if permissionRequirements.requiresAccessibility &&
                    controller.state.permissions.accessibility != .granted {
                    Button("Accessibility") {
                        controller.requestAccessibilityPermission()
                    }
                    .buttonStyle(ACPrimaryButton())
                }

                if controller.usingOnlineMonitoring {
                    EmptyView()
                } else if !controller.setupDiagnostics.missingTools.isEmpty {
                    Button(controller.installingDependencies
                           ? "Installing tools…"
                           : "Install tools") {
                        controller.installMissingDependencies()
                    }
                    .buttonStyle(ACPrimaryButton())
                    .disabled(controller.installingDependencies)
                } else if runtimeState != .done {
                    Button(primaryRuntimeActionTitle) {
                        controller.installRuntime()
                    }
                    .buttonStyle(ACPrimaryButton())
                    .disabled(controller.installingRuntime)
                }

                Button("Refresh") {
                    controller.refreshSystemState()
                }
                .buttonStyle(ACSecondaryButton())
            }
        }
    }

    // MARK: - Helpers

    private var subtitle: String {
        if controller.state.setupStatus == .ready {
            if controller.usingOnlineMonitoring {
                return permissionRequirements.requiresScreenRecording
                    ? "Online monitoring is active with screenshot upload."
                    : "Online monitoring is active with text-only context."
            }
            return "Running locally — fully private."
        }
        if controller.usingOnlineMonitoring {
            return "Add your OpenRouter key below to enable online monitoring."
        }
        return "Local setup downloads a small model. Everything stays on your Mac."
    }

    private var permissionRequirements: MonitoringPermissionRequirements {
        LLMPolicyCatalog.permissionRequirements(for: controller.state.monitoringConfiguration)
    }

    private var runtimeState: SetupStepState {
        if controller.usingOnlineMonitoring {
            return controller.hasOnlineAPIKeyConfigured ? .done : .needed
        }
        if controller.setupDiagnostics.isReady { return .done }
        if controller.installingRuntime         { return .progress }
        return .needed
    }

    private var primaryRuntimeActionTitle: String {
        if controller.usingOnlineMonitoring {
            return "Configure OpenRouter"
        }
        if controller.installingRuntime {
            if controller.setupDiagnostics.runtimePresent {
                return "Downloading model…"
            }
            return "Building runtime…"
        }

        if controller.setupDiagnostics.runtimePresent {
            return "Download model"
        }
        return "Install local model"
    }
}

// MARK: - Mode chooser card

private struct ModeCard: View {
    let title: String
    let tagline: String
    let bullets: [String]
    let isSelected: Bool
    let accent: Color
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(isSelected ? accent : Color.secondary.opacity(0.6))
                    Text(title)
                        .font(.ac(13, weight: .semibold))
                        .foregroundStyle(Color.acTextPrimary)
                    Spacer(minLength: 0)
                }
                Text(tagline)
                    .font(.ac(10, weight: .medium))
                    .foregroundStyle(accent.opacity(0.85))
                ForEach(bullets, id: \.self) { bullet in
                    HStack(alignment: .top, spacing: 4) {
                        Text("•")
                            .font(.ac(10))
                            .foregroundStyle(.secondary)
                        Text(bullet)
                            .font(.ac(10))
                            .foregroundStyle(Color.acTextPrimary.opacity(0.78))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: ACRadius.sm, style: .continuous)
                    .fill(isSelected ? accent.opacity(0.10) : Color(nsColor: .controlBackgroundColor).opacity(0.6))
                    .overlay(
                        RoundedRectangle(cornerRadius: ACRadius.sm, style: .continuous)
                            .stroke(isSelected ? accent.opacity(0.55) : Color.acHairline, lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Step Row

private enum SetupStepState { case done, progress, needed }

private struct SetupStepRow: View {
    let title: String
    let state: SetupStepState
    @Environment(\.acAccent) private var accent

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: iconName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(iconColor)
                .frame(width: 20)

            Text(title)
                .font(.ac(13))
                .foregroundStyle(state == .done ? Color.acTextPrimary.opacity(0.68) : Color.acTextPrimary)

            Spacer()

            if state == .done {
                Text("Ready")
                    .font(.ac(10, weight: .medium))
                    .foregroundStyle(.green.opacity(0.85))
            }
        }
        .padding(.horizontal, 2)
        .padding(.vertical, 3)
    }

    private var iconName: String {
        switch state {
        case .done:     return "checkmark.circle.fill"
        case .progress: return "clock.arrow.circlepath"
        case .needed:   return "circle"
        }
    }

    private var iconColor: Color {
        switch state {
        case .done:     return .green
        case .progress: return accent
        case .needed:   return Color.acTextPrimary.opacity(0.55)
        }
    }
}

//
//  OnboardingDialogView.swift
//  AC
//
//  Compact setup checklist embedded in the Home tab of the popover.
//  No longer a modal overlay — just a clean inline card.
//

import SwiftUI

struct OnboardingDialogView: View {
    @EnvironmentObject private var controller: AppController

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(controller.state.setupStatus == .ready
                         ? "AccountyCat is ready ✓"
                         : "Finish setup")
                        .font(.ac(16, weight: .semibold))
                        .foregroundStyle(Color.acTextPrimary)

                    Text(subtitle)
                        .font(.ac(12))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("?") { controller.refreshSystemState() }
                    .buttonStyle(ACSecondaryButton())
                    .help("Refresh status")
            }

            // Step rows
            VStack(spacing: 6) {
                SetupStepRow(
                    title: "Screen Recording",
                    state: controller.state.permissions.screenRecording == .granted ? .done : .needed
                )
                SetupStepRow(
                    title: "Accessibility",
                    state: controller.state.permissions.accessibility == .granted ? .done : .needed
                )
                SetupStepRow(
                    title: "Build tools",
                    state: controller.setupDiagnostics.missingTools.isEmpty ? .done : .needed
                )
                SetupStepRow(
                    title: "Local runtime",
                    state: runtimeState
                )
            }

            // Error
            if let err = controller.setupErrorMessage {
                Text(err)
                    .font(.ac(11))
                    .foregroundStyle(.red)
            }

            // Action buttons
            if controller.state.setupStatus != .ready {
                actionButtons
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.7))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
                )
        )
    }

    // MARK: - Action Buttons

    private var actionButtons: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if controller.state.permissions.screenRecording != .granted {
                    Button("Screen Recording") {
                        controller.requestScreenRecordingPermission()
                    }
                    .buttonStyle(ACPrimaryButton())
                }

                if controller.state.permissions.accessibility != .granted {
                    Button("Accessibility") {
                        controller.requestAccessibilityPermission()
                    }
                    .buttonStyle(ACPrimaryButton())
                }

                if !controller.setupDiagnostics.missingTools.isEmpty {
                    Button(controller.installingDependencies
                           ? "Installing tools…"
                           : "Install tools") {
                        controller.installMissingDependencies()
                    }
                    .buttonStyle(ACPrimaryButton())
                    .disabled(controller.installingDependencies)
                } else if runtimeState != .done {
                    Button(controller.installingRuntime
                           ? "Building runtime…"
                           : "Install runtime") {
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
            return "Running locally — fully private."
        }
        return "Everything stays on-device. One-time setup."
    }

    private var runtimeState: SetupStepState {
        if controller.setupDiagnostics.isReady { return .done }
        if controller.installingRuntime         { return .progress }
        return .needed
    }
}

// MARK: - Step Row

private enum SetupStepState { case done, progress, needed }

private struct SetupStepRow: View {
    let title: String
    let state: SetupStepState

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: iconName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(iconColor)
                .frame(width: 20)

            Text(title)
                .font(.ac(13))
                .foregroundStyle(state == .done ? .secondary : Color.acTextPrimary)

            Spacer()
        }
        .padding(.horizontal, 2)
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
        case .progress: return .acCaramel
        case .needed:   return Color.secondary.opacity(0.5)
        }
    }
}

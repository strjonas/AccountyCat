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
    @Environment(\.acAccent) private var accent

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Header
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
                         : "Finish setup")
                        .font(.ac(15, weight: .semibold))
                        .foregroundStyle(Color.acTextPrimary)

                    Text(subtitle)
                        .font(.ac(12))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button(action: { controller.refreshSystemState() }) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(ACIconButton())
                .help("Refresh status")
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
                SetupStepRow(
                    title: "Build tools",
                    state: controller.setupDiagnostics.missingTools.isEmpty ? .done : .needed
                )
                SetupStepRow(
                    title: "Local runtime",
                    state: runtimeState
                )
            }
            .padding(.vertical, 2)

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

    private var permissionRequirements: MonitoringPermissionRequirements {
        LLMPolicyCatalog.permissionRequirements(for: controller.state.monitoringConfiguration)
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
    @Environment(\.acAccent) private var accent

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
        case .needed:   return Color.secondary.opacity(0.5)
        }
    }
}

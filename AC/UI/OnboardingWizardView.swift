//
//  OnboardingWizardView.swift
//  AC
//
//  First-run onboarding wizard. Guides the user through mode selection (Offline /
//  BYOK / Managed-waitlist), tier selection, permissions, and — for BYOK — API key
//  entry. Replaces the inline OnboardingDialogView for brand-new users.
//

import AppKit
import SwiftUI

// MARK: - Wizard step

private enum WizardStep: Int, CaseIterable {
    case welcome       = 0
    case modeSelection = 1
    case tierSelection = 2
    case permissions   = 3
    case apiKey        = 4  // BYOK path only
    case completion    = 5
}

// MARK: - Onboarding mode (wizard-local — maps to MonitoringInferenceBackend)

enum OnboardingMode: Equatable {
    case offline, byok, managed
}

// MARK: - OnboardingWizardView

struct OnboardingWizardView: View {
    @EnvironmentObject private var controller: AppController
    @Environment(\.acAccent) private var accent

    @State private var step: WizardStep = .welcome
    @State private var selectedMode: OnboardingMode = .offline

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            stepDots

            Group {
                switch step {
                case .welcome:       welcomeScreen
                case .modeSelection: modeScreen
                case .tierSelection: tierScreen
                case .permissions:   permissionsScreen
                case .apiKey:        apiKeyScreen
                case .completion:    completionScreen
                }
            }
            .transition(.asymmetric(
                insertion: .move(edge: .trailing).combined(with: .opacity),
                removal:   .move(edge: .leading).combined(with: .opacity)
            ))
            .animation(.acSpring, value: step)
        }
        .padding(20)
    }

    // MARK: - Step indicator

    private var stepDots: some View {
        let steps = relevantSteps
        return HStack(spacing: 6) {
            ForEach(steps, id: \.rawValue) { s in
                Circle()
                    .fill(s.rawValue <= step.rawValue ? accent : Color.acHairline.opacity(0.6))
                    .frame(width: s == step ? 8 : 6, height: s == step ? 8 : 6)
                    .animation(.acSnap, value: step)
            }
            Spacer()
            Text("You can change this later in Settings.")
                .font(.ac(10))
                .foregroundStyle(Color.acTextPrimary.opacity(0.38))
        }
    }

    private var relevantSteps: [WizardStep] {
        selectedMode == .byok
            ? [.welcome, .modeSelection, .tierSelection, .permissions, .apiKey, .completion]
            : [.welcome, .modeSelection, .tierSelection, .permissions, .completion]
    }

    // MARK: - Screen 1: Welcome

    private var welcomeScreen: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 14) {
                ZStack {
                    Circle()
                        .fill(LinearGradient(
                            colors: [controller.state.character.orbTopColor,
                                     controller.state.character.orbBottomColor],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ))
                        .overlay(Circle().stroke(Color.white.opacity(0.45), lineWidth: 1))
                        .shadow(color: controller.state.character.shadowColor.opacity(0.22), radius: 8, y: 2)
                        .frame(width: 54, height: 54)
                    Image(systemName: "pawprint.fill")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(accent.opacity(0.82))
                }

                Text("Meet your focus companion.")
                    .font(.ac(22, weight: .semibold))
                    .foregroundStyle(Color.acTextPrimary)

                Text("AccountyCat watches what you're doing and nudges you when you drift — not by blocking anything, just a quiet word from a cat in your menu bar.")
                    .font(.ac(13))
                    .foregroundStyle(Color.acTextPrimary.opacity(0.75))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button("Get started →") {
                withAnimation(.acSpring) { step = .modeSelection }
            }
            .buttonStyle(ACPrimaryButton())
        }
    }

    // MARK: - Screen 2: Mode selection

    private var modeScreen: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("How do you want to power AccountyCat?")
                .font(.ac(17, weight: .semibold))
                .foregroundStyle(Color.acTextPrimary)

            VStack(spacing: 8) {
                WizardModeCard(
                    icon: "lock.fill",
                    title: "Fully Private",
                    description: "Runs entirely on your Mac. No internet, no account, no data ever leaves your machine. Uses a local AI model via llama.cpp.",
                    isSelected: selectedMode == .offline,
                    isDisabled: false,
                    onSelect: { selectedMode = .offline }
                )

                WizardModeCard(
                    icon: "key.fill",
                    title: "Bring Your Own Key",
                    description: "Connect your OpenRouter account. You pay only for what you use — typically under $1/month. Zero Data Retention is enforced on all requests.",
                    isSelected: selectedMode == .byok,
                    isDisabled: false,
                    onSelect: { selectedMode = .byok }
                )

                WizardModeCard(
                    icon: "sparkles",
                    title: "Effortless",
                    badge: "Coming soon",
                    description: "Pay a flat monthly fee. We handle everything — no API key, no configuration. Just works.",
                    isSelected: selectedMode == .managed,
                    isDisabled: true,
                    onSelect: { selectedMode = .managed }
                )
            }

            if selectedMode == .managed {
                HStack(spacing: 8) {
                    Image(systemName: "envelope")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text("Already on the waitlist? You'll get an email when it's ready.")
                        .font(.ac(11))
                        .foregroundStyle(.secondary)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: ACRadius.sm, style: .continuous)
                        .fill(Color.acSurface)
                        .overlay(RoundedRectangle(cornerRadius: ACRadius.sm, style: .continuous).stroke(Color.acHairline, lineWidth: 1))
                )
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            HStack {
                Button("← Back") { withAnimation(.acSpring) { step = .welcome } }
                    .buttonStyle(ACSecondaryButton())
                Spacer()
                if selectedMode == .managed {
                    Button("Join waitlist →") {
                        NSWorkspace.shared.open(URL(string: "https://accountycat.com/waitlist")!)
                    }
                    .buttonStyle(ACPrimaryButton())
                } else {
                    Button("Continue →") {
                        applyModeSelection()
                        withAnimation(.acSpring) { step = .tierSelection }
                    }
                    .buttonStyle(ACPrimaryButton())
                }
            }
        }
        .animation(.acSnap, value: selectedMode)
    }

    private func applyModeSelection() {
        switch selectedMode {
        case .offline:  controller.updateMonitoringInferenceBackend(.local)
        case .byok:     controller.updateMonitoringInferenceBackend(.openRouter)
        case .managed:  break
        }
    }

    // MARK: - Screen 3: Tier selection

    private var tierScreen: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("How much intelligence do you want?")
                .font(.ac(17, weight: .semibold))
                .foregroundStyle(Color.acTextPrimary)

            WizardTierPicker(
                selectedTier: Binding(
                    get: { controller.currentAITier },
                    set: { controller.updateAITier($0) }
                ),
                mode: selectedMode
            )

            HStack {
                Button("← Back") { withAnimation(.acSpring) { step = .modeSelection } }
                    .buttonStyle(ACSecondaryButton())
                Spacer()
                Button("Continue →") { withAnimation(.acSpring) { step = .permissions } }
                    .buttonStyle(ACPrimaryButton())
            }
        }
    }

    // MARK: - Screen 4: Permissions

    private var permissionsScreen: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Two quick permissions")
                .font(.ac(17, weight: .semibold))
                .foregroundStyle(Color.acTextPrimary)

            VStack(spacing: 10) {
                WizardPermissionRow(
                    icon: "camera.viewfinder",
                    title: "Screen Recording",
                    description: "Takes a screenshot every few minutes to understand what you're working on. Analyzed and immediately discarded — nothing is stored or sent except to the AI you configured.",
                    state: controller.state.permissions.screenRecording,
                    onRequest: { controller.requestScreenRecordingPermission() }
                )

                WizardPermissionRow(
                    icon: "accessibility",
                    title: "Accessibility",
                    description: "Used only to read the name of the active app. Never logs keystrokes or input.",
                    state: controller.state.permissions.accessibility,
                    onRequest: { controller.requestAccessibilityPermission() }
                )
            }

            if controller.state.permissions.screenRecording == .denied
                || controller.state.permissions.accessibility == .denied {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.system(size: 12))
                    Text("AccountyCat can't function without these. Open System Settings → Privacy & Security to grant them.")
                        .font(.ac(11))
                        .foregroundStyle(Color.acTextPrimary.opacity(0.82))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Open") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy")!)
                    }
                    .buttonStyle(ACSecondaryButton())
                }
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: ACRadius.sm, style: .continuous)
                        .fill(Color.orange.opacity(0.08))
                        .overlay(RoundedRectangle(cornerRadius: ACRadius.sm, style: .continuous).stroke(Color.orange.opacity(0.25), lineWidth: 1))
                )
                .transition(.opacity)
            }

            HStack {
                Button("← Back") { withAnimation(.acSpring) { step = .tierSelection } }
                    .buttonStyle(ACSecondaryButton())
                Spacer()
                Button("Continue →") {
                    withAnimation(.acSpring) {
                        step = selectedMode == .byok ? .apiKey : .completion
                    }
                }
                .buttonStyle(ACPrimaryButton())
                .disabled(!permissionsGranted)
            }
        }
        .animation(.acSnap, value: permissionsGranted)
        .onAppear { controller.refreshSystemState(persist: false) }
    }

    private var permissionsGranted: Bool {
        controller.state.permissions.screenRecording == .granted
            && controller.state.permissions.accessibility == .granted
    }

    // MARK: - Screen 5: API key (BYOK only)

    private var apiKeyScreen: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Your OpenRouter key")
                .font(.ac(17, weight: .semibold))
                .foregroundStyle(Color.acTextPrimary)

            VStack(alignment: .leading, spacing: 6) {
                Text("OpenRouter provides access to models like Gemma, Llama, Gemini, and more. Creating an account and getting a key takes about 2 minutes.")
                    .font(.ac(12))
                    .foregroundStyle(Color.acTextPrimary.opacity(0.75))
                    .fixedSize(horizontal: false, vertical: true)

                Button("Get a key at openrouter.ai →") {
                    NSWorkspace.shared.open(URL(string: "https://openrouter.ai/keys")!)
                }
                .buttonStyle(.plain)
                .foregroundStyle(accent)
                .font(.ac(11, weight: .medium))
            }

            OpenRouterKeyField()
                .environmentObject(controller)

            HStack {
                Button("← Back") { withAnimation(.acSpring) { step = .permissions } }
                    .buttonStyle(ACSecondaryButton())
                Spacer()
                Button("Continue →") { withAnimation(.acSpring) { step = .completion } }
                    .buttonStyle(ACPrimaryButton())
                    .disabled(!controller.hasOnlineAPIKeyConfigured)
            }
        }
    }

    // MARK: - Screen 6: Completion

    private var completionScreen: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 14) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 32, weight: .semibold))
                    .foregroundStyle(.green)

                Text("You're all set.")
                    .font(.ac(22, weight: .semibold))
                    .foregroundStyle(Color.acTextPrimary)

                VStack(alignment: .leading, spacing: 8) {
                    completionSummaryRow(
                        icon: selectedMode == .offline ? "lock.fill" : "key.fill",
                        label: selectedMode == .offline ? "Fully Private — local AI" : "Bring Your Own Key — OpenRouter"
                    )
                    completionSummaryRow(
                        icon: "brain",
                        label: "\(controller.currentAITier.displayName) tier · \(tierDetailLabel)"
                    )
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: ACRadius.md, style: .continuous)
                        .fill(Color.acSurface)
                        .overlay(RoundedRectangle(cornerRadius: ACRadius.md, style: .continuous).stroke(Color.acHairline, lineWidth: 1))
                )

                Text("You can adjust any of this in Settings → AI.")
                    .font(.ac(11))
                    .foregroundStyle(.secondary)
            }

            if selectedMode == .offline {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .padding(.top, 1)
                    Text("Local mode requires a one-time download (~2–5 GB depending on tier). It will start in the background and you'll see progress in the Home tab.")
                        .font(.ac(11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: ACRadius.sm, style: .continuous)
                        .fill(Color.acSurface)
                        .overlay(RoundedRectangle(cornerRadius: ACRadius.sm, style: .continuous).stroke(Color.acHairline, lineWidth: 1))
                )
            }

            Button("Start focusing →") {
                controller.completeOnboardingWizard()
                if selectedMode == .offline && !controller.setupDiagnostics.isReady {
                    controller.installRuntime()
                }
            }
            .buttonStyle(ACPrimaryButton())
        }
    }

    private func completionSummaryRow(icon: String, label: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(accent)
                .frame(width: 18)
            Text(label)
                .font(.ac(12, weight: .medium))
                .foregroundStyle(Color.acTextPrimary)
        }
    }

    private var tierDetailLabel: String {
        let tier = controller.currentAITier
        switch selectedMode {
        case .offline:  return tier.localModelDisplayName
        case .byok:     return AppController.shortModelName(for: tier.byokModelIdentifier)
        case .managed:  return ""
        }
    }
}

// MARK: - Mode card

private struct WizardModeCard: View {
    let icon: String
    let title: String
    var badge: String? = nil
    let description: String
    let isSelected: Bool
    let isDisabled: Bool
    let onSelect: () -> Void
    @Environment(\.acAccent) private var accent

    var body: some View {
        Button(action: { if !isDisabled { onSelect() } }) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(isDisabled ? Color.secondary.opacity(0.35)
                                     : isSelected ? accent
                                     : Color.secondary.opacity(0.65))
                    .frame(width: 22, height: 22)
                    .background(
                        Circle().fill((isDisabled ? Color.secondary
                                       : isSelected ? accent
                                       : Color.secondary).opacity(0.10))
                    )
                    .padding(.top, 1)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(title)
                            .font(.ac(13, weight: .semibold))
                            .foregroundStyle(isDisabled ? Color.secondary.opacity(0.5) : Color.acTextPrimary)
                        if let badge {
                            Text(badge)
                                .font(.ac(9, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(
                                    Capsule(style: .continuous)
                                        .fill(Color.acSurface)
                                        .overlay(Capsule(style: .continuous).stroke(Color.acHairline, lineWidth: 1))
                                )
                        }
                    }
                    Text(description)
                        .font(.ac(11))
                        .foregroundStyle(isDisabled ? Color.secondary.opacity(0.42)
                                         : Color.acTextPrimary.opacity(0.72))
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                if !isDisabled {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(isSelected ? accent : Color.secondary.opacity(0.38))
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: ACRadius.md, style: .continuous)
                    .fill(isSelected && !isDisabled ? accent.opacity(0.08) : Color.acSurface)
                    .overlay(
                        RoundedRectangle(cornerRadius: ACRadius.md, style: .continuous)
                            .stroke(isSelected && !isDisabled ? accent.opacity(0.45) : Color.acHairline,
                                    lineWidth: isSelected && !isDisabled ? 1.5 : 1)
                    )
            )
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .animation(.acSnap, value: isSelected)
    }
}

// MARK: - Tier picker

struct WizardTierPicker: View {
    @Binding var selectedTier: AITier
    let mode: OnboardingMode
    @Environment(\.acAccent) private var accent

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 3-way segmented control
            HStack(spacing: 0) {
                ForEach(AITier.allCases, id: \.self) { tier in
                    TierSegment(tier: tier, isSelected: selectedTier == tier, accent: accent) {
                        withAnimation(.acSnap) { selectedTier = tier }
                    }
                    if tier != .smartest {
                        Divider()
                            .frame(height: 36)
                            .opacity(0.2)
                    }
                }
            }
            .background(
                RoundedRectangle(cornerRadius: ACRadius.sm, style: .continuous)
                    .fill(Color.acSurface)
                    .overlay(
                        RoundedRectangle(cornerRadius: ACRadius.sm, style: .continuous)
                            .stroke(Color.acHairline, lineWidth: 1)
                    )
            )
            .clipShape(RoundedRectangle(cornerRadius: ACRadius.sm, style: .continuous))

            // Dynamic description card
            VStack(alignment: .leading, spacing: 8) {
                Text(selectedTier.description)
                    .font(.ac(12))
                    .foregroundStyle(Color.acTextPrimary.opacity(0.80))
                    .fixedSize(horizontal: false, vertical: true)

                Divider().opacity(0.3)

                tierDetailLine
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: ACRadius.sm, style: .continuous)
                    .fill(Color.acSurface)
                    .overlay(
                        RoundedRectangle(cornerRadius: ACRadius.sm, style: .continuous)
                            .stroke(Color.acHairline, lineWidth: 1)
                    )
            )
            .animation(.acFade, value: selectedTier)
        }
    }

    @ViewBuilder
    private var tierDetailLine: some View {
        switch mode {
        case .offline:
            HStack(spacing: 5) {
                Image(systemName: "desktopcomputer")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Text("Offline: \(selectedTier.localModelDisplayName) · \(selectedTier.localRAMEstimate)")
                    .font(.ac(10))
                    .foregroundStyle(.secondary)
            }
        case .byok:
            HStack(spacing: 5) {
                Image(systemName: "key.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Text("BYOK: \(AppController.shortModelName(for: selectedTier.byokModelIdentifier)) · \(selectedTier.byokCostEstimate)")
                    .font(.ac(10))
                    .foregroundStyle(.secondary)
            }
        case .managed:
            EmptyView()
        }
    }
}

private struct TierSegment: View {
    let tier: AITier
    let isSelected: Bool
    let accent: Color
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            VStack(spacing: 3) {
                HStack(spacing: 3) {
                    Text(tier.displayName)
                        .font(.ac(12, weight: isSelected ? .semibold : .medium))
                        .foregroundStyle(isSelected ? accent : Color.acTextPrimary.opacity(0.65))
                    if tier == .balanced {
                        Text("★")
                            .font(.ac(10))
                            .foregroundStyle(isSelected ? accent.opacity(0.9) : Color.secondary.opacity(0.5))
                    }
                }
                if tier == .balanced {
                    Text("Our pick")
                        .font(.ac(9))
                        .foregroundStyle(isSelected ? accent.opacity(0.8) : Color.secondary.opacity(0.5))
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: ACRadius.xs, style: .continuous)
                    .fill(isSelected ? accent.opacity(0.12) : Color.clear)
                    .padding(3)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Permission row

private struct WizardPermissionRow: View {
    let icon: String
    let title: String
    let description: String
    let state: PermissionState
    let onRequest: () -> Void
    @Environment(\.acAccent) private var accent

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: state == .granted ? "checkmark.circle.fill" : icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(state == .granted ? .green : accent)
                .frame(width: 22, height: 22)
                .background(
                    Circle().fill((state == .granted ? Color.green : accent).opacity(0.12))
                )
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.ac(13, weight: .semibold))
                        .foregroundStyle(Color.acTextPrimary)
                    if state == .granted {
                        Text("Granted")
                            .font(.ac(10, weight: .medium))
                            .foregroundStyle(.green.opacity(0.85))
                    }
                }
                Text(description)
                    .font(.ac(11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if state != .granted {
                    Button("Grant \(title)") { onRequest() }
                        .buttonStyle(ACSecondaryButton())
                        .padding(.top, 2)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: ACRadius.md, style: .continuous)
                .fill(state == .granted ? Color.green.opacity(0.06) : Color.acSurface)
                .overlay(
                    RoundedRectangle(cornerRadius: ACRadius.md, style: .continuous)
                        .stroke(state == .granted ? Color.green.opacity(0.22) : Color.acHairline,
                                lineWidth: 1)
                )
        )
        .animation(.acSnap, value: state)
    }
}

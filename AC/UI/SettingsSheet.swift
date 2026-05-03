//
//  SettingsSheet.swift
//  AC
//
//  Settings sheet shown from the gear icon in the chat popover header.
//  Replaces the former Settings tab — a modal sheet keeps settings out of
//  the way while making them easily accessible.
//

import SwiftUI

struct SettingsSheet: View {
    @EnvironmentObject private var controller: AppController
    @Environment(\.acAccent) private var accent
    @Environment(\.dismiss) private var dismiss

    @State private var expandedSections: Set<String> = ["controls"]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    characterPicker

                    Divider().opacity(0.3)

                    aiSection

                    collapsibleSection(id: "visionGate", icon: "eye", title: "Vision Gate") {
                        VisionGateSettingsCard(
                            threshold: Binding(
                                get: { controller.state.monitoringConfiguration.titleLengthForTextOnly },
                                set: { controller.updateTitleLengthForTextOnly($0) }
                            )
                        )
                    }

                    collapsibleSection(id: "calendar", icon: "calendar", title: "Calendar Intelligence") {
                        CalendarIntelligenceSection()
                            .environmentObject(controller)
                    }

                    collapsibleSection(id: "rescue", icon: "arrow.uturn.backward.circle", title: "Rescue App") {
                        rescueAppContent
                    }

                    collapsibleSection(id: "models", icon: "externaldrive", title: "Local Model Storage") {
                        ContentView.LocalModelStorageSection(onDelete: {
                            pendingSettingsAction = .deleteLocalModels
                        })
                        .environmentObject(controller)
                    }

                    collapsibleSection(id: "about", icon: "info.circle", title: "About") {
                        AboutSection()
                    }

                    Divider().opacity(0.3)

                    dangerZone
                }
                .padding(20)
            }
        }
        .frame(width: ACD.popoverWidth)
        .background(Color(nsColor: .windowBackgroundColor))
        .alert(
            "Are you sure?",
            isPresented: Binding(
                get: { pendingSettingsAction != nil },
                set: { isPresented in if !isPresented { pendingSettingsAction = nil } }
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
            case .resetAlgorithm: Text("This clears learned memory, recent behavior context, chat history, and usage context.")
            case .deleteLocalModels: Text("This removes the selected AC-downloaded local model from Application Support. The runtime stays installed.")
            case .none: Text("")
            }
        }
        .alert(
            "Done",
            isPresented: Binding(
                get: { settingsSuccessMessage != nil },
                set: { isPresented in if !isPresented { settingsSuccessMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) { settingsSuccessMessage = nil }
        } message: {
            Text(settingsSuccessMessage ?? "")
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Text("Settings")
                .font(.acTitle)
                .foregroundStyle(Color.acTextPrimary)
            Spacer()
            Button {
                dismiss()
            } label: {
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
        .background(
            LinearGradient(
                colors: [controller.state.character.headerLightTop, controller.state.character.headerLightBottom],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
    }

    // MARK: - Character picker

    private var characterPicker: some View {
        CharacterPickerSection(
            selected: controller.state.character,
            onSelect: { controller.updateCharacter($0) }
        )
    }

    // MARK: - AI section (always visible)

    private var aiSection: some View {
        VStack(alignment: .leading, spacing: 14) {
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

            SettingsModeRow(
                current: controller.state.monitoringConfiguration.inferenceBackend,
                onChange: { controller.updateMonitoringInferenceBackend($0) }
            )

            if controller.usingOnlineMonitoring {
                OpenRouterKeyField(compact: true)
                    .environmentObject(controller)
                    .padding(.leading, 26)
            }

            WizardTierPicker(
                selectedTier: Binding(
                    get: { controller.currentAITier },
                    set: { controller.updateAITier($0) }
                ),
                mode: controller.usingOnlineMonitoring ? .byok : .offline
            )
            .onAppear {
                controller.refreshSystemState(persist: false)
            }

            if showLocalModelProgress {
                localModelProgress
                    .padding(.leading, 26)
            }
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
                if let percentText { Text(percentText) }
            }
            .font(.ac(10))
            .foregroundStyle(Color.acTextPrimary.opacity(0.72))
        }
        .padding(.top, 2)
    }

    // MARK: - Controls (always-visible section content)

    // MARK: - Rescue app

    private var rescueAppContent: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(controller.state.rescueApp.displayName)
                    .font(.ac(13, weight: .medium))
                    .foregroundStyle(Color.acTextPrimary)
                Text(controller.state.rescueApp.applicationPath ?? controller.state.rescueApp.bundleIdentifier)
                    .font(.acMono)
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
                .overlay(RoundedRectangle(cornerRadius: ACRadius.md, style: .continuous).stroke(Color.acHairline, lineWidth: 1))
        )
    }

    // MARK: - Danger zone

    @State private var pendingSettingsAction: SettingsAlertAction?
    @State private var settingsSuccessMessage: String?

    private var dangerZone: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsSection(title: "Reset monitoring profile", icon: "arrow.counterclockwise",
                subtitle: "Clears learned memory, recent behavior context, chat history, and usage context.") {
                Button("Reset") { pendingSettingsAction = .resetAlgorithm }
                    .buttonStyle(ACDangerButton())
            }

            HStack {
                Spacer()
                Button("Quit AccountyCat") {
                    dismiss()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        NSApp.terminate(nil)
                    }
                }
                .font(.ac(12, weight: .medium))
                .foregroundStyle(Color.red.opacity(0.78))
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Collapsible section

    private func collapsibleSection<Content: View>(
        id: String, icon: String, title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.acSnap) {
                    if expandedSections.contains(id) {
                        expandedSections.remove(id)
                    } else {
                        expandedSections.insert(id)
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: icon)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(accent)
                        .frame(width: 18, height: 18)
                        .background(Circle().fill(accent.opacity(0.13)))
                    Text(title)
                        .font(.ac(13, weight: .semibold))
                        .foregroundStyle(Color.acTextPrimary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary.opacity(0.6))
                        .rotationEffect(.degrees(expandedSections.contains(id) ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expandedSections.contains(id) {
                content()
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}

private enum SettingsAlertAction: String, Identifiable {
    case resetAlgorithm
    case deleteLocalModels
    var id: String { rawValue }
}
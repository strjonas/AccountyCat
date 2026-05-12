//
//  ControlsTab.swift
//  AC
//
//  Display mode, intervention toggles, sound toggles, read-only shortcuts list.
//

import SwiftUI

struct ControlsTab: View {
    @EnvironmentObject private var controller: AppController
    @Environment(\.acAccent) private var accent

    @State private var escalationOverlayOn = true
    @State private var nudgeChimeOn = true
    @State private var celebrationSoundOn = true

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            // Display picker
            pickerRow(label: "show AC in", selection: displayModeBinding, options: ACDisplayMode.allCases) { $0.displayName }

            Divider().opacity(0.3)

            sectionLabel("when AC intervenes")
            ToggleRow(label: "escalation overlay", hint: "visual-novel screen if nudge is ignored ~3 min", isOn: $escalationOverlayOn)
            ToggleRow(
                label: "auto-quiet on calls",
                hint: "zoom, facetime, meet, teams",
                isOn: Binding(
                    get: { controller.state.autoQuietOnCalls },
                    set: { controller.updateAutoQuietOnCalls($0) }
                )
            )

            Divider().opacity(0.3)

            sectionLabel("sounds")
            ToggleRow(label: "nudge chime", hint: "gentle once", isOn: $nudgeChimeOn)
            ToggleRow(label: "celebration", hint: "streak milestones, completed profiles", isOn: $celebrationSoundOn)
        }
    }

    // MARK: - Bindings

    private var displayModeBinding: Binding<ACDisplayMode> {
        Binding(
            get: { controller.state.displayMode },
            set: { controller.updateDisplayMode($0) }
        )
    }

    // MARK: - Compact picker row

    private func pickerRow<T: Hashable & CaseIterable>(
        label: String,
        selection: Binding<T>,
        options: [T],
        title: @escaping (T) -> String
    ) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .tracking(0.06)
                .foregroundStyle(Color.acTextPrimary.opacity(0.45))
                .textCase(.uppercase)
                .fixedSize()
            HStack(spacing: 4) {
                ForEach(Array(options), id: \.self) { option in
                    let isSelected = selection.wrappedValue == option
                    Button {
                        selection.wrappedValue = option
                    } label: {
                        Text(title(option))
                            .font(.ac(11, weight: isSelected ? .semibold : .medium))
                            .foregroundStyle(isSelected ? Color.white : Color.acTextPrimary.opacity(0.7))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(isSelected ? accent : Color.acSurfaceInset)
                                    .overlay(
                                        Capsule(style: .continuous)
                                            .stroke(isSelected ? accent.opacity(0.5) : Color.acHairline, lineWidth: 0.5)
                                    )
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .tracking(0.06)
            .foregroundStyle(Color.acTextPrimary.opacity(0.45))
            .textCase(.uppercase)
    }
}

// MARK: - Toggle row

struct ToggleRow: View {
    let label: String
    let hint: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.ac(12, weight: .medium))
                    .foregroundStyle(Color.acTextPrimary)
                Text(hint)
                    .font(.acCaption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("", isOn: $isOn)
                .toggleStyle(.switch)
                .controlSize(.small)
        }
    }
}

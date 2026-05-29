//
//  ControlsTab.swift
//  AC
//
//  Display mode, intervention toggles, sound toggles, read-only shortcuts list.
//

import SwiftUI

struct ControlsTab: View {
    @EnvironmentObject private var controller: AppController

    @State private var escalationOverlayOn = true
    @State private var nudgeChimeOn = true
    @State private var celebrationSoundOn = true

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            // Display mode (orb / menu bar / both) now lives in the Look tab,
            // alongside the character picker.
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

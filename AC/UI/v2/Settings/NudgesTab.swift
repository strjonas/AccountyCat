//
//  NudgesTab.swift
//  AC
//
//  Intervention toggles, sound toggles, read-only shortcuts list.
//

import SwiftUI

struct NudgesTab: View {
    @EnvironmentObject private var controller: AppController
    @Environment(\.acAccent) private var accent

    // TODO: wire these to persisted settings when nudge/sound toggles are implemented
    @State private var firstNudgeOn = true
    @State private var escalationOverlayOn = true
    @State private var autoQuietOnCalls = true
    @State private var nudgeChimeOn = true
    @State private var celebrationSoundOn = true

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            sectionLabel("when AC intervenes")
            ToggleRow(label: "first nudge", hint: "inline chat message + tooltip near cat", isOn: $firstNudgeOn)
            ToggleRow(label: "escalation overlay", hint: "visual-novel screen if nudge is ignored ~3 min", isOn: $escalationOverlayOn)
            ToggleRow(label: "auto-quiet on calls", hint: "zoom, facetime, meet, teams", isOn: $autoQuietOnCalls)

            Divider().opacity(0.3)

            sectionLabel("sounds")
            ToggleRow(label: "nudge chime", hint: "gentle once", isOn: $nudgeChimeOn)
            ToggleRow(label: "celebration", hint: "streak milestones, completed profiles", isOn: $celebrationSoundOn)

            Divider().opacity(0.3)

            sectionLabel("keyboard shortcuts")
            shortcutRow(label: "open / close panel", keys: ["⌘", "⌥", "C"])
            shortcutRow(label: "toggle vision", keys: ["⌘", "⌥", "V"])
            shortcutRow(label: "start / switch focus", keys: ["⌘", "⌥", "F"])
            shortcutRow(label: "extend +15 min", keys: ["⌘", "⌥", "↑"])
            shortcutRow(label: "pause / resume watching", keys: ["⌘", "⌥", "P"])

            Button {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.keyboard?Shortcuts")!)
            } label: {
                Text("customize in shortcuts.app →")
                    .font(.ac(11, weight: .medium))
                    .foregroundStyle(accent.opacity(0.85))
            }
            .buttonStyle(.plain)
            .padding(.top, 4)
        }
    }

    private func shortcutRow(label: String, keys: [String]) -> some View {
        HStack {
            Text(label)
                .font(.ac(12))
                .foregroundStyle(Color.acTextPrimary.opacity(0.8))
            Spacer()
            HStack(spacing: 3) {
                ForEach(keys, id: \.self) { key in
                    Text(key)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color.acTextPrimary.opacity(0.7))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(Color.acSurfaceInset)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                                        .stroke(Color.acHairline, lineWidth: 1)
                                )
                        )
                }
            }
        }
        .padding(.vertical, 3)
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.ac(11, weight: .semibold))
            .foregroundStyle(Color.acTextPrimary.opacity(0.7))
            .textCase(.lowercase)
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

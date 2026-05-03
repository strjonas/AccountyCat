//
//  ContextBar.swift
//  AC
//
//  Collapsible bottom bar in the chat popover.  Shows a one-line summary
//  when collapsed; expands to reveal goals, rules summary, memory summary,
//  and the core toggles (watching/paused, sound, vision).
//

import SwiftUI

struct ContextBar: View {
    @EnvironmentObject private var controller: AppController
    @Environment(\.acAccent) private var accent
    @AppStorage("acContextBarExpanded") private var isExpanded = false

    private var activeProfile: FocusProfile { controller.state.activeProfile }
    private var rulesCount: Int {
        controller.state.policyMemory.rules
            .filter { !$0.isAutoSafelistRule && ($0.profileID == nil || $0.profileID == controller.state.activeProfileID) }
            .count
    }
    private var memoryCount: Int { controller.state.memoryEntries.count }
    private var lockedCount: Int {
        controller.state.policyMemory.rules
            .filter { !$0.isAutoSafelistRule && $0.isLocked && ($0.profileID == nil || $0.profileID == controller.state.activeProfileID) }
            .count
    }

    var body: some View {
        VStack(spacing: 0) {
            Divider().opacity(0.4)

            Button {
                withAnimation(.acSnap) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(accent)
                    Text(contextSummary)
                        .font(.acCaption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                expandedContent
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .move(edge: .bottom)),
                        removal: .opacity.combined(with: .move(edge: .bottom))
                    ))
            }
        }
        .background(
            Color(nsColor: .windowBackgroundColor)
                .contentShape(Rectangle())
                .onTapGesture {
                    NotificationCenter.default.post(name: .acUnfocusChatInput, object: nil)
                }
        )
    }

    private var contextSummary: String {
        let profile = activeProfile.isDefault ? "General" : activeProfile.name
        var parts = [profile]
        if rulesCount > 0 {
            parts.append("\(rulesCount) rule\(rulesCount == 1 ? "" : "s")")
        }
        if memoryCount > 0 {
            parts.append("\(memoryCount) memor\(memoryCount == 1 ? "y" : "ies")")
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            goalsSection
            rulesSummary
            memorySummary
            quickToggles
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    // MARK: - Goals

    @State private var localGoalsText: String = ""
    @State private var goalsTextDirty = false
    @FocusState private var goalsEditorFocused: Bool

    private var goalsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Goals")
                .font(.acCaptionStrong)
                .foregroundStyle(.secondary)

            TextField("What are you working toward?", text: $localGoalsText, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .font(.acBody)
                .lineLimit(2...4)
                .focused($goalsEditorFocused)
                .onChange(of: controller.state.goalsText) { _, newValue in
                    if !goalsEditorFocused {
                        localGoalsText = newValue
                        goalsTextDirty = false
                    }
                }
                .onChange(of: localGoalsText) { _, newValue in
                    goalsTextDirty = newValue != controller.state.goalsText
                }
                .onAppear {
                    localGoalsText = controller.state.goalsText
                }

            if goalsTextDirty {
                HStack {
                    Spacer()
                    Button("Save goals") {
                        controller.updateGoals(localGoalsText)
                        goalsTextDirty = false
                        goalsEditorFocused = false
                    }
                    .buttonStyle(ACPrimaryButton())
                    .transition(.opacity.combined(with: .scale(scale: 0.95, anchor: .trailing)))
                }
            }
        }
        .animation(.acSnap, value: goalsTextDirty)
    }

    // MARK: - Rules summary

    private var rulesSummary: some View {
        HStack(spacing: 8) {
            Image(systemName: "checklist")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(accent)
                .frame(width: 18, height: 18)
                .background(Circle().fill(accent.opacity(0.12)))

            VStack(alignment: .leading, spacing: 1) {
                Text(rulesCount == 0 ? "No rules yet" : "\(rulesCount) rule\(rulesCount == 1 ? "" : "s")\(lockedCount > 0 ? " · \(lockedCount) locked" : "")")
                    .font(.acCaptionStrong)
                    .foregroundStyle(Color.acTextPrimary)
            }

            Spacer()

            Button("View all rules") {
                controller.showRulesSheetFromContextBar = true
            }
            .buttonStyle(ACSecondaryButton())
        }
    }

    // MARK: - Memory summary

    private var memorySummary: some View {
        HStack(spacing: 8) {
            Image(systemName: "brain.head.profile")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(accent)
                .frame(width: 18, height: 18)
                .background(Circle().fill(accent.opacity(0.12)))

            Text(memoryCount == 0 ? "No memories yet" : "\(memoryCount) memor\(memoryCount == 1 ? "y" : "ies")")
                .font(.acCaptionStrong)
                .foregroundStyle(Color.acTextPrimary)

            Spacer()

            if controller.canConsolidateMemory {
                Button("Clean up") {
                    controller.consolidateMemoryNow()
                }
                .buttonStyle(ACSecondaryButton())
                .disabled(controller.consolidatingMemory)
            }
        }
    }

    // MARK: - Quick toggles

    @AppStorage("acSoundEnabled") private var soundEnabled: Bool = false

    private var quickToggles: some View {
        HStack(spacing: 10) {
            QuickTogglePill(
                icon: controller.state.isPaused ? "play.circle.fill" : "pause.circle.fill",
                label: controller.state.isPaused ? "Resume" : "Pause",
                shortcut: "P",
                isOn: !controller.state.isPaused,
                tint: accent
            ) {
                controller.togglePause()
            }
            .keyboardShortcut("p", modifiers: .command)

            QuickTogglePill(
                icon: soundEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill",
                label: "Sound",
                shortcut: "M",
                isOn: soundEnabled,
                tint: accent
            ) { soundEnabled.toggle() }
            .keyboardShortcut("m", modifiers: .command)

            QuickTogglePill(
                icon: controller.visionEnabled ? "eye.fill" : "eye.slash.fill",
                label: "Vision",
                shortcut: "V",
                isOn: controller.visionEnabled,
                tint: accent
            ) {
                controller.updateVisionEnabled(!controller.visionEnabled)
            }
            .keyboardShortcut("v", modifiers: .command)
        }
    }
}

// MARK: - Quick Toggle Pill

private struct QuickTogglePill: View {
    let icon: String
    let label: String
    var shortcut: String? = nil
    let isOn: Bool
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(isOn ? tint : Color.secondary.opacity(0.65))
                Text(label)
                    .font(.acCaptionStrong)
                    .foregroundStyle(isOn ? Color.acTextPrimary.opacity(0.9) : Color.secondary.opacity(0.7))

                if let shortcut {
                    Text("⌘\(shortcut)")
                        .font(.system(size: 9, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.secondary.opacity(0.45))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule(style: .continuous)
                    .fill(isOn ? tint.opacity(0.12) : Color.acSurface)
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(isOn ? tint.opacity(0.35) : Color.acHairline, lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
        .animation(.acSnap, value: isOn)
    }
}
//
//  ProfilesTab.swift
//  AC
//
//  Profile chip row + editor with unified rules list.
//

import SwiftUI

struct ProfilesTab: View {
    @EnvironmentObject private var controller: AppController
    @Environment(\.acAccent) private var accent

    @State private var editingProfileID: String?
    @State private var nameDraft = ""
    @State private var descriptionDraft = ""
    @State private var emojiDraft = ""
    @State private var colorDraft = ""
    @State private var defaultDurationDraft: Int?
    @State private var showingDeleteConfirm = false
    @State private var newRuleKind: PolicyRuleKind = .allow
    @State private var newRuleItem = ""

    private var sortedProfiles: [FocusProfile] {
        var list = controller.state.profiles
        // Everyday (default) first
        list.sort { lhs, rhs in
            if lhs.isDefault != rhs.isDefault { return lhs.isDefault }
            return lhs.lastUsedAt > rhs.lastUsedAt
        }
        return list
    }

    private var resolvedEditingID: String {
        let candidate = editingProfileID ?? controller.state.activeProfileID
        if controller.state.profiles.contains(where: { $0.id == candidate }) {
            return candidate
        }
        return PolicyRule.defaultProfileID
    }

    private var editingProfile: FocusProfile {
        controller.state.profile(withID: resolvedEditingID) ?? FocusProfile.makeDefault()
    }

    private var canAddProfile: Bool {
        controller.state.profiles.filter { !$0.isDefault }.count < FocusProfile.maximumProfileCount - 1
    }

    private var allDisplayRules: [PolicyRule] {
        let profileID = resolvedEditingID
        var seen = Set<String>()

        // Active policy rules scoped to this profile (or global)
        let rules = controller.state.policyMemory.rules
            .filter { $0.isActive(at: Date()) && ($0.profileID == nil || $0.profileID == profileID) }
            .sorted { $0.priority != $1.priority ? $0.priority > $1.priority : $0.updatedAt > $1.updatedAt }
            .filter { seen.insert($0.id).inserted }

        // Inactive policy rules (expired, revoked) for visibility
        let inactive = controller.state.policyMemory.rules
            .filter { !$0.isActive(at: Date()) && ($0.profileID == nil || $0.profileID == profileID) }
            .sorted { $0.updatedAt > $1.updatedAt }
            .filter { seen.insert($0.id).inserted }

        return rules + inactive
    }

    private var runningAppNames: [String] {
        var seen = Set<String>()
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { $0.localizedName }
            .filter { seen.insert($0.lowercased()).inserted }
            .sorted()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            sectionLabel("your profiles")
            Text("everyday is the default — no mode required. use named profiles for focused sessions.")
                .font(.acCaption)
                .foregroundStyle(.secondary)
                .padding(.top, -12)

            profileChipRow

            Divider().opacity(0.3)

            profileEditor
        }
        .onAppear { syncDrafts() }
        .onChange(of: resolvedEditingID) { _, _ in syncDrafts() }
    }

    // MARK: - Profile chip row

    private var profileChipRow: some View {
        ACFlowLayout(spacing: 8) {
            ForEach(sortedProfiles) { profile in
                let isEditing = profile.id == resolvedEditingID
                let isActive = profile.id == controller.state.activeProfileID
                let draftTrimmed = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                let displayName = isEditing && !draftTrimmed.isEmpty ? draftTrimmed : profile.name
                Button {
                    withAnimation(.acSnap) { editingProfileID = profile.id }
                } label: {
                    HStack(spacing: 5) {
                        Text(profile.emoji)
                            .font(.ac(13))
                        Text(displayName)
                            .font(.ac(11, weight: isEditing ? .semibold : .medium))
                        if isActive {
                            Text("active")
                                .font(.ac(9, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Capsule(style: .continuous).fill(accent))
                        }
                    }
                    .foregroundStyle(isEditing ? colorFromHex(profile.color) : Color.acTextPrimary.opacity(0.8))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        Capsule(style: .continuous)
                            .fill(isEditing ? colorFromHex(profile.color).opacity(0.10) : Color.acSurface)
                            .overlay(
                                Capsule(style: .continuous)
                                    .stroke(isEditing ? colorFromHex(profile.color).opacity(0.45) : Color.acHairline, lineWidth: 1)
                            )
                    )
                }
                .buttonStyle(.plain)
            }

            if canAddProfile {
                Button {
                    createNewProfile()
                } label: {
                    HStack(spacing: 4) {
                        Text("+")
                            .font(.ac(13, weight: .semibold))
                        Text("new")
                            .font(.ac(11, weight: .medium))
                    }
                    .foregroundStyle(Color.acTextPrimary.opacity(0.55))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Color.acSurface)
                            .overlay(Capsule(style: .continuous).stroke(Color.acHairline, lineWidth: 1))
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Profile editor

    private var profileEditor: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Text(editingProfile.emoji)
                    .font(.ac(20))
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(colorFromHex(editingProfile.color).opacity(0.15)))

                if editingProfile.isDefault {
                    Text(editingProfile.name)
                        .font(.ac(14, weight: .semibold))
                        .foregroundStyle(Color.acTextPrimary)
                } else {
                    TextField("Profile name", text: $nameDraft)
                        .textFieldStyle(.plain)
                        .font(.ac(14, weight: .semibold))
                        .foregroundStyle(Color.acTextPrimary)
                        .onSubmit { saveProfile() }
                }

                Spacer()

                if !editingProfile.isDefault {
                    Button {
                        showingDeleteConfirm = true
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Color.secondary.opacity(0.6))
                            .frame(width: 22, height: 22)
                            .background(Circle().fill(Color.acSurface).overlay(Circle().stroke(Color.acHairline, lineWidth: 1)))
                    }
                    .buttonStyle(.plain)
                    .disabled(!controller.canDeleteProfile(id: editingProfile.id))
                    .help("Delete profile")
                    .alert("Delete profile?", isPresented: $showingDeleteConfirm) {
                        Button("Delete", role: .destructive) {
                            controller.deleteProfile(id: editingProfile.id)
                            editingProfileID = nil
                        }
                        Button("Cancel", role: .cancel) { }
                    } message: {
                        Text("This will remove the profile and any rules scoped to it.")
                    }
                }
            }

            if editingProfile.isDefault {
                Text("everyday baseline — no specific focus. AC watches passively and only nudges for things you've asked it to help with.")
                    .font(.acCaption)
                    .foregroundStyle(.secondary)
                    .italic()
            } else {
                TextField("What belongs in this profile?", text: $descriptionDraft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.ac(12))
                    .lineLimit(1...3)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: ACRadius.sm, style: .continuous)
                            .fill(Color.acSurface)
                            .overlay(
                                RoundedRectangle(cornerRadius: ACRadius.sm, style: .continuous)
                                    .stroke(Color.acHairline, lineWidth: 1)
                            )
                    )

                // Color picker (simple hex presets)
                colorPicker

                // Default duration
                durationPicker
            }

            // Unified rules
            rulesSection

            if !editingProfile.isDefault && draftsChanged {
                HStack {
                    Spacer()
                    Button("Save profile") { saveProfile() }
                        .buttonStyle(ACPrimaryButton())
                }
                .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .trailing)))
            }
        }
        .animation(.acSnap, value: draftsChanged)
    }

    private var colorPicker: some View {
        let presets = [
            "#7BA3D9", "#A88BFF", "#E89B7A",
            "#A8B58E", "#D9A8C7", "#9aa1a8",
            "#D9B87A", "#7AD9C4"
        ]
        return HStack(spacing: 8) {
            ForEach(presets, id: \.self) { hex in
                Button {
                    colorDraft = hex
                } label: {
                    Circle()
                        .fill(colorFromHex(hex))
                        .frame(width: 22, height: 22)
                        .overlay(
                            Circle()
                                .stroke(colorDraft == hex ? Color.acTextPrimary.opacity(0.6) : Color.clear, lineWidth: 2)
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var durationPicker: some View {
        let options = [25, 45, 60, 90, 120]
        return VStack(alignment: .leading, spacing: 6) {
            Text("default duration")
                .font(.ac(11, weight: .semibold))
                .foregroundStyle(Color.acTextPrimary.opacity(0.7))
            HStack(spacing: 6) {
                ForEach(options, id: \.self) { min in
                    Button {
                        defaultDurationDraft = min
                    } label: {
                        Text(min < 60 ? "\(min)m" : min == 60 ? "1h" : "\(min / 60)h")
                            .font(.ac(11, weight: defaultDurationDraft == min ? .semibold : .medium))
                            .foregroundStyle(defaultDurationDraft == min ? .white : Color.acTextPrimary.opacity(0.75))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(defaultDurationDraft == min ? accent.opacity(0.85) : Color.acSurface)
                                    .overlay(
                                        Capsule(style: .continuous)
                                            .stroke(defaultDurationDraft == min ? Color.clear : Color.acHairline, lineWidth: 1)
                                    )
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Rules

    private var rulesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("rules · \"\(editingProfile.name)\"")
                    .font(.ac(11, weight: .semibold))
                    .foregroundStyle(Color.acTextPrimary.opacity(0.7))
                Spacer()
                Text("AC manages these automatically")
                    .font(.ac(9))
                    .foregroundStyle(Color.acTextPrimary.opacity(0.35))
            }

            if allDisplayRules.isEmpty {
                Text("No rules yet. AC will create them as it learns your patterns.")
                    .font(.acCaption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 4) {
                    ForEach(allDisplayRules) { rule in
                        ruleRow(rule)
                    }
                }
            }

            addRuleRow
        }
    }

    private func ruleRow(_ rule: PolicyRule) -> some View {
        let isActive = rule.isActive(at: Date())
        return HStack(spacing: 8) {
            // Kind badge
            Text(ruleKindLabel(rule.kind))
                .font(.ac(9, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(Capsule(style: .continuous).fill(ruleKindColor(rule.kind).opacity(isActive ? 0.85 : 0.4)))

            // Summary
            Text(rule.summary)
                .font(.ac(11))
                .foregroundStyle(Color.acTextPrimary.opacity(isActive ? 0.8 : 0.4))
                .lineLimit(1)

            if rule.isAutoSafelistRule {
                Text("auto")
                    .font(.ac(8, weight: .medium))
                    .foregroundStyle(Color.acTextPrimary.opacity(0.3))
            }

            Spacer()

            // Lock
            Button {
                controller.toggleRuleLocked(id: rule.id)
            } label: {
                Image(systemName: rule.isLocked ? "lock.fill" : "lock.open")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(rule.isLocked ? accent : Color.secondary.opacity(0.35))
                    .frame(width: 22, height: 22)
                    .background(
                        Circle()
                            .fill(rule.isLocked ? accent.opacity(0.10) : Color.acSurface)
                            .overlay(Circle().stroke(rule.isLocked ? accent.opacity(0.22) : Color.acHairline, lineWidth: 1))
                    )
            }
            .buttonStyle(.plain)
            .help(rule.isLocked ? "Unlock — allow AC to modify" : "Lock — prevent AC from changing")

            // Delete
            Button {
                controller.deleteRule(id: rule.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Color.secondary.opacity(0.4))
                    .frame(width: 22, height: 22)
                    .background(
                        Circle()
                            .fill(Color.acSurface)
                            .overlay(Circle().stroke(Color.acHairline, lineWidth: 1))
                    )
            }
            .buttonStyle(.plain)
            .disabled(rule.isLocked)
            .help("Delete this rule")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: ACRadius.sm, style: .continuous)
                .fill(rule.isLocked ? accent.opacity(0.04) : Color.acSurface)
                .overlay(
                    RoundedRectangle(cornerRadius: ACRadius.sm, style: .continuous)
                        .stroke(rule.isLocked ? accent.opacity(0.15) : Color.acHairline, lineWidth: 1)
                )
        )
    }

    private var addRuleRow: some View {
        HStack(spacing: 6) {
            // Kind selector (compact pills)
            HStack(spacing: 3) {
                ForEach([PolicyRuleKind.allow, .disallow, .discourage], id: \.self) { kind in
                    Button {
                        newRuleKind = kind
                    } label: {
                        Text(ruleKindLabel(kind))
                            .font(.ac(9, weight: newRuleKind == kind ? .semibold : .medium))
                            .foregroundStyle(newRuleKind == kind ? .white : Color.acTextPrimary.opacity(0.6))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(newRuleKind == kind ? ruleKindColor(kind).opacity(0.8) : Color.acSurface)
                                    .overlay(
                                        Capsule(style: .continuous)
                                            .stroke(newRuleKind == kind ? Color.clear : Color.acHairline, lineWidth: 0.5)
                                    )
                            )
                    }
                    .buttonStyle(.plain)
                }
            }

            // App picker
            Menu {
                ForEach(runningAppNames, id: \.self) { app in
                    Button(app) { addRule(app) }
                }
                if !runningAppNames.isEmpty { Divider() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "plus")
                        .font(.system(size: 9, weight: .semibold))
                    Text("app")
                        .font(.ac(10, weight: .medium))
                }
                .foregroundStyle(accent.opacity(0.8))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    Capsule(style: .continuous)
                        .fill(Color.acSurface)
                        .overlay(Capsule(style: .continuous).stroke(Color.acHairline, lineWidth: 0.5))
                )
            }
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .disabled(runningAppNames.isEmpty)

            // Text input
            TextField("app or tab name", text: $newRuleItem)
                .textFieldStyle(.plain)
                .font(.ac(10))
                .frame(width: 110)
                .onSubmit { submitRule() }

            Button { submitRule() } label: {
                Text("add")
                    .font(.ac(10, weight: .medium))
                    .foregroundStyle(accent)
            }
            .buttonStyle(.plain)
            .disabled(newRuleItem.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    // MARK: - Rule helpers

    private func ruleKindLabel(_ kind: PolicyRuleKind) -> String {
        switch kind {
        case .allow:          return "Allow"
        case .disallow:       return "Block"
        case .discourage:     return "Limit"
        case .limit:          return "Cap"
        case .tonePreference: return "Tone"
        }
    }

    private func ruleKindColor(_ kind: PolicyRuleKind) -> Color {
        switch kind {
        case .allow:          return .green
        case .disallow:       return .red
        case .discourage:     return .orange
        case .limit:          return .blue
        case .tonePreference: return .purple
        }
    }

    private func addRule(_ appName: String) {
        let trimmed = appName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let exists = controller.state.policyMemory.rules.contains {
            $0.kind == newRuleKind && $0.summary.localizedCaseInsensitiveContains(trimmed)
                && ($0.profileID == nil || $0.profileID == resolvedEditingID)
        }
        guard !exists else { return }
        controller.addUserRule(trimmed, kind: newRuleKind, appName: trimmed, profileID: resolvedEditingID)
    }

    private func submitRule() {
        let trimmed = newRuleItem.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        addRule(trimmed)
        newRuleItem = ""
    }

    // MARK: - Drafts

    private var draftsChanged: Bool {
        nameDraft.trimmingCharacters(in: .whitespacesAndNewlines) != editingProfile.name ||
            descriptionDraft.trimmingCharacters(in: .whitespacesAndNewlines) != (editingProfile.description ?? "") ||
            emojiDraft != editingProfile.emoji ||
            colorDraft != editingProfile.color ||
            defaultDurationDraft != editingProfile.defaultDurationMin
    }

    private func syncDrafts() {
        nameDraft = editingProfile.name
        descriptionDraft = editingProfile.description ?? ""
        emojiDraft = editingProfile.emoji
        colorDraft = editingProfile.color
        defaultDurationDraft = editingProfile.defaultDurationMin
    }

    private func saveProfile() {
        controller.updateProfile(
            id: editingProfile.id,
            name: nameDraft,
            description: descriptionDraft,
            emoji: emojiDraft,
            color: colorDraft,
            blocklist: editingProfile.blocklist,
            defaultDurationMin: defaultDurationDraft
        )
    }

    private func createNewProfile() {
        let colors = ["#7BA3D9", "#A88BFF", "#E89B7A", "#A8B58E", "#D9A8C7", "#D9B87A", "#7AD9C4"]
        let emojis = ["✎", "⌘", "◐", "✉", "◭", "◎", "◈"]
        let count = controller.state.profiles.filter { !$0.isDefault }.count
        let color = colors[count % colors.count]
        let emoji = emojis[count % emojis.count]
        let name = "Focus \(count + 1)"
        let profile = FocusProfile(
            name: name,
            emoji: emoji,
            color: color,
            defaultDurationMin: 60
        )
        controller.state.profiles.append(profile)
        controller.persistState()
        withAnimation(.acSnap) { editingProfileID = profile.id }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .tracking(0.06)
            .foregroundStyle(Color.acTextPrimary.opacity(0.45))
            .textCase(.uppercase)
    }
}

private func colorFromHex(_ hex: String) -> Color {
    let cleaned = hex.trimmingCharacters(in: .whitespacesAndNewlines)
    let digits = cleaned.hasPrefix("#") ? String(cleaned.dropFirst()) : cleaned
    guard let value = UInt(digits, radix: 16) else { return Color.secondary }
    return Color(hex: value, alpha: 1)
}

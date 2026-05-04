//
//  ProfilesTab.swift
//  AC
//
//  Profile chip row + editor with safelist and blocklist.
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
    @State private var blocklistDraft: [String] = []
    @State private var defaultDurationDraft: Int?
    @State private var newBlocklistItem = ""
    @State private var showingDeleteConfirm = false

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

    private var profileRules: [PolicyRule] {
        controller.state.policyMemory.rules
            .filter { !$0.isAutoSafelistRule && ($0.profileID == nil || $0.profileID == resolvedEditingID) }
    }

    private var safelistRules: [PolicyRule] {
        controller.state.policyMemory.rules
            .filter { $0.isAutoSafelistRule && ($0.profileID == nil || $0.profileID == resolvedEditingID) }
            .sorted { $0.updatedAt > $1.updatedAt }
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
                Button {
                    withAnimation(.acSnap) { editingProfileID = profile.id }
                } label: {
                    HStack(spacing: 5) {
                        Text(profile.emoji)
                            .font(.ac(13))
                        Text(profile.name)
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
                Text("everyday mode — AC watches passively. it will only intervene if you've asked it to help with something specific in chat. no safelist, no timer.")
                    .font(.acCaption)
                    .foregroundStyle(.secondary)
                    .italic()
            } else {
                TextField("What belongs in this profile?", text: $descriptionDraft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .font(.ac(12))
                    .lineLimit(1...3)

                // Color picker (simple hex presets)
                colorPicker

                // Default duration
                durationPicker

                // Safelist
                safelistSection

                // Blocklist
                blocklistSection

                if draftsChanged {
                    HStack {
                        Spacer()
                        Button("Save profile") { saveProfile() }
                            .buttonStyle(ACPrimaryButton())
                    }
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .trailing)))
                }
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

    // MARK: - Safelist

    private var safelistSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("safelist · ok during \"\(editingProfile.name)\"")
                    .font(.ac(11, weight: .semibold))
                    .foregroundStyle(Color.acTextPrimary.opacity(0.7))
                Spacer()
            }

            let allSafelist = safelistRules + profileRules.filter { $0.kind == .allow }

            if allSafelist.isEmpty {
                Text("No safelisted items yet.")
                    .font(.acCaption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 4) {
                    ForEach(allSafelist) { rule in
                        HStack(spacing: 8) {
                            Text(rule.kindLabel)
                                .font(.ac(9, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Capsule(style: .continuous).fill(Color.green.opacity(0.75)))
                            Text(rule.summary)
                                .font(.ac(11))
                                .foregroundStyle(Color.acTextPrimary.opacity(0.8))
                            Spacer()
                            if !rule.isAutoSafelistRule {
                                Button {
                                    controller.deleteRule(id: rule.id)
                                } label: {
                                    Image(systemName: "xmark")
                                        .font(.system(size: 9, weight: .bold))
                                        .foregroundStyle(Color.secondary.opacity(0.5))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: ACRadius.sm, style: .continuous)
                                .fill(Color.acSurface)
                        )
                    }
                }
            }
        }
    }

    // MARK: - Blocklist

    private var blocklistSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("always-distractions")
                .font(.ac(11, weight: .semibold))
                .foregroundStyle(Color.acTextPrimary.opacity(0.7))

            ACFlowLayout(spacing: 6) {
                ForEach(blocklistDraft, id: \.self) { item in
                    HStack(spacing: 4) {
                        Text(item)
                            .font(.ac(11, weight: .medium))
                            .foregroundStyle(Color.acTextPrimary.opacity(0.85))
                        Button {
                            blocklistDraft.removeAll { $0 == item }
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(Color.secondary.opacity(0.5))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Color.red.opacity(0.08))
                            .overlay(Capsule(style: .continuous).stroke(Color.red.opacity(0.22), lineWidth: 1))
                    )
                }

                HStack(spacing: 4) {
                    TextField("add app or site", text: $newBlocklistItem)
                        .textFieldStyle(.plain)
                        .font(.ac(11))
                        .frame(width: 100)
                    Button {
                        let trimmed = newBlocklistItem.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty, !blocklistDraft.contains(trimmed) else { return }
                        blocklistDraft.append(trimmed)
                        newBlocklistItem = ""
                    } label: {
                        Text("+ add")
                            .font(.ac(11, weight: .medium))
                            .foregroundStyle(accent)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    Capsule(style: .continuous)
                        .fill(Color.acSurface)
                        .overlay(Capsule(style: .continuous).stroke(Color.acHairline, lineWidth: 1))
                )
            }
        }
    }

    // MARK: - Drafts

    private var draftsChanged: Bool {
        nameDraft.trimmingCharacters(in: .whitespacesAndNewlines) != editingProfile.name ||
            descriptionDraft.trimmingCharacters(in: .whitespacesAndNewlines) != (editingProfile.description ?? "") ||
            emojiDraft != editingProfile.emoji ||
            colorDraft != editingProfile.color ||
            blocklistDraft != editingProfile.blocklist ||
            defaultDurationDraft != editingProfile.defaultDurationMin
    }

    private func syncDrafts() {
        nameDraft = editingProfile.name
        descriptionDraft = editingProfile.description ?? ""
        emojiDraft = editingProfile.emoji
        colorDraft = editingProfile.color
        blocklistDraft = editingProfile.blocklist
        defaultDurationDraft = editingProfile.defaultDurationMin
    }

    private func saveProfile() {
        controller.updateProfile(
            id: editingProfile.id,
            name: nameDraft,
            description: descriptionDraft,
            emoji: emojiDraft,
            color: colorDraft,
            blocklist: blocklistDraft,
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
            .font(.ac(11, weight: .semibold))
            .foregroundStyle(Color.acTextPrimary.opacity(0.7))
            .textCase(.lowercase)
    }
}

private extension PolicyRule {
    var kindLabel: String {
        switch kind {
        case .allow:      return "Allow"
        case .discourage: return "Limit"
        case .disallow:   return "Block"
        case .limit:      return "Limit"
        case .tonePreference: return "Tone"
        }
    }
}

private func colorFromHex(_ hex: String) -> Color {
    let cleaned = hex.trimmingCharacters(in: .whitespacesAndNewlines)
    let digits = cleaned.hasPrefix("#") ? String(cleaned.dropFirst()) : cleaned
    guard let value = UInt(digits, radix: 16) else { return Color.secondary }
    return Color(hex: value, alpha: 1)
}

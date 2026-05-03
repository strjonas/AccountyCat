//
//  RulesSheet.swift
//  AC
//
//  Full rules management sheet — accessible from the context bar's "View all
//  rules" link.  Contains the profile picker, rules list, add-rule form,
//  safelist, and memory management that formerly lived in the Brain tab.
//

import SwiftUI

struct RulesSheet: View {
    @EnvironmentObject private var controller: AppController
    @Environment(\.acAccent) private var accent
    @Environment(\.dismiss) private var dismiss

    @State private var showingAddRule = false
    @State private var newRuleSummary = ""
    @State private var newRuleKind: PolicyRuleKind = .allow
    @State private var editingProfile = false
    @State private var selectedProfileID: String? = nil
    @State private var profileNameDraft = ""
    @State private var profileDescriptionDraft = ""
    @FocusState private var profileNameFocused: Bool
    @FocusState private var profileDescriptionFocused: Bool

    private var resolvedProfileID: String {
        let candidate = selectedProfileID ?? controller.state.activeProfileID
        if controller.state.profiles.contains(where: { $0.id == candidate }) {
            return candidate
        }
        return PolicyRule.defaultProfileID
    }
    private var selectedProfile: FocusProfile {
        controller.state.profile(withID: resolvedProfileID) ?? FocusProfile.makeDefault()
    }
    private var activeProfile: FocusProfile { controller.state.activeProfile }

    private var rules: [PolicyRule] {
        controller.state.policyMemory.rules
            .filter { !$0.isAutoSafelistRule && ($0.profileID == nil || $0.profileID == resolvedProfileID) }
    }

    private var safelistRules: [PolicyRule] {
        controller.state.policyMemory.rules
            .filter { $0.isAutoSafelistRule && ($0.profileID == nil || $0.profileID == resolvedProfileID) }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    private var memoryEntries: [MemoryEntry] {
        controller.state.memoryEntries
    }

    private var profileDraftsChanged: Bool {
        profileNameDraft.trimmingCharacters(in: .whitespacesAndNewlines) != selectedProfile.name ||
            profileDescriptionDraft.trimmingCharacters(in: .whitespacesAndNewlines) != (selectedProfile.description ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    profileSection
                    rulesSection
                    addRuleSection
                    safelistSection
                    memorySection
                }
                .padding(20)
            }
        }
        .frame(width: ACD.popoverWidth)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { syncProfileDrafts() }
        .onChange(of: resolvedProfileID) { _, _ in
            syncProfileDrafts()
            profileNameFocused = false
            profileDescriptionFocused = false
        }
        .onChange(of: controller.state.profiles) { _, _ in syncProfileDrafts() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "checklist")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(accent)
            Text("Brain Rules")
                .font(.acTitle)
                .foregroundStyle(Color.acTextPrimary)
            Spacer()
            Button { dismiss() } label: {
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

    // MARK: - Profile section

    private var profileSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: activeProfile.isDefault ? "circle.hexagongrid" : "scope")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(accent)
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(accent.opacity(0.13)))
                Text(activeProfile.name)
                    .font(.ac(13, weight: .semibold))
                    .foregroundStyle(Color.acTextPrimary)
                if !activeProfile.isDefault {
                    Text("active")
                        .font(.ac(10, weight: .medium))
                        .foregroundStyle(accent.opacity(0.8))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule(style: .continuous).fill(accent.opacity(0.12)))
                }
                Spacer()
                Button(editingProfile ? "Done" : "Edit profile") {
                    withAnimation(.acSnap) {
                        editingProfile.toggle()
                    }
                    if !editingProfile {
                        profileNameFocused = false
                        profileDescriptionFocused = false
                    }
                }
                .buttonStyle(ACSecondaryButton())
            }

            if editingProfile {
                profileEditor
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.acSnap, value: editingProfile)
    }

    private var profileEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Picker("", selection: Binding<String>(
                    get: { resolvedProfileID },
                    set: { selectedProfileID = $0 }
                )) {
                    ForEach(controller.state.profiles, id: \.id) { profile in
                        Text(profile.id == controller.state.activeProfileID ? "● \(profile.name)" : profile.name).tag(profile.id)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 200)

                if !selectedProfile.isDefault {
                    Button(role: .destructive) {
                        controller.deleteProfile(id: selectedProfile.id)
                        selectedProfileID = nil
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .disabled(!controller.canDeleteProfile(id: selectedProfile.id))
                }
            }

            TextField("Profile name", text: $profileNameDraft)
                .textFieldStyle(.roundedBorder)
                .font(.ac(12))
                .focused($profileNameFocused)
                .onSubmit {
                    if !profileNameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        saveProfile()
                    }
                }

            TextField("What belongs in this profile?", text: $profileDescriptionDraft, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .font(.ac(12))
                .lineLimit(1...3)
                .focused($profileDescriptionFocused)

            if profileDraftsChanged {
                HStack {
                    Spacer()
                    Button("Save profile") { saveProfile() }
                        .buttonStyle(ACPrimaryButton())
                        .disabled(profileNameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .trailing)))
            }

            if !selectedProfile.isDefault && !controller.canDeleteProfile(id: selectedProfile.id) {
                Text("This profile still has locked scoped rules. Unlock or remove them before deleting.")
                    .font(.ac(10))
                    .foregroundStyle(Color.orange.opacity(0.85))
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: ACRadius.md, style: .continuous)
                .fill(Color.acSurface)
                .overlay(RoundedRectangle(cornerRadius: ACRadius.md, style: .continuous).stroke(Color.acHairline, lineWidth: 1))
        )
        .animation(.acSnap, value: profileDraftsChanged)
    }

    private func syncProfileDrafts() {
        profileNameDraft = selectedProfile.name
        profileDescriptionDraft = selectedProfile.description ?? ""
    }

    private func saveProfile() {
        controller.updateProfile(
            id: selectedProfile.id,
            name: profileNameDraft,
            description: profileDescriptionDraft
        )
        profileNameFocused = false
        profileDescriptionFocused = false
    }

    // MARK: - Rules section

    private var rulesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "shield")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(accent)
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(accent.opacity(0.13)))
                Text("Rules")
                    .font(.ac(13, weight: .semibold))
                    .foregroundStyle(Color.acTextPrimary)
                if !rules.isEmpty {
                    Text("\(rules.count)")
                        .font(.acCaptionStrong)
                        .foregroundStyle(accent)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule(style: .continuous).fill(accent.opacity(0.12)))
                }
            }

            if rules.isEmpty {
                Text("No rules yet. Rules you add here apply to the active profile.")
                    .font(.acCaption)
                    .foregroundStyle(.secondary)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: ACRadius.md, style: .continuous)
                            .fill(Color.acSurface)
                    )
            } else {
                VStack(spacing: 6) {
                    ForEach(rules) { rule in
                        RuleRowView(rule: rule) {
                            controller.toggleRuleLocked(id: rule.id)
                        } onDelete: {
                            controller.deleteRule(id: rule.id)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Add rule

    private var addRuleSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if showingAddRule {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        ForEach([PolicyRuleKind.allow, .limit, .disallow], id: \.self) { kind in
                            Button(kind.displayName) {
                                newRuleKind = kind
                            }
                            .buttonStyle(newRuleKind == kind ? AnyButtonStyle(ACPrimaryButton()) : AnyButtonStyle(ACSecondaryButton()))
                        }
                    }

                    TextField("Rule description", text: $newRuleSummary, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .font(.acBody)
                        .lineLimit(1...3)

                    HStack {
                        Button("Cancel") {
                            showingAddRule = false
                            newRuleSummary = ""
                        }
                        .buttonStyle(ACSecondaryButton())

                        Spacer()

                        Button("Add rule") {
                            controller.addUserRule(newRuleSummary, kind: newRuleKind, profileID: resolvedProfileID)
                            showingAddRule = false
                            newRuleSummary = ""
                        }
                        .buttonStyle(ACPrimaryButton())
                        .disabled(newRuleSummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: ACRadius.md, style: .continuous)
                        .fill(Color.acSurfaceInset)
                        .overlay(RoundedRectangle(cornerRadius: ACRadius.md, style: .continuous).stroke(Color.acHairline, lineWidth: 1))
                )
            } else {
                Button {
                    withAnimation(.acSnap) { showingAddRule = true }
                } label: {
                    Label("Add a rule", systemImage: "plus.circle")
                        .font(.acCaption)
                        .foregroundStyle(accent)
                }
                .buttonStyle(.plain)
            }
        }
        .animation(.acSnap, value: showingAddRule)
    }

    // MARK: - Safelist

    private var safelistSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.shield")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(accent)
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(accent.opacity(0.13)))
                Text("Auto-allowed")
                    .font(.ac(13, weight: .semibold))
                    .foregroundStyle(Color.acTextPrimary)
                if !safelistRules.isEmpty {
                    Text("\(safelistRules.count)")
                        .font(.acCaptionStrong)
                        .foregroundStyle(accent)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule(style: .continuous).fill(accent.opacity(0.12)))
                }
            }

            if safelistRules.isEmpty {
                Text("No auto-allowed apps yet. AC will learn which apps are safe as you work.")
                    .font(.acCaption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 6) {
                    ForEach(safelistRules) { rule in
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark.shield.fill")
                                .foregroundStyle(Color.green.opacity(0.75))
                                .font(.system(size: 11, weight: .semibold))
                            Text(rule.summary)
                                .font(.acCaption)
                                .foregroundStyle(Color.acTextPrimary.opacity(0.8))
                            Spacer()
                            if rule.isLocked {
                                Image(systemName: "lock.fill")
                                    .font(.system(size: 9))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(
                            RoundedRectangle(cornerRadius: ACRadius.sm, style: .continuous)
                                .fill(Color.acSurface)
                        )
                    }
                }
            }
        }
    }

    // MARK: - Memory

    private var memorySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "brain.head.profile")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(accent)
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(accent.opacity(0.13)))
                Text("Memory")
                    .font(.ac(13, weight: .semibold))
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

            if memoryEntries.isEmpty {
                Text("No memories yet. AC will build memory as you interact.")
                    .font(.acCaption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 4) {
                    ForEach(memoryEntries) { entry in
                        HStack(spacing: 6) {
                            if let profileName = entry.profileName, profileName != "General" {
                                Text("[\(profileName)]")
                                    .font(.acCaption)
                                    .foregroundStyle(accent.opacity(0.7))
                            }
                            Text(entry.text)
                                .font(.acCaption)
                                .foregroundStyle(Color.acTextPrimary.opacity(0.8))
                                .lineLimit(2)
                            Spacer()
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
}

// MARK: - PolicyRuleKind display

private extension PolicyRuleKind {
    var displayName: String {
        switch self {
        case .allow:           return "Allow"
        case .discourage:      return "Limit"
        case .disallow:        return "Block"
        case .limit:           return "Limit"
        case .tonePreference:  return "Tone"
        }
    }
}
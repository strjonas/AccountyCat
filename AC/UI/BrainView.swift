//
//  BrainView.swift
//  AC
//
//  "AC's Brain" tab — focus statement, learned rules panel, manual rule creation.
//

import AppKit
import SwiftUI

// MARK: - Brain View

struct BrainView: View {
    @EnvironmentObject private var controller: AppController
    @Environment(\.acAccent) private var accent

    @State private var showingAddRule = false
    @State private var newRuleSummary = ""
    @State private var newRuleKind: PolicyRuleKind = .allow
    @FocusState private var summaryFieldFocused: Bool
    @FocusState private var goalsEditorFocused: Bool
    @State private var localGoalsText: String = ""
    /// Profile being inspected. Defaults to the active profile; user can switch via picker
    /// to view/edit rules of any other stored profile without activating it.
    @State private var selectedProfileID: String? = nil
    @State private var showingProfileOverview = false
    @State private var profileNameDraft = ""
    @State private var profileDescriptionDraft = ""

    private var resolvedSelectedProfileID: String {
        let candidate = selectedProfileID ?? controller.state.activeProfileID
        if controller.state.profiles.contains(where: { $0.id == candidate }) {
            return candidate
        }
        return PolicyRule.defaultProfileID
    }
    private var selectedProfile: FocusProfile {
        controller.state.profile(withID: resolvedSelectedProfileID)
            ?? FocusProfile.makeDefault()
    }
    private var namedProfileCount: Int {
        controller.state.profiles.filter { !$0.isDefault }.count
    }
    private var rules: [PolicyRule] {
        controller.state.policyMemory.rules
            .filter { !$0.isAutoSafelistRule && $0.profileID == resolvedSelectedProfileID }
    }
    private var safelistRules: [PolicyRule] {
        controller.state.policyMemory.rules
            .filter { $0.isAutoSafelistRule && $0.profileID == resolvedSelectedProfileID }
            .sorted { $0.updatedAt > $1.updatedAt }
    }
    private var safelistObservations: [FocusedObservationStat] {
        controller.state.algorithmState.llmPolicy.focusedObservations.values
            .sorted { $0.lastSeenAt > $1.lastSeenAt }
    }
    private var lockedCount: Int { rules.filter(\.isLocked).count }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            profileSection
            focusSection
            rulesSection
            memoryConsolidationSection
            safelistSection
        }
        .padding(20)
        .padding(.bottom, 8)
        .onAppear {
            syncProfileDrafts()
        }
        .onChange(of: resolvedSelectedProfileID) { _, _ in
            syncProfileDrafts()
        }
        .onChange(of: controller.state.profiles) { _, _ in
            syncProfileDrafts()
        }
    }

    // MARK: - Profile

    private var profileSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            brainSectionHeader(
                icon: "person.crop.rectangle.stack",
                title: "Profile rules",
                subtitle: profileSubtitle
            )

            HStack(spacing: 8) {
                Picker("", selection: Binding<String>(
                    get: { resolvedSelectedProfileID },
                    set: { selectedProfileID = $0 }
                )) {
                    ForEach(controller.state.profiles, id: \.id) { profile in
                        Text(profileMenuLabel(for: profile)).tag(profile.id)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 260)

                Spacer()

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

            profileMetadataEditor
            profileOverviewSection
        }
    }

    private var profileMetadataEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Profile name", text: $profileNameDraft)
                .textFieldStyle(.roundedBorder)
                .font(.ac(12))

            TextField("What belongs in this profile?", text: $profileDescriptionDraft, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .font(.ac(12))
                .lineLimit(1...3)

            if profileDraftsChanged {
                HStack {
                    Spacer()
                    Button("Save profile") {
                        controller.updateProfile(
                            id: selectedProfile.id,
                            name: profileNameDraft,
                            description: profileDescriptionDraft
                        )
                    }
                    .buttonStyle(ACPrimaryButton())
                    .disabled(profileNameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .trailing)))
            }

            if !selectedProfile.isDefault && !controller.canDeleteProfile(id: selectedProfile.id) {
                Text("This profile still has locked scoped rules. Unlock or remove them before deleting the profile.")
                    .font(.ac(10))
                    .foregroundStyle(Color.orange.opacity(0.85))
            }
        }
        .animation(.acSnap, value: profileDraftsChanged)
    }

    private var profileDraftsChanged: Bool {
        profileNameDraft.trimmingCharacters(in: .whitespacesAndNewlines) != selectedProfile.name ||
            profileDescriptionDraft.trimmingCharacters(in: .whitespacesAndNewlines) != (selectedProfile.description ?? "")
    }

    private var profileSubtitle: String {
        let active = controller.state.activeProfile
        let viewingHint: String
        if resolvedSelectedProfileID == active.id {
            viewingHint = "You are editing the rules for the active profile."
        } else {
            viewingHint = "You are editing \(selectedProfile.name) here. Use the top-right profile control to switch AC into it live."
        }

        if active.isDefault {
            return "General is active. \(viewingHint)"
        }
        let until: String
        if let exp = active.expiresAt {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "HH:mm"
            until = " until \(formatter.string(from: exp))"
        } else {
            until = ""
        }
        return "\(active.name) is active\(until). \(viewingHint)"
    }

    private func profileMenuLabel(for profile: FocusProfile) -> String {
        if profile.id == controller.state.activeProfileID {
            return "● \(profile.name)"
        }
        return profile.name
    }

    private func syncProfileDrafts() {
        profileNameDraft = selectedProfile.name
        profileDescriptionDraft = selectedProfile.description ?? ""
    }

    private var profileOverviewSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Button(showingProfileOverview ? "Hide saved profiles" : "Browse saved profiles") {
                    withAnimation(.acSnap) {
                        showingProfileOverview.toggle()
                    }
                }
                .buttonStyle(ACSecondaryButton())

                Text(profileOverviewSubtitle)
                    .font(.ac(11))
                    .foregroundStyle(.secondary)

                Spacer(minLength: 0)
            }

            if showingProfileOverview {
                VStack(spacing: 8) {
                    ForEach(profileOverviewProfiles, id: \.id) { profile in
                        ProfileSummaryRowView(
                            profile: profile,
                            isActive: controller.state.activeProfileID == profile.id,
                            isSelected: resolvedSelectedProfileID == profile.id,
                            manualRuleCount: manualRuleCount(for: profile.id),
                            safelistRuleCount: safelistRuleCount(for: profile.id),
                            lockedRuleCount: lockedRuleCount(for: profile.id),
                            canDelete: controller.canDeleteProfile(id: profile.id),
                            onViewDetails: {
                                selectedProfileID = profile.id
                            },
                            onActivate: nil,
                            onDelete: profile.isDefault ? nil : {
                                controller.deleteProfile(id: profile.id)
                                if resolvedSelectedProfileID == profile.id {
                                    selectedProfileID = controller.state.activeProfileID
                                }
                            }
                        )
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.acSnap, value: showingProfileOverview)
    }

    private var profileOverviewProfiles: [FocusProfile] {
        controller.state.profiles.sorted { lhs, rhs in
            if lhs.id == controller.state.activeProfileID { return true }
            if rhs.id == controller.state.activeProfileID { return false }
            if lhs.isDefault != rhs.isDefault { return lhs.isDefault }
            return lhs.lastUsedAt > rhs.lastUsedAt
        }
    }

    private var profileOverviewSubtitle: String {
        if namedProfileCount == 0 {
            return "Only General exists so far."
        }
        return "View/edit does not switch AC. Activate changes live behavior."
    }

    private func manualRuleCount(for profileID: String) -> Int {
        controller.state.policyMemory.rules.filter { !$0.isAutoSafelistRule && $0.profileID == profileID }.count
    }

    private func safelistRuleCount(for profileID: String) -> Int {
        controller.state.policyMemory.rules.filter { $0.isAutoSafelistRule && $0.profileID == profileID }.count
    }

    private func lockedRuleCount(for profileID: String) -> Int {
        controller.lockedRuleCount(forProfileID: profileID)
    }

    // MARK: - Focus

    private var focusSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            brainSectionHeader(
                icon: "target",
                title: "Focus",
                subtitle: "AC uses this as background context for every decision."
            )

            TextEditor(text: $localGoalsText)
                .font(.ac(13))
                .frame(minHeight: 88, maxHeight: 130)
                .padding(10)
                .scrollContentBackground(.hidden)
                .focused($goalsEditorFocused)
                .background(
                    RoundedRectangle(cornerRadius: ACRadius.md, style: .continuous)
                        .fill(Color(nsColor: .textBackgroundColor))
                        .overlay(
                            RoundedRectangle(cornerRadius: ACRadius.md, style: .continuous)
                                .stroke(Color.acHairline, lineWidth: 1)
                        )
                )

            if localGoalsText != controller.state.goalsText {
                HStack {
                    Spacer()
                    Button("Save") {
                        controller.updateGoals(localGoalsText)
                        goalsEditorFocused = false
                    }
                    .buttonStyle(ACPrimaryButton())
                }
                .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .trailing)))
            }
        }
        .animation(.acSnap, value: localGoalsText != controller.state.goalsText)
        .onAppear { localGoalsText = controller.state.goalsText }
        .onChange(of: controller.state.goalsText) { oldValue, newValue in
            if localGoalsText == oldValue { localGoalsText = newValue }
        }
    }

    // MARK: - Rules

    private var rulesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                brainSectionHeader(
                    icon: "list.bullet.rectangle.portrait",
                    title: "Rules",
                    subtitle: rules.isEmpty
                        ? "Rules AC learns will appear here."
                        : "\(rules.count) rule\(rules.count == 1 ? "" : "s")\(lockedCount > 0 ? " · \(lockedCount) locked" : "")"
                )
            }

            if lockedCount >= 5 {
                lockedRulesBanner
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            if rules.isEmpty {
                emptyRulesView
            } else {
                VStack(spacing: 6) {
                    ForEach(rules) { rule in
                        RuleRowView(
                            rule: rule,
                            onToggleLocked: { controller.toggleRuleLocked(id: rule.id) },
                            onDelete: { controller.deleteRule(id: rule.id) }
                        )
                    }
                }
            }

            if showingAddRule {
                addRuleForm
                    .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
            } else {
                addRuleTrigger
            }
        }
        .animation(.acSnap, value: showingAddRule)
        .animation(.acSnap, value: lockedCount >= 5)
        .animation(.acSnap, value: rules.map(\.id))
    }

    // MARK: - Safelist

    private var safelistSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            brainSectionHeader(
                icon: "checkmark.shield",
                title: "Safelist",
                subtitle: safelistRules.isEmpty
                    ? "Auto-approved contexts will appear here."
                    : "\(safelistRules.count) auto-approved context\(safelistRules.count == 1 ? "" : "s")"
            )

            if safelistRules.isEmpty {
                Text("Nothing has been auto-safelisted yet.")
                    .font(.ac(11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 2)
            } else {
                VStack(spacing: 6) {
                    ForEach(safelistRules) { rule in
                        RuleRowView(
                            rule: rule,
                            onToggleLocked: { controller.toggleRuleLocked(id: rule.id) },
                            onDelete: { controller.deleteRule(id: rule.id) }
                        )
                    }
                }
            }

            if ACBuild.isDebug {
                let candidates = safelistObservations
                    .filter { $0.lastPromotionOutcome != .approved || $0.lastAutoAllowRuleID == nil }
                    .prefix(10)
                if !candidates.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Not safelisted")
                            .font(.ac(11, weight: .semibold))
                            .foregroundStyle(Color.acTextPrimary.opacity(0.70))
                            .padding(.top, 4)
                        ForEach(Array(candidates), id: \.contextFingerprint) { observation in
                            SafelistObservationRowView(observation: observation)
                        }
                    }
                }
            }
        }
        .animation(.acSnap, value: safelistRules.map(\.id))
    }

    // MARK: - Locked threshold banner

    @ViewBuilder
    private var lockedRulesBanner: some View {
        let isHigh = lockedCount >= 8
        HStack(spacing: 10) {
            Image(systemName: isHigh ? "lock.fill" : "lock")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isHigh ? Color.orange : Color.yellow.opacity(0.75))
            Text(isHigh
                 ? "\(lockedCount) rules locked — AC is mostly following fixed rules. Consider unlocking some to let it adapt."
                 : "\(lockedCount) rules locked — AC's adaptability is slightly reduced.")
                .font(.ac(11))
                .foregroundStyle(Color.acTextPrimary.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: ACRadius.sm, style: .continuous)
                .fill(isHigh ? Color.orange.opacity(0.09) : Color.yellow.opacity(0.07))
                .overlay(
                    RoundedRectangle(cornerRadius: ACRadius.sm, style: .continuous)
                        .stroke(isHigh ? Color.orange.opacity(0.28) : Color.yellow.opacity(0.18), lineWidth: 1)
                )
        )
    }

    // MARK: - Empty state

    private var emptyRulesView: some View {
        VStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(accent.opacity(0.40))
            Text("No rules yet")
                .font(.ac(13, weight: .medium))
                .foregroundStyle(Color.acTextPrimary.opacity(0.50))
            Text("AC will learn rules from your conversations and behavior. You can also add your own below.")
                .font(.ac(11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
        .padding(.horizontal, 12)
    }

    // MARK: - Add rule trigger

    private var addRuleTrigger: some View {
        Button {
            withAnimation(.acSnap) { showingAddRule = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                summaryFieldFocused = true
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 12, weight: .medium))
                Text("Add a rule")
                    .font(.ac(12, weight: .medium))
            }
            .foregroundStyle(accent.opacity(0.85))
            .padding(.vertical, 2)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Add rule form

    private var addRuleForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Describe the rule...", text: $newRuleSummary)
                .textFieldStyle(.plain)
                .font(.ac(13))
                .focused($summaryFieldFocused)
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: ACRadius.sm, style: .continuous)
                        .fill(Color(nsColor: .textBackgroundColor))
                        .overlay(
                            RoundedRectangle(cornerRadius: ACRadius.sm, style: .continuous)
                                .stroke(Color.acHairline, lineWidth: 1)
                        )
                )
                .onSubmit { commitRule() }

            HStack(spacing: 0) {
                HStack(spacing: 6) {
                    kindChip(.allow,      label: "Allow",   color: .green)
                    kindChip(.discourage, label: "Limit",   color: .orange)
                    kindChip(.disallow,   label: "Block",   color: .red)
                }
                Spacer(minLength: 8)
                HStack(spacing: 6) {
                    Button("Cancel") {
                        withAnimation(.acSnap) {
                            showingAddRule = false
                            newRuleSummary = ""
                            newRuleKind = .allow
                        }
                    }
                    .buttonStyle(ACSecondaryButton())

                    Button("Add rule") { commitRule() }
                        .buttonStyle(ACPrimaryButton())
                        .disabled(newRuleSummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: ACRadius.md, style: .continuous)
                .fill(Color.acSurface)
                .overlay(
                    RoundedRectangle(cornerRadius: ACRadius.md, style: .continuous)
                        .stroke(accent.opacity(0.22), lineWidth: 1)
                )
        )
    }

    @ViewBuilder
    private func kindChip(_ kind: PolicyRuleKind, label: String, color: Color) -> some View {
        let isSelected = newRuleKind == kind
        Button {
            withAnimation(.acSnap) { newRuleKind = kind }
        } label: {
            Text(label)
                .font(.ac(11, weight: isSelected ? .semibold : .medium))
                .foregroundStyle(isSelected ? .white : Color.acTextPrimary.opacity(0.70))
                .padding(.horizontal, 11)
                .padding(.vertical, 5)
                .background(
                    Capsule(style: .continuous)
                        .fill(isSelected ? color.opacity(0.82) : Color.acSurface)
                        .overlay(
                            Capsule(style: .continuous)
                                .stroke(isSelected ? Color.clear : Color.acHairline, lineWidth: 1)
                        )
                )
        }
        .buttonStyle(.plain)
        .animation(.acSnap, value: isSelected)
    }

    private func commitRule() {
        let trimmed = newRuleSummary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        controller.addUserRule(trimmed, kind: newRuleKind, profileID: resolvedSelectedProfileID)
        withAnimation(.acSnap) {
            showingAddRule = false
            newRuleSummary = ""
            newRuleKind = .allow
        }
    }

    // MARK: - Section header

    private func brainSectionHeader(icon: String, title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(accent)
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(accent.opacity(0.13)))
                Text(title)
                    .font(.ac(13, weight: .semibold))
                    .foregroundStyle(Color.acTextPrimary)
            }
            Text(subtitle)
                .font(.ac(11))
                .foregroundStyle(.secondary)
                .padding(.leading, 26)
        }
    }

    private var memoryConsolidationSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            brainSectionHeader(
                icon: "brain.head.profile",
                title: "Context",
                subtitle: "Facts AC has picked up about you and your work."
            )

            HStack(spacing: 10) {
                Button(controller.consolidatingMemory ? "Consolidating…" : "Clean up context") {
                    controller.consolidateMemoryNow()
                }
                .buttonStyle(ACSecondaryButton())
                .disabled(!controller.canConsolidateMemory)

                let count = controller.state.memoryEntries.count
                Text(count == 0 ? "No saved entries" : "\(count) saved entr\(count == 1 ? "y" : "ies")")
                    .font(.ac(11))
                    .foregroundStyle(.secondary)

                Spacer(minLength: 0)
            }

            if controller.state.memoryEntries.isEmpty {
                Text("No memory saved yet.")
                    .font(.ac(11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 2)
            } else {
                VStack(spacing: 6) {
                    ForEach(controller.state.memoryEntries.sorted { $0.createdAt > $1.createdAt }) { entry in
                        MemoryEntryRowView(
                            entry: entry,
                            onDelete: { controller.deleteMemoryEntry(id: entry.id) }
                        )
                    }
                }
                .animation(.acSnap, value: controller.state.memoryEntries.map(\.id))
            }
        }
    }
}

// MARK: - Profile Summary Row

private struct ProfileSummaryRowView: View {
    let profile: FocusProfile
    let isActive: Bool
    let isSelected: Bool
    let manualRuleCount: Int
    let safelistRuleCount: Int
    let lockedRuleCount: Int
    let canDelete: Bool
    let onViewDetails: () -> Void
    let onActivate: (() -> Void)?
    let onDelete: (() -> Void)?

    @Environment(\.acAccent) private var accent
    @State private var hoveringDelete = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(profile.name)
                        .font(.ac(12, weight: .semibold))
                        .foregroundStyle(Color.acTextPrimary)

                    if isActive {
                        profileBadge("Active", fill: accent.opacity(0.16), stroke: accent.opacity(0.22))
                    }
                    if isSelected {
                        profileBadge("Viewing", fill: Color.acSurface, stroke: Color.acHairline)
                    }
                    if profile.isDefault {
                        profileBadge("General", fill: Color.secondary.opacity(0.12), stroke: Color.secondary.opacity(0.18))
                    }
                }

                if let description = profile.description, !description.isEmpty {
                    Text(description)
                        .font(.ac(11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 4) {
                    Text("\(manualRuleCount) rule\(manualRuleCount == 1 ? "" : "s")")
                    Text("·")
                    Text("\(safelistRuleCount) safelist")
                    Text("·")
                    Text("Last used \(profile.lastUsedAt.profileRelativeLabel)")
                    if lockedRuleCount > 0 {
                        Text("·")
                        Text("\(lockedRuleCount) locked")
                    }
                }
                .font(.ac(10))
                .foregroundStyle(.secondary)

                if !canDelete && !profile.isDefault {
                    Text("Unlock or remove locked rules before deleting this profile.")
                        .font(.ac(10))
                        .foregroundStyle(Color.orange.opacity(0.85))
                }
            }

            Spacer(minLength: 0)

            HStack(spacing: 6) {
                Button("Edit rules", action: onViewDetails)
                    .buttonStyle(ACSecondaryButton())

                if let onActivate {
                    Button("Activate", action: onActivate)
                        .buttonStyle(ACSecondaryButton())
                        .disabled(isActive)
                }

                if let onDelete {
                    Button(action: onDelete) {
                        Image(systemName: "trash")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(
                                canDelete
                                ? (hoveringDelete ? Color.red.opacity(0.78) : Color.secondary.opacity(0.40))
                                : Color.secondary.opacity(0.22)
                            )
                            .frame(width: 26, height: 26)
                            .background(
                                Circle()
                                    .fill(
                                        canDelete && hoveringDelete
                                        ? Color.red.opacity(0.08)
                                        : Color.acSurface
                                    )
                                    .overlay(
                                        Circle().stroke(
                                            canDelete && hoveringDelete
                                            ? Color.red.opacity(0.22)
                                            : Color.acHairline,
                                            lineWidth: 1
                                        )
                                    )
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(!canDelete)
                    .onHover { hoveringDelete = $0 }
                    .help(canDelete ? "Delete this profile" : "Locked rules must be resolved before deleting this profile")
                    .animation(.acFade, value: hoveringDelete)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: ACRadius.md, style: .continuous)
                .fill(isActive ? accent.opacity(0.05) : Color.acSurface)
                .overlay(
                    RoundedRectangle(cornerRadius: ACRadius.md, style: .continuous)
                        .stroke(isActive ? accent.opacity(0.18) : Color.acHairline, lineWidth: 1)
                )
        )
    }

    private func profileBadge(_ text: String, fill: Color, stroke: Color) -> some View {
        Text(text)
            .font(.ac(9, weight: .semibold))
            .foregroundStyle(Color.acTextPrimary.opacity(0.78))
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                Capsule(style: .continuous)
                    .fill(fill)
                    .overlay(Capsule(style: .continuous).stroke(stroke, lineWidth: 1))
            )
    }
}

// MARK: - Rule Row

private struct RuleRowView: View {
    let rule: PolicyRule
    let onToggleLocked: () -> Void
    let onDelete: () -> Void

    @Environment(\.acAccent) private var accent
    @State private var hoveringDelete = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            // Kind badge
            Text(rule.kindLabel)
                .font(.ac(9, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Capsule(style: .continuous).fill(kindColor.opacity(0.82)))
                .padding(.top, 1)

            // Content
            VStack(alignment: .leading, spacing: 3) {
                Text(rule.summary)
                    .font(.ac(12, weight: .medium))
                    .foregroundStyle(Color.acTextPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineLimit(4)

                HStack(spacing: 4) {
                    Text(rule.sourceLabel)
                        .font(.ac(10))
                        .foregroundStyle(.secondary)

                    if let appName = rule.scope.appName, !appName.isEmpty {
                        Text("·")
                            .font(.ac(10))
                            .foregroundStyle(Color.secondary.opacity(0.5))
                        Text(appName)
                            .font(.ac(10))
                            .foregroundStyle(.secondary)
                    }

                    Text("·")
                        .font(.ac(10))
                        .foregroundStyle(Color.secondary.opacity(0.5))
                    Text(rule.updatedAt.brainRelativeLabel)
                        .font(.ac(10))
                        .foregroundStyle(Color.secondary.opacity(0.75))

                    if !rule.active {
                        Text("· inactive")
                            .font(.ac(10))
                            .foregroundStyle(Color.secondary.opacity(0.5))
                    }
                }
            }

            Spacer(minLength: 4)

            // Lock button
            Button(action: onToggleLocked) {
                Image(systemName: rule.isLocked ? "lock.fill" : "lock.open")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(rule.isLocked ? accent : Color.secondary.opacity(0.40))
                    .frame(width: 26, height: 26)
                    .background(
                        Circle()
                            .fill(rule.isLocked ? accent.opacity(0.10) : Color.acSurface)
                            .overlay(Circle().stroke(
                                rule.isLocked ? accent.opacity(0.22) : Color.acHairline, lineWidth: 1
                            ))
                    )
            }
            .buttonStyle(.plain)
            .help(rule.isLocked ? "Unlock — let AC update this rule" : "Lock — prevent AC from changing this rule")
            .animation(.acFade, value: rule.isLocked)

            // Delete button
            Button(action: onDelete) {
                Image(systemName: "trash")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(hoveringDelete ? Color.red.opacity(0.78) : Color.secondary.opacity(0.40))
                    .frame(width: 26, height: 26)
                    .background(
                        Circle()
                            .fill(hoveringDelete ? Color.red.opacity(0.08) : Color.acSurface)
                            .overlay(Circle().stroke(
                                hoveringDelete ? Color.red.opacity(0.22) : Color.acHairline, lineWidth: 1
                            ))
                    )
            }
            .buttonStyle(.plain)
            .onHover { hoveringDelete = $0 }
            .help("Delete this rule")
            .animation(.acFade, value: hoveringDelete)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: ACRadius.md, style: .continuous)
                .fill(rule.isLocked ? accent.opacity(0.04) : Color.acSurface)
                .overlay(
                    RoundedRectangle(cornerRadius: ACRadius.md, style: .continuous)
                        .stroke(rule.isLocked ? accent.opacity(0.18) : Color.acHairline, lineWidth: 1)
                )
        )
        .opacity(rule.active ? 1.0 : 0.55)
        .animation(.acFade, value: rule.isLocked)
        .animation(.acFade, value: rule.active)
    }

    private var kindColor: Color {
        switch rule.kind {
        case .allow:           return .green
        case .discourage:      return .orange
        case .disallow:        return .red
        case .limit:           return .orange
        case .tonePreference:  return accent
        }
    }
}

// MARK: - Safelist Observation Row

private struct SafelistObservationRowView: View {
    let observation: FocusedObservationStat

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(observation.promotionStatusLabel)
                .font(.ac(9, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Capsule(style: .continuous).fill(observation.promotionStatusColor.opacity(0.82)))
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 3) {
                Text(observation.titleSignature ?? observation.appName)
                    .font(.ac(12, weight: .medium))
                    .foregroundStyle(Color.acTextPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineLimit(4)

                Text(observation.debugSummary)
                    .font(.ac(10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineLimit(3)
            }

            Spacer(minLength: 4)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: ACRadius.md, style: .continuous)
                .fill(Color.acSurface)
                .overlay(
                    RoundedRectangle(cornerRadius: ACRadius.md, style: .continuous)
                        .stroke(Color.acHairline, lineWidth: 1)
                )
        )
    }
}

// MARK: - Memory Entry Row

private struct MemoryEntryRowView: View {
    let entry: MemoryEntry
    let onDelete: () -> Void
    @State private var hoveringDelete = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.text)
                    .font(.ac(12, weight: .medium))
                    .foregroundStyle(Color.acTextPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineLimit(6)
                Text(entry.createdAt.brainRelativeLabel)
                    .font(.ac(10))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Button(action: onDelete) {
                Image(systemName: "trash")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(hoveringDelete ? Color.red.opacity(0.78) : Color.secondary.opacity(0.40))
                    .frame(width: 26, height: 26)
                    .background(
                        Circle()
                            .fill(hoveringDelete ? Color.red.opacity(0.08) : Color.acSurface)
                            .overlay(Circle().stroke(
                                hoveringDelete ? Color.red.opacity(0.22) : Color.acHairline, lineWidth: 1
                            ))
                    )
            }
            .buttonStyle(.plain)
            .onHover { hoveringDelete = $0 }
            .help("Delete this memory entry")
            .animation(.acFade, value: hoveringDelete)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: ACRadius.md, style: .continuous)
                .fill(Color.acSurface)
                .overlay(
                    RoundedRectangle(cornerRadius: ACRadius.md, style: .continuous)
                        .stroke(Color.acHairline, lineWidth: 1)
                )
        )
    }
}

// MARK: - PolicyRule display helpers

private extension PolicyRule {
    var kindLabel: String {
        switch kind {
        case .allow:           return "Allow"
        case .discourage:      return "Limit"
        case .disallow:        return "Block"
        case .limit:           return "Limit"
        case .tonePreference:  return "Tone"
        }
    }

    var sourceLabel: String {
        switch source {
        case .userChat:         return "From chat"
        case .explicitFeedback: return "Your rule"
        case .implicitFeedback: return "AC learned"
        case .appeal:           return "Appeal"
        case .system:           return "System"
        }
    }
}

private extension FocusedObservationStat {
    var promotionStatusLabel: String {
        switch lastPromotionOutcome {
        case .approved: return "Approved"
        case .denied: return "Denied"
        case .invalid: return "Invalid"
        case .error: return "Error"
        case .ineligible: return "Waiting"
        case .none: return "Seen"
        }
    }

    var promotionStatusColor: Color {
        switch lastPromotionOutcome {
        case .approved: return .green
        case .denied, .invalid: return .red
        case .error: return .orange
        case .ineligible, .none: return .secondary
        }
    }

    var debugSummary: String {
        var parts = [
            appName,
            "\(focusedCount) focused",
            "\(distinctDayCount)d",
            "last \(lastSeenAt.brainRelativeLabel)"
        ]
        if let reason = lastPromotionReason, !reason.isEmpty {
            parts.append(reason)
        } else if let lastPromotionOutcome {
            parts.append(lastPromotionOutcome.rawValue)
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Relative date

private extension Date {
    var brainRelativeLabel: String {
        let s = -timeIntervalSinceNow
        if s < 60    { return "just now" }
        if s < 3600  { return "\(Int(s / 60))m ago" }
        if s < 86400 { return "\(Int(s / 3600))h ago" }
        let d = Int(s / 86400)
        if d < 30    { return "\(d)d ago" }
        return "\(Int(d / 30))mo ago"
    }

    var profileRelativeLabel: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: self, relativeTo: Date())
    }
}

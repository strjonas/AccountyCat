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

    private var rules: [PolicyRule] { controller.state.policyMemory.rules }
    private var lockedCount: Int { rules.filter(\.isLocked).count }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            focusSection
            rulesSection
        }
        .padding(20)
        .padding(.bottom, 8)
    }

    // MARK: - Focus

    private var focusSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            brainSectionHeader(
                icon: "target",
                title: "Focus",
                subtitle: "AC uses this as background context for every decision."
            )

            TextEditor(text: Binding(
                get: { controller.state.goalsText },
                set: { controller.updateGoals($0) }
            ))
            .font(.ac(13))
            .frame(minHeight: 88, maxHeight: 130)
            .padding(10)
            .scrollContentBackground(.hidden)
            .background(
                RoundedRectangle(cornerRadius: ACRadius.md, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor))
                    .overlay(
                        RoundedRectangle(cornerRadius: ACRadius.md, style: .continuous)
                            .stroke(Color.acHairline, lineWidth: 1)
                    )
            )
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
        controller.addUserRule(trimmed, kind: newRuleKind)
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
}

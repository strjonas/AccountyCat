//
//  YouTab.swift
//  AC
//
//  Name, learned facts with lock/delete, version, privacy/export/reset/quit.
//

import SwiftUI
import UniformTypeIdentifiers

struct YouTab: View {
    @EnvironmentObject private var controller: AppController
    @Environment(\.acAccent) private var accent
    @Environment(\.dismiss) private var dismiss

    @State private var nameDraft = ""
    @State private var newMemoryDraft = ""
    @State private var showingResetConfirm = false
    @State private var showingExportPanel = false
    @FocusState private var memoryFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            sectionLabel("your name")
            nameField

            // Memory entries
            HStack {
                sectionLabel("what \(controller.state.character.displayName.lowercased()) knows about you")
                Spacer()
                HStack(spacing: 10) {
                    Button {
                        withAnimation(.acSnap) { memoryFocused = true }
                    } label: {
                        Text("+ add")
                            .font(.ac(10, weight: .medium))
                            .foregroundStyle(accent)
                    }
                    .buttonStyle(.plain)

                    if controller.canConsolidateMemory {
                        Button {
                            controller.consolidateMemoryNow()
                        } label: {
                            Text("clean up")
                                .font(.ac(10, weight: .medium))
                                .foregroundStyle(Color.acTextPrimary.opacity(0.5))
                        }
                        .buttonStyle(.plain)
                        .disabled(controller.consolidatingMemory)
                    }
                }
            }

            Text("locked items are never auto-removed during cleanup.")
                .font(.acCaption)
                .foregroundStyle(.secondary)
                .padding(.top, -12)

            memoryInput
            memoryList

            // Pending proposals (rule/memory suggestions awaiting approval)
            if !controller.state.proposedChanges.isEmpty {
                proposalsSection
            }

            // Calendar integration
            CalendarIntelligenceSection()
                .environmentObject(controller)

            // Version & actions
            sectionLabel("version")
            Text("AccountyCat \(appVersion) · macOS \(systemVersion)")
                .font(.acCaption)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 0) {
                settingsLinkRow(
                    icon: "lock.shield",
                    label: "privacy & data",
                    action: {
                        if let url = URL(string: "https://accountycat.com/privacy") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                )

                Divider().opacity(0.15).padding(.leading, 36)

                settingsLinkRow(
                    icon: "square.and.arrow.up",
                    label: "export everything",
                    action: { exportState() }
                )

                Divider().opacity(0.15).padding(.leading, 36)

                settingsLinkRow(
                    icon: "arrow.counterclockwise",
                    label: "reset all data",
                    isDestructive: true,
                    action: { showingResetConfirm = true }
                )
                .alert("Reset all data?", isPresented: $showingResetConfirm) {
                    Button("Reset", role: .destructive) {
                        controller.resetAlgorithmProfile()
                        dismiss()
                    }
                    Button("Cancel", role: .cancel) { }
                } message: {
                    Text("This clears learned memory, recent behavior context, chat history, and usage context. Your profiles and settings will also reset to defaults.")
                }

                Divider().opacity(0.15).padding(.leading, 36)

                settingsLinkRow(
                    icon: "power",
                    label: "quit AccountyCat",
                    isMuted: true,
                    action: {
                        dismiss()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            NSApp.terminate(nil)
                        }
                    }
                )
            }
            .background(
                RoundedRectangle(cornerRadius: ACRadius.sm, style: .continuous)
                    .fill(Color.acSurface)
                    .overlay(
                        RoundedRectangle(cornerRadius: ACRadius.sm, style: .continuous)
                            .stroke(Color.acHairline, lineWidth: 1)
                    )
            )
        }
    }

    // MARK: - Settings link row

    private func settingsLinkRow(
        icon: String,
        label: String,
        isDestructive: Bool = false,
        isMuted: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(
                        isDestructive ? Color.acRedEnd.opacity(0.85)
                            : isMuted ? Color.secondary.opacity(0.45)
                            : Color.acTextPrimary.opacity(0.55)
                    )
                    .frame(width: 20, height: 20)

                Text(label)
                    .font(.ac(12, weight: .medium))
                    .foregroundStyle(
                        isDestructive ? Color.acRedEnd.opacity(0.85)
                            : isMuted ? Color.acTextPrimary.opacity(0.45)
                            : Color.acTextPrimary.opacity(0.72)
                    )

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.secondary.opacity(0.35))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Name field

    private var nameField: some View {
        TextField("What should AC call you?", text: $nameDraft)
            .textFieldStyle(.plain)
            .font(.ac(13))
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
            .onAppear { nameDraft = controller.state.userName }
            .onSubmit { controller.updateUserName(nameDraft) }
            .onChange(of: nameDraft) { _, newValue in
                controller.updateUserName(newValue)
            }
    }

    // MARK: - Memory input

    private var memoryInput: some View {
        HStack(spacing: 8) {
            TextField("Add something AC should remember…", text: $newMemoryDraft)
                .textFieldStyle(.plain)
                .font(.ac(12))
                .focused($memoryFocused)
                .onSubmit { addMemory() }

            Button(action: addMemory) {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(canAddMemory ? Color.white : Color.acTextPrimary.opacity(0.4))
                    .frame(width: 24, height: 24)
                    .background(
                        Circle()
                            .fill(canAddMemory ? accent : Color.acSurface)
                            .overlay(Circle().stroke(canAddMemory ? Color.clear : Color.acHairline, lineWidth: 1))
                    )
            }
            .buttonStyle(.plain)
            .disabled(!canAddMemory)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: ACRadius.sm, style: .continuous)
                .fill(Color.acSurface)
                .overlay(
                    RoundedRectangle(cornerRadius: ACRadius.sm, style: .continuous)
                        .stroke(memoryFocused ? accent.opacity(0.5) : Color.acHairline, lineWidth: 1)
                )
        )
        .animation(.acSnap, value: memoryFocused)
    }

    private var canAddMemory: Bool {
        !newMemoryDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func addMemory() {
        let trimmed = newMemoryDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        controller.addMemoryEntry(text: trimmed)
        newMemoryDraft = ""
        memoryFocused = false
    }

    // MARK: - Memory list

    private var memoryList: some View {
        let entries = controller.state.memoryEntries.sorted { $0.createdAt > $1.createdAt }
        if entries.isEmpty {
            return AnyView(
                Text("No memories yet. AC will build memory as you interact.")
                    .font(.acCaption)
                    .foregroundStyle(.secondary)
            )
        }
        return AnyView(
            VStack(spacing: 4) {
                ForEach(entries) { entry in
                    HStack(alignment: .top, spacing: 8) {
                        Text(entry.text)
                            .font(.ac(11))
                            .foregroundStyle(Color.acTextPrimary.opacity(0.85))
                            .lineLimit(4)
                        Spacer(minLength: 4)

                        Button {
                            controller.toggleMemoryEntryLocked(id: entry.id)
                        } label: {
                            Image(systemName: entry.isLocked ? "lock.fill" : "lock.open")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(entry.isLocked ? accent : Color.secondary.opacity(0.35))
                                .frame(width: 24, height: 24)
                                .background(
                                    Circle()
                                        .fill(entry.isLocked ? accent.opacity(0.10) : Color.acSurface)
                                        .overlay(Circle().stroke(
                                            entry.isLocked ? accent.opacity(0.22) : Color.acHairline, lineWidth: 1
                                        ))
                                )
                        }
                        .buttonStyle(.plain)
                        .help(entry.isLocked ? "Unlock — allow cleanup to remove" : "Lock — keep on cleanup")

                        Button {
                            controller.deleteMemoryEntry(id: entry.id)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(Color.secondary.opacity(0.4))
                                .frame(width: 24, height: 24)
                                .background(
                                    Circle()
                                        .fill(Color.acSurface)
                                        .overlay(Circle().stroke(Color.acHairline, lineWidth: 1))
                                )
                        }
                        .buttonStyle(.plain)
                        .disabled(entry.isLocked)
                        .help("Delete this memory entry")
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: ACRadius.sm, style: .continuous)
                            .fill(entry.isLocked ? accent.opacity(0.04) : Color.acSurface)
                            .overlay(
                                RoundedRectangle(cornerRadius: ACRadius.sm, style: .continuous)
                                    .stroke(entry.isLocked ? accent.opacity(0.15) : Color.acHairline, lineWidth: 1)
                            )
                    )
                }
            }
        )
    }

    // MARK: - Helpers

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    private var systemVersion: String {
        ProcessInfo.processInfo.operatingSystemVersionString
    }

    private func exportState() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "accountycat-state.json"
        panel.allowedContentTypes = [.json]
        panel.begin { result in
            guard result == .OK, let url = panel.url else { return }
            do {
                let data = try JSONEncoder().encode(controller.state)
                try data.write(to: url)
            } catch {
                print("Export failed: \(error)")
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

    // MARK: - Proposals

    private var proposalsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("waiting on you")

            Text("ac noticed a pattern but didn't apply anything yet. accept or dismiss.")
                .font(.acCaption)
                .foregroundStyle(.secondary)
                .padding(.top, -4)

            VStack(spacing: 4) {
                ForEach(controller.state.proposedChanges.sorted { $0.createdAt > $1.createdAt }) { proposal in
                    proposalRow(proposal)
                }
            }
        }
    }

    private func proposalRow(_ proposal: ProposedPolicyChange) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: proposalIcon(for: proposal))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(accent.opacity(0.8))
                .frame(width: 18, height: 18)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 2) {
                Text(proposalSummary(for: proposal))
                    .font(.ac(11, weight: .medium))
                    .foregroundStyle(Color.acTextPrimary.opacity(0.92))
                    .lineLimit(3)
                if let reason = proposal.reason?.cleanedSingleLine, !reason.isEmpty {
                    Text(reason)
                        .font(.acCaption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 4)

            HStack(spacing: 6) {
                Button {
                    controller.acceptProposedChange(id: proposal.id)
                } label: {
                    Text("accept")
                        .font(.ac(10, weight: .semibold))
                        .foregroundStyle(Color.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(accent))
                }
                .buttonStyle(.plain)

                Button {
                    controller.dismissProposedChange(id: proposal.id)
                } label: {
                    Text("dismiss")
                        .font(.ac(10, weight: .semibold))
                        .foregroundStyle(Color.acTextPrimary.opacity(0.55))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            Capsule().stroke(Color.acHairline, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: ACRadius.sm, style: .continuous)
                .fill(accent.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: ACRadius.sm, style: .continuous)
                        .stroke(accent.opacity(0.18), lineWidth: 1)
                )
        )
    }

    private func proposalIcon(for proposal: ProposedPolicyChange) -> String {
        switch proposal.kind {
        case .rule:
            switch proposal.proposedRule?.kind {
            case .allow: return "checkmark.shield"
            case .disallow, .discourage: return "exclamationmark.shield"
            case .limit: return "timer"
            case .tonePreference, nil: return "sparkles"
            }
        case .memory:
            return "brain"
        }
    }

    private func proposalSummary(for proposal: ProposedPolicyChange) -> String {
        switch proposal.kind {
        case .rule:
            guard let rule = proposal.proposedRule else { return "Proposed rule" }
            let target = rule.scope.appName
                ?? rule.scope.bundleIdentifier
                ?? rule.scope.titleContains.first
                ?? rule.summary
            let kind: String
            switch rule.kind {
            case .allow: kind = "Allow"
            case .disallow: kind = "Block"
            case .discourage: kind = "Discourage"
            case .limit: kind = "Limit"
            case .tonePreference: kind = "Tone"
            }
            return "\(kind) \(target)"
        case .memory:
            return proposal.proposedMemoryNote ?? "Proposed memory entry"
        }
    }
}

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
    @State private var showingResetConfirm = false
    @State private var showingExportPanel = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            sectionLabel("your name")
            TextField("What should AC call you?", text: $nameDraft)
                .textFieldStyle(.roundedBorder)
                .font(.ac(13))
                .onAppear { nameDraft = controller.state.userName }
                .onSubmit { controller.updateUserName(nameDraft) }
                .onChange(of: nameDraft) { _, newValue in
                    controller.updateUserName(newValue)
                }

            // Memory entries
            HStack {
                sectionLabel("what \(controller.state.character.displayName.lowercased()) knows about you")
                Spacer()
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

            Text("locked items are never auto-removed during cleanup.")
                .font(.acCaption)
                .foregroundStyle(.secondary)
                .padding(.top, -12)

            memoryList

            Divider().opacity(0.3)

            // Version & actions
            sectionLabel("version")
            Text("AccountyCat \(appVersion) · macOS \(systemVersion)")
                .font(.acCaption)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 10) {
                Button {
                    if let url = URL(string: "https://accountycat.com/privacy") {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Text("privacy & data →")
                        .font(.ac(11, weight: .medium))
                        .foregroundStyle(accent.opacity(0.85))
                }
                .buttonStyle(.plain)

                Button {
                    exportState()
                } label: {
                    Text("export everything…")
                        .font(.ac(11, weight: .medium))
                        .foregroundStyle(accent.opacity(0.85))
                }
                .buttonStyle(.plain)

                Button {
                    showingResetConfirm = true
                } label: {
                    Text("reset all data…")
                        .font(.ac(11, weight: .medium))
                        .foregroundStyle(Color.red.opacity(0.72))
                }
                .buttonStyle(.plain)
                .alert("Reset all data?", isPresented: $showingResetConfirm) {
                    Button("Reset", role: .destructive) {
                        controller.resetAlgorithmProfile()
                        dismiss()
                    }
                    Button("Cancel", role: .cancel) { }
                } message: {
                    Text("This clears learned memory, recent behavior context, chat history, and usage context. Your profiles and settings will also reset to defaults.")
                }

                Button {
                    dismiss()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        NSApp.terminate(nil)
                    }
                } label: {
                    Text("quit AccountyCat")
                        .font(.ac(11, weight: .medium))
                        .foregroundStyle(Color.acTextPrimary.opacity(0.6))
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
            }
        }
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
            .font(.ac(11, weight: .semibold))
            .foregroundStyle(Color.acTextPrimary.opacity(0.7))
            .textCase(.lowercase)
    }
}

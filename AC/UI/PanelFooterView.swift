//
//  PanelFooterView.swift
//  AC
//
//  Always-visible footer below chat: status dot, model name, last-check ago,
//  and pause/resume toggle.
//

import SwiftUI

struct PanelFooterView: View {
    @EnvironmentObject private var controller: AppController

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(controller.state.isPaused ? Color.secondary.opacity(0.4) : Color.acOkGreen)
                .frame(width: 6, height: 6)

            Text(statusLine)
                .font(.system(size: 9.5, weight: .regular, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(0)

            modelMenu

            if let scope = scopeLabel {
                Button {
                    openSettings(tab: .you)
                    // After the tab swaps in, scroll straight to the app-scope section.
                    DispatchQueue.main.async {
                        NotificationCenter.default.post(
                            name: .acScrollToSettingsAnchor,
                            object: YouTab.appScopeAnchor
                        )
                    }
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "app.dashed")
                            .font(.system(size: 9, weight: .semibold))
                        Text(scope)
                            .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule(style: .continuous)
                            .stroke(Color.acHairline, lineWidth: 1)
                    )
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .fixedSize()
                .help("AC monitoring is limited to certain apps — tap to manage")
            }

            Button {
                controller.togglePause()
            } label: {
                Text(controller.state.isPaused ? "▶ resume" : "⏸ pause")
                    .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .fixedSize()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(
            Color(nsColor: NSColor(name: nil) { appearance in
                appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                    ? NSColor(white: 0.12, alpha: 0.45)
                    : NSColor(white: 1.0, alpha: 0.35)
            })
        )
    }

    private var statusLine: String {
        let assessment = controller.state.algorithmState.llmPolicy.distraction.lastAssessment?.rawValue ?? "observing"
        let lastCheck = controller.lastMonitoringCheckAt.map { timeAgo($0) } ?? "—"
        return "\(assessment) · \(lastCheck)"
    }

    /// Deep-links into a specific Settings tab: stash the target on the controller
    /// (SettingsView reads it on appear) then post the open notification so the panel
    /// swaps from chat to Settings.
    private func openSettings(tab: SettingsTab) {
        controller.pendingSettingsTab = tab
        NotificationCenter.default.post(
            name: .acSelectSettingsTab,
            object: tab.rawValue
        )
    }

    // MARK: - Model quick-switch

    /// Tap the model name (bottom right) to switch models on the spot — mirrors the
    /// partner quick-swap in the header. Lists installed local models (or the BYOK
    /// tiers when online) plus a shortcut into AI settings to download/manage more.
    /// The active model name, capped so a long custom name can't crowd the footer.
    /// The full name is always available in the menu itself.
    private var modelChipLabel: String {
        let full = controller.activeModelFooterLabel
        let limit = 24
        guard full.count > limit else { return full }
        return String(full.prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }

    private var modelMenu: some View {
        Menu {
            if controller.state.monitoringConfiguration.usesOnlineInference {
                ForEach(AITier.allCases, id: \.self) { tier in
                    Button {
                        controller.updateAITier(tier)
                    } label: {
                        let active = controller.currentAITier == tier
                        Text(active ? "✓ \(tier.displayName)" : tier.displayName)
                    }
                }
            } else {
                let options = localModelOptions
                ForEach(options) { option in
                    Button {
                        controller.selectInstalledLocalModel(identifier: option.id, tier: option.tier)
                    } label: {
                        Text(option.active ? "✓ \(option.label)" : option.label)
                    }
                }
                if options.isEmpty {
                    Text("No models downloaded yet")
                }
            }
            Divider()
            Button("Manage models…") {
                openSettings(tab: .ai)
            }
        } label: {
            HStack(spacing: 2) {
                Text(modelChipLabel)
                    .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .semibold))
            }
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .tint(.secondary)
        .fixedSize()
        .help("Switch AI model")
    }

    private struct FooterModelOption: Identifiable {
        let id: String
        let label: String
        let tier: AITier?
        let active: Bool
    }

    /// Installed local models offered in the quick-switch menu: built-in tiers that
    /// are downloaded, then the user's custom models, each shown by friendly name.
    private var localModelOptions: [FooterModelOption] {
        let active = controller.activeLocalModelIdentifier()
        var options: [FooterModelOption] = []
        for tier in AITier.allCases where controller.localModelInstalled(tier.localModelIdentifierText) {
            options.append(FooterModelOption(
                id: tier.localModelIdentifierText,
                label: "\(tier.displayName) · \(tier.localModelDisplayName)",
                tier: tier,
                active: tier.localModelIdentifierText == active
            ))
        }
        for model in controller.state.localCustomModels
        where controller.localModelInstalled(model.modelIdentifier) {
            options.append(FooterModelOption(
                id: model.modelIdentifier,
                label: model.displayName,
                tier: nil,
                active: model.modelIdentifier == active
            ))
        }
        return options
    }

    private var scopeLabel: String? {
        let mode = controller.state.appMonitoringScopeMode
        let count = controller.state.activeAppMonitoringSelections.count
        guard mode != .disabled, count > 0 else { return nil }
        switch mode {
        case .allowlist: return count == 1 ? "1 app only" : "\(count) apps only"
        case .blocklist: return "skipping \(count)"
        case .disabled: return nil
        }
    }

    private func timeAgo(_ date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        if interval < 60 {
            return "\(Int(interval))s"
        } else if interval < 3600 {
            return "\(Int(interval / 60))m"
        } else {
            return "\(Int(interval / 3600))h"
        }
    }
}

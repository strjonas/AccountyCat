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

            if let scope = scopeLabel {
                Button {
                    NotificationCenter.default.post(
                        name: .acSelectSettingsTab,
                        object: SettingsTab.you.rawValue
                    )
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
        let model = controller.activeModelShortName
        let assessment = controller.state.algorithmState.llmPolicy.distraction.lastAssessment?.rawValue ?? "observing"
        let lastCheck = controller.lastMonitoringCheckAt.map { timeAgo($0) } ?? "—"
        return "\(assessment) · \(model) · \(lastCheck)"
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

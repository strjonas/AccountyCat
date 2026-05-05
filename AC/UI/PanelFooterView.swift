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
        HStack(spacing: 6) {
            HStack(spacing: 6) {
                Circle()
                    .fill(controller.state.isPaused ? Color.secondary.opacity(0.4) : Color.acOkGreen)
                    .frame(width: 6, height: 6)

                Text(statusLine)
                    .font(.system(size: 9.5, weight: .regular, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                controller.togglePause()
            } label: {
                Text(controller.state.isPaused ? "▶ resume" : "⏸ pause")
                    .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
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
        return "\(assessment) · \(model) · last check: \(lastCheck)"
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

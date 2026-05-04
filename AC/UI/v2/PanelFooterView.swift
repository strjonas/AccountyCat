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
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var statusLine: String {
        let state = controller.state.isPaused ? "paused" : "watching"
        let model = controller.activeModelShortName
        // Placeholder for "38s ago" — we don't track last check timestamp in UI currently
        return "\(state) · \(model)"
    }
}

//
//  SettingsView.swift
//  AC
//
//  6-tab settings embedded in the main panel.
//  Tabs: look · profiles · ai · controls · persona · you
//

import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var controller: AppController
    @Environment(\.dismiss) private var dismiss
    @Environment(\.acAccent) private var accent
    @Environment(\.acAccentLight) private var accentLight

    var embeddedInPanel = false
    @State private var selectedTab: SettingsTab = .look

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !embeddedInPanel {
                header
            }
            tabBar
            Divider().opacity(0.3)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    switch selectedTab {
                    case .look:     LookTab()
                    case .profiles: ProfilesTab()
                    case .ai:       AITab()
                    case .controls: ControlsTab()
                    case .persona:  PersonaTab()
                    case .you:      YouTab()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
        }
        .frame(width: embeddedInPanel ? nil : ACD.popoverWidth)
        .background(embeddedInPanel ? Color.clear : Color(nsColor: .windowBackgroundColor))
        .onReceive(NotificationCenter.default.publisher(for: .acSelectSettingsTab)) { notification in
            if let raw = notification.object as? String,
               let tab = SettingsTab(rawValue: raw) {
                withAnimation(.acSnap) { selectedTab = tab }
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Text("SETTINGS")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .tracking(0.06)
                .foregroundStyle(Color.acTextPrimary.opacity(0.45))
                .textCase(.uppercase)
            Spacer()
            Button {
                dismiss()
            } label: {
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
                colors: [accentLight.opacity(0.72), accent.opacity(0.10)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
    }

    // MARK: - Tab bar

    private var tabBar: some View {
        HStack(spacing: 8) {
            ForEach(SettingsTab.allCases, id: \.self) { tab in
                Button {
                    withAnimation(.acSnap) { selectedTab = tab }
                } label: {
                    Text(tab.rawValue)
                        .font(.ac(11, weight: selectedTab == tab ? .semibold : .medium))
                        .foregroundStyle(selectedTab == tab ? accent : Color.acTextPrimary.opacity(0.55))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                        .background(
                            Capsule(style: .continuous)
                                .fill(selectedTab == tab ? accent.opacity(0.11) : Color.clear)
                                .overlay(
                                    Capsule(style: .continuous)
                                        .stroke(selectedTab == tab ? accent.opacity(0.28) : Color.clear, lineWidth: 0.5)
                                )
                        )
                }
                .buttonStyle(.plain)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
    }
}

// MARK: - Tabs

enum SettingsTab: String, CaseIterable {
    case look     = "look"
    case profiles = "profiles"
    case ai       = "ai"
    case controls = "controls"
    case persona  = "persona"
    case you      = "you"
}

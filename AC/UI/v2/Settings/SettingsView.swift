//
//  SettingsView.swift
//  AC
//
//  New 6-tab settings sheet replacing SettingsSheet.
//  Tabs: look · profiles · ai · nudges · persona · you
//

import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var controller: AppController
    @Environment(\.dismiss) private var dismiss
    @Environment(\.acAccent) private var accent

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
                    case .nudges:   NudgesTab()
                    case .persona:  PersonaTab()
                    case .you:      YouTab()
                    }
                }
                .padding(20)
            }
        }
        .frame(width: embeddedInPanel ? nil : ACD.popoverWidth)
        .background(embeddedInPanel ? Color.clear : Color(nsColor: .windowBackgroundColor))
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
                colors: [controller.state.character.headerLightTop, controller.state.character.headerLightBottom],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
    }

    // MARK: - Tab bar

    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(SettingsTab.allCases, id: \.self) { tab in
                Button {
                    withAnimation(.acSnap) { selectedTab = tab }
                } label: {
                    Text(tab.rawValue)
                        .font(.ac(11, weight: selectedTab == tab ? .semibold : .medium))
                        .foregroundStyle(selectedTab == tab ? accent : Color.acTextPrimary.opacity(0.55))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                        .overlay(
                            Rectangle()
                                .fill(selectedTab == tab ? accent : Color.clear)
                                .frame(height: 3)
                                .offset(y: 13),
                            alignment: .bottom
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 6)
    }
}

// MARK: - Tabs

private enum SettingsTab: String, CaseIterable {
    case look     = "look"
    case profiles = "profiles"
    case ai       = "ai"
    case nudges   = "nudges"
    case persona  = "persona"
    case you      = "you"
}

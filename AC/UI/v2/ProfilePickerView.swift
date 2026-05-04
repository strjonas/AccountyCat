//
//  ProfilePickerView.swift
//  AC
//
//  In-panel profile picker matching the reference: everyday first, duration
//  chips for named profiles, and a single start CTA.
//

import SwiftUI

struct ProfilePickerView: View {
    @EnvironmentObject private var controller: AppController
    @Environment(\.acAccent) private var accent

    @Binding var isPresented: Bool
    @State private var selectedProfileID: String?
    @State private var selectedDuration = 60

    private var profiles: [FocusProfile] {
        controller.state.profiles.sorted { lhs, rhs in
            if lhs.isDefault != rhs.isDefault { return lhs.isDefault }
            return lhs.lastUsedAt > rhs.lastUsedAt
        }
    }

    private var selectedProfile: FocusProfile {
        let id = selectedProfileID ?? profiles.first?.id ?? PolicyRule.defaultProfileID
        return controller.state.profile(withID: id) ?? FocusProfile.makeDefault()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("pick a focus")
                    .font(.ac(12, weight: .semibold))
                    .foregroundStyle(Color.acTextPrimary.opacity(0.72))
                Spacer()
                Button {
                    withAnimation(.acSnap) { isPresented = false }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            VStack(spacing: 6) {
                ForEach(profiles) { profile in
                    profileRow(profile)
                }
            }

            if !selectedProfile.isDefault {
                HStack(spacing: 6) {
                    ForEach([25, 45, 60, 90], id: \.self) { minutes in
                        durationChip(minutes)
                    }
                    Spacer()
                }
            }

            Button {
                startSelectedProfile()
            } label: {
                HStack {
                    Text(selectedProfile.isDefault ? "use everyday mode" : "start \(selectedProfile.name) →")
                    Spacer()
                }
            }
            .buttonStyle(ACPrimaryButton())
        }
        .padding(14)
        .frame(width: 342)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor).opacity(0.92))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.white.opacity(0.55), lineWidth: 0.5)
                )
                .shadow(color: Color.black.opacity(0.18), radius: 22, y: 12)
        )
        .onAppear {
            selectedProfileID = controller.state.activeProfileID
            selectedDuration = selectedProfile.defaultDurationMin ?? 60
        }
    }

    private func profileRow(_ profile: FocusProfile) -> some View {
        let color = Color(acHexString: profile.color) ?? accent
        let selected = profile.id == (selectedProfileID ?? controller.state.activeProfileID)
        return Button {
            withAnimation(.acSnap) {
                selectedProfileID = profile.id
                selectedDuration = profile.defaultDurationMin ?? selectedDuration
            }
        } label: {
            HStack(spacing: 10) {
                Text(profile.emoji)
                    .font(.system(size: 15))
                    .foregroundStyle(color)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(color.opacity(0.14)))

                VStack(alignment: .leading, spacing: 2) {
                    Text(profile.isDefault ? "everyday" : profile.name)
                        .font(.ac(12, weight: .semibold))
                        .foregroundStyle(Color.acTextPrimary)
                    Text(profile.description ?? (profile.isDefault ? "passive watching, no timer" : "focused session"))
                        .font(.ac(10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                if controller.state.activeProfileID == profile.id {
                    Text("active")
                        .font(.ac(9, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule(style: .continuous).fill(color))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(selected ? color.opacity(0.10) : Color.acSurface)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(selected ? color.opacity(0.36) : Color.acHairline, lineWidth: 0.5)
                    )
            )
        }
        .buttonStyle(.plain)
    }

    private func durationChip(_ minutes: Int) -> some View {
        let selected = selectedDuration == minutes
        return Button {
            withAnimation(.acSnap) { selectedDuration = minutes }
        } label: {
            Text(minutes < 60 ? "\(minutes)m" : minutes == 60 ? "1h" : "\(minutes / 60)h")
                .font(.ac(11, weight: selected ? .semibold : .medium))
                .foregroundStyle(selected ? Color.white : Color.acTextPrimary.opacity(0.72))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    Capsule(style: .continuous)
                        .fill(selected ? accent.opacity(0.86) : Color.acSurface)
                        .overlay(Capsule(style: .continuous).stroke(selected ? Color.clear : Color.acHairline, lineWidth: 0.5))
                )
        }
        .buttonStyle(.plain)
    }

    private func startSelectedProfile() {
        if selectedProfile.isDefault {
            _ = controller.activateProfile(id: selectedProfile.id, announce: true)
        } else {
            _ = controller.activateProfile(id: selectedProfile.id, durationMinutes: selectedDuration, announce: true)
        }
        withAnimation(.acSnap) { isPresented = false }
    }
}

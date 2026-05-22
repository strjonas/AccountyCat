//
//  ProfilePickerView.swift
//  AC
//
//  Inline content view (not an overlay) so clicks are never stolen by the
//  chat scroll view. Flow: tap row → duration chips for named profiles → start.
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
        VStack(alignment: .leading, spacing: 0) {
            header

            ScrollView {
                VStack(spacing: 8) {
                    ForEach(profiles) { profile in
                        profileRow(profile)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }

            footer
        }
        .onAppear { resetSelection() }
        .onChange(of: isPresented) { _, presented in
            if presented { resetSelection() }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Button {
                withAnimation(.acSnap) { isPresented = false }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.acTextPrimary.opacity(0.6))
            }
            .buttonStyle(.plain)

            Text("pick a focus")
                .font(.ac(13, weight: .semibold))
                .foregroundStyle(Color.acTextPrimary)

            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    // MARK: - Footer (duration + start)

    private var footer: some View {
        VStack(spacing: 10) {
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
                    Spacer()
                    Text(startLabel)
                    Spacer()
                }
            }
            .buttonStyle(ACPrimaryButton())
            .disabled(isAlreadyActive)
            .opacity(isAlreadyActive ? 0.5 : 1)
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 14)
        .background(
            Rectangle()
                .fill(Color.acSurface.opacity(0.4))
                .overlay(alignment: .top) {
                    Rectangle().fill(Color.acHairline).frame(height: 0.5)
                }
        )
    }

    private var isAlreadyActive: Bool {
        controller.state.activeProfileID == selectedProfile.id
    }

    private var startLabel: String {
        if isAlreadyActive { return "already active" }
        if selectedProfile.isDefault { return "switch to everyday" }
        return "start \(selectedProfile.name)  ·  \(chipLabel(for: selectedDuration))"
    }

    // MARK: - Profile row

    private func profileRow(_ profile: FocusProfile) -> some View {
        let color = Color(acHexString: profile.color) ?? accent
        let selected = profile.id == selectedProfile.id

        return Button {
            withAnimation(.acSnap) {
                selectedProfileID = profile.id
                if !profile.isDefault {
                    selectedDuration = profile.defaultDurationMin ?? selectedDuration
                }
            }
        } label: {
            HStack(spacing: 11) {
                Text(profile.emoji.isEmpty ? (profile.isDefault ? "☀️" : "🎯") : profile.emoji)
                    .font(.system(size: 16))
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(color.opacity(0.16)))

                VStack(alignment: .leading, spacing: 2) {
                    Text(profile.isDefault ? "everyday" : profile.name)
                        .font(.ac(13, weight: .semibold))
                        .foregroundStyle(Color.acTextPrimary)
                    Text(profile.description ?? (profile.isDefault ? "passive watching, no timer" : "focused session"))
                        .font(.ac(11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                if controller.state.activeProfileID == profile.id {
                    Text("active")
                        .font(.ac(9, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule(style: .continuous).fill(color))
                } else if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(color)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(selected ? color.opacity(0.12) : Color.acSurface)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(selected ? color.opacity(0.45) : Color.acHairline, lineWidth: selected ? 1 : 0.5)
                    )
            )
        }
        .buttonStyle(.plain)
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: - Duration chip

    private func durationChip(_ minutes: Int) -> some View {
        let selected = selectedDuration == minutes
        return Button {
            withAnimation(.acSnap) { selectedDuration = minutes }
        } label: {
            Text(chipLabel(for: minutes))
                .font(.ac(11, weight: selected ? .semibold : .medium))
                .foregroundStyle(selected ? Color.white : Color.acTextPrimary.opacity(0.72))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    Capsule(style: .continuous)
                        .fill(selected ? accent.opacity(0.9) : Color.acSurface)
                        .overlay(Capsule(style: .continuous).stroke(selected ? Color.clear : Color.acHairline, lineWidth: 0.5))
                )
        }
        .buttonStyle(.plain)
        .contentShape(Capsule(style: .continuous))
    }

    private func chipLabel(for minutes: Int) -> String {
        if minutes < 60 { return "\(minutes)m" }
        if minutes == 60 { return "1h" }
        let hours = minutes / 60
        let mins = minutes % 60
        return mins == 0 ? "\(hours)h" : "\(hours)h \(mins)m"
    }

    // MARK: - Actions

    private func startSelectedProfile() {
        guard !isAlreadyActive else {
            withAnimation(.acSnap) { isPresented = false }
            return
        }
        if selectedProfile.isDefault {
            _ = controller.activateProfile(id: selectedProfile.id, announce: true)
        } else {
            _ = controller.activateProfile(id: selectedProfile.id, durationMinutes: selectedDuration, announce: true)
        }
        withAnimation(.acSnap) { isPresented = false }
    }

    private func resetSelection() {
        selectedProfileID = controller.state.activeProfileID
        selectedDuration = selectedProfile.defaultDurationMin ?? 60
    }
}

//
//  ProfileQuickPopoverView.swift
//  AC
//
//  Dedicated profile control surface used from the menu bar status item and
//  the in-popover profile chip. Supports explicit timer selection before a
//  switch, richer extension controls, and a direct path to the full app.
//

import Combine
import SwiftUI

private enum ProfileSessionDurationChoice: String, CaseIterable, Identifiable {
    case thirty
    case sixty
    case ninety
    case oneTwenty
    case custom

    var id: String { rawValue }

    var minutes: Int? {
        switch self {
        case .thirty: return 30
        case .sixty: return 60
        case .ninety: return 90
        case .oneTwenty: return 120
        case .custom: return nil
        }
    }

    var label: String {
        switch self {
        case .thirty: return "30m"
        case .sixty: return "1h"
        case .ninety: return "90m"
        case .oneTwenty: return "2h"
        case .custom: return "Custom"
        }
    }
}

struct ProfileQuickPopoverView: View {
    private static let tickPublisher = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    @EnvironmentObject private var controller: AppController
    @Environment(\.acAccent) private var accent
    @Environment(\.acAccentSoft) private var accentSoft
    @Environment(\.colorScheme) private var colorScheme

    let showOpenAppButton: Bool

    @State private var selectedDuration: ProfileSessionDurationChoice = .ninety
    @State private var customMinutesText = ""
    @State private var nowTick = Date()
    @State private var startingProfileID: String? = nil

    private var active: FocusProfile { controller.state.activeProfile }
    private var switchableProfiles: [FocusProfile] {
        controller.state.profiles
            .filter { $0.id != active.id }
            .sorted { lhs, rhs in
                if lhs.isDefault != rhs.isDefault { return lhs.isDefault }
                return lhs.lastUsedAt > rhs.lastUsedAt
            }
    }
    private var selectedMinutes: Int? {
        if let preset = selectedDuration.minutes {
            return preset
        }
        guard let value = Int(customMinutesText.trimmingCharacters(in: .whitespacesAndNewlines)),
              (5...720).contains(value) else {
            return nil
        }
        return value
    }
    private var selectedDurationLabel: String {
        if let minutes = selectedMinutes {
            if minutes % 60 == 0 {
                return "\(minutes / 60)h"
            }
            return "\(minutes)m"
        }
        return "custom time"
    }
    private var currentStatusLine: String {
        if active.isDefault {
            return "General mode is active."
        }
        if let expiresAt = active.expiresAt {
            return "Ends at \(timeLabel(expiresAt)) · \(remainingText(until: expiresAt)) left"
        }
        return "No timer set."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            headerCard
            actionRow
            if !active.isDefault {
                extendSection
            }
            savedProfilesSection
            if showOpenAppButton {
                Divider()
                footerRow
            }
        }
        .padding(16)
        .frame(width: 336)
        .background(
            RoundedRectangle(cornerRadius: ACRadius.lg, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor))
        )
        .onReceive(Self.tickPublisher) { date in
            nowTick = date
        }
    }

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: active.isDefault ? "circle.hexagongrid" : "scope")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(accent)
                Text(active.name)
                    .font(.ac(15, weight: .semibold))
                    .foregroundStyle(Color.acTextPrimary)
                Spacer(minLength: 0)
                if !active.isDefault {
                    Button("End") {
                        controller.endActiveProfile(announce: true)
                        controller.markAllChatMessagesRead()
                    }
                    .buttonStyle(ACDangerButton())
                }
            }

            Text(currentStatusLine)
                .font(.ac(11))
                .foregroundStyle(.secondary)

            if active.isDefault {
                Text("Pick a profile below to start a timed session.")
                    .font(.ac(11))
                    .foregroundStyle(.secondary)
            } else if let description = active.description?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !description.isEmpty {
                Text(description)
                    .font(.ac(11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }

    private var actionRow: some View {
        EmptyView()
    }

    private var extendSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Current session")
                .font(.ac(12, weight: .semibold))
                .foregroundStyle(Color.acTextPrimary)

            HStack(spacing: 8) {
                Button("Add \(selectedDurationLabel)") {
                    guard let minutes = selectedMinutes else { return }
                    _ = controller.extendActiveProfile(
                        byMinutes: minutes,
                        announce: true
                    )
                    controller.markAllChatMessagesRead()
                }
                .buttonStyle(ACPrimaryButton())
                .disabled(selectedMinutes == nil)

                if let expiresAt = active.expiresAt {
                    Text("Now ending \(timeLabel(expiresAt))")
                        .font(.ac(11))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var savedProfilesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Saved profiles")
                .font(.ac(12, weight: .semibold))
                .foregroundStyle(Color.acTextPrimary)

            if switchableProfiles.isEmpty {
                Text("No other saved profiles yet. Tell AC “help me focus on coding for 2 hours” to create one.")
                    .font(.ac(11))
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 8) {
                    ForEach(switchableProfiles, id: \.id) { profile in
                        profileRow(for: profile)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func profileRow(for profile: FocusProfile) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(profile.name)
                        .font(.ac(12, weight: .semibold))
                        .foregroundStyle(Color.acTextPrimary)
                    Text(profileRowSubtitle(for: profile))
                        .font(.ac(10))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer(minLength: 10)

                if profile.isDefault {
                    Button("Switch") {
                        _ = controller.activateProfile(
                            id: profile.id,
                            reason: "user_switched",
                            announce: true
                        )
                        controller.markAllChatMessagesRead()
                    }
                    .buttonStyle(ACSecondaryButton())
                } else if startingProfileID == profile.id {
                    Button("Cancel") {
                        startingProfileID = nil
                    }
                    .buttonStyle(ACSecondaryButton())
                } else {
                    Button("Start") {
                        startingProfileID = profile.id
                    }
                    .buttonStyle(ACPrimaryButton())
                }
            }
            .padding(12)

            if startingProfileID == profile.id {
                inlineDurationPicker(profileID: profile.id)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(
            RoundedRectangle(cornerRadius: ACRadius.md, style: .continuous)
                .fill(Color.acSurface.opacity(0.92))
                .overlay(
                    RoundedRectangle(cornerRadius: ACRadius.md, style: .continuous)
                        .stroke(Color.acHairline, lineWidth: 1)
                )
        )
    }

    private func inlineDurationPicker(profileID: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 60), spacing: 6, alignment: .leading)],
                alignment: .leading,
                spacing: 6
            ) {
                ForEach(ProfileSessionDurationChoice.allCases) { option in
                    Button {
                        selectedDuration = option
                    } label: {
                        Text(option.label)
                            .font(.ac(10, weight: .semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(selectedDuration == option ? accent.opacity(0.18) : Color.acSurface)
                                    .overlay(
                                        Capsule(style: .continuous)
                                            .stroke(selectedDuration == option ? accent.opacity(0.55) : Color.acHairline, lineWidth: 1)
                                    )
                            )
                    }
                    .buttonStyle(.plain)
                }
            }

            if selectedDuration == .custom {
                TextField("Custom minutes (5-720)", text: $customMinutesText)
                    .textFieldStyle(.roundedBorder)
                    .font(.ac(11))
            }

            HStack {
                if selectedMinutes == nil {
                    Text("Choose a duration")
                        .font(.ac(10))
                        .foregroundStyle(Color.orange.opacity(0.88))
                }
                Spacer()
                Button("Start session") {
                    guard let minutes = selectedMinutes else { return }
                    _ = controller.activateProfile(
                        id: profileID,
                        durationMinutes: minutes,
                        reason: "user_switched",
                        announce: true
                    )
                    startingProfileID = nil
                    controller.markAllChatMessagesRead()
                }
                .buttonStyle(ACPrimaryButton())
                .disabled(selectedMinutes == nil)
            }
        }
    }

    private var footerRow: some View {
        HStack(spacing: 8) {
            Button("Open AccountyCat") {
                controller.openMainPopover?()
            }
            .buttonStyle(ACSecondaryButton())

            Spacer(minLength: 0)

            if controller.hasUnreadChatMessages {
                Text("Chat has a new note")
                    .font(.ac(10))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func profileRowSubtitle(for profile: FocusProfile) -> String {
        if profile.isDefault {
            return "Switch back to everyday mode."
        }
        if let description = profile.description?.trimmingCharacters(in: .whitespacesAndNewlines),
           !description.isEmpty {
            return description
        }
        return "Reuse this profile with a fresh timer."
    }

    private func remainingText(until date: Date) -> String {
        let minutes = Int(max(0, date.timeIntervalSince(nowTick)) / 60)
        if minutes >= 60 {
            let hours = minutes / 60
            let leftover = minutes % 60
            return leftover == 0 ? "\(hours)h" : "\(hours)h \(leftover)m"
        }
        return "\(max(1, minutes))m"
    }

    private func timeLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}

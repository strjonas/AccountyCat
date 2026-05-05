//
//  ProfileQuickPopoverView.swift
//  AC
//
//  Quick profile control surface — opened from the menu bar status item.
//  Redesigned to match the v2 panel aesthetic.
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
    private static let tickPublisher = Timer.publish(every: 30, on: .main, in: .common)
        .autoconnect()

    @EnvironmentObject private var controller: AppController
    @Environment(\.acAccent) private var accent
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
            (5...720).contains(value)
        else {
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
            if !active.isDefault {
                extendSection
            }
            savedProfilesSection
            bottomActions
            if showOpenAppButton {
                Divider().opacity(0.3)
                footerRow
            }
        }
        .padding(16)
        .frame(width: 336)
        .background(popoverBackground)
        .onReceive(Self.tickPublisher) { date in
            nowTick = date
        }
    }

    // MARK: - Background

    private var popoverBackground: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
            LinearGradient(
                colors: [
                    accent.opacity(colorScheme == .dark ? 0.06 : 0.10),
                    Color.clear
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            LinearGradient(
                colors: [
                    Color.white.opacity(colorScheme == .dark ? 0.06 : 0.20),
                    Color.clear
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }

    // MARK: - Header

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: active.isDefault ? "circle.hexagongrid" : "scope")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(active.isDefault ? accent : active.swiftUIColor)
                Text(active.name)
                    .font(.ac(15, weight: .semibold))
                    .foregroundStyle(Color.acTextPrimary)
                Spacer(minLength: 0)
                if !active.isDefault {
                    Button("end") {
                        controller.endActiveProfile(announce: true)
                        controller.markAllChatMessagesRead()
                    }
                    .buttonStyle(QuickPopoverDangerButton())
                }
            }

            Text(currentStatusLine)
                .font(.ac(11))
                .foregroundStyle(.secondary)

            if active.isDefault {
                Text("Pick a profile below to start a timed session.")
                    .font(.ac(11))
                    .foregroundStyle(.secondary)
            } else if let description = active.description?.trimmingCharacters(
                in: .whitespacesAndNewlines),
                !description.isEmpty
            {
                Text(description)
                    .font(.ac(11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: ACRadius.md, style: .continuous)
                .fill(active.isDefault ? Color.acSurface.opacity(0.92) : active.swiftUIColor.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: ACRadius.md, style: .continuous)
                        .stroke(active.isDefault ? Color.acHairline : active.swiftUIColor.opacity(0.20), lineWidth: 1)
                )
        )
    }

    // MARK: - Extend

    private var extendSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("CURRENT SESSION")
                .font(.system(size: 9.5, weight: .bold, design: .rounded))
                .tracking(0.08)
                .foregroundStyle(Color.acTextPrimary.opacity(0.42))

            HStack(spacing: 8) {
                Button("Add \(selectedDurationLabel)") {
                    guard let minutes = selectedMinutes else { return }
                    _ = controller.extendActiveProfile(
                        byMinutes: minutes,
                        announce: true
                    )
                    controller.markAllChatMessagesRead()
                }
                .buttonStyle(QuickPopoverPrimaryButton())
                .disabled(selectedMinutes == nil)

                if let expiresAt = active.expiresAt {
                    Text("Now ending \(timeLabel(expiresAt))")
                        .font(.ac(11))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Saved profiles

    private var savedProfilesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("SAVED PROFILES")
                .font(.system(size: 9.5, weight: .bold, design: .rounded))
                .tracking(0.08)
                .foregroundStyle(Color.acTextPrimary.opacity(0.42))

            if switchableProfiles.isEmpty {
                Text(
                    "No other saved profiles yet. Tell AC “help me focus on coding for 2 hours” to create one."
                )
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
                    .buttonStyle(QuickPopoverQuietButton())
                } else if startingProfileID == profile.id {
                    Button("Cancel") {
                        startingProfileID = nil
                    }
                    .buttonStyle(QuickPopoverQuietButton())
                } else {
                    Button("Start") {
                        startingProfileID = profile.id
                    }
                    .buttonStyle(QuickPopoverPrimaryButton())
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
                                    .fill(
                                        selectedDuration == option
                                            ? accent.opacity(0.18) : Color.acSurface
                                    )
                                    .overlay(
                                        Capsule(style: .continuous)
                                            .stroke(
                                                selectedDuration == option
                                                    ? accent.opacity(0.55) : Color.acHairline,
                                                lineWidth: 1)
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
                .buttonStyle(QuickPopoverPrimaryButton())
                .disabled(selectedMinutes == nil)
            }
        }
    }

    private var bottomActions: some View {
        HStack(spacing: 8) {
            Button {
                controller.openMainPopover?()
                NotificationCenter.default.post(name: .acOpenSettings, object: nil)
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Settings")
                        .font(.ac(11, weight: .medium))
                }
                .foregroundStyle(accent.opacity(0.85))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    Capsule(style: .continuous)
                        .fill(Color.acSurface)
                        .overlay(Capsule(style: .continuous).stroke(Color.acHairline, lineWidth: 1))
                )
            }
            .buttonStyle(.plain)

            Spacer(minLength: 0)
        }
    }

    private var footerRow: some View {
        HStack(spacing: 8) {
            Button("Open AccountyCat") {
                controller.openMainPopover?()
            }
            .buttonStyle(QuickPopoverQuietButton())

            Spacer(minLength: 0)

            if controller.hasUnreadChatMessages {
                HStack(spacing: 4) {
                    Circle()
                        .fill(accent)
                        .frame(width: 6, height: 6)
                    Text("New note")
                        .font(.ac(10))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func profileRowSubtitle(for profile: FocusProfile) -> String {
        if profile.isDefault {
            return "Switch back to everyday mode."
        }
        if let description = profile.description?.trimmingCharacters(in: .whitespacesAndNewlines),
            !description.isEmpty
        {
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

// MARK: - Button styles

private struct QuickPopoverPrimaryButton: ButtonStyle {
    @Environment(\.acAccent) private var accent

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.ac(12, weight: .semibold))
            .foregroundStyle(Color.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                Capsule(style: .continuous)
                    .fill(accent.opacity(configuration.isPressed ? 0.76 : 0.92))
                    .overlay(Capsule(style: .continuous).stroke(Color.acBubbleStroke, lineWidth: 0.5))
                    .shadow(color: accent.opacity(0.22), radius: 6, y: 2)
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.acSnap, value: configuration.isPressed)
    }
}

private struct QuickPopoverQuietButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.ac(12, weight: .medium))
            .foregroundStyle(Color.acTextPrimary.opacity(0.85))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.acSurfaceElevated)
                    .overlay(Capsule(style: .continuous).stroke(Color.acHairline, lineWidth: 1))
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.acSnap, value: configuration.isPressed)
    }
}

private struct QuickPopoverDangerButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.ac(12, weight: .semibold))
            .foregroundStyle(Color.acRedEnd.opacity(0.85))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.red.opacity(0.08))
                    .overlay(Capsule(style: .continuous).stroke(Color.red.opacity(0.20), lineWidth: 1))
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.acSnap, value: configuration.isPressed)
    }
}

private extension FocusProfile {
    var swiftUIColor: Color {
        Color(acHexString: color) ?? Color.acProfileEveryday
    }
}

//
//  CalendarIntelligenceSection.swift
//  AC
//
//  Opt-in calendar integration toggle + permission prompt + calendar picker.
//  Extracted from the old ContentView for reuse across settings tabs.
//

import SwiftUI

struct CalendarIntelligenceSection: View {
    @EnvironmentObject private var controller: AppController
    @Environment(\.acAccent) private var accent
    @State private var hoveringInfo = false
    @State private var calendarListExpanded = false

    private var isOn: Bool { controller.state.calendarIntelligenceEnabled }
    private var calendarGranted: Bool { controller.state.permissions.calendar == .granted }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(
                isOn: Binding(
                    get: { isOn },
                    set: { controller.setCalendarIntelligence(enabled: $0) }
                )
            ) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text("Use my calendar")
                            .font(.ac(13, weight: .medium))
                            .foregroundStyle(Color.acTextPrimary)
                        Image(systemName: "info.circle")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .help(
                                """
                                Let AC read your current calendar event to infer what you want \
                                to focus on — so it stays out of the way with less effort \
                                from you. Works with any calendar already in Apple Calendar \
                                (iCloud, Google, Exchange, Fastmail, …). Events are read \
                                locally and never leave your Mac.
                                """
                            )
                            .onHover { hoveringInfo = $0 }
                            .opacity(hoveringInfo ? 1.0 : 0.75)
                    }
                    Text("Read-only. Never leaves your Mac.")
                        .font(.ac(11))
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
            .tint(accent)

            if isOn {
                if calendarGranted {
                    calendarPicker
                } else {
                    permissionPrompt
                }
            }
        }
        .onAppear {
            if isOn && calendarGranted {
                controller.refreshAvailableCalendars()
            }
        }
    }

    private var permissionPrompt: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(
                "Calendar access is required. If you denied it earlier, re-enable it in System Settings → Privacy & Security → Calendars."
            )
            .font(.ac(11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Button("Request access") {
                    controller.setCalendarIntelligence(enabled: false)
                    controller.setCalendarIntelligence(enabled: true)
                }
                .buttonStyle(ACSecondaryButton())

                Button("Open System Settings") {
                    if let url = URL(
                        string:
                            "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars"
                    ) {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(ACSecondaryButton())
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: ACRadius.sm, style: .continuous)
                .fill(Color.acSurface.opacity(0.65))
                .overlay(
                    RoundedRectangle(cornerRadius: ACRadius.sm, style: .continuous)
                        .stroke(Color.acHairline.opacity(0.65), lineWidth: 0.5)
                )
        )
    }

    @ViewBuilder
    private var calendarPicker: some View {
        if controller.availableCalendars.isEmpty {
            HStack(spacing: 8) {
                Text("No calendars found in Apple Calendar.")
                    .font(.ac(11))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Refresh") { controller.refreshAvailableCalendars() }
                    .buttonStyle(ACSecondaryButton())
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: ACRadius.sm, style: .continuous)
                    .fill(Color.acSurface.opacity(0.65))
                    .overlay(
                        RoundedRectangle(cornerRadius: ACRadius.sm, style: .continuous)
                            .stroke(Color.acHairline.opacity(0.65), lineWidth: 0.5)
                    )
            )
        } else {
            let enabledCount = controller.availableCalendars.filter {
                controller.isCalendarEnabled($0.id)
            }.count
            VStack(alignment: .leading, spacing: 0) {
                Button {
                    withAnimation(.acSnap) { calendarListExpanded.toggle() }
                } label: {
                    HStack(spacing: 8) {
                        Text("Calendars")
                            .font(.ac(11, weight: .semibold))
                            .foregroundStyle(Color.acTextPrimary.opacity(0.55))
                        Spacer()
                        Text("\(enabledCount) of \(controller.availableCalendars.count) active")
                            .font(.ac(10))
                            .foregroundStyle(.secondary)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Color.secondary.opacity(0.4))
                            .rotationEffect(.degrees(calendarListExpanded ? 90 : 0))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if calendarListExpanded {
                    Divider().opacity(0.25)
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(
                                Array(controller.availableCalendars.enumerated()), id: \.element.id
                            ) { index, cal in
                                Toggle(
                                    isOn: Binding(
                                        get: { controller.isCalendarEnabled(cal.id) },
                                        set: { _ in controller.toggleCalendarEnabled(cal.id) }
                                    )
                                ) {
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(cal.title)
                                            .font(.ac(11, weight: .medium))
                                            .foregroundStyle(Color.acTextPrimary)
                                            .lineLimit(1)
                                        Text(cal.sourceTitle)
                                            .font(.ac(10))
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                                .toggleStyle(.switch)
                                .controlSize(.small)
                                .tint(accent)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)

                                if index < controller.availableCalendars.count - 1 {
                                    Divider().opacity(0.2).padding(.leading, 10)
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 160)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .background(
                RoundedRectangle(cornerRadius: ACRadius.sm, style: .continuous)
                    .fill(Color.acSurface.opacity(0.65))
                    .overlay(
                        RoundedRectangle(cornerRadius: ACRadius.sm, style: .continuous)
                            .stroke(Color.acHairline.opacity(0.65), lineWidth: 0.5)
                    )
            )
            .clipShape(RoundedRectangle(cornerRadius: ACRadius.sm, style: .continuous))
        }
    }
}

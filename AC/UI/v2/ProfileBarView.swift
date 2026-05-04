//
//  ProfileBarView.swift
//  AC
//
//  Top profile bar in the main panel. Shows active profile with countdown,
//  or empty-state CTA when no profile is active.
//

import Combine
import SwiftUI

struct ProfileBarView: View {
    @EnvironmentObject private var controller: AppController
    @State private var nowTick = Date()

    var onPick: () -> Void = {}

    private var active: FocusProfile { controller.state.activeProfile }

    var body: some View {
        if active.isDefault {
            emptyState
        } else {
            activeState
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                Circle()
                    .fill(Color.secondary.opacity(0.35))
                    .frame(width: 6, height: 6)
                Text("no focus active · open mode")
                    .font(.ac(12, weight: .medium).italic())
                    .foregroundStyle(Color.acTextPrimary.opacity(0.55))
            }

            Spacer()

            Button {
                onPick()
            } label: {
                Text("pick a focus →")
                    .font(.ac(12, weight: .semibold))
                    .foregroundStyle(Color.acTextPrimary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: ACRadius.sm, style: .continuous)
                .fill(Color.acSurface)
                .overlay(
                    RoundedRectangle(cornerRadius: ACRadius.sm, style: .continuous)
                        .stroke(Color.acHairline, lineWidth: 1)
                )
        )
        .padding(.horizontal, 14)
        .padding(.top, 10)
    }

    // MARK: - Active state

    private var activeState: some View {
        HStack(spacing: 0) {
            // Left side: ring + meta
            HStack(spacing: 12) {
                // Countdown ring (28pt) with emoji inside
                ZStack {
                    Circle()
                        .stroke(active.swiftUIColor.opacity(0.22), lineWidth: 2.5)
                    Circle()
                        .trim(from: 0, to: 1 - elapsedFraction)
                        .stroke(active.swiftUIColor, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Text(active.emoji)
                        .font(.system(size: 10))
                        .foregroundStyle(active.swiftUIColor)
                }
                .frame(width: 28, height: 28)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text("focus:")
                            .font(.ac(11, weight: .semibold))
                            .foregroundStyle(active.swiftUIColor)
                        Text(active.name)
                            .font(.ac(11, weight: .semibold))
                            .foregroundStyle(Color.acTextPrimary)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8, weight: .black))
                            .foregroundStyle(Color.secondary.opacity(0.4))
                    }

                    if let remaining = remainingText {
                        Text(remaining)
                            .font(.ac(10))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { onPick() }

            Spacer()

            // Actions
            HStack(spacing: 8) {
                Button("+15m") {
                    _ = controller.extendActiveProfile(byMinutes: 15, announce: true)
                }
                .buttonStyle(ACSecondaryButton())

                Button("end") {
                    controller.endActiveProfile(announce: true)
                    controller.markAllChatMessagesRead()
                }
                .buttonStyle(ACSecondaryButton())
                .foregroundStyle(Color.acRedEnd.opacity(0.85))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: ACRadius.sm, style: .continuous)
                .fill(active.swiftUIColor.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: ACRadius.sm, style: .continuous)
                        .stroke(active.swiftUIColor.opacity(0.20), lineWidth: 1)
                )
        )
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .onReceive(Timer.publish(every: 30, on: .main, in: .common).autoconnect()) { date in
            nowTick = date
        }
    }

    // MARK: - Helpers

    private var elapsedFraction: CGFloat {
        guard let activatedAt = active.activatedAt,
              let expiresAt = active.expiresAt else { return 0 }
        let total = expiresAt.timeIntervalSince(activatedAt)
        let elapsed = nowTick.timeIntervalSince(activatedAt)
        guard total > 0 else { return 0 }
        return CGFloat(min(max(elapsed / total, 0), 1))
    }

    private var remainingText: String? {
        guard let expiresAt = active.expiresAt else { return nil }
        let remaining = max(0, expiresAt.timeIntervalSince(nowTick))
        let mins = Int(remaining / 60)
        let h = mins / 60
        let m = mins % 60
        let timeStr = h > 0 ? "\(h)h \(m)m" : "\(m)m"
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return "\(timeStr) · started \(formatter.string(from: active.activatedAt ?? Date()))"
    }
}

// MARK: - Profile color helper

private extension FocusProfile {
    var swiftUIColor: Color {
        Color(hexString: color) ?? Color.acProfileEveryday
    }
}

private extension Color {
    init?(hexString: String) {
        let trimmed = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
        let hex = trimmed.hasPrefix("#") ? String(trimmed.dropFirst()) : trimmed
        guard hex.count == 6,
              let value = UInt(hex, radix: 16) else { return nil }
        self.init(
            red: Double((value >> 16) & 0xFF) / 255.0,
            green: Double((value >> 8) & 0xFF) / 255.0,
            blue: Double(value & 0xFF) / 255.0
        )
    }
}

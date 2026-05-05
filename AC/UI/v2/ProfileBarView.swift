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
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.acSurfaceElevated)
                    .overlay(Circle().stroke(Color.acHairline, lineWidth: 0.5))
                Image(systemName: "circle.dotted")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color.acTextPrimary.opacity(0.44))
            }
            .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 2) {
                Text("OPEN MODE")
                    .font(.system(size: 9.5, weight: .bold, design: .rounded))
                    .tracking(0.08)
                    .foregroundStyle(Color.acTextPrimary.opacity(0.42))
                Text("no focus active")
                    .font(.ac(12, weight: .semibold))
                    .foregroundStyle(Color.acTextPrimary.opacity(0.76))
            }

            Spacer()

            Button {
                onPick()
            } label: {
                HStack(spacing: 5) {
                    Text("pick focus")
                    Image(systemName: "arrow.right")
                        .font(.system(size: 9, weight: .bold))
                }
                .font(.ac(12, weight: .semibold))
            }
            .buttonStyle(ProfileBarCTAButton())
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(emptyBandBackground)
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
                        Text("FOCUS")
                            .font(.system(size: 9.5, weight: .bold, design: .rounded))
                            .tracking(0.08)
                            .foregroundStyle(active.swiftUIColor)
                        Text(active.name)
                            .font(.ac(12, weight: .semibold))
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
                .buttonStyle(ProfileBarQuietButton())

                Button("end") {
                    controller.endActiveProfile(announce: true)
                    controller.markAllChatMessagesRead()
                }
                .buttonStyle(ProfileBarQuietButton())
                .foregroundStyle(Color.acRedEnd.opacity(0.85))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(activeBandBackground)
        .onReceive(Timer.publish(every: 30, on: .main, in: .common).autoconnect()) { date in
            nowTick = date
        }
    }

    private var emptyBandBackground: some View {
        ZStack {
            Rectangle().fill(Color.acSurface.opacity(0.74))
            LinearGradient(
                colors: [
                    Color(nsColor: NSColor(name: nil) { appearance in
                        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                            ? NSColor(white: 1.0, alpha: 0.06)
                            : NSColor(white: 1.0, alpha: 0.20)
                    }),
                    Color.clear
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            VStack {
                Spacer()
                Rectangle()
                    .fill(Color.acHairline)
                    .frame(height: 0.5)
            }
        }
    }

    private var activeBandBackground: some View {
        ZStack {
            Rectangle().fill(active.swiftUIColor.opacity(0.08))
            LinearGradient(
                colors: [
                    Color(nsColor: NSColor(name: nil) { appearance in
                        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                            ? NSColor(white: 1.0, alpha: 0.08)
                            : NSColor(white: 1.0, alpha: 0.24)
                    }),
                    active.swiftUIColor.opacity(0.04)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            VStack {
                Spacer()
                Rectangle()
                    .fill(active.swiftUIColor.opacity(0.20))
                    .frame(height: 0.5)
            }
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

private struct ProfileBarCTAButton: ButtonStyle {
    @Environment(\.acAccent) private var accent

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Color.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                Capsule(style: .continuous)
                    .fill(accent.opacity(configuration.isPressed ? 0.76 : 0.92))
                    .overlay(Capsule(style: .continuous).stroke(Color.acBubbleStroke, lineWidth: 0.5))
                    .shadow(color: accent.opacity(0.22), radius: 7, y: 2)
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.acSnap, value: configuration.isPressed)
    }
}

private struct ProfileBarQuietButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.ac(11, weight: .semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.acSurfaceElevated)
                    .overlay(Capsule(style: .continuous).stroke(Color.acHairline, lineWidth: 1))
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.acSnap, value: configuration.isPressed)
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

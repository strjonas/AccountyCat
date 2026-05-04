//
//  StatStripView.swift
//  AC
//
//  Three-column stat strip above chat: focused today, % of day, streak.
//

import SwiftUI

struct StatStripView: View {
    @EnvironmentObject private var controller: AppController
    @Environment(\.acAccent) private var accent

    var body: some View {
        HStack(spacing: 0) {
            statColumn(
                value: focusedTodayText,
                label: "focused today"
            )

            Divider()
                .frame(height: 36)
                .opacity(0.25)

            statColumn(
                value: pctOfDayText,
                label: "% of day"
            )

            Divider()
                .frame(height: 36)
                .opacity(0.25)

            streakColumn
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
        .background(
            RoundedRectangle(cornerRadius: ACRadius.sm, style: .continuous)
                .fill(Color.acSurface)
                .overlay(
                    RoundedRectangle(cornerRadius: ACRadius.sm, style: .continuous)
                        .stroke(Color.acHairline, lineWidth: 1)
                )
        )
        .padding(.horizontal, 14)
    }

    // MARK: - Stat column

    private func statColumn(value: String, label: String) -> some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.system(size: 19, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color.acTextPrimary)
            Text(label)
                .font(.ac(10, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Streak column

    private var streakColumn: some View {
        let stats = controller.todayStats
        let isMilestone = stats.streakDays > 0 && (stats.streakDays % 7 == 0 || stats.streakDays == 12)

        return VStack(spacing: 3) {
            HStack(spacing: 3) {
                Text("𖤍")
                    .font(.system(size: 16))
                    .foregroundStyle(accent)
                Text("\(stats.streakDays)")
                    .font(.system(size: 19, weight: .semibold, design: .monospaced))
                    .foregroundStyle(accent)
                Text("days")
                    .font(.ac(10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 2)
            }

            Text(trendText)
                .font(.ac(10))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .overlay(alignment: .topTrailing) {
            if isMilestone {
                Text("✦")
                    .font(.system(size: 8))
                    .foregroundStyle(accent)
                    .offset(x: -4, y: -4)
            }
        }
    }

    // MARK: - Computed values

    private var focusedTodayText: String {
        let s = controller.todayStats.focusedSeconds
        let h = Int(s) / 3600
        let m = (Int(s) % 3600) / 60
        if h > 0 { return "\(h)h \(String(format: "%02d", m))m" }
        return "\(m)m"
    }

    private var pctOfDayText: String {
        let s = controller.todayStats.focusedSeconds
        // Use elapsed time since midnight or since wake, whichever is smaller
        let now = Date()
        let calendar = Calendar.current
        let midnight = calendar.startOfDay(for: now)
        let elapsed = now.timeIntervalSince(midnight)
        guard elapsed > 0 else { return "—" }
        let pct = min(100, Int((s / elapsed) * 100))
        return "\(pct)%"
    }

    private var trendText: String {
        // Placeholder — real trend needs historical data
        "+2 vs last wk"
    }
}

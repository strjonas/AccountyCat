//
//  StatsView.swift
//  AC
//

import Foundation
import SwiftUI

struct StatsView: View {
    @EnvironmentObject private var controller: AppController
    @State private var window: StatsWindow = .day
    @State private var snapshot: MonitoringStatsSnapshot = .empty
    @State private var isLoading = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Stats")
                        .font(.ac(16, weight: .semibold))
                    Text("Telemetry-derived usage, monitoring mix, and cost estimates.")
                        .font(.ac(11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Picker("", selection: $window) {
                    ForEach(StatsWindow.allCases, id: \.self) { option in
                        Text(option.label).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 150)
                Button {
                    Task { await reload(forceRefresh: true) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh stats")
            }

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                statsCard("Total tokens", snapshot.totalTokensSummary, tokenSubtitle)
                statsCard("LLM calls", snapshot.totalLLMRequestsSummary, "All kinds in \(window.label) window")
                statsCard(
                    "Monitoring / active hr",
                    snapshot.monitoringCallsPerActiveHour,
                    "Evaluations while not idle · \(snapshot.activeMonitoringTime) active"
                )
                statsCard(
                    "Monitoring / wall hr",
                    snapshot.callsPerWallHour,
                    "Spread across full \(window.label) window"
                )
                statsCard("Avg tokens", snapshot.averageTokenSummary, "prompt / completion / image per call")
                statsCard("Vision", snapshot.visionAttachRate, "model calls with screenshot")
            }

            if let cost = snapshot.totalCostUSD {
                statsCard("Reported cost", cost, "Sum of runtime-reported costUSD in window")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            statsSection("Cost estimate") {
                Text("Extrapolates observed rates from active monitoring time (excludes idle backoff). Use for planning 10h/day usage.")
                    .font(.ac(10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(snapshot.costProjections) { row in
                    StatsRow(label: row.label, value: row.value)
                }
            }

            statsSection("Decision mix") {
                ForEach(snapshot.decisionMix) { row in
                    StatsRow(label: row.label, value: row.value)
                }
            }

            statsSection("Watch list") {
                ForEach(snapshot.watchItems) { item in
                    WatchRow(item: item)
                }
            }

            statsSection("Skip causes") {
                if snapshot.skipCauses.isEmpty {
                    Text("No skip metrics recorded in this window.")
                        .font(.ac(11))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(snapshot.skipCauses) { row in
                        StatsRow(label: row.label, value: row.value)
                    }
                }
            }

            statsSection("LLM calls by kind") {
                if snapshot.llmKindBreakdown.isEmpty {
                    Text("No llm_interaction events in this window (older sessions may only have model_output).")
                        .font(.ac(11))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(snapshot.llmKindBreakdown) { row in
                        StatsRow(label: row.label, value: row.value)
                    }
                }
            }

            statsSection("Per-stage tokens") {
                if snapshot.stageBreakdown.isEmpty {
                    Text("No token usage recorded in this window.")
                        .font(.ac(11))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(snapshot.stageBreakdown) { row in
                        StatsRow(label: row.label, value: row.value)
                    }
                }
            }

            statsSection("Per-profile decisions") {
                if snapshot.profileBreakdown.isEmpty {
                    Text("No profile-tagged decisions recorded in this window.")
                        .font(.ac(11))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(snapshot.profileBreakdown) { row in
                        StatsRow(label: row.label, value: row.value)
                    }
                }
            }

            statsSection("Retries") {
                StatsRow(label: "vision retried", value: "\(snapshot.visionRetryCount)")
            }
        }
        .padding(20)
        .task(id: window) {
            if let cached = controller.cachedStatsSnapshot(for: window) {
                snapshot = cached
            } else {
                await reload()
            }
        }
        .overlay(alignment: .topTrailing) {
            if isLoading {
                ProgressView()
                    .scaleEffect(0.7)
                    .padding(18)
            }
        }
    }

    private var tokenSubtitle: String {
        if let cost = snapshot.totalCostUSD {
            return "In \(window.label) window · \(cost) reported"
        }
        return "In \(window.label) window"
    }

    private func statsCard(_ title: String, _ value: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.ac(10, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            Text(value)
                .font(.ac(16, weight: .semibold))
                .foregroundStyle(Color.acTextPrimary)
            Text(subtitle)
                .font(.ac(10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: ACRadius.md, style: .continuous)
                .fill(Color.acSurface)
                .overlay(
                    RoundedRectangle(cornerRadius: ACRadius.md, style: .continuous)
                        .stroke(Color.acHairline, lineWidth: 1)
                )
        )
    }

    private func statsSection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.ac(11, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            VStack(spacing: 6) {
                content()
            }
        }
    }

    @MainActor
    private func reload(forceRefresh: Bool = false) async {
        if !forceRefresh, let cached = controller.cachedStatsSnapshot(for: window) {
            snapshot = cached
            return
        }

        isLoading = true
        let store = controller.telemetryStore
        let selectedWindow = window
        let loaded = await Task.detached {
            await MonitoringStatsSnapshot.load(from: store, window: selectedWindow)
        }.value
        snapshot = loaded
        controller.storeStatsSnapshot(loaded, for: selectedWindow)
        isLoading = false
    }
}

private struct StatsRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .font(.ac(11))
                .foregroundStyle(Color.acTextPrimary)
            Spacer()
            Text(value)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: ACRadius.sm, style: .continuous)
                .fill(Color.acSurface.opacity(0.62))
        )
    }
}

private struct WatchRow: View {
    let item: MonitoringStatsSnapshot.WatchItem

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
                .padding(.top, 4)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.label)
                    .font(.ac(11, weight: .semibold))
                    .foregroundStyle(Color.acTextPrimary)
                Text(item.message)
                    .font(.ac(10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: ACRadius.sm, style: .continuous)
                .fill(Color.acSurface.opacity(0.62))
        )
    }

    private var statusColor: Color {
        switch item.status {
        case .healthy:
            return .green.opacity(0.85)
        case .watch:
            return Color.acAmber
        case .alert:
            return .red.opacity(0.78)
        }
    }
}

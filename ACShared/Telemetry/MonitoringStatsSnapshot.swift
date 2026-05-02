//
//  MonitoringStatsSnapshot.swift
//  AC
//

import Foundation

enum StatsWindow: CaseIterable, Hashable, Sendable {
    case day
    case week

    var label: String {
        switch self {
        case .day: return "24h"
        case .week: return "7d"
        }
    }

    var interval: TimeInterval {
        switch self {
        case .day: return 24 * 60 * 60
        case .week: return 7 * 24 * 60 * 60
        }
    }
}

struct MonitoringStatsSnapshot: Sendable {
    struct Row: Identifiable, Sendable {
        var id: String { label }
        var label: String
        var value: String
    }

    enum WatchStatus: Sendable {
        case healthy
        case watch
        case alert
    }

    struct WatchItem: Identifiable, Sendable {
        var id: String { label }
        var label: String
        var message: String
        var status: WatchStatus
    }

    var callsPerHour: String
    var callsPerHourValue: Double
    var averageTokenSummary: String
    var visionAttachRate: String
    var visionAttachRateValue: Double
    var visionRetryCount: Int
    var visionRetryRateValue: Double
    var focusedRateValue: Double
    var unclearRateValue: Double
    var decisionMix: [Row]
    var skipCauses: [Row]
    var stageBreakdown: [Row]
    var profileBreakdown: [Row]

    static let empty = MonitoringStatsSnapshot(
        callsPerHour: "0.0",
        callsPerHourValue: 0,
        averageTokenSummary: "0 / 0 / 0",
        visionAttachRate: "0%",
        visionAttachRateValue: 0,
        visionRetryCount: 0,
        visionRetryRateValue: 0,
        focusedRateValue: 0,
        unclearRateValue: 0,
        decisionMix: [],
        skipCauses: [],
        stageBreakdown: [],
        profileBreakdown: []
    )

    var watchItems: [WatchItem] {
        var items: [WatchItem] = []

        if unclearRateValue >= 15 {
            items.append(
                WatchItem(
                    label: "Unclear rate",
                    message: "\(Self.percentString(unclearRateValue)) is high. Raise the title-only threshold or keep vision on for more contexts.",
                    status: .alert
                )
            )
        }

        if visionRetryRateValue > 20 {
            items.append(
                WatchItem(
                    label: "Vision retries",
                    message: "\(Self.percentString(visionRetryRateValue)) of decisions retried with vision. The text-only gate is probably too loose.",
                    status: .alert
                )
            )
        }

        if focusedRateValue > 90, callsPerHourValue >= 4 {
            items.append(
                WatchItem(
                    label: "Focused saturation",
                    message: "\(Self.percentString(focusedRateValue)) focused at \(String(format: "%.1f", callsPerHourValue)) calls/hr. Skip logic may still be too eager.",
                    status: .watch
                )
            )
        }

        if visionAttachRateValue > 70 {
            items.append(
                WatchItem(
                    label: "Vision attach rate",
                    message: "\(Self.percentString(visionAttachRateValue)) of calls still include screenshots. Raise the threshold only if unclear and retry rates stay healthy.",
                    status: .watch
                )
            )
        }

        if items.isEmpty {
            items.append(
                WatchItem(
                    label: "Vision gate",
                    message: "Unclear, retry, and call-volume signals look healthy in this window.",
                    status: .healthy
                )
            )
        }

        return items
    }

    static func load(from store: TelemetryStore, window: StatsWindow) async -> MonitoringStatsSnapshot {
        let now = Date()
        let cutoff = now.addingTimeInterval(-window.interval)
        let sessions = await store.listSessions()
        var events: [TelemetryEvent] = []
        for session in sessions where session.startedAt >= cutoff.addingTimeInterval(-60 * 60) || session.endedAt == nil {
            let loaded = await store.loadEvents(sessionID: session.id)
            events.append(contentsOf: loaded.filter { $0.timestamp >= cutoff && $0.timestamp <= now })
        }

        // Single-pass accumulation instead of multiple filters.
        var evaluationCount = 0
        var tokenUsages: [(String, TokenUsageRecord)] = []
        var policyDecisions: [PolicyDecisionRecord] = []
        var metricsRecords: [MonitoringMetricRecord] = []

        for event in events {
            if event.evaluation != nil { evaluationCount += 1 }
            if let output = event.modelOutput, let usage = output.tokenUsage {
                tokenUsages.append((output.promptMode, usage))
            }
            if let policy = event.policy { policyDecisions.append(policy) }
            if let metric = event.metric { metricsRecords.append(metric) }
        }

        let hours = max(1.0, window.interval / 3600)
        let callsPerHour = Double(evaluationCount) / hours

        let avgPrompt = average(tokenUsages.map { $0.1.promptTokens })
        let avgCompletion = average(tokenUsages.map { $0.1.completionTokens })
        let avgImage = average(tokenUsages.map { $0.1.imageTokens ?? 0 })
        let visionAttachCount = tokenUsages.filter { $0.1.includesScreenshot }.count
        let visionRateValue = percentValue(part: visionAttachCount, total: tokenUsages.count)
        let visionRate = percentString(visionRateValue)

        let focused = policyDecisions.filter { $0.model.assessment == .focused }.count
        let distracted = policyDecisions.filter { $0.model.assessment == .distracted }.count
        let unclear = policyDecisions.filter { $0.model.assessment == .unclear }.count
        let abstain = policyDecisions.filter { $0.model.suggestedAction == .abstain }.count
        let decisionTotal = max(1, policyDecisions.count)
        let focusedRateValue = percentValue(part: focused, total: decisionTotal)
        let unclearRateValue = percentValue(part: unclear, total: decisionTotal)
        let visionRetryCount = metricsRecords.filter { $0.kind == .visionRetried }.count
        let visionRetryRateValue = percentValue(part: visionRetryCount, total: decisionTotal)
        let decisionMix = [
            Row(label: "focused", value: "\(focused) · \(percent(part: focused, total: decisionTotal))"),
            Row(label: "distracted", value: "\(distracted) · \(percent(part: distracted, total: decisionTotal))"),
            Row(label: "unclear", value: "\(unclear) · \(percent(part: unclear, total: decisionTotal))"),
            Row(label: "abstain action", value: "\(abstain) · \(percent(part: abstain, total: decisionTotal))")
        ]

        let skipRows = groupedRows(
            metricsRecords
                .filter { $0.kind == .evaluationSkipped }
                .map(\.reason)
        )

        let stageRows = Dictionary(grouping: tokenUsages, by: { $0.0 })
            .map { stage, values in
                let usages = values.map(\.1)
                let total = usages.reduce(0) { $0 + $1.totalTokens }
                let avg = average(usages.map(\.totalTokens))
                let imageAvg = average(usages.map { $0.imageTokens ?? 0 })
                return Row(label: stage, value: "\(values.count)x · avg \(avg) · img \(imageAvg) · total \(total)")
            }
            .sorted { $0.label < $1.label }

        let profileRows = Dictionary(grouping: policyDecisions, by: { policy in
            policy.activeProfileName ?? policy.activeProfileID ?? "unknown"
        })
        .map { profile, values in
            let f = values.filter { $0.model.assessment == .focused }.count
            let d = values.filter { $0.model.assessment == .distracted }.count
            let u = values.filter { $0.model.assessment == .unclear }.count
            return Row(label: profile, value: "\(values.count)x · F \(f) / D \(d) / U \(u)")
        }
        .sorted { $0.label < $1.label }

        return MonitoringStatsSnapshot(
            callsPerHour: String(format: "%.1f", callsPerHour),
            callsPerHourValue: callsPerHour,
            averageTokenSummary: "\(avgPrompt) / \(avgCompletion) / \(avgImage)",
            visionAttachRate: visionRate,
            visionAttachRateValue: visionRateValue,
            visionRetryCount: visionRetryCount,
            visionRetryRateValue: visionRetryRateValue,
            focusedRateValue: focusedRateValue,
            unclearRateValue: unclearRateValue,
            decisionMix: decisionMix,
            skipCauses: skipRows,
            stageBreakdown: stageRows,
            profileBreakdown: profileRows
        )
    }

    private static func average(_ values: [Int]) -> Int {
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / values.count
    }

    private static func percent(part: Int, total: Int) -> String {
        percentString(percentValue(part: part, total: total))
    }

    private static func percentValue(part: Int, total: Int) -> Double {
        guard total > 0 else { return 0 }
        return Double(part) / Double(total) * 100
    }

    private static func percentString(_ value: Double) -> String {
        "\(Int(value.rounded()))%"
    }

    private static func groupedRows(_ values: [String]) -> [Row] {
        let grouped = Dictionary(grouping: values, by: { $0 })
        let total = max(1, values.count)
        return grouped
            .map { (label: $0.key, count: $0.value.count) }
            .sorted { lhs, rhs in
                if lhs.count == rhs.count { return lhs.label < rhs.label }
                return lhs.count > rhs.count
            }
            .map { Row(label: $0.label, value: "\($0.count) · \(percent(part: $0.count, total: total))") }
    }
}

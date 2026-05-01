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

    var callsPerHour: String
    var averageTokenSummary: String
    var visionAttachRate: String
    var visionRetryCount: Int
    var decisionMix: [Row]
    var skipCauses: [Row]
    var stageBreakdown: [Row]
    var profileBreakdown: [Row]

    static let empty = MonitoringStatsSnapshot(
        callsPerHour: "0.0",
        averageTokenSummary: "0 / 0 / 0",
        visionAttachRate: "0%",
        visionRetryCount: 0,
        decisionMix: [],
        skipCauses: [],
        stageBreakdown: [],
        profileBreakdown: []
    )

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
        let visionRate = percent(
            part: tokenUsages.filter { $0.1.includesScreenshot }.count,
            total: tokenUsages.count
        )

        let focused = policyDecisions.filter { $0.model.assessment == .focused }.count
        let distracted = policyDecisions.filter { $0.model.assessment == .distracted }.count
        let unclear = policyDecisions.filter { $0.model.assessment == .unclear }.count
        let abstain = policyDecisions.filter { $0.model.suggestedAction == .abstain }.count
        let decisionTotal = max(1, policyDecisions.count)
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
            averageTokenSummary: "\(avgPrompt) / \(avgCompletion) / \(avgImage)",
            visionAttachRate: visionRate,
            visionRetryCount: metricsRecords.filter { $0.kind == .visionRetried }.count,
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
        guard total > 0 else { return "0%" }
        return "\(Int((Double(part) / Double(total) * 100).rounded()))%"
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

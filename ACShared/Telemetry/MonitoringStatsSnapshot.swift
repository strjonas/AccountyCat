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

    var daysInWindow: Double {
        switch self {
        case .day: return 1
        case .week: return 7
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

    /// Total LLM calls in the window (all kinds: monitoring, chat, memory, etc.).
    var totalLLMRequests: Int
    var totalLLMRequestsSummary: String
    /// Sum of reported/estimated tokens across all LLM calls in the window.
    var totalTokens: Int
    var totalTokensSummary: String
    /// Sum of `costUSD` when the runtime reported it; nil when no priced calls exist.
    var totalCostUSD: String?
    /// Wall-clock average: monitoring evaluations / full window length.
    var callsPerWallHour: String
    var callsPerWallHourValue: Double
    /// Monitoring evaluations per hour while AC was actively watching (non-idle).
    var monitoringCallsPerActiveHour: String
    var monitoringCallsPerActiveHourValue: Double
    /// Human-readable active monitoring duration in the window, e.g. `2.4h`.
    var activeMonitoringTime: String
    var activeMonitoringHoursValue: Double
    /// Legacy alias used by watch-list heuristics.
    var callsPerHour: String { monitoringCallsPerActiveHour }
    var callsPerHourValue: Double { monitoringCallsPerActiveHourValue }
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
    var llmKindBreakdown: [Row]
    var costProjections: [Row]

    static let empty = MonitoringStatsSnapshot(
        totalLLMRequests: 0,
        totalLLMRequestsSummary: "0",
        totalTokens: 0,
        totalTokensSummary: "0",
        totalCostUSD: nil,
        callsPerWallHour: "0.0",
        callsPerWallHourValue: 0,
        monitoringCallsPerActiveHour: "0.0",
        monitoringCallsPerActiveHourValue: 0,
        activeMonitoringTime: "0m",
        activeMonitoringHoursValue: 0,
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
        profileBreakdown: [],
        llmKindBreakdown: [],
        costProjections: []
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

        if focusedRateValue > 90, monitoringCallsPerActiveHourValue >= 4 {
            items.append(
                WatchItem(
                    label: "Focused saturation",
                    message: "\(Self.percentString(focusedRateValue)) focused at \(String(format: "%.1f", monitoringCallsPerActiveHourValue)) monitoring calls/hr (active). Skip logic may still be too eager.",
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

        var evaluationCount = 0
        var tokenUsages: [(String, TokenUsageRecord)] = []
        var policyDecisions: [PolicyDecisionRecord] = []
        var metricsRecords: [MonitoringMetricRecord] = []
        var llmInteractions: [LLMInteractionRecord] = []

        for event in events {
            if event.evaluation != nil { evaluationCount += 1 }
            if let output = event.modelOutput, let usage = output.tokenUsage {
                tokenUsages.append((output.promptMode, usage))
            }
            if let policy = event.policy { policyDecisions.append(policy) }
            if let metric = event.metric { metricsRecords.append(metric) }
            if let record = event.llmInteraction, !record.isAnnotation {
                llmInteractions.append(record)
            }
        }

        let activeSeconds = computeActiveMonitoringSeconds(events: events, cutoff: cutoff, now: now)
        let activeHours = max(
            activeSeconds / 3600,
            evaluationCount > 0 || !llmInteractions.isEmpty ? 60 / 3600 : 0
        )
        let wallHours = max(1.0, window.interval / 3600)
        let callsPerWallHour = Double(evaluationCount) / wallHours
        let monitoringCallsPerActiveHour = Double(evaluationCount) / max(activeHours, 1.0 / 3600)

        let llmTokenUsages = llmInteractions.compactMap(\.tokenUsage)
        let usesLLMInteractions = !llmTokenUsages.isEmpty
        let totalTokens = usesLLMInteractions
            ? llmTokenUsages.reduce(0) { $0 + $1.totalTokens }
            : tokenUsages.map(\.1).reduce(0) { $0 + $1.totalTokens }
        let totalLLMRequests = usesLLMInteractions ? llmInteractions.count : evaluationCount
        let pricedCosts = (usesLLMInteractions ? llmTokenUsages : tokenUsages.map(\.1))
            .compactMap(\.costUSD)
        let totalCost = pricedCosts.isEmpty ? nil : pricedCosts.reduce(0, +)

        let usageSource = usesLLMInteractions ? llmTokenUsages : tokenUsages.map(\.1)
        let avgPrompt = average(usageSource.map(\.promptTokens))
        let avgCompletion = average(usageSource.map(\.completionTokens))
        let avgImage = average(usageSource.map { $0.imageTokens ?? 0 })
        let visionAttachCount = usageSource.filter(\.includesScreenshot).count
        let visionRateValue = percentValue(part: visionAttachCount, total: usageSource.count)
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

        let llmKindRows = Dictionary(grouping: llmInteractions, by: { $0.kind.rawValue })
            .map { kind, values in
                let tokens = values.compactMap(\.tokenUsage).reduce(0) { $0 + $1.totalTokens }
                return Row(label: kind, value: "\(values.count)x · \(formatCount(tokens)) tok")
            }
            .sorted { $0.label < $1.label }

        let costProjections = makeCostProjections(
            window: window,
            totalTokens: totalTokens,
            totalLLMRequests: totalLLMRequests,
            monitoringEvaluations: evaluationCount,
            activeHours: activeHours,
            totalCostUSD: totalCost
        )

        return MonitoringStatsSnapshot(
            totalLLMRequests: totalLLMRequests,
            totalLLMRequestsSummary: formatCount(totalLLMRequests),
            totalTokens: totalTokens,
            totalTokensSummary: formatCount(totalTokens),
            totalCostUSD: totalCost.map { formatUSD($0) },
            callsPerWallHour: String(format: "%.1f", callsPerWallHour),
            callsPerWallHourValue: callsPerWallHour,
            monitoringCallsPerActiveHour: String(format: "%.1f", monitoringCallsPerActiveHour),
            monitoringCallsPerActiveHourValue: monitoringCallsPerActiveHour,
            activeMonitoringTime: formatDuration(activeSeconds),
            activeMonitoringHoursValue: activeHours,
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
            profileBreakdown: profileRows,
            llmKindBreakdown: llmKindRows,
            costProjections: costProjections
        )
    }

    // MARK: - Active monitoring time

    /// Seconds AC was actively monitoring (not in idle backoff), derived from telemetry gaps and idle-skip markers.
    static func computeActiveMonitoringSeconds(
        events: [TelemetryEvent],
        cutoff: Date,
        now: Date
    ) -> TimeInterval {
        let sorted = events.sorted { $0.timestamp < $1.timestamp }
        let gapLimit: TimeInterval = 30

        func isIdleEnd(_ event: TelemetryEvent) -> Bool {
            event.metric?.kind == .evaluationSkipped && event.metric?.reason == "idle"
        }

        func isActivity(_ event: TelemetryEvent) -> Bool {
            switch event.kind {
            case .observation, .evaluationRequested, .modelOutputReceived, .modelOutputParsed, .policyDecided:
                return true
            case .monitoringMetric:
                return !isIdleEnd(event)
            case .llmInteraction:
                guard let record = event.llmInteraction, !record.isAnnotation else { return false }
                switch record.kind {
                case .monitoringText, .monitoringVision:
                    return true
                default:
                    return false
                }
            case .sessionStarted, .sessionHeartbeat:
                return true
            default:
                return false
            }
        }

        var intervals: [(start: Date, end: Date)] = []
        var periodStart: Date?
        var lastActivity: Date?

        for event in sorted {
            let timestamp = event.timestamp
            guard timestamp >= cutoff, timestamp <= now else { continue }

            if isIdleEnd(event) {
                if let start = periodStart, let last = lastActivity {
                    intervals.append((max(start, cutoff), min(last, timestamp)))
                }
                periodStart = nil
                lastActivity = nil
                continue
            }

            guard isActivity(event) else { continue }

            if periodStart == nil {
                periodStart = max(timestamp, cutoff)
                lastActivity = timestamp
            } else if let last = lastActivity, timestamp.timeIntervalSince(last) > gapLimit {
                if let start = periodStart {
                    intervals.append((max(start, cutoff), min(last, now)))
                }
                periodStart = max(timestamp, cutoff)
                lastActivity = timestamp
            } else {
                lastActivity = timestamp
            }
        }

        if let start = periodStart, let last = lastActivity {
            let end: Date
            if now.timeIntervalSince(last) <= gapLimit {
                end = now
            } else {
                end = last.addingTimeInterval(gapLimit)
            }
            intervals.append((max(start, cutoff), min(end, now)))
        }

        return mergeIntervals(intervals).reduce(0) { $0 + $1.end.timeIntervalSince($1.start) }
    }

    private static func mergeIntervals(_ intervals: [(start: Date, end: Date)]) -> [(start: Date, end: Date)] {
        guard !intervals.isEmpty else { return [] }
        let sorted = intervals.sorted { $0.start < $1.start }
        var merged: [(start: Date, end: Date)] = [sorted[0]]
        for interval in sorted.dropFirst() {
            var last = merged[merged.count - 1]
            if interval.start <= last.end {
                last.end = max(last.end, interval.end)
                merged[merged.count - 1] = last
            } else {
                merged.append(interval)
            }
        }
        return merged
    }

    // MARK: - Cost projections

    private static func makeCostProjections(
        window: StatsWindow,
        totalTokens: Int,
        totalLLMRequests: Int,
        monitoringEvaluations: Int,
        activeHours: Double,
        totalCostUSD: Double?
    ) -> [Row] {
        guard activeHours > 0, totalTokens > 0 || totalLLMRequests > 0 else {
            return [
                Row(
                    label: "Need more data",
                    value: "Use AC while monitoring for a while, then refresh"
                )
            ]
        }

        let tokensPerActiveHour = Double(totalTokens) / activeHours
        let llmPerActiveHour = Double(totalLLMRequests) / activeHours
        let monitoringPerActiveHour = Double(monitoringEvaluations) / activeHours
        let hoursPerDay = 10.0
        let daysPerWeek = 7.0
        let weeklyActiveHours = hoursPerDay * daysPerWeek

        var rows: [Row] = [
            Row(
                label: "Tokens / active hr",
                value: "\(formatCount(Int(tokensPerActiveHour.rounded()))) (observed)"
            ),
            Row(
                label: "LLM calls / active hr",
                value: String(format: "%.1f", llmPerActiveHour)
            ),
            Row(
                label: "Monitoring evals / active hr",
                value: String(format: "%.1f", monitoringPerActiveHour)
            ),
            Row(
                label: "Tokens @ \(Int(hoursPerDay))h day",
                value: formatCount(Int((tokensPerActiveHour * hoursPerDay).rounded()))
            ),
            Row(
                label: "LLM calls @ \(Int(hoursPerDay))h day",
                value: formatCount(Int((llmPerActiveHour * hoursPerDay).rounded()))
            ),
            Row(
                label: "Tokens @ \(Int(hoursPerDay))h × \(Int(daysPerWeek))d",
                value: formatCount(Int((tokensPerActiveHour * weeklyActiveHours).rounded()))
            ),
            Row(
                label: "LLM calls @ \(Int(hoursPerDay))h × \(Int(daysPerWeek))d",
                value: formatCount(Int((llmPerActiveHour * weeklyActiveHours).rounded()))
            )
        ]

        if let totalCostUSD, activeHours > 0 {
            let costPerActiveHour = totalCostUSD / activeHours
            rows.append(
                Row(
                    label: "Cost @ \(Int(hoursPerDay))h day",
                    value: formatUSD(costPerActiveHour * hoursPerDay)
                )
            )
            rows.append(
                Row(
                    label: "Cost @ \(Int(hoursPerDay))h × \(Int(daysPerWeek))d",
                    value: formatUSD(costPerActiveHour * weeklyActiveHours)
                )
            )
        }

        let dailyTokens = Int((Double(totalTokens) / window.daysInWindow).rounded())
        let dailyRequests = Int((Double(totalLLMRequests) / window.daysInWindow).rounded())
        rows.insert(
            Row(
                label: "Avg tokens / calendar day",
                value: "\(formatCount(dailyTokens)) (in \(window.label) window)"
            ),
            at: 0
        )
        rows.insert(
            Row(
                label: "Avg LLM calls / calendar day",
                value: "\(formatCount(dailyRequests)) (in \(window.label) window)"
            ),
            at: 1
        )

        return rows
    }

    // MARK: - Formatting

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

    static func formatCount(_ value: Int) -> String {
        let absValue = abs(value)
        switch absValue {
        case 1_000_000...:
            return String(format: "%.1fM", Double(value) / 1_000_000)
        case 1_000...:
            return String(format: "%.1fk", Double(value) / 1_000)
        default:
            return "\(value)"
        }
    }

    static func formatUSD(_ value: Double) -> String {
        if value >= 1 {
            return String(format: "$%.2f", value)
        }
        if value >= 0.01 {
            return String(format: "$%.3f", value)
        }
        return String(format: "$%.4f", value)
    }

    static func formatDuration(_ seconds: TimeInterval) -> String {
        guard seconds > 0 else { return "0m" }
        if seconds >= 3600 {
            return String(format: "%.1fh", seconds / 3600)
        }
        return "\(max(1, Int((seconds / 60).rounded())))m"
    }
}

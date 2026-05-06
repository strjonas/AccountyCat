//
//  OpenRouterHealthStatsService.swift
//  AC
//

import Foundation

nonisolated struct OpenRouterSourceHealthRecord: Codable, Hashable, Sendable {
    var source: String
    var attempts: Int
    var successes: Int
    var failures: Int
}

nonisolated struct OpenRouterModelHealthRecord: Codable, Hashable, Sendable {
    var requestedModel: String
    var attempts: Int
    var successes: Int
    var failures: Int
    var retries: Int
    var fallbackSuccesses: Int
    var lastSuccessAt: Date?
    var lastFailureAt: Date?
    var servedModelSuccesses: [String: Int]
    var providerFailures: [String: Int]
    var failureStatuses: [String: Int]
    var sourceBreakdown: [String: OpenRouterSourceHealthRecord]
    // Resilience tracking
    var consecutiveFailures: Int = 0
    var bannedUntil: Date?
}

nonisolated struct OpenRouterHealthSnapshot: Codable, Hashable, Sendable {
    var updatedAt: Date
    var models: [String: OpenRouterModelHealthRecord]
}

actor OpenRouterHealthStatsService {
    static let shared = OpenRouterHealthStatsService()

    private let fileURL: URL
    private let fileManager: FileManager
    private var snapshot: OpenRouterHealthSnapshot?

    init(fileManager: FileManager = .default, fileURL: URL? = nil) {
        self.fileManager = fileManager
        self.fileURL = fileURL
            ?? TelemetryPaths.applicationSupportURL(fileManager: fileManager)
                .appendingPathComponent("openrouter-health.json")
    }

    func snapshotFileURL() -> URL {
        fileURL
    }

    // MARK: - Queries

    func isModelBanned(_ modelIdentifier: String, at date: Date = Date()) async -> Bool {
        let snapshot = await loadSnapshot()
        guard let record = snapshot.models[modelIdentifier] else { return false }
        if let bannedUntil = record.bannedUntil, bannedUntil > date {
            return true
        }
        return false
    }

    func failureRate(for modelIdentifier: String, inLast hours: TimeInterval = 1) async -> Double {
        let snapshot = await loadSnapshot()
        guard let record = snapshot.models[modelIdentifier] else { return 0 }
        let total = record.attempts
        guard total > 0 else { return 0 }
        return Double(record.failures) / Double(total)
    }

    /// Returns the input identifiers filtered to non-banned models and sorted by health
    /// (lowest failure rate first). Falls back to input order if no health data exists.
    func sortedHealthyModels(_ modelIdentifiers: [String], at date: Date = Date()) async -> [String] {
        let snapshot = await loadSnapshot()
        return modelIdentifiers.filter { model in
            guard let record = snapshot.models[model] else { return true }
            if let bannedUntil = record.bannedUntil, bannedUntil > date {
                return false
            }
            return true
        }.sorted { lhs, rhs in
            let lhsRate = snapshot.models[lhs].map { Double($0.failures) / max(1.0, Double($0.attempts)) } ?? 0
            let rhsRate = snapshot.models[rhs].map { Double($0.failures) / max(1.0, Double($0.attempts)) } ?? 0
            return lhsRate < rhsRate
        }
    }

    // MARK: - Mutations

    func recordRetry(requestedModel: String) async {
        await mutateRecord(for: requestedModel) { record in
            record.retries += 1
        }
    }

    func recordSuccess(
        requestedModel: String,
        servedModel: String,
        source: OnlineModelRequestSource,
        timestamp: Date = Date()
    ) async {
        await mutateRecord(for: requestedModel, timestamp: timestamp) { record in
            record.attempts += 1
            record.successes += 1
            record.lastSuccessAt = timestamp
            if OnlineModelService.modelIdentifiersEquivalent(servedModel, requestedModel) {
                record.consecutiveFailures = 0
                record.bannedUntil = nil
            }
            record.servedModelSuccesses[servedModel, default: 0] += 1
            if !OnlineModelService.modelIdentifiersEquivalent(servedModel, requestedModel) {
                record.fallbackSuccesses += 1
            }

            var sourceRecord = record.sourceBreakdown[source.rawValue]
                ?? OpenRouterSourceHealthRecord(source: source.rawValue, attempts: 0, successes: 0, failures: 0)
            sourceRecord.attempts += 1
            sourceRecord.successes += 1
            record.sourceBreakdown[source.rawValue] = sourceRecord
        }
    }

    func recordFailure(
        requestedModel: String,
        source: OnlineModelRequestSource,
        statusCode: Int?,
        providerName: String?,
        countsTowardBan: Bool = true,
        timestamp: Date = Date()
    ) async {
        await mutateRecord(for: requestedModel, timestamp: timestamp) { record in
            record.attempts += 1
            record.failures += 1
            record.lastFailureAt = timestamp
            if countsTowardBan {
                record.consecutiveFailures += 1
                record.bannedUntil = Self.banUntil(consecutiveFailures: record.consecutiveFailures, from: timestamp)
            }
            if let statusCode {
                record.failureStatuses[String(statusCode), default: 0] += 1
            }
            if let providerName, !providerName.isEmpty {
                record.providerFailures[providerName, default: 0] += 1
            }

            var sourceRecord = record.sourceBreakdown[source.rawValue]
                ?? OpenRouterSourceHealthRecord(source: source.rawValue, attempts: 0, successes: 0, failures: 0)
            sourceRecord.attempts += 1
            sourceRecord.failures += 1
            record.sourceBreakdown[source.rawValue] = sourceRecord
        }
    }

    // MARK: - Private

    /// Escalating ban durations: minutes -> hours -> days.
    private static func banUntil(consecutiveFailures: Int, from date: Date) -> Date? {
        guard consecutiveFailures >= 3 else {
            return nil
        }
        let duration: TimeInterval
        switch consecutiveFailures {
        case 3:  duration = 5 * 60          // 5 minutes
        case 4:  duration = 15 * 60         // 15 minutes
        case 5:  duration = 60 * 60         // 1 hour
        case 6:  duration = 4 * 60 * 60     // 4 hours
        case 7:  duration = 24 * 60 * 60    // 1 day
        default: duration = 3 * 24 * 60 * 60 // 3 days
        }
        return date.addingTimeInterval(duration)
    }

    private func mutateRecord(
        for requestedModel: String,
        timestamp: Date = Date(),
        _ transform: (inout OpenRouterModelHealthRecord) -> Void
    ) async {
        var snapshot = await loadSnapshot()
        var record = snapshot.models[requestedModel] ?? OpenRouterModelHealthRecord(
            requestedModel: requestedModel,
            attempts: 0,
            successes: 0,
            failures: 0,
            retries: 0,
            fallbackSuccesses: 0,
            lastSuccessAt: nil,
            lastFailureAt: nil,
            servedModelSuccesses: [:],
            providerFailures: [:],
            failureStatuses: [:],
            sourceBreakdown: [:],
            consecutiveFailures: 0,
            bannedUntil: nil
        )
        transform(&record)
        snapshot.models[requestedModel] = record
        snapshot.updatedAt = timestamp
        self.snapshot = snapshot
        persist(snapshot)
    }

    private func loadSnapshot() async -> OpenRouterHealthSnapshot {
        if let snapshot {
            return snapshot
        }
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode(OpenRouterHealthSnapshot.self, from: data) else {
            let empty = OpenRouterHealthSnapshot(updatedAt: Date(), models: [:])
            self.snapshot = empty
            return empty
        }
        self.snapshot = decoded
        return decoded
    }

    private func persist(_ snapshot: OpenRouterHealthSnapshot) {
        do {
            try fileManager.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(snapshot)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // Best-effort stats recording only.
        }
    }
}

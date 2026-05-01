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

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.fileURL = TelemetryPaths.applicationSupportURL(fileManager: fileManager)
            .appendingPathComponent("openrouter-health.json")
    }

    func snapshotFileURL() -> URL {
        fileURL
    }

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
            record.servedModelSuccesses[servedModel, default: 0] += 1
            if servedModel != requestedModel {
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
        timestamp: Date = Date()
    ) async {
        await mutateRecord(for: requestedModel, timestamp: timestamp) { record in
            record.attempts += 1
            record.failures += 1
            record.lastFailureAt = timestamp
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
            sourceBreakdown: [:]
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

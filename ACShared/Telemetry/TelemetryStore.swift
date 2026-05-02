//
//  TelemetryStore.swift
//  AC
//
//  Created by Codex on 13.04.26.
//

import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import os.log
import UniformTypeIdentifiers

private enum TelemetryLogging {
    nonisolated static let logger = Logger(subsystem: "dev.accountycat", category: "telemetry")
}

struct StoredImageArtifacts: Sendable {
    var original: ArtifactRef
    var thumbnail: ArtifactRef?
    var absoluteOriginalURL: URL
}

enum TelemetryPaths {
    nonisolated static func applicationSupportURL(fileManager: FileManager = .default) -> URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent("AC", isDirectory: true)
    }

    nonisolated static func telemetryRootURL(fileManager: FileManager = .default) -> URL {
        applicationSupportURL(fileManager: fileManager)
            .appendingPathComponent("telemetry", isDirectory: true)
    }

    nonisolated static func inspectorSupportURL(fileManager: FileManager = .default) -> URL {
        applicationSupportURL(fileManager: fileManager)
            .appendingPathComponent("inspector", isDirectory: true)
    }
}

actor TelemetryStore {
    static let shared = TelemetryStore()

    private let fileManager: FileManager
    private let rootURL: URL
    private var currentSession: TelemetrySessionDescriptor?

    init(
        rootURL: URL = TelemetryPaths.telemetryRootURL(),
        fileManager: FileManager = .default
    ) {
        self.rootURL = rootURL
        self.fileManager = fileManager
    }

    func rootDirectoryURL() -> URL {
        rootURL
    }

    func inspectorSupportDirectoryURL() -> URL {
        TelemetryPaths.inspectorSupportURL(fileManager: fileManager)
    }

    func currentSessionDescriptor() -> TelemetrySessionDescriptor? {
        currentSession
    }

    func ensureCurrentSession(reason: String = "app_launch") async throws -> TelemetrySessionDescriptor {
        if let currentSession {
            return currentSession
        }
        return try await startSession(reason: reason)
    }

    func startSession(reason: String, retentionDays: Int = 7) async throws -> TelemetrySessionDescriptor {
        try await cleanupExpiredSessions(retentionDays: retentionDays)

        if let currentSession {
            return currentSession
        }

        let startedAt = Date()
        let sessionID = Self.makeSessionID(date: startedAt)
        let sessionURL = rootURL.appendingPathComponent(sessionID, isDirectory: true)
        let artifactsURL = sessionURL.appendingPathComponent("artifacts", isDirectory: true)

        try fileManager.createDirectory(at: artifactsURL, withIntermediateDirectories: true, attributes: nil)

        let descriptor = TelemetrySessionDescriptor(
            id: sessionID,
            startedAt: startedAt,
            endedAt: nil,
            reason: reason,
            retentionDays: retentionDays,
            eventsRelativePath: "events.jsonl",
            artifactsRelativePath: "artifacts"
        )

        try await saveSessionDescriptor(descriptor)
        currentSession = descriptor

        try await appendEvent(
            TelemetryEvent(
                id: UUID().uuidString,
                kind: .sessionStarted,
                timestamp: startedAt,
                sessionID: sessionID,
                episodeID: nil,
                episode: nil,
                session: SessionLifecycleRecord(reason: reason),
                observation: nil,
                evaluation: nil,
                modelInput: nil,
                modelOutput: nil,
                parsedOutput: nil,
                policy: nil,
                action: nil,
                reaction: nil,
                annotation: nil,
                failure: nil
            ),
            sessionID: sessionID
        )

        return descriptor
    }

    func endCurrentSession(reason: String) async {
        guard var currentSession else {
            return
        }

        let endedAt = Date()
        do {
            try await appendEvent(
                TelemetryEvent(
                    id: UUID().uuidString,
                    kind: .sessionEnded,
                    timestamp: endedAt,
                    sessionID: currentSession.id,
                    episodeID: nil,
                    episode: nil,
                    session: SessionLifecycleRecord(reason: reason),
                    observation: nil,
                    evaluation: nil,
                    modelInput: nil,
                    modelOutput: nil,
                    parsedOutput: nil,
                    policy: nil,
                    action: nil,
                    reaction: nil,
                    annotation: nil,
                    failure: nil
                ),
                sessionID: currentSession.id
            )
            currentSession.endedAt = endedAt
            try await saveSessionDescriptor(currentSession)
        } catch {
            TelemetryLogging.logger.error("failed to close telemetry session: \(error.localizedDescription, privacy: .public)")
        }

        self.currentSession = nil
    }

    func listSessions() async -> [TelemetrySessionDescriptor] {
        guard let contents = try? fileManager.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: nil) else {
            return []
        }

        var sessions: [TelemetrySessionDescriptor] = []
        for sessionURL in contents {
            let descriptorURL = sessionURL.appendingPathComponent("session.json")
            guard let data = try? Data(contentsOf: descriptorURL),
                  let descriptor = try? await Self.decodeJSON(TelemetrySessionDescriptor.self, from: data) else {
                continue
            }
            sessions.append(descriptor)
        }

        return sessions.sorted { $0.startedAt > $1.startedAt }
    }

    func loadEvents(sessionID: String) async -> [TelemetryEvent] {
        let eventsURL = sessionDirectoryURL(for: sessionID)
            .appendingPathComponent("events.jsonl")
        guard let contents = try? String(contentsOf: eventsURL, encoding: .utf8) else {
            return []
        }

        var events: [TelemetryEvent] = []
        for line in contents.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let event = try? await Self.decodeJSON(TelemetryEvent.self, from: data) else {
                continue
            }
            events.append(event)
        }
        return events
    }

    func appendEvent(_ event: TelemetryEvent, sessionID: String? = nil) async throws {
        let resolvedSessionID: String
        if let sessionID {
            resolvedSessionID = sessionID
        } else {
            resolvedSessionID = try await ensureCurrentSession().id
        }
        let sessionURL = sessionDirectoryURL(for: resolvedSessionID)
        let eventsURL = sessionURL.appendingPathComponent("events.jsonl")

        try fileManager.createDirectory(at: sessionURL, withIntermediateDirectories: true, attributes: nil)

        let data = try await Self.encodeJSON(event, sortedKeys: true)
        let lineData = data + Data("\n".utf8)

        if fileManager.fileExists(atPath: eventsURL.path) {
            let handle = try FileHandle(forWritingTo: eventsURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: lineData)
        } else {
            try lineData.write(to: eventsURL, options: .atomic)
        }
    }

    func appendAnnotation(_ annotation: EpisodeAnnotation, episode: EpisodeRecord?) async throws {
        try await appendEvent(
            TelemetryEvent(
                id: UUID().uuidString,
                kind: .annotationSaved,
                timestamp: annotation.createdAt,
                sessionID: annotation.sessionID,
                episodeID: annotation.episodeID,
                episode: episode,
                session: nil,
                observation: nil,
                evaluation: nil,
                modelInput: nil,
                modelOutput: nil,
                parsedOutput: nil,
                policy: nil,
                action: nil,
                reaction: nil,
                annotation: annotation,
                failure: nil
            ),
            sessionID: annotation.sessionID
        )
    }

    func writePromptTemplateArtifact(
        contents: String,
        sessionID: String,
        template: PromptTemplateRecord
    ) async throws -> ArtifactRef {
        let templateDirectory = sessionDirectoryURL(for: sessionID)
            .appendingPathComponent("artifacts/prompt-templates", isDirectory: true)
        try fileManager.createDirectory(at: templateDirectory, withIntermediateDirectories: true, attributes: nil)

        let filename = "\(template.id)-\(template.sha256.prefix(12)).md"
        let url = templateDirectory.appendingPathComponent(filename)
        if !fileManager.fileExists(atPath: url.path) {
            guard let data = contents.data(using: .utf8) else {
                throw CocoaError(.fileWriteInapplicableStringEncoding)
            }
            try data.write(to: url, options: .atomic)
        }
        let data = try Data(contentsOf: url)
        return makeArtifactRef(
            kind: .promptTemplate,
            relativePath: relativeArtifactPath(for: url, sessionID: sessionID),
            data: data,
            width: nil,
            height: nil
        )
    }

    func writeJSONArtifact<T: Encodable & Sendable>(
        _ value: T,
        sessionID: String,
        prefix: String,
        kind: ArtifactKind
    ) async throws -> ArtifactRef {
        let data = try await Self.encodeJSON(value, sortedKeys: true)
        return try await writeArtifactData(
            data,
            sessionID: sessionID,
            prefix: prefix,
            fileExtension: "json",
            kind: kind,
            width: nil,
            height: nil
        )
    }

    func writeTextArtifact(
        _ text: String,
        sessionID: String,
        prefix: String,
        kind: ArtifactKind
    ) async throws -> ArtifactRef {
        let data = Data(text.utf8)
        return try await writeArtifactData(
            data,
            sessionID: sessionID,
            prefix: prefix,
            fileExtension: "txt",
            kind: kind,
            width: nil,
            height: nil
        )
    }

    func writeScreenshotArtifacts(
        from sourceURL: URL,
        sessionID: String,
        stem: String
    ) async throws -> StoredImageArtifacts {
        let data = try Data(contentsOf: sourceURL)
        let imageSource = CGImageSourceCreateWithData(data as CFData, nil)

        let properties = imageSource.flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any] }
        let width = properties?[kCGImagePropertyPixelWidth] as? Int
        let height = properties?[kCGImagePropertyPixelHeight] as? Int

        let originalRef = try await writeArtifactData(
            data,
            sessionID: sessionID,
            prefix: stem,
            fileExtension: sourceURL.pathExtension.isEmpty ? "png" : sourceURL.pathExtension,
            kind: .screenshotOriginal,
            width: width,
            height: height
        )
        let originalURL = absoluteArtifactURL(for: originalRef, sessionID: sessionID)

        let thumbnailRef: ArtifactRef?
        if let imageSource,
           let thumbnailData = Self.makeThumbnailData(imageSource: imageSource) {
            thumbnailRef = try await writeArtifactData(
                thumbnailData,
                sessionID: sessionID,
                prefix: "\(stem)-thumb",
                fileExtension: "png",
                kind: .screenshotThumbnail,
                width: 320,
                height: 200
            )
        } else {
            thumbnailRef = nil
        }

        return StoredImageArtifacts(
            original: originalRef,
            thumbnail: thumbnailRef,
            absoluteOriginalURL: originalURL
        )
    }

    func absoluteArtifactURL(for artifact: ArtifactRef, sessionID: String) -> URL {
        if artifact.relativePath.hasPrefix("/") {
            return URL(fileURLWithPath: artifact.relativePath)
        }
        return sessionDirectoryURL(for: sessionID).appendingPathComponent(artifact.relativePath)
    }

    func exportManifest(
        sessionIDs: [String],
        to sessionID: String,
        manifest: TrainingExportManifest
    ) async throws -> ArtifactRef {
        _ = sessionIDs
        return try await writeJSONArtifact(
            manifest,
            sessionID: sessionID,
            prefix: "training-export-manifest",
            kind: .exportManifest
        )
    }

    func cleanupExpiredSessions(retentionDays: Int = 7) async throws {
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true, attributes: nil)

        let sessions = await listSessions()
        let cutoff = Date().addingTimeInterval(TimeInterval(-retentionDays * 24 * 60 * 60))

        for session in sessions where session.startedAt < cutoff {
            let sessionURL = sessionDirectoryURL(for: session.id)
            if try await sessionContainsPinnedAnnotation(sessionURL: sessionURL) {
                continue
            }
            try? fileManager.removeItem(at: sessionURL)
        }
    }

    private func saveSessionDescriptor(_ descriptor: TelemetrySessionDescriptor) async throws {
        let sessionURL = sessionDirectoryURL(for: descriptor.id)
        try fileManager.createDirectory(at: sessionURL, withIntermediateDirectories: true, attributes: nil)
        let data = try await Self.encodeJSON(descriptor, sortedKeys: true)
        try data.write(
            to: sessionURL.appendingPathComponent("session.json"),
            options: .atomic
        )
    }

    private func sessionContainsPinnedAnnotation(sessionURL: URL) async throws -> Bool {
        let eventsURL = sessionURL.appendingPathComponent("events.jsonl")
        guard let contents = try? String(contentsOf: eventsURL, encoding: .utf8) else {
            return false
        }

        for line in contents.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let event = try? await Self.decodeJSON(TelemetryEvent.self, from: data) else {
                continue
            }
            if event.kind == .annotationSaved, event.annotation?.pinned == true {
                return true
            }
        }
        return false
    }

    private func writeArtifactData(
        _ data: Data,
        sessionID: String,
        prefix: String,
        fileExtension: String,
        kind: ArtifactKind,
        width: Int?,
        height: Int?
    ) async throws -> ArtifactRef {
        let artifactsURL = sessionDirectoryURL(for: sessionID)
            .appendingPathComponent("artifacts", isDirectory: true)
        try fileManager.createDirectory(at: artifactsURL, withIntermediateDirectories: true, attributes: nil)

        let filename = "\(prefix)-\(UUID().uuidString).\(fileExtension)"
        let destinationURL = artifactsURL.appendingPathComponent(filename)
        try data.write(to: destinationURL, options: .atomic)

        return makeArtifactRef(
            kind: kind,
            relativePath: relativeArtifactPath(for: destinationURL, sessionID: sessionID),
            data: data,
            width: width,
            height: height
        )
    }

    private func makeArtifactRef(
        kind: ArtifactKind,
        relativePath: String,
        data: Data,
        width: Int?,
        height: Int?
    ) -> ArtifactRef {
        ArtifactRef(
            id: UUID().uuidString,
            kind: kind,
            relativePath: relativePath,
            sha256: Self.sha256Hex(data),
            byteCount: data.count,
            width: width,
            height: height,
            createdAt: Date()
        )
    }

    private func sessionDirectoryURL(for sessionID: String) -> URL {
        rootURL.appendingPathComponent(sessionID, isDirectory: true)
    }

    private func relativeArtifactPath(for url: URL, sessionID: String) -> String {
        let sessionURL = sessionDirectoryURL(for: sessionID)
        let sessionPath = sessionURL.path
        let absolutePath = url.path
        if absolutePath.hasPrefix(sessionPath) {
            return String(absolutePath.dropFirst(sessionPath.count + 1))
        }
        return url.lastPathComponent
    }

    private static func makeSessionID(date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "session-\(formatter.string(from: date))-\(UUID().uuidString.prefix(8))"
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func makeThumbnailData(imageSource: CGImageSource) -> Data? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceThumbnailMaxPixelSize: 640,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options as CFDictionary) else {
            return nil
        }

        let mutable = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            mutable,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            return nil
        }
        return mutable as Data
    }

    private static func encodeJSON<T: Encodable & Sendable>(
        _ value: T,
        sortedKeys: Bool
    ) async throws -> Data {
        try await MainActor.run {
            let encoder = JSONEncoder()
            if sortedKeys {
                encoder.outputFormatting = [.sortedKeys]
            }
            encoder.dateEncodingStrategy = .iso8601
            return try encoder.encode(value)
        }
    }

    private static func decodeJSON<T: Decodable & Sendable>(
        _ type: T.Type,
        from data: Data
    ) async throws -> T {
        try await MainActor.run {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(T.self, from: data)
        }
    }
}

enum TrainingDatasetExporter {
    static func buildManifest(
        events: [TelemetryEvent],
        sessionIDs: [String]
    ) throws -> TrainingExportManifest {
        var annotationsByEpisode: [String: [EpisodeAnnotation]] = [:]
        var latestModelOutputByEpisode: [String: ModelOutputParsedRecord] = [:]
        var latestScreenshotByEpisode: [String: ArtifactRef] = [:]
        var latestPromptPayloadByEpisode: [String: ArtifactRef] = [:]
        var latestRenderedPromptByEpisode: [String: ArtifactRef] = [:]
        var strategyByEpisode: [String: MonitoringExecutionMetadataRecord] = [:]
        var shortTermOutcomeLabelsByEpisode: [String: Set<String>] = [:]

        for event in events {
            if let episodeID = event.episodeID,
               let annotation = event.annotation {
                annotationsByEpisode[episodeID, default: []].append(annotation)
            }
            if let episodeID = event.episodeID,
               let parsedOutput = event.parsedOutput {
                latestModelOutputByEpisode[episodeID] = parsedOutput
            }
            if let episodeID = event.episodeID,
               let modelInput = event.modelInput {
                latestScreenshotByEpisode[episodeID] = modelInput.screenshot
                if let promptPayloadArtifact = modelInput.promptPayloadArtifact {
                    latestPromptPayloadByEpisode[episodeID] = promptPayloadArtifact
                }
                if let renderedPromptArtifact = modelInput.renderedPromptArtifact {
                    latestRenderedPromptByEpisode[episodeID] = renderedPromptArtifact
                }
            }
            if let episodeID = event.episodeID,
               let strategy = event.evaluation?.strategy ??
                    event.policy?.strategy ??
                    event.action?.strategy {
                strategyByEpisode[episodeID] = strategy
            }
            if let episodeID = event.episodeID,
               let reaction = event.reaction {
                shortTermOutcomeLabelsByEpisode[episodeID, default: []].insert(reaction.kind.rawValue)
            }
        }

        var exports: [TrainingEpisodeExportRecord] = []

        for (episodeID, annotations) in annotationsByEpisode {
            let sourceSet = Set(annotations.map(\.source))
            if sourceSet.count > 1 {
                throw TrainingExportError.mixedAnnotationSources(episodeID)
            }

            guard let first = annotations.first else {
                continue
            }

            let labels = Array(
                Set(annotations.flatMap(\.labels))
            ).sorted { $0.rawValue < $1.rawValue }
            let note = annotations
                .map(\.note)
                .filter { !$0.isEmpty }
                .joined(separator: "\n\n")

            exports.append(
                TrainingEpisodeExportRecord(
                    sessionID: first.sessionID,
                    episodeID: episodeID,
                    strategy: strategyByEpisode[episodeID],
                    labels: labels,
                    note: note,
                    source: first.source,
                    screenshot: latestScreenshotByEpisode[episodeID],
                    promptPayload: latestPromptPayloadByEpisode[episodeID],
                    renderedPrompt: latestRenderedPromptByEpisode[episodeID],
                    modelOutput: latestModelOutputByEpisode[episodeID],
                    shortTermOutcomeLabels: Array(shortTermOutcomeLabelsByEpisode[episodeID] ?? []).sorted(),
                    longTermOutcomeLabels: labels.map(\.rawValue)
                )
            )
        }

        exports.sort {
            if $0.sessionID == $1.sessionID {
                return $0.episodeID < $1.episodeID
            }
            return $0.sessionID < $1.sessionID
        }

        return TrainingExportManifest(
            version: 2,
            generatedAt: Date(),
            sessionIDs: sessionIDs.sorted(),
            episodeCount: exports.count,
            episodes: exports
        )
    }
}

enum TrainingExportError: LocalizedError {
    case mixedAnnotationSources(String)

    var errorDescription: String? {
        switch self {
        case let .mixedAnnotationSources(episodeID):
            return "Episode \(episodeID) contains annotations from multiple source types."
        }
    }
}

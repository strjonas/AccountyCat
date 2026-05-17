//
//  ACEvalStore.swift
//  AC
//

import Foundation

nonisolated enum ACEvalStoreError: LocalizedError {
    case caseNotFound(String)
    case invalidCaseFolder(String)

    var errorDescription: String? {
        switch self {
        case let .caseNotFound(id):
            return "Eval case not found: \(id)"
        case let .invalidCaseFolder(id):
            return "Eval case folder is invalid: \(id)"
        }
    }
}

nonisolated struct ACEvalStore {
    let rootURL: URL
    private let fileManager: FileManager

    init(
        rootURL: URL = TelemetryPaths.applicationSupportURL()
            .appendingPathComponent("evals", isDirectory: true),
        fileManager: FileManager = .default
    ) {
        self.rootURL = rootURL
        self.fileManager = fileManager
    }

    var manifestURL: URL {
        rootURL.appendingPathComponent("manifest.json")
    }

    func casesRootURL() -> URL {
        rootURL.appendingPathComponent("cases", isDirectory: true)
    }

    func caseDirectoryURL(id: String) -> URL {
        casesRootURL().appendingPathComponent(id, isDirectory: true)
    }

    func caseFileURL(id: String) -> URL {
        caseDirectoryURL(id: id).appendingPathComponent("case.json")
    }

    @discardableResult
    func save(_ evalCase: ACEvalCase, copyArtifacts: Bool = true) throws -> ACEvalCase {
        var stored = evalCase
        stored.updatedAt = Date()

        let caseURL = caseDirectoryURL(id: stored.id)
        try fileManager.createDirectory(at: caseURL, withIntermediateDirectories: true)

        if copyArtifacts {
            stored = try copyCaseArtifacts(for: stored, into: caseURL)
        }

        let data = try Self.encoder.encode(stored)
        try data.write(to: caseFileURL(id: stored.id), options: .atomic)
        try regenerateManifest()
        return stored
    }

    func load(id: String) throws -> ACEvalCase {
        let url = caseFileURL(id: id)
        guard fileManager.fileExists(atPath: url.path) else {
            throw ACEvalStoreError.caseNotFound(id)
        }
        return try Self.decoder.decode(ACEvalCase.self, from: Data(contentsOf: url))
    }

    func loadAll() throws -> [ACEvalCase] {
        let root = casesRootURL()
        guard let contents = try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return try contents
            .filter { $0.hasDirectoryPath }
            .compactMap { directory -> ACEvalCase? in
                let fileURL = directory.appendingPathComponent("case.json")
                guard fileManager.fileExists(atPath: fileURL.path) else { return nil }
                return try Self.decoder.decode(ACEvalCase.self, from: Data(contentsOf: fileURL))
            }
            .sorted { lhs, rhs in
                if lhs.importance.rank == rhs.importance.rank {
                    return lhs.updatedAt > rhs.updatedAt
                }
                return lhs.importance.rank > rhs.importance.rank
            }
    }

    func delete(id: String) throws {
        let directory = caseDirectoryURL(id: id)
        guard fileManager.fileExists(atPath: directory.path) else {
            throw ACEvalStoreError.caseNotFound(id)
        }
        try fileManager.removeItem(at: directory)
        try regenerateManifest()
    }

    func loadManifest() throws -> ACEvalManifest {
        if fileManager.fileExists(atPath: manifestURL.path) {
            return try Self.decoder.decode(ACEvalManifest.self, from: Data(contentsOf: manifestURL))
        }
        return try regenerateManifest()
    }

    @discardableResult
    func regenerateManifest() throws -> ACEvalManifest {
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let cases = try loadAll()
        let manifest = ACEvalManifest(
            version: 1,
            generatedAt: Date(),
            caseCount: cases.count,
            cases: cases.map(Self.manifestEntry)
        )
        let data = try Self.encoder.encode(manifest)
        try data.write(to: manifestURL, options: .atomic)
        return manifest
    }

    func query(
        kind: ACEvalKind? = nil,
        importances: Set<ACEvalImportance> = [],
        categories: Set<String> = [],
        limit: Int? = nil
    ) throws -> [ACEvalCase] {
        var cases = try loadAll()
        if let kind {
            cases = cases.filter { $0.kind == kind }
        }
        if !importances.isEmpty {
            cases = cases.filter { importances.contains($0.importance) }
        }
        if !categories.isEmpty {
            let normalized = Set(categories.map(Self.normalizeCategory))
            cases = cases.filter { evalCase in
                let caseCategories = Set(evalCase.categories.map(Self.normalizeCategory))
                return !caseCategories.isDisjoint(with: normalized)
            }
        }
        if let limit, limit > 0 {
            cases = Array(cases.prefix(limit))
        }
        return cases
    }

    private func copyCaseArtifacts(for evalCase: ACEvalCase, into caseURL: URL) throws -> ACEvalCase {
        var stored = evalCase
        guard let screenshotPath = evalCase.source.screenshotPath ?? evalCase.focusInput?.screenshotPath,
              !screenshotPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return stored
        }

        let sourceURL = URL(fileURLWithPath: screenshotPath)
        guard fileManager.fileExists(atPath: sourceURL.path) else {
            return stored
        }

        let artifactsURL = caseURL.appendingPathComponent("artifacts", isDirectory: true)
        try fileManager.createDirectory(at: artifactsURL, withIntermediateDirectories: true)
        let ext = sourceURL.pathExtension.isEmpty ? "png" : sourceURL.pathExtension
        let targetURL = artifactsURL.appendingPathComponent("screenshot.\(ext)")
        if fileManager.fileExists(atPath: targetURL.path) {
            try fileManager.removeItem(at: targetURL)
        }
        try fileManager.copyItem(at: sourceURL, to: targetURL)
        stored.source.screenshotPath = targetURL.path
        if stored.focusInput != nil {
            stored.focusInput?.screenshotPath = targetURL.path
        }
        return stored
    }

    private static func manifestEntry(for evalCase: ACEvalCase) -> ACEvalManifestEntry {
        ACEvalManifestEntry(
            id: evalCase.id,
            name: evalCase.name,
            kind: evalCase.kind,
            importance: evalCase.importance,
            categories: evalCase.categories,
            sourceEpisodeID: evalCase.source.episodeID,
            appName: evalCase.source.appName,
            bundleIdentifier: evalCase.source.bundleIdentifier,
            windowTitle: evalCase.source.windowTitle,
            hasScreenshot: evalCase.hasScreenshot,
            expectedOutcomeSummary: evalCase.expectedOutcomeSummary,
            recommendedBackend: evalCase.recommendedBackend,
            updatedAt: evalCase.updatedAt
        )
    }

    static func normalizeCategory(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "-", with: "_")
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

//
//  RuntimeSetupService.swift
//  AC
//
//  Created by Codex on 12.04.26.
//

import Foundation

enum RuntimeSetupService {
    nonisolated private static let runtimeRepositoryRemote = "https://github.com/ggml-org/llama.cpp.git"
    nonisolated private static let pinnedLlamaCommit = "a279d0f0f4e746d1ef3429d8e9d02d2990b2daa7"

    /// Minimum free disk space we require before we start pulling the runtime + model.
    /// Model alone is ~4.4GB compressed; we leave headroom for the llama.cpp build
    /// artifacts, HF cache metadata, and user margin.
    nonisolated static let requiredFreeBytesForInstall: Int64 = 6 * 1024 * 1024 * 1024

    nonisolated private static func modelCacheRelativePath(for modelIdentifier: String) -> String {
        DevelopmentModelConfiguration.cacheRelativePath(for: modelIdentifier)
    }

    nonisolated private static var preferredBaseDirectory: URL {
        TelemetryPaths.applicationSupportURL()
            .appendingPathComponent("runtime", isDirectory: true)
    }

    nonisolated private static var legacyBaseDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("accountycat", isDirectory: true)
    }

    nonisolated static var defaultRuntimePath: String {
        runtimeBinaryURL(in: resolvedBaseDirectory()).path
    }

    nonisolated static var defaultRuntimeDirectory: String {
        runtimeRepositoryURL(in: resolvedBaseDirectory()).path
    }

    nonisolated static var managedHuggingFaceCachePath: String {
        defaultHuggingFaceCacheURL().path
    }

    nonisolated static func inspect(runtimeOverride: String?, modelIdentifier: String) -> RuntimeDiagnostics {
        let runtimePath = normalizedRuntimePath(from: runtimeOverride)
        let runtimeDirectory = runtimeDirectoryPath(for: runtimePath)
        let modelCacheRoots = modelCacheRoots(
            forRuntimePath: runtimePath,
            modelIdentifier: modelIdentifier
        )
        let resolvedArtifacts = resolvedModelArtifacts(
            cacheRoots: modelCacheRoots,
            modelIdentifier: modelIdentifier
        )
        let existingModelCacheRoot = modelCacheRoots.first {
            FileManager.default.fileExists(atPath: $0.path)
        }
        let modelCachePath = (existingModelCacheRoot ?? modelCacheRoots.first)?.path ?? ""
        let modelCachePresent = existingModelCacheRoot != nil
        let managedModelCachePath = managedModelCacheURL(for: modelIdentifier).path
        let modelArtifactsPresent = resolvedArtifacts != nil
        let tools = ["git", "cmake", "ninja"]
        let missingTools = tools.filter { tool in
            !toolExists(tool)
        }

        return RuntimeDiagnostics(
            runtimePath: runtimePath,
            runtimeDirectory: runtimeDirectory,
            runtimePresent: FileManager.default.isExecutableFile(atPath: runtimePath),
            modelCachePath: modelCachePath,
            managedModelCachePath: managedModelCachePath,
            modelCachePresent: modelCachePresent,
            modelArtifactsPresent: modelArtifactsPresent,
            resolvedModelPath: resolvedArtifacts?.modelURL.path,
            resolvedProjectorPath: resolvedArtifacts?.projectorURL?.path,
            missingTools: missingTools
        )
    }

    nonisolated static func managedModelCacheURL(for modelIdentifier: String) -> URL {
        let repository = DevelopmentModelConfiguration.repositoryIdentifier(for: modelIdentifier)
        let cacheDirectoryName = "models--\(repository.replacingOccurrences(of: "/", with: "--"))"
        return defaultHuggingFaceCacheURL()
            .appendingPathComponent("hub", isDirectory: true)
            .appendingPathComponent(cacheDirectoryName, isDirectory: true)
    }

    @discardableResult
    static func deleteManagedModelCache(for modelIdentifier: String) throws -> Bool {
        let cacheURL = managedModelCacheURL(for: modelIdentifier)
        guard FileManager.default.fileExists(atPath: cacheURL.path) else {
            return false
        }
        try FileManager.default.removeItem(at: cacheURL)
        return true
    }

    @discardableResult
    static func deleteAllManagedModelCaches() throws -> Bool {
        let hubURL = defaultHuggingFaceCacheURL().appendingPathComponent("hub", isDirectory: true)
        guard FileManager.default.fileExists(atPath: hubURL.path) else {
            return false
        }
        try FileManager.default.removeItem(at: hubURL)
        return true
    }

    @discardableResult
    static func deleteManagedModelCache(at cachePath: String) throws -> Bool {
        let cacheURL = URL(fileURLWithPath: cachePath)
        guard FileManager.default.fileExists(atPath: cacheURL.path) else {
            return false
        }
        try FileManager.default.removeItem(at: cacheURL)
        return true
    }

    @discardableResult
    static func deleteCachesCreatedByAC(
        for modelIdentifier: String,
        selectedCachePath: String,
        runtimePath: String
    ) throws -> Int {
        var removed = 0
        var seenPaths = Set<String>()

        let candidateURLs = [
            URL(fileURLWithPath: selectedCachePath),
            modelCacheURL(forRuntimePath: runtimePath, modelIdentifier: modelIdentifier)
        ]

        for url in candidateURLs {
            let standardizedPath = url.standardizedFileURL.path
            guard seenPaths.insert(standardizedPath).inserted else { continue }
            guard FileManager.default.fileExists(atPath: standardizedPath) else { continue }
            try FileManager.default.removeItem(at: URL(fileURLWithPath: standardizedPath))
            removed += 1
        }

        return removed
    }

    nonisolated static func managedInstalledModels() -> [InstalledLocalModel] {
        let hubURL = defaultHuggingFaceCacheURL().appendingPathComponent("hub", isDirectory: true)
        guard
            let cacheRoots = try? FileManager.default.contentsOfDirectory(
                at: hubURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        else {
            return []
        }

        return cacheRoots.compactMap { cacheRoot in
            let values = try? cacheRoot.resourceValues(forKeys: [.isDirectoryKey])
            guard values?.isDirectory == true else { return nil }
            guard cacheRoot.lastPathComponent.hasPrefix("models--") else { return nil }

            let repository = repositoryIdentifier(fromCacheDirectoryName: cacheRoot.lastPathComponent)
            guard
                let artifacts = resolvedModelArtifacts(
                    cacheRoots: [cacheRoot],
                    modelIdentifier: repository
                )
            else {
                return nil
            }

            let modelIdentifier = inferredModelIdentifier(
                repository: repository,
                modelURL: artifacts.modelURL
            )
            return InstalledLocalModel(
                modelIdentifier: modelIdentifier,
                repositoryIdentifier: repository,
                cachePath: cacheRoot.path,
                snapshotPath: artifacts.snapshotURL.path,
                modelPath: artifacts.modelURL.path,
                projectorPath: artifacts.projectorURL?.path
            )
        }
        .sorted { lhs, rhs in
            lhs.modelIdentifier.localizedCaseInsensitiveCompare(rhs.modelIdentifier) == .orderedAscending
        }
    }

    static func installRuntime(log: @escaping @MainActor (String) -> Void) async throws {
        let baseDirectory = installBaseDirectory()
        try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        try verifyFreeDiskSpace(at: baseDirectory)
        guard let cmakePath = resolvedToolPath("cmake") else {
            throw RuntimeSetupError.commandFailed("cmake", 127, stderrTail: "`cmake` is missing. Install Xcode Command Line Tools or Homebrew cmake and retry.")
        }

        let repoURL = runtimeRepositoryURL(in: baseDirectory)
        if !FileManager.default.fileExists(atPath: repoURL.path) {
            try await runStreaming(
                launchPath: "/usr/bin/git",
                arguments: ["clone", runtimeRepositoryRemote],
                currentDirectory: baseDirectory,
                log: log
            )
        } else {
            await MainActor.run {
                log("$ git clone skipped, repo already exists at \(repoURL.path)")
            }
        }

        try await runStreaming(
            launchPath: "/usr/bin/git",
            arguments: ["fetch", "--depth", "1", "origin", pinnedLlamaCommit],
            currentDirectory: repoURL,
            log: log
        )

        try await runStreaming(
            launchPath: "/usr/bin/git",
            arguments: ["checkout", "--detach", pinnedLlamaCommit],
            currentDirectory: repoURL,
            log: log
        )

        try await runStreaming(
            launchPath: cmakePath,
            arguments: [
                "-B", "build",
                "-G", "Ninja",
                "-DGGML_METAL=ON",
                "-DCMAKE_BUILD_TYPE=Release",
            ],
            currentDirectory: repoURL,
            log: log
        )

        try await runStreaming(
            launchPath: cmakePath,
            arguments: ["--build", "build", "-j"],
            currentDirectory: repoURL,
            log: log
        )
    }

    static func warmUpRuntime(
        runtimePath: String,
        modelIdentifier: String,
        log: @escaping @MainActor (String) -> Void
    ) async throws {
        let runtimeURL = URL(fileURLWithPath: runtimePath)
        let repoURL = runtimeURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let huggingFaceCacheURL = defaultHuggingFaceCacheURL()
        try FileManager.default.createDirectory(at: huggingFaceCacheURL, withIntermediateDirectories: true)
        try verifyFreeDiskSpace(at: huggingFaceCacheURL)

        // Remove any leftover partial blobs from a previous interrupted download
        // so the retry doesn't trip over stale files. Safe best-effort; never throws.
        let removedPartials = cleanupInterruptedDownloads(in: huggingFaceCacheURL)
        if removedPartials > 0 {
            await MainActor.run {
                log("Cleaned up \(removedPartials) partial download file(s) from a previous run.")
            }
        }

        try await runStreaming(
            launchPath: runtimePath,
            arguments: [
                "-hf", modelIdentifier,
                "-p", "Reply with OK.",
                "-n", "8",
                "--reasoning", "off",
                "--temp", "0.1",
                "--ctx-size", "1024",
                "--batch-size", "128",
                "--ubatch-size", "64",
                "--no-display-prompt",
            ],
            currentDirectory: repoURL,
            environmentOverrides: ["HF_HOME": huggingFaceCacheURL.path],
            log: log
        )
    }

    nonisolated static func normalizedRuntimePath(from override: String?) -> String {
        guard let override, !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return Self.defaultRuntimePath
        }
        return override.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated private static func resolvedBaseDirectory(fileManager: FileManager = .default) -> URL {
        let legacyRepoURL = runtimeRepositoryURL(in: legacyBaseDirectory)
        if fileManager.fileExists(atPath: legacyRepoURL.path) {
            return legacyBaseDirectory
        }

        return preferredBaseDirectory
    }

    nonisolated private static func installBaseDirectory(fileManager: FileManager = .default) -> URL {
        let legacyRepoURL = runtimeRepositoryURL(in: legacyBaseDirectory)
        if fileManager.fileExists(atPath: legacyRepoURL.path) {
            return legacyBaseDirectory
        }

        return preferredBaseDirectory
    }

    nonisolated private static func runtimeDirectoryPath(for runtimePath: String) -> String {
        runtimeRepositoryURL(forRuntimePath: runtimePath).path
    }

    nonisolated private static func runtimeBinaryURL(in baseDirectory: URL) -> URL {
        runtimeRepositoryURL(in: baseDirectory)
            .appendingPathComponent("build/bin/llama-cli")
    }

    nonisolated private static func runtimeRepositoryURL(in baseDirectory: URL) -> URL {
        baseDirectory.appendingPathComponent("llama.cpp", isDirectory: true)
    }

    nonisolated private static func runtimeRepositoryURL(forRuntimePath runtimePath: String) -> URL {
        URL(fileURLWithPath: runtimePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    nonisolated private static func modelCacheURL(forRuntimePath runtimePath: String, modelIdentifier: String) -> URL {
        runtimeRepositoryURL(forRuntimePath: runtimePath)
            .appendingPathComponent(modelCacheRelativePath(for: modelIdentifier), isDirectory: true)
    }

    nonisolated private static func hasModelArtifacts(
        cacheRoots: [URL],
        modelIdentifier: String
    ) -> Bool {
        resolvedModelArtifacts(cacheRoots: cacheRoots, modelIdentifier: modelIdentifier) != nil
    }

    nonisolated private static func modelCacheRoots(
        forRuntimePath runtimePath: String,
        modelIdentifier: String
    ) -> [URL] {
        let repository = DevelopmentModelConfiguration.repositoryIdentifier(for: modelIdentifier)
        let cacheDirectoryName = "models--\(repository.replacingOccurrences(of: "/", with: "--"))"
        return [
            defaultHuggingFaceCacheURL()
                .appendingPathComponent("hub", isDirectory: true)
                .appendingPathComponent(cacheDirectoryName, isDirectory: true)
        ]
    }

    nonisolated private static func defaultHuggingFaceCacheURL() -> URL {
        TelemetryPaths.applicationSupportURL()
            .appendingPathComponent("runtime", isDirectory: true)
            .appendingPathComponent("hf-cache", isDirectory: true)
    }

    nonisolated private static func resolvedModelArtifacts(
        cacheRoots: [URL],
        modelIdentifier: String
    ) -> ResolvedModelArtifacts? {
        let components = modelIdentifier.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard components.first != nil else {
            return nil
        }

        let quant = components.count > 1 ? String(components[1]).uppercased() : nil
        for cacheRoot in cacheRoots where FileManager.default.fileExists(atPath: cacheRoot.path) {
            let snapshotsRoot = cacheRoot.appendingPathComponent("snapshots", isDirectory: true)
            guard let snapshotURL = resolvedSnapshotURL(cacheRoot: cacheRoot, snapshotsRoot: snapshotsRoot) else {
                continue
            }

            guard
                let files = try? FileManager.default.contentsOfDirectory(
                    at: snapshotURL,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                )
            else {
                continue
            }

            let ggufFiles = files.filter { $0.pathExtension.lowercased() == "gguf" }
            let projectorURL = ggufFiles.first {
                $0.lastPathComponent.lowercased().contains("mmproj")
            }
            let modelCandidates = ggufFiles.filter {
                !$0.lastPathComponent.lowercased().contains("mmproj")
            }
            guard let modelURL = selectModelFile(from: modelCandidates, quant: quant) else {
                continue
            }

            return ResolvedModelArtifacts(
                cacheRoot: cacheRoot,
                snapshotURL: snapshotURL,
                modelURL: modelURL,
                projectorURL: projectorURL
            )
        }

        return nil
    }

    nonisolated private static func selectModelFile(from candidates: [URL], quant: String?) -> URL? {
        guard !candidates.isEmpty else { return nil }
        guard let quant, !quant.isEmpty else { return candidates.first }

        return candidates.first { candidate in
            let basename = candidate.deletingPathExtension().lastPathComponent.uppercased()
            return basename.hasSuffix("-\(quant)") ||
                basename.hasSuffix("_\(quant)") ||
                basename.contains("-\(quant)-") ||
                basename.contains("_\(quant)_") ||
                basename.contains(quant)
        } ?? candidates.first
    }

    nonisolated private static func repositoryIdentifier(fromCacheDirectoryName directoryName: String) -> String {
        let encoded = String(directoryName.dropFirst("models--".count))
        return encoded.replacingOccurrences(of: "--", with: "/")
    }

    nonisolated private static func inferredModelIdentifier(repository: String, modelURL: URL) -> String {
        let baseName = modelURL.deletingPathExtension().lastPathComponent
        let repositoryName = repository.components(separatedBy: "/").last ?? repository
        let normalizedRepositoryName = repositoryName.replacingOccurrences(of: "-GGUF", with: "")
        let quant: String?
        if baseName.hasPrefix(normalizedRepositoryName + "-") {
            quant = String(baseName.dropFirst(normalizedRepositoryName.count + 1))
        } else if baseName.hasPrefix(normalizedRepositoryName + "_") {
            quant = String(baseName.dropFirst(normalizedRepositoryName.count + 1))
        } else {
            quant = nil
        }

        guard let quant, !quant.isEmpty else {
            return repository
        }
        return "\(repository):\(quant)"
    }

    nonisolated private static func resolvedSnapshotURL(cacheRoot: URL, snapshotsRoot: URL) -> URL? {
        let refsMainURL = cacheRoot.appendingPathComponent("refs/main")
        if let ref = try? String(contentsOf: refsMainURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !ref.isEmpty {
            let snapshotURL = snapshotsRoot.appendingPathComponent(ref, isDirectory: true)
            if FileManager.default.fileExists(atPath: snapshotURL.path) {
                return snapshotURL
            }
        }

        guard
            let snapshots = try? FileManager.default.contentsOfDirectory(
                at: snapshotsRoot,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ),
            !snapshots.isEmpty
        else {
            return nil
        }

        return snapshots.max {
            let lhsDate = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let rhsDate = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return lhsDate < rhsDate
        }
    }

    nonisolated private static func toolExists(_ tool: String) -> Bool {
        resolvedToolPath(tool) != nil
    }

    nonisolated private static func resolvedToolPath(_ tool: String) -> String? {
        let commonLocations = [
            "/usr/bin/\(tool)",
            "/usr/local/bin/\(tool)",
            "/opt/homebrew/bin/\(tool)",
        ]

        if commonLocations.contains(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return commonLocations.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
        }

        return ProcessInfo.processInfo.environment["PATH"]?
            .split(separator: ":")
            .map(String.init)
            .first { directory in
                FileManager.default.isExecutableFile(atPath: "\(directory)/\(tool)")
            }
            .map { "\($0)/\(tool)" }
    }

    private static func runStreaming(
        launchPath: String,
        arguments: [String],
        currentDirectory: URL,
        environmentOverrides: [String: String] = [:],
        log: @escaping @MainActor (String) -> Void
    ) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectory
        var environment = ProcessInfo.processInfo.environment
        for (key, value) in environmentOverrides {
            environment[key] = value
        }
        process.environment = environment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // Capture recent stderr lines so we can surface them if the process fails.
        // stdout can be verbose build noise; stderr is what usually carries the
        // actual error (git, cmake, llama.cpp all write failures there).
        let tail = OutputTail()

        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in log(chunk) }
        }

        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
            tail.append(chunk)
            Task { @MainActor in log(chunk) }
        }

        try process.run()
        let status = await waitForProcess(process)
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil

        if status != 0 {
            throw RuntimeSetupError.commandFailed(
                arguments.joined(separator: " "),
                status,
                stderrTail: tail.snapshot()
            )
        }
    }

    private static func waitForProcess(_ process: Process) async -> Int32 {
        await withCheckedContinuation { continuation in
            process.terminationHandler = { finishedProcess in
                continuation.resume(returning: finishedProcess.terminationStatus)
            }
        }
    }

    nonisolated private static func verifyFreeDiskSpace(at url: URL) throws {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let available = values?.volumeAvailableCapacityForImportantUsage else {
            // Couldn't determine — don't block the user, let the install proceed.
            return
        }
        if available < requiredFreeBytesForInstall {
            throw RuntimeSetupError.insufficientDiskSpace(
                availableBytes: available,
                requiredBytes: requiredFreeBytesForInstall
            )
        }
    }

    /// Removes obvious partial-download leftovers (`*.incomplete`, `*.partial`,
    /// `*.tmp`, `*.downloading`) from the Hugging Face cache. Older than 60s
    /// to avoid racing an in-flight download from another process.
    ///
    /// Best-effort; returns the number of files removed.
    @discardableResult
    nonisolated private static func cleanupInterruptedDownloads(in cacheRoot: URL) -> Int {
        let fileManager = FileManager.default
        guard
            let enumerator = fileManager.enumerator(
                at: cacheRoot,
                includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
        else { return 0 }

        let partialSuffixes = [".incomplete", ".partial", ".tmp", ".downloading"]
        let cutoff = Date().addingTimeInterval(-60)
        var removed = 0

        for case let url as URL in enumerator {
            let lower = url.lastPathComponent.lowercased()
            guard partialSuffixes.contains(where: { lower.hasSuffix($0) }) else { continue }
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            let modified = values?.contentModificationDate ?? .distantPast
            guard modified < cutoff else { continue }
            if (try? fileManager.removeItem(at: url)) != nil {
                removed += 1
            }
        }
        return removed
    }
}

private struct ResolvedModelArtifacts: Sendable {
    var cacheRoot: URL
    var snapshotURL: URL
    var modelURL: URL
    var projectorURL: URL?
}

/// Rolling buffer for the last N lines of stderr so we can include them when
/// reporting a subprocess failure.
nonisolated private final class OutputTail: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    private let maxLines = 40

    func append(_ chunk: String) {
        let pieces = chunk.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        lock.lock()
        for piece in pieces {
            let trimmed = piece.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            lines.append(trimmed)
        }
        if lines.count > maxLines {
            lines.removeFirst(lines.count - maxLines)
        }
        lock.unlock()
    }

    func snapshot() -> String {
        lock.lock()
        defer { lock.unlock() }
        return lines.joined(separator: "\n")
    }
}

enum RuntimeSetupError: LocalizedError {
    case commandFailed(String, Int32, stderrTail: String)
    case insufficientDiskSpace(availableBytes: Int64, requiredBytes: Int64)

    var errorDescription: String? {
        switch self {
        case let .commandFailed(command, status, stderrTail):
            let friendly = Self.friendlyDescription(forCommand: command, status: status)
            var message = friendly ?? "Command failed (\(status)): \(command)"
            let trimmed = stderrTail.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                message += "\nDetails: \(trimmed)"
            }
            return message
        case let .insufficientDiskSpace(available, required):
            let availableGB = Double(available) / 1_000_000_000
            let requiredGB = Double(required) / 1_000_000_000
            return String(
                format: "Not enough free disk space. AC needs about %.1f GB to download the runtime and model, but only %.1f GB is available. Free up some space and try again.",
                requiredGB,
                availableGB
            )
        }
    }

    private static func friendlyDescription(forCommand command: String, status: Int32) -> String? {
        let lower = command.lowercased()
        if lower.contains("git clone") || lower.contains("git fetch") {
            return "Couldn't download the llama.cpp runtime. Check your internet connection and try again."
        }
        if lower.contains("llama-cli") || lower.contains("-hf") {
            return "The local model failed to download or warm up. This usually means the download was interrupted or Hugging Face is unreachable."
        }
        if lower.contains("cmake") {
            return "Building the llama.cpp runtime failed."
        }
        return nil
    }
}

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

    nonisolated private static var modelCacheRelativePath: String {
        DevelopmentModelConfiguration.cacheRelativePath()
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

    nonisolated static func inspect(runtimeOverride: String?) -> RuntimeDiagnostics {
        let runtimePath = normalizedRuntimePath(from: runtimeOverride)
        let runtimeDirectory = runtimeDirectoryPath(for: runtimePath)
        let modelCacheRoots = modelCacheRoots(
            forRuntimePath: runtimePath,
            modelIdentifier: DevelopmentModelConfiguration.defaultModelIdentifier
        )
        let existingModelCacheRoot = modelCacheRoots.first {
            FileManager.default.fileExists(atPath: $0.path)
        }
        let modelCachePath = (existingModelCacheRoot ?? modelCacheRoots.first)?.path ?? ""
        let modelCachePresent = existingModelCacheRoot != nil
        let modelArtifactsPresent = hasModelArtifacts(
            cacheRoots: modelCacheRoots,
            modelIdentifier: DevelopmentModelConfiguration.defaultModelIdentifier
        )
        let tools = ["git", "cmake", "ninja"]
        let missingTools = tools.filter { tool in
            !toolExists(tool)
        }

        return RuntimeDiagnostics(
            runtimePath: runtimePath,
            runtimeDirectory: runtimeDirectory,
            runtimePresent: FileManager.default.isExecutableFile(atPath: runtimePath),
            modelCachePath: modelCachePath,
            modelCachePresent: modelCachePresent,
            modelArtifactsPresent: modelArtifactsPresent,
            missingTools: missingTools
        )
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
            await log("$ git clone skipped, repo already exists at \(repoURL.path)")
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

    static func warmUpRuntime(runtimePath: String, log: @escaping @MainActor (String) -> Void) async throws {
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
            await log("Cleaned up \(removedPartials) partial download file(s) from a previous run.")
        }

        try await runStreaming(
            launchPath: runtimePath,
            arguments: [
                "-hf", DevelopmentModelConfiguration.defaultModelIdentifier,
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

    nonisolated private static func modelCacheURL(forRuntimePath runtimePath: String) -> URL {
        runtimeRepositoryURL(forRuntimePath: runtimePath)
            .appendingPathComponent(modelCacheRelativePath, isDirectory: true)
    }

    nonisolated private static func hasModelArtifacts(
        cacheRoots: [URL],
        modelIdentifier: String
    ) -> Bool {
        let components = modelIdentifier.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard components.first != nil else {
            return false
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

            let modelCandidates = files.filter {
                $0.pathExtension.lowercased() == "gguf" &&
                !$0.lastPathComponent.lowercased().contains("mmproj")
            }
            if modelCandidates.isEmpty {
                continue
            }

            guard let quant else {
                return true
            }

            let hasQuantMatch = modelCandidates.contains { candidate in
                let basename = candidate.deletingPathExtension().lastPathComponent.uppercased()
                return basename.hasSuffix("-\(quant)") ||
                    basename.hasSuffix("_\(quant)") ||
                    basename.contains("-\(quant)-") ||
                    basename.contains("_\(quant)_") ||
                    basename.contains(quant)
            }
            if hasQuantMatch {
                return true
            }
        }

        return false
    }

    nonisolated private static func modelCacheRoots(
        forRuntimePath runtimePath: String,
        modelIdentifier: String
    ) -> [URL] {
        let repository = DevelopmentModelConfiguration.repositoryIdentifier(for: modelIdentifier)
        let cacheDirectoryName = "models--\(repository.replacingOccurrences(of: "/", with: "--"))"

        var roots: [URL] = [
            modelCacheURL(forRuntimePath: runtimePath)
        ]

        if let hfHome = ProcessInfo.processInfo.environment["HF_HOME"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !hfHome.isEmpty {
            roots.append(
                URL(fileURLWithPath: hfHome, isDirectory: true)
                    .appendingPathComponent("hub", isDirectory: true)
                    .appendingPathComponent(cacheDirectoryName, isDirectory: true)
            )
        }

        roots.append(
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".cache", isDirectory: true)
                .appendingPathComponent("huggingface", isDirectory: true)
                .appendingPathComponent("hub", isDirectory: true)
                .appendingPathComponent(cacheDirectoryName, isDirectory: true)
        )

        roots.append(
            defaultHuggingFaceCacheURL()
                .appendingPathComponent("hub", isDirectory: true)
                .appendingPathComponent(cacheDirectoryName, isDirectory: true)
        )

        return roots
    }

    nonisolated private static func defaultHuggingFaceCacheURL() -> URL {
        TelemetryPaths.applicationSupportURL()
            .appendingPathComponent("runtime", isDirectory: true)
            .appendingPathComponent("hf-cache", isDirectory: true)
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

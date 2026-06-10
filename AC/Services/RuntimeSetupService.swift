//
//  RuntimeSetupService.swift
//  AC
//
//  Created by Codex on 12.04.26.
//

import Foundation

enum RuntimeSetupService {
    nonisolated private static let runtimeRepositoryRemote = "https://github.com/ggml-org/llama.cpp.git"
    // llama.cpp tag b9571 (2026-06-09). Includes the gemma-4 "unified" multimodal
    // fixes (#24082/#24088/#24118) and the projector loader for `gemma4uv`. Note
    // the checkpoint-spacing flag was renamed in this range
    // (`--checkpoint-every-n-tokens` → `--checkpoint-min-step`); AC selects the
    // supported flag at launch (see LocalModelRuntime.checkpointSpacingArguments)
    // so existing installs on the prior commit keep working until they rebuild.
    nonisolated private static let pinnedLlamaCommit = "e3471b3e7306fe120dc8f38a2263c1293fc2add7"

    /// Minimum free disk space we require before we start pulling the runtime + model.
    /// Model alone is ~4.4GB compressed; we leave headroom for the llama.cpp build
    /// artifacts, HF cache metadata, and user margin.
    nonisolated static let requiredFreeBytesForInstall: Int64 = 6 * 1024 * 1024 * 1024

    nonisolated static func repositoryIdentifier(for modelIdentifier: String) -> String {
        String(
            modelIdentifier
                .split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
                .first ?? ""
        )
    }

    nonisolated private static func modelCacheRelativePath(for modelIdentifier: String) -> String {
        let repo = repositoryIdentifier(for: modelIdentifier)
        return "\(repo)/models--\(repo.replacingOccurrences(of: "/", with: "--"))"
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

    /// True when a model identifier is actually an absolute path to a `.gguf` file
    /// the user linked from disk (e.g. a model they already downloaded via Ollama or
    /// elsewhere), rather than a Hugging Face repo id we download and cache ourselves.
    nonisolated static func isLocalFileModelIdentifier(_ identifier: String) -> Bool {
        let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("/") && trimmed.lowercased().hasSuffix(".gguf")
    }

    /// Resolves a linked-on-disk `.gguf` path to its model file and, if a sibling
    /// `*mmproj*.gguf` lives next to it, its multimodal projector. Returns nil if the
    /// identifier isn't a file path or the file no longer exists.
    nonisolated static func localFileModelArtifacts(for identifier: String) -> (modelURL: URL, projectorURL: URL?)? {
        let path = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isLocalFileModelIdentifier(path), FileManager.default.fileExists(atPath: path) else {
            return nil
        }
        let modelURL = URL(fileURLWithPath: path)
        let directory = modelURL.deletingLastPathComponent()
        let projectorURL = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ))?.first {
            $0.pathExtension.lowercased() == "gguf"
                && $0.lastPathComponent.lowercased().contains("mmproj")
        }
        return (modelURL, projectorURL)
    }

    nonisolated static func inspect(runtimeOverride: String?, modelIdentifier: String) -> RuntimeDiagnostics {
        let runtimePath = normalizedRuntimePath(from: runtimeOverride)
        let runtimeDirectory = runtimeDirectoryPath(for: runtimePath)
        let tools = ["git", "cmake", "ninja"]

        // A user-linked file lives wherever they put it — there is nothing for AC to
        // download or cache, so report it present as soon as the file exists.
        if let fileArtifacts = localFileModelArtifacts(for: modelIdentifier) {
            return RuntimeDiagnostics(
                runtimePath: runtimePath,
                runtimeDirectory: runtimeDirectory,
                runtimePresent: FileManager.default.isExecutableFile(atPath: runtimePath),
                modelCachePath: fileArtifacts.modelURL.deletingLastPathComponent().path,
                managedModelCachePath: "",
                modelCachePresent: true,
                modelArtifactsPresent: true,
                resolvedModelPath: fileArtifacts.modelURL.path,
                resolvedProjectorPath: fileArtifacts.projectorURL?.path,
                missingTools: tools.filter { !toolExists($0) }
            )
        }

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

    /// The llama.cpp commit AC currently targets. New installs build this; an
    /// existing install that sits on a different commit is considered out of date.
    nonisolated static var pinnedRuntimeCommit: String { pinnedLlamaCommit }

    /// The commit the installed runtime was actually built from, or nil when it
    /// can't be determined (no repo / git unavailable / shallow-detached oddities).
    /// Best-effort and synchronous — `git rev-parse` is cheap.
    nonisolated static func runtimeInstalledCommit(forRuntimePath runtimePath: String) -> String? {
        let repoURL = runtimeRepositoryURL(forRuntimePath: runtimePath)
        guard FileManager.default.fileExists(atPath: repoURL.appendingPathComponent(".git").path) else {
            return nil
        }
        guard let output = gitOutput(arguments: ["rev-parse", "HEAD"], in: repoURL) else {
            return nil
        }
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Whether the installed runtime is behind the pinned target and should be
    /// rebuilt. Conservative: when the installed commit can't be determined we
    /// return `false` so AC never nags about an update it can't verify.
    nonisolated static func runtimeNeedsUpdate(forRuntimePath runtimePath: String) -> Bool {
        runtimeNeedsUpdate(
            installedCommit: runtimeInstalledCommit(forRuntimePath: runtimePath),
            pinnedCommit: pinnedLlamaCommit
        )
    }

    /// Pure comparison, split out for testing without touching git.
    nonisolated static func runtimeNeedsUpdate(installedCommit: String?, pinnedCommit: String) -> Bool {
        guard let installed = installedCommit?.trimmingCharacters(in: .whitespacesAndNewlines),
              !installed.isEmpty else {
            return false
        }
        let pinned = pinnedCommit.trimmingCharacters(in: .whitespacesAndNewlines)
        // Git may report a full 40-char hash while the pin is also full-length;
        // tolerate one being an abbreviation of the other.
        if installed == pinned { return false }
        if installed.hasPrefix(pinned) || pinned.hasPrefix(installed) { return false }
        return true
    }

    nonisolated private static func gitOutput(arguments: [String], in directory: URL) -> String? {
        let gitPath = resolvedToolPath("git") ?? "/usr/bin/git"
        guard FileManager.default.isExecutableFile(atPath: gitPath) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: gitPath)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    nonisolated static func managedModelCacheURL(for modelIdentifier: String) -> URL {
        let repository = repositoryIdentifier(for: modelIdentifier)
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
        guard let ninjaPath = resolvedToolPath("ninja") else {
            throw RuntimeSetupError.commandFailed("ninja", 127, stderrTail: "`ninja` is missing. Install it with `brew install ninja` and retry.")
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
                "-DCMAKE_MAKE_PROGRAM=\(ninjaPath)",
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
        hfToken: String? = nil,
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

        // Repair blobs corrupted by a non-resumable interrupted download (see
        // purgeCorruptModelBlobs): without this, an oversized/garbage blob is reused on
        // every retry and warm-up keeps failing with no way out but a manual cache wipe.
        let expectedFiles = await expectedModelFiles(for: modelIdentifier)
        let repaired = purgeCorruptModelBlobs(for: modelIdentifier, expectedFiles: expectedFiles)
        if repaired > 0 {
            await MainActor.run {
                log("Removed \(repaired) corrupt model file(s) from a previous download; re-downloading.")
            }
        }

        // Authenticated HF downloads avoid the unauthenticated single-stream throttle.
        // Missing/empty token → unauthenticated download (the prior behavior).
        var environmentOverrides = ["HF_HOME": huggingFaceCacheURL.path]
        if let hfToken, !hfToken.isEmpty {
            environmentOverrides["HF_TOKEN"] = hfToken
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
            environmentOverrides: environmentOverrides,
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
        let repository = repositoryIdentifier(for: modelIdentifier)
        let cacheDirectoryName = "models--\(repository.replacingOccurrences(of: "/", with: "--"))"
        return [
            modelCacheURL(forRuntimePath: runtimePath, modelIdentifier: modelIdentifier),
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

    /// PATH for build/setup subprocesses. A GUI app launched from Finder inherits
    /// launchd's minimal PATH (`/usr/bin:/bin:/usr/sbin:/sbin`), which omits the
    /// Homebrew prefixes where users install cmake/ninja. Without this, cmake is
    /// found via `resolvedToolPath` but can't locate `ninja` (or its compiler) at
    /// build time. Prepend the standard tool prefixes so child lookups succeed.
    nonisolated private static func augmentedSubprocessPATH() -> String {
        let toolPrefixes = ["/opt/homebrew/bin", "/usr/local/bin"]
        let existing = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        var directories = existing.split(separator: ":").map(String.init)
        for prefix in toolPrefixes.reversed() where !directories.contains(prefix) {
            directories.insert(prefix, at: 0)
        }
        return directories.joined(separator: ":")
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
        environment["PATH"] = augmentedSubprocessPATH()
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

        // Hold the process behind a Sendable box so the cancellation handler can
        // terminate it. Task cancellation is cooperative — without this, a switch
        // away from Local mode wouldn't actually stop an in-flight git/cmake/llama
        // download; it would keep running until the subprocess finished on its own.
        let handle = ProcessHandle(process)
        try process.run()
        let status = await withTaskCancellationHandler {
            await waitForProcess(process)
        } onCancel: {
            handle.terminate()
        }
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil

        if Task.isCancelled {
            throw CancellationError()
        }

        if status != 0 {
            throw RuntimeSetupError.commandFailed(
                arguments.joined(separator: " "),
                status,
                stderrTail: tail.snapshot()
            )
        }
    }

    /// Total bytes currently on disk in the managed cache's blob dir for this model,
    /// including in-progress (`*.downloadInProgress`) partials. llama.cpp streams the
    /// GGUF (and projector) into `blobs/<sha>.downloadInProgress`, so summing this gives
    /// an accurate live "downloaded so far" figure without parsing subprocess output.
    nonisolated static func downloadedModelBytes(for modelIdentifier: String) -> Int64 {
        downloadedModelBytes(inCacheRoot: managedModelCacheURL(for: modelIdentifier))
    }

    /// Testable core of `downloadedModelBytes(for:)` — sums the regular files in the
    /// cache root's `blobs/` directory (completed blobs + `*.downloadInProgress`).
    nonisolated static func downloadedModelBytes(inCacheRoot cacheRoot: URL) -> Int64 {
        let blobsURL = cacheRoot.appendingPathComponent("blobs", isDirectory: true)
        guard
            let entries = try? FileManager.default.contentsOfDirectory(
                at: blobsURL,
                includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
        else { return 0 }

        var total: Int64 = 0
        for url in entries {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            total += Int64(values?.fileSize ?? 0)
        }
        return total
    }

    /// Bytes on disk for *exactly* the given content blobs (`blobs/<oid>`, or its
    /// `<oid>.downloadInProgress` partial while in flight). Because the blob filename is
    /// the file's LFS oid, this measures the progress of one specific model's files and
    /// ignores orphaned partials from earlier attempts or other quants in the same repo —
    /// the honest "downloaded so far" figure for the model the user is installing.
    nonisolated static func downloadedModelBytes(forOids oids: [String], inCacheRoot cacheRoot: URL) -> Int64 {
        let blobsURL = cacheRoot.appendingPathComponent("blobs", isDirectory: true)
        var total: Int64 = 0
        for oid in oids where !oid.isEmpty {
            let blob = blobsURL.appendingPathComponent(oid)
            let partial = blobsURL.appendingPathComponent(oid + ".downloadInProgress")
            total += regularFileSize(blob) ?? regularFileSize(partial) ?? 0
        }
        return total
    }

    /// Removes blobs whose on-disk size disagrees with the Hugging Face manifest, so the
    /// runtime re-downloads them cleanly. llama.cpp opens the temp blob in append mode and
    /// only seeks to a resume offset when the server advertises range support; a resume
    /// served as a plain 200 therefore appends a *full* copy onto the existing partial,
    /// producing an oversized blob that then gets finalized and trusted via its `.etag`.
    /// That corrupt file loads as garbage and fails warm-up forever. We catch both a
    /// finalized blob whose size ≠ expected and an in-progress partial that already
    /// exceeds the expected size (a partial can only be ≤ the real file). Returns the
    /// number of files removed.
    @discardableResult
    nonisolated static func purgeCorruptModelBlobs(
        for modelIdentifier: String,
        expectedFiles: [ExpectedModelFile]
    ) -> Int {
        purgeCorruptModelBlobs(
            expectedFiles: expectedFiles,
            inCacheRoot: managedModelCacheURL(for: modelIdentifier)
        )
    }

    /// Testable core of `purgeCorruptModelBlobs(for:expectedFiles:)`.
    @discardableResult
    nonisolated static func purgeCorruptModelBlobs(
        expectedFiles: [ExpectedModelFile],
        inCacheRoot cacheRoot: URL
    ) -> Int {
        let fileManager = FileManager.default
        let blobsURL = cacheRoot.appendingPathComponent("blobs", isDirectory: true)
        // LFS sizes are exact byte counts; real corruption is gigabytes off. A small
        // slack avoids ever fighting a healthy file over rounding/metadata quirks.
        let tolerance: Int64 = 1_048_576
        var removed = 0

        for file in expectedFiles {
            guard let oid = file.oid, !oid.isEmpty, file.size > 0 else { continue }

            let blob = blobsURL.appendingPathComponent(oid)
            if let size = regularFileSize(blob), abs(size - file.size) > tolerance {
                if (try? fileManager.removeItem(at: blob)) != nil { removed += 1 }
                try? fileManager.removeItem(at: blobsURL.appendingPathComponent(oid + ".etag"))
            }

            let partial = blobsURL.appendingPathComponent(oid + ".downloadInProgress")
            if let size = regularFileSize(partial), size > file.size + tolerance {
                if (try? fileManager.removeItem(at: partial)) != nil { removed += 1 }
            }
        }
        return removed
    }

    nonisolated private static func regularFileSize(_ url: URL) -> Int64? {
        guard
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
            values.isRegularFile == true
        else { return nil }
        return Int64(values.fileSize ?? 0)
    }

    /// Best-effort expected download size for a model identifier, queried from the
    /// Hugging Face tree API. Returns nil on any failure so the caller can fall back
    /// to an indeterminate / downloaded-only display rather than blocking the UI.
    nonisolated static func expectedDownloadBytes(for modelIdentifier: String) async -> Int64? {
        let total = await expectedModelFiles(for: modelIdentifier)
            .reduce(Int64(0)) { $0 + $1.size }
        return total > 0 ? total : nil
    }

    /// The specific files (chosen quant GGUF + optional `mmproj` projector) the runtime
    /// will download for this model, each with its LFS `oid` (blob filename) and exact
    /// byte size, queried from the Hugging Face tree API. Returns an empty array on any
    /// failure so callers fall back gracefully (indeterminate progress, no purge).
    nonisolated static func expectedModelFiles(for modelIdentifier: String) async -> [ExpectedModelFile] {
        let repo = repositoryIdentifier(for: modelIdentifier)
        guard !repo.isEmpty else { return [] }

        let components = modelIdentifier.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let quant = components.count > 1 ? String(components[1]).uppercased() : nil

        guard let url = URL(string: "https://huggingface.co/api/models/\(repo)/tree/main?recursive=true") else {
            return []
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10

        guard
            let (data, response) = try? await URLSession.shared.data(for: request),
            (response as? HTTPURLResponse)?.statusCode == 200,
            let entries = try? JSONDecoder().decode([HFTreeEntry].self, from: data)
        else { return [] }

        let ggufFiles = entries.filter { $0.path.lowercased().hasSuffix(".gguf") }
        let projector = ggufFiles.first { $0.path.lowercased().contains("mmproj") }
        let modelCandidates = ggufFiles.filter { !$0.path.lowercased().contains("mmproj") }
        let modelEntry = selectModelTreeEntry(from: modelCandidates, quant: quant)

        return [modelEntry, projector].compactMap { entry in
            guard let entry else { return nil }
            let size = entry.lfs?.size ?? entry.size ?? 0
            guard size > 0 else { return nil }
            return ExpectedModelFile(oid: entry.lfs?.oid, size: size)
        }
    }

    nonisolated private static func selectModelTreeEntry(from candidates: [HFTreeEntry], quant: String?) -> HFTreeEntry? {
        guard !candidates.isEmpty else { return nil }
        guard let quant, !quant.isEmpty else { return candidates.first }
        let matched = candidates.first { entry in
            ((entry.path as NSString).lastPathComponent).uppercased().contains(quant)
        }
        return matched ?? candidates.first
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

/// Sendable wrapper so a cancellation handler can terminate a running `Process`
/// without capturing the non-Sendable `Process` directly.
private final class ProcessHandle: @unchecked Sendable {
    private let process: Process
    init(_ process: Process) { self.process = process }
    nonisolated func terminate() {
        if process.isRunning {
            process.terminate()
        }
    }
}

private struct HFTreeEntry: Decodable {
    let path: String
    let size: Int64?
    let lfs: HFLFS?

    struct HFLFS: Decodable {
        let oid: String?
        let size: Int64?
    }
}

/// One file the runtime is expected to download for a model, as described by the
/// Hugging Face manifest. `oid` is the LFS sha256 — and also the on-disk blob
/// filename (`blobs/<oid>`), which lets us measure progress and detect corruption
/// for the *specific* files of one model rather than the whole cache directory.
struct ExpectedModelFile: Sendable, Equatable {
    let oid: String?
    let size: Int64
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

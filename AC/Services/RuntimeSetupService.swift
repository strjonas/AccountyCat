//
//  RuntimeSetupService.swift
//  AC
//
//  Created by Codex on 12.04.26.
//

import Foundation

enum RuntimeSetupService {
    nonisolated private static let modelCacheRelativePath = "unsloth/gemma-4-E2B-it-GGUF/models--unsloth--gemma-4-E2B-it-GGUF"
    nonisolated private static let runtimeRepositoryRemote = "https://github.com/ggml-org/llama.cpp.git"
    nonisolated private static let pinnedLlamaCommit = "a279d0f0f4e746d1ef3429d8e9d02d2990b2daa7"

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
        let modelCachePath = modelCacheURL(forRuntimePath: runtimePath).path
        let tools = ["git", "cmake", "ninja"]
        let missingTools = tools.filter { tool in
            !toolExists(tool)
        }

        return RuntimeDiagnostics(
            runtimePath: runtimePath,
            runtimeDirectory: runtimeDirectory,
            runtimePresent: FileManager.default.isExecutableFile(atPath: runtimePath),
            modelCachePath: modelCachePath,
            modelCachePresent: FileManager.default.fileExists(atPath: modelCachePath),
            missingTools: missingTools
        )
    }

    static func installRuntime(log: @escaping @MainActor (String) -> Void) async throws {
        let baseDirectory = installBaseDirectory()
        try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)

        let repoURL = runtimeRepositoryURL(in: baseDirectory)
        if !FileManager.default.fileExists(atPath: repoURL.path) {
            try await runStreaming(
                launchPath: "/usr/bin/git",
                arguments: ["clone", runtimeRepositoryRemote],
                currentDirectory: baseDirectory,
                log: log
            )
        } else {
            log("$ git clone skipped, repo already exists at \(repoURL.path)")
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
            launchPath: "/usr/bin/env",
            arguments: [
                "cmake",
                "-B", "build",
                "-G", "Ninja",
                "-DGGML_METAL=ON",
                "-DCMAKE_BUILD_TYPE=Release",
            ],
            currentDirectory: repoURL,
            log: log
        )

        try await runStreaming(
            launchPath: "/usr/bin/env",
            arguments: ["cmake", "--build", "build", "-j"],
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

        try await runStreaming(
            launchPath: runtimePath,
            arguments: [
                "-hf", "unsloth/gemma-4-E2B-it-GGUF:Q4_0",
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

    nonisolated private static func toolExists(_ tool: String) -> Bool {
        let commonLocations = [
            "/usr/bin/\(tool)",
            "/usr/local/bin/\(tool)",
            "/opt/homebrew/bin/\(tool)",
        ]

        if commonLocations.contains(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return true
        }

        return ProcessInfo.processInfo.environment["PATH"]?
            .split(separator: ":")
            .map(String.init)
            .contains { directory in
                FileManager.default.isExecutableFile(atPath: "\(directory)/\(tool)")
            } ?? false
    }

    private static func runStreaming(
        launchPath: String,
        arguments: [String],
        currentDirectory: URL,
        log: @escaping @MainActor (String) -> Void
    ) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectory

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        let handle = pipe.fileHandleForReading
        handle.readabilityHandler = { fileHandle in
            let data = fileHandle.availableData
            guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else {
                return
            }

            Task { @MainActor in
                log(chunk)
            }
        }

        try process.run()
        let status = await waitForProcess(process)
        handle.readabilityHandler = nil

        if status != 0 {
            throw RuntimeSetupError.commandFailed(arguments.joined(separator: " "), status)
        }
    }

    private static func waitForProcess(_ process: Process) async -> Int32 {
        await withCheckedContinuation { continuation in
            process.terminationHandler = { finishedProcess in
                continuation.resume(returning: finishedProcess.terminationStatus)
            }
        }
    }
}

enum RuntimeSetupError: LocalizedError {
    case commandFailed(String, Int32)

    var errorDescription: String? {
        switch self {
        case let .commandFailed(command, status):
            return "Command failed (\(status)): \(command)"
        }
    }
}

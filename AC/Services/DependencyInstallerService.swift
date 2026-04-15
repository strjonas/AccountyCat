//
//  DependencyInstallerService.swift
//  AC
//
//  Created by Codex on 12.04.26.
//

import Foundation

enum DependencyInstallerService {
    static func installMissingTools(
        _ tools: [String],
        log: @escaping @MainActor (String) -> Void
    ) async throws {
        let packages = Array(Set(tools.compactMap(Self.packageName(for:)))).sorted()
        guard !packages.isEmpty else {
            return
        }

        if let brewPath = brewExecutablePath() {
            try await runStreaming(
                launchPath: brewPath,
                arguments: ["install"] + packages,
                currentDirectory: FileManager.default.homeDirectoryForCurrentUser,
                log: log
            )
            return
        }

        try await openInteractiveInstallInTerminal(packages: packages, log: log)
    }

    private static func packageName(for tool: String) -> String? {
        switch tool {
        case "cmake":
            return "cmake"
        case "ninja":
            return "ninja"
        default:
            return nil
        }
    }

    private static func brewExecutablePath() -> String? {
        let candidates = [
            "/opt/homebrew/bin/brew",
            "/usr/local/bin/brew",
        ]

        if let firstMatch = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return firstMatch
        }

        return ProcessInfo.processInfo.environment["PATH"]?
            .split(separator: ":")
            .map(String.init)
            .map { "\($0)/brew" }
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) })
    }

    private static func openInteractiveInstallInTerminal(
        packages: [String],
        log: @escaping @MainActor (String) -> Void
    ) async throws {
        let joinedPackages = packages.joined(separator: " ")
        let command = """
        if ! command -v brew >/dev/null 2>&1; then
          /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
        fi
        if [ -x /opt/homebrew/bin/brew ]; then
          eval "$(/opt/homebrew/bin/brew shellenv)"
        elif [ -x /usr/local/bin/brew ]; then
          eval "$(/usr/local/bin/brew shellenv)"
        fi
        brew install \(joinedPackages)
        echo
        echo "Dependency installation finished. Return to AccountyCat and press Refresh."
        """

        try await runProcess(
            launchPath: "/usr/bin/osascript",
            arguments: [
                "-e", "tell application \"Terminal\" to activate",
                "-e", "tell application \"Terminal\" to do script \(appleScriptStringLiteral(command))",
            ],
            currentDirectory: FileManager.default.homeDirectoryForCurrentUser
        )

        await log("Opened Terminal to install Homebrew and missing dependencies: \(joinedPackages)")
    }

    private static func appleScriptStringLiteral(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "\"\(escaped)\""
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
            throw DependencyInstallerError.commandFailed(arguments.joined(separator: " "), status)
        }
    }

    private static func runProcess(
        launchPath: String,
        arguments: [String],
        currentDirectory: URL
    ) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectory

        try process.run()
        let status = await waitForProcess(process)

        if status != 0 {
            throw DependencyInstallerError.commandFailed(arguments.joined(separator: " "), status)
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

enum DependencyInstallerError: LocalizedError {
    case commandFailed(String, Int32)

    var errorDescription: String? {
        switch self {
        case let .commandFailed(command, status):
            return "Dependency install failed (\(status)): \(command)"
        }
    }
}

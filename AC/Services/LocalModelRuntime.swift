//
//  LocalModelRuntime.swift
//  AC
//
//  Created by Codex on 15.04.26.
//

import Foundation

struct RuntimeProcessOutput: Sendable {
    var stdout: String
    var stderr: String
}

actor LocalModelRuntime {
    static let defaultModelIdentifier = "unsloth/gemma-4-E2B-it-GGUF:Q4_0"

    func runVisionInference(
        runtimePath: String,
        modelIdentifier: String,
        snapshotPath: String,
        systemPrompt: String,
        userPrompt: String
    ) async throws -> RuntimeProcessOutput {
        let repoURL = repositoryURL(forRuntimePath: runtimePath)
        let systemPromptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ac-system-\(UUID().uuidString).txt")
        guard let promptData = systemPrompt.data(using: .utf8) else {
            throw LLMError.commandFailed(1, "Could not encode system prompt.")
        }
        try promptData.write(to: systemPromptURL, options: .atomic)
        defer {
            try? FileManager.default.removeItem(at: systemPromptURL)
        }

        return try await runProcess(
            executablePath: runtimePath,
            arguments: Self.visionArguments(
                systemPromptURL: systemPromptURL,
                snapshotPath: snapshotPath,
                userPrompt: userPrompt,
                modelIdentifier: modelIdentifier
            ),
            currentDirectoryURL: repoURL
        )
    }

    func runTextInference(
        runtimePath: String,
        modelIdentifier: String,
        systemPrompt: String,
        userPrompt: String
    ) async throws -> RuntimeProcessOutput {
        let repoURL = repositoryURL(forRuntimePath: runtimePath)
        let systemPromptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ac-chat-system-\(UUID().uuidString).txt")
        guard let promptData = systemPrompt.data(using: .utf8) else {
            throw LLMError.commandFailed(1, "Could not encode chat system prompt.")
        }
        try promptData.write(to: systemPromptURL, options: .atomic)
        defer {
            try? FileManager.default.removeItem(at: systemPromptURL)
        }

        return try await runProcess(
            executablePath: runtimePath,
            arguments: Self.textArguments(
                systemPromptURL: systemPromptURL,
                userPrompt: userPrompt,
                modelIdentifier: modelIdentifier
            ),
            currentDirectoryURL: repoURL
        )
    }

    private func repositoryURL(forRuntimePath runtimePath: String) -> URL {
        URL(fileURLWithPath: runtimePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func runProcess(
        executablePath: String,
        arguments: [String],
        currentDirectoryURL: URL
    ) async throws -> RuntimeProcessOutput {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectoryURL

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()

        let outputTask = Task.detached {
            let stdoutData = stdout.fileHandleForReading.readDataToEndOfFile()
            let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()
            return RuntimeProcessOutput(
                stdout: String(decoding: stdoutData, as: UTF8.self),
                stderr: String(decoding: stderrData, as: UTF8.self)
            )
        }

        let status = try await withTimeout(seconds: 45) {
            process.waitUntilExit()
            return process.terminationStatus
        }

        let output = await outputTask.value
        if status != 0 {
            let combined = [output.stdout, output.stderr]
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            throw LLMError.commandFailed(status, combined)
        }

        return output
    }

    private func withTimeout<T>(
        seconds: UInt64,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }

            group.addTask {
                try await Task.sleep(nanoseconds: seconds * NSEC_PER_SEC)
                throw LLMError.timeout
            }

            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    private static func visionArguments(
        systemPromptURL: URL,
        snapshotPath: String,
        userPrompt: String,
        modelIdentifier: String
    ) -> [String] {
        [
            "-hf", modelIdentifier,
            "-sysf", systemPromptURL.path,
            "--image", snapshotPath,
            "-p", userPrompt,
            "-cnv",
            "-st",
            "-n", "120",
            "--reasoning", "off",
            "--temp", "0.15",
            "--top-p", "0.95",
            "--top-k", "64",
            "--ctx-size", "2048",
            "--batch-size", "2048",
            "--ubatch-size", "2048",
            "--no-display-prompt",
        ]
    }

    private static func textArguments(
        systemPromptURL: URL,
        userPrompt: String,
        modelIdentifier: String
    ) -> [String] {
        [
            "-hf", modelIdentifier,
            "-sysf", systemPromptURL.path,
            "-p", userPrompt,
            "-cnv",
            "-st",
            "-n", "240",
            "--reasoning", "off",
            "--temp", "0.4",
            "--top-p", "0.95",
            "--top-k", "64",
            "--ctx-size", "4096",
            "--batch-size", "1024",
            "--ubatch-size", "512",
            "--no-display-prompt",
        ]
    }
}

enum LLMError: LocalizedError {
    case timeout
    case commandFailed(Int32, String)

    var errorDescription: String? {
        switch self {
        case .timeout:
            return "llama.cpp timed out."
        case let .commandFailed(status, output):
            return "llama.cpp exited with \(status): \(output)"
        }
    }
}

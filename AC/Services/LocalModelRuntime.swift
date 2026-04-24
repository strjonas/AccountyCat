//
//  LocalModelRuntime.swift
//  AC
//
//  Created by Codex on 15.04.26.
//

import Darwin
import Foundation

struct RuntimeProcessOutput: Sendable {
    var stdout: String
    var stderr: String
}

nonisolated private struct CachedModelArtifacts: Sendable, Equatable {
    var modelPath: String
    var multimodalProjectorPath: String?
}

nonisolated private enum RuntimeModelSource: Sendable {
    case local(CachedModelArtifacts)
    case huggingFace(String)
}

nonisolated private enum RuntimeInferenceInput: Sendable {
    case text(userPrompt: String)
    case vision(snapshotPath: String, userPrompt: String)

    var requiresVision: Bool {
        switch self {
        case .text:
            return false
        case .vision:
            return true
        }
    }
}

nonisolated private struct RuntimeServerConfig: Sendable, Equatable {
    var executablePath: String
    var runtimePath: String
    var modelIdentifier: String
    var modelPath: String
    var multimodalProjectorPath: String?
    var ctxSize: Int
    var batchSize: Int
    var ubatchSize: Int
}

nonisolated private final class RuntimeCancellationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var cancellation: (() -> Void)?
    private var isCancelled = false

    func setCancellation(_ cancellation: @escaping () -> Void) {
        var shouldCancelImmediately = false
        lock.lock()
        if isCancelled {
            shouldCancelImmediately = true
        } else {
            self.cancellation = cancellation
        }
        lock.unlock()

        if shouldCancelImmediately {
            cancellation()
        }
    }

    func cancel() {
        let cancellation: (() -> Void)?
        lock.lock()
        isCancelled = true
        cancellation = self.cancellation
        lock.unlock()
        cancellation?()
    }
}

nonisolated private final class RuntimeOutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var stdout = Data()
    private var stderr = Data()

    func appendStdout(_ data: Data) {
        append(data, to: \.stdout)
    }

    func appendStderr(_ data: Data) {
        append(data, to: \.stderr)
    }

    func output() -> RuntimeProcessOutput {
        lock.lock()
        let stdoutString = String(decoding: stdout, as: UTF8.self)
        let stderrString = String(decoding: stderr, as: UTF8.self)
        lock.unlock()
        return RuntimeProcessOutput(stdout: stdoutString, stderr: stderrString)
    }

    private func append(_ data: Data, to keyPath: ReferenceWritableKeyPath<RuntimeOutputCollector, Data>) {
        guard !data.isEmpty else { return }
        lock.lock()
        self[keyPath: keyPath].append(data)
        lock.unlock()
    }
}

nonisolated private final class RuntimeLogTail: @unchecked Sendable {
    private let limit: Int
    private let lock = NSLock()
    private var contents = ""

    init(limit: Int = 16_384) {
        self.limit = limit
    }

    func append(_ data: Data) {
        guard !data.isEmpty else { return }
        append(String(decoding: data, as: UTF8.self))
    }

    func append(_ text: String) {
        guard !text.isEmpty else { return }
        lock.lock()
        contents.append(text)
        if contents.count > limit {
            contents = String(contents.suffix(limit))
        }
        lock.unlock()
    }

    func snapshot() -> String {
        lock.lock()
        let snapshot = contents
        lock.unlock()
        return snapshot
    }
}

nonisolated private final class LocalModelServerHandle: @unchecked Sendable {
    let process: Process
    let port: Int
    let config: RuntimeServerConfig
    let logTail: RuntimeLogTail
    let stdoutPipe: Pipe
    let stderrPipe: Pipe

    init(
        process: Process,
        port: Int,
        config: RuntimeServerConfig,
        logTail: RuntimeLogTail,
        stdoutPipe: Pipe,
        stderrPipe: Pipe
    ) {
        self.process = process
        self.port = port
        self.config = config
        self.logTail = logTail
        self.stdoutPipe = stdoutPipe
        self.stderrPipe = stderrPipe
    }
}

actor LocalModelRuntime {
    nonisolated static var defaultModelIdentifier: String {
        DevelopmentModelConfiguration.defaultModelIdentifier
    }

    private let urlSession: URLSession
    private var sharedServer: LocalModelServerHandle?

    init() {
        Self.killStalePIDIfNeeded()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 300
        configuration.timeoutIntervalForResource = 300
        self.urlSession = URLSession(configuration: configuration)
    }

    func runVisionInference(
        runtimePath: String,
        modelIdentifier: String,
        snapshotPath: String,
        systemPrompt: String,
        userPrompt: String
    ) async throws -> RuntimeProcessOutput {
        try await runVisionInference(
            runtimePath: runtimePath,
            snapshotPath: snapshotPath,
            systemPrompt: systemPrompt,
            userPrompt: userPrompt,
            options: Self.defaultVisionOptions(modelIdentifier: modelIdentifier)
        )
    }

    func runVisionInference(
        runtimePath: String,
        snapshotPath: String,
        systemPrompt: String,
        userPrompt: String,
        options: RuntimeInferenceOptions
    ) async throws -> RuntimeProcessOutput {
        try await runInference(
            runtimePath: runtimePath,
            input: .vision(snapshotPath: snapshotPath, userPrompt: userPrompt),
            systemPrompt: systemPrompt,
            options: options
        )
    }

    func runTextInference(
        runtimePath: String,
        modelIdentifier: String,
        systemPrompt: String,
        userPrompt: String
    ) async throws -> RuntimeProcessOutput {
        try await runTextInference(
            runtimePath: runtimePath,
            systemPrompt: systemPrompt,
            userPrompt: userPrompt,
            options: Self.defaultTextOptions(modelIdentifier: modelIdentifier)
        )
    }

    func runTextInference(
        runtimePath: String,
        systemPrompt: String,
        userPrompt: String,
        options: RuntimeInferenceOptions
    ) async throws -> RuntimeProcessOutput {
        try await runInference(
            runtimePath: runtimePath,
            input: .text(userPrompt: userPrompt),
            systemPrompt: systemPrompt,
            options: options
        )
    }

    func shutdown() async {
        await stopSharedServer(reason: "runtime_shutdown")
    }

    private func repositoryURL(forRuntimePath runtimePath: String) -> URL {
        URL(fileURLWithPath: runtimePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func runInference(
        runtimePath: String,
        input: RuntimeInferenceInput,
        systemPrompt: String,
        options: RuntimeInferenceOptions
    ) async throws -> RuntimeProcessOutput {
        let cancellationBox = RuntimeCancellationBox()

        return try await withTaskCancellationHandler {
            try Task.checkCancellation()

            let modelSource = resolveModelSource(
                runtimePath: runtimePath,
                modelIdentifier: options.modelIdentifier
            )

            if case let .local(artifacts) = modelSource,
               let serverExecutablePath = serverExecutablePath(for: runtimePath),
               FileManager.default.isExecutableFile(atPath: serverExecutablePath),
               (!input.requiresVision || artifacts.multimodalProjectorPath != nil) {
                do {
                    return try await runServerInference(
                        runtimePath: runtimePath,
                        serverExecutablePath: serverExecutablePath,
                        artifacts: artifacts,
                        input: input,
                        systemPrompt: systemPrompt,
                        options: options,
                        cancellationBox: cancellationBox
                    )
                } catch is CancellationError {
                    throw CancellationError()
                } catch let error as LLMError where error == .timeout {
                    await stopSharedServer(reason: "request_timeout")
                    throw error
                } catch {
                    await stopSharedServer(reason: "server_fallback")
                }
            }

            return try await runCLIInference(
                runtimePath: runtimePath,
                input: input,
                systemPrompt: systemPrompt,
                modelSource: modelSource,
                options: options,
                cancellationBox: cancellationBox
            )
        } onCancel: {
            cancellationBox.cancel()
        }
    }

    private func runServerInference(
        runtimePath: String,
        serverExecutablePath: String,
        artifacts: CachedModelArtifacts,
        input: RuntimeInferenceInput,
        systemPrompt: String,
        options: RuntimeInferenceOptions,
        cancellationBox: RuntimeCancellationBox
    ) async throws -> RuntimeProcessOutput {
        let server = try await ensureSharedServer(
            config: RuntimeServerConfig(
                executablePath: serverExecutablePath,
                runtimePath: runtimePath,
                modelIdentifier: options.modelIdentifier,
                modelPath: artifacts.modelPath,
                multimodalProjectorPath: artifacts.multimodalProjectorPath,
                ctxSize: options.ctxSize,
                batchSize: options.batchSize,
                ubatchSize: options.ubatchSize
            )
        )

        let requestBody = try makeServerRequestBody(
            modelIdentifier: options.modelIdentifier,
            input: input,
            systemPrompt: systemPrompt,
            options: options
        )
        let requestURL = URL(string: "http://127.0.0.1:\(server.port)/v1/chat/completions")!
        var request = URLRequest(url: requestURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = requestBody

        let requestTask = Task {
            try await urlSession.data(for: request)
        }
        cancellationBox.setCancellation {
            requestTask.cancel()
        }

        do {
            let (data, response) = try await withTimeout(seconds: options.timeoutSeconds) {
                try await requestTask.value
            }
            try Task.checkCancellation()

            guard let httpResponse = response as? HTTPURLResponse else {
                throw LLMError.commandFailed(1, "llama-server returned a non-HTTP response.")
            }
            guard (200...299).contains(httpResponse.statusCode) else {
                let message = String(decoding: data, as: UTF8.self)
                throw LLMError.commandFailed(Int32(httpResponse.statusCode), message)
            }

            let assistantMessage = try extractAssistantMessage(from: data)
            return RuntimeProcessOutput(stdout: assistantMessage, stderr: "")
        } catch is CancellationError {
            requestTask.cancel()
            throw CancellationError()
        } catch let error as LLMError where error == .timeout {
            requestTask.cancel()
            throw error
        } catch {
            if Task.isCancelled {
                requestTask.cancel()
                throw CancellationError()
            }
            throw error
        }
    }

    private func runCLIInference(
        runtimePath: String,
        input: RuntimeInferenceInput,
        systemPrompt: String,
        modelSource: RuntimeModelSource,
        options: RuntimeInferenceOptions,
        cancellationBox: RuntimeCancellationBox
    ) async throws -> RuntimeProcessOutput {
        let repoURL = repositoryURL(forRuntimePath: runtimePath)
        let promptFilenamePrefix: String = input.requiresVision ? "ac-system" : "ac-chat-system"
        let systemPromptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(promptFilenamePrefix)-\(UUID().uuidString).txt")

        guard let promptData = systemPrompt.data(using: .utf8) else {
            throw LLMError.commandFailed(1, "Could not encode system prompt.")
        }
        try promptData.write(to: systemPromptURL, options: .atomic)
        defer {
            try? FileManager.default.removeItem(at: systemPromptURL)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: runtimePath)
        process.currentDirectoryURL = repoURL
        process.arguments = arguments(
            systemPromptURL: systemPromptURL,
            modelSource: modelSource,
            input: input,
            options: options
        )

        let stdout = Pipe()
        let stderr = Pipe()
        let collector = RuntimeOutputCollector()
        stdout.fileHandleForReading.readabilityHandler = { fileHandle in
            let data = fileHandle.availableData
            if data.isEmpty {
                fileHandle.readabilityHandler = nil
            } else {
                collector.appendStdout(data)
            }
        }
        stderr.fileHandleForReading.readabilityHandler = { fileHandle in
            let data = fileHandle.availableData
            if data.isEmpty {
                fileHandle.readabilityHandler = nil
            } else {
                collector.appendStderr(data)
            }
        }

        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        cancellationBox.setCancellation {
            Self.terminate(process: process)
        }

        let status: Int32
        do {
            status = try await withTimeout(seconds: options.timeoutSeconds) {
                process.waitUntilExit()
                return process.terminationStatus
            }
        } catch is CancellationError {
            cancellationBox.cancel()
            _ = await waitForTermination(of: process, timeoutMilliseconds: 1_000)
            _ = finalizeCLIOutput(stdout: stdout, stderr: stderr, collector: collector)
            throw CancellationError()
        } catch let error as LLMError where error == .timeout {
            cancellationBox.cancel()
            _ = await waitForTermination(of: process, timeoutMilliseconds: 1_000)
            _ = finalizeCLIOutput(stdout: stdout, stderr: stderr, collector: collector)
            throw error
        } catch {
            cancellationBox.cancel()
            _ = await waitForTermination(of: process, timeoutMilliseconds: 1_000)
            _ = finalizeCLIOutput(stdout: stdout, stderr: stderr, collector: collector)
            if Task.isCancelled {
                throw CancellationError()
            }
            throw error
        }

        if Task.isCancelled {
            cancellationBox.cancel()
            _ = await waitForTermination(of: process, timeoutMilliseconds: 1_000)
            _ = finalizeCLIOutput(stdout: stdout, stderr: stderr, collector: collector)
            throw CancellationError()
        }

        let output = finalizeCLIOutput(stdout: stdout, stderr: stderr, collector: collector)
        if status != 0 {
            let combined = [output.stdout, output.stderr]
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            throw LLMError.commandFailed(status, combined)
        }

        return output
    }

    private func ensureSharedServer(
        config: RuntimeServerConfig
    ) async throws -> LocalModelServerHandle {
        if let sharedServer {
            let sameBinary = sharedServer.config.executablePath == config.executablePath
            let sameModel = sharedServer.config.modelPath == config.modelPath
            let sameProjector = sharedServer.config.multimodalProjectorPath == config.multimodalProjectorPath
            let canReuseCapacity =
                sharedServer.config.ctxSize >= config.ctxSize &&
                sharedServer.config.batchSize >= config.batchSize &&
                sharedServer.config.ubatchSize >= config.ubatchSize

            if sharedServer.process.isRunning, sameBinary, sameModel, sameProjector, canReuseCapacity {
                return sharedServer
            }

            await stopSharedServer(reason: "server_reconfigure")
        }

        let port = try Self.reserveLocalPort()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: config.executablePath)
        process.currentDirectoryURL = repositoryURL(forRuntimePath: config.runtimePath)

        var arguments = [
            "-m", config.modelPath,
            "--offline",
            "--host", "127.0.0.1",
            "--port", String(port),
            "--ctx-size", String(config.ctxSize),
            "--batch-size", String(config.batchSize),
            "--ubatch-size", String(config.ubatchSize),
            "--reasoning", "off",
            "--no-webui",
            "-a", config.modelIdentifier,
        ]
        if let multimodalProjectorPath = config.multimodalProjectorPath {
            arguments.append(contentsOf: ["--mmproj", multimodalProjectorPath])
        }
        process.arguments = arguments

        let stdout = Pipe()
        let stderr = Pipe()
        let logTail = RuntimeLogTail()
        stdout.fileHandleForReading.readabilityHandler = { fileHandle in
            let data = fileHandle.availableData
            if data.isEmpty {
                fileHandle.readabilityHandler = nil
            } else {
                logTail.append(data)
            }
        }
        stderr.fileHandleForReading.readabilityHandler = { fileHandle in
            let data = fileHandle.availableData
            if data.isEmpty {
                fileHandle.readabilityHandler = nil
            } else {
                logTail.append(data)
            }
        }
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        Self.writePID(process.processIdentifier)

        let serverHandle = LocalModelServerHandle(
            process: process,
            port: port,
            config: config,
            logTail: logTail,
            stdoutPipe: stdout,
            stderrPipe: stderr
        )
        sharedServer = serverHandle

        do {
            try await waitForServerReady(serverHandle, timeoutSeconds: 60)
            return serverHandle
        } catch {
            await stopSharedServer(reason: "server_start_failed")
            throw error
        }
    }

    private func stopSharedServer(reason: String) async {
        guard let sharedServer else { return }
        self.sharedServer = nil
        Self.deletePIDFile()

        sharedServer.stdoutPipe.fileHandleForReading.readabilityHandler = nil
        sharedServer.stderrPipe.fileHandleForReading.readabilityHandler = nil
        Self.terminate(process: sharedServer.process)
        _ = await waitForTermination(of: sharedServer.process, timeoutMilliseconds: 1_000)

        let _ = reason
    }

    private func waitForServerReady(
        _ server: LocalModelServerHandle,
        timeoutSeconds: UInt64
    ) async throws {
        let healthURL = URL(string: "http://127.0.0.1:\(server.port)/health")!

        try await withTimeout(seconds: timeoutSeconds) {
            while true {
                if !server.process.isRunning {
                    let status = server.process.terminationStatus
                    let logs = server.logTail.snapshot()
                    throw LLMError.commandFailed(
                        status,
                        logs.isEmpty ? "llama-server exited before becoming ready." : logs
                    )
                }

                var request = URLRequest(url: healthURL)
                request.httpMethod = "GET"

                do {
                    let (data, response) = try await self.urlSession.data(for: request)
                    if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
                        let body = String(decoding: data, as: UTF8.self)
                        if body.contains("\"ok\"") {
                            return
                        }
                    }
                } catch {
                    if Task.isCancelled {
                        throw CancellationError()
                    }
                }

                try await Task.sleep(nanoseconds: 250_000_000)
            }
        }
    }

    private func makeServerRequestBody(
        modelIdentifier: String,
        input: RuntimeInferenceInput,
        systemPrompt: String,
        options: RuntimeInferenceOptions
    ) throws -> Data {
        let messages: [[String: Any]]
        switch input {
        case let .text(userPrompt):
            messages = [
                [
                    "role": "system",
                    "content": systemPrompt,
                ],
                [
                    "role": "user",
                    "content": userPrompt,
                ],
            ]

        case let .vision(snapshotPath, userPrompt):
            let imageDataURL = try Self.makeImageDataURL(from: snapshotPath)
            messages = [
                [
                    "role": "system",
                    "content": systemPrompt,
                ],
                [
                    "role": "user",
                    "content": [
                        [
                            "type": "text",
                            "text": userPrompt,
                        ],
                        [
                            "type": "image_url",
                            "image_url": [
                                "url": imageDataURL,
                            ],
                        ],
                    ],
                ],
            ]
        }

        let body: [String: Any] = [
            "model": modelIdentifier,
            "messages": messages,
            "max_tokens": options.maxTokens,
            "temperature": options.temperature,
            "top_p": options.topP,
            "top_k": options.topK,
            "cache_prompt": false,
            "reasoning_format": "none",
            "stream": false,
        ]

        return try JSONSerialization.data(withJSONObject: body, options: [])
    }

    private func extractAssistantMessage(from data: Data) throws -> String {
        guard
            let json = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
            let choices = json["choices"] as? [[String: Any]],
            let firstChoice = choices.first,
            let message = firstChoice["message"] as? [String: Any]
        else {
            let raw = String(decoding: data, as: UTF8.self)
            throw LLMError.commandFailed(1, "llama-server returned an unexpected payload: \(raw)")
        }

        if let content = message["content"] as? String {
            return content
        }

        if let parts = message["content"] as? [[String: Any]] {
            let text = parts
                .compactMap { part -> String? in
                    if let value = part["text"] as? String {
                        return value
                    }
                    return nil
                }
                .joined()
            if !text.isEmpty {
                return text
            }
        }

        let raw = String(decoding: data, as: UTF8.self)
        throw LLMError.commandFailed(1, "llama-server returned an empty message: \(raw)")
    }

    private func resolveModelSource(
        runtimePath: String,
        modelIdentifier: String
    ) -> RuntimeModelSource {
        if let artifacts = cachedModelArtifacts(
            runtimePath: runtimePath,
            modelIdentifier: modelIdentifier
        ) {
            return .local(artifacts)
        }

        return .huggingFace(modelIdentifier)
    }

    private func cachedModelArtifacts(
        runtimePath: String,
        modelIdentifier: String
    ) -> CachedModelArtifacts? {
        let components = modelIdentifier.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard let repositoryComponent = components.first else {
            return nil
        }

        let repository = String(repositoryComponent)
        let quant = components.count > 1 ? String(components[1]) : nil
        let cacheRoot = repositoryURL(forRuntimePath: runtimePath)
            .appendingPathComponent(repository, isDirectory: true)
            .appendingPathComponent(
                "models--\(repository.replacingOccurrences(of: "/", with: "--"))",
                isDirectory: true
            )

        guard FileManager.default.fileExists(atPath: cacheRoot.path) else {
            return nil
        }

        let snapshotsRoot = cacheRoot.appendingPathComponent("snapshots", isDirectory: true)
        guard let snapshotURL = resolvedSnapshotURL(cacheRoot: cacheRoot, snapshotsRoot: snapshotsRoot) else {
            return nil
        }

        guard
            let files = try? FileManager.default.contentsOfDirectory(
                at: snapshotURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
        else {
            return nil
        }

        let ggufFiles = files.filter { $0.pathExtension.lowercased() == "gguf" }
        let projectorPath = ggufFiles
            .first(where: { $0.lastPathComponent.lowercased().contains("mmproj") })?
            .path

        let modelCandidates = ggufFiles.filter { !$0.lastPathComponent.lowercased().contains("mmproj") }
        guard let modelURL = Self.selectModelFile(from: modelCandidates, quant: quant) else {
            return nil
        }

        return CachedModelArtifacts(
            modelPath: modelURL.path,
            multimodalProjectorPath: projectorPath
        )
    }

    private func resolvedSnapshotURL(cacheRoot: URL, snapshotsRoot: URL) -> URL? {
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

    private func serverExecutablePath(for runtimePath: String) -> String? {
        let runtimeURL = URL(fileURLWithPath: runtimePath)
        return runtimeURL
            .deletingLastPathComponent()
            .appendingPathComponent("llama-server")
            .path
    }

    private func arguments(
        systemPromptURL: URL,
        modelSource: RuntimeModelSource,
        input: RuntimeInferenceInput,
        options: RuntimeInferenceOptions
    ) -> [String] {
        var arguments = Self.modelArguments(
            for: modelSource,
            requiresVision: input.requiresVision
        )

        arguments.append(contentsOf: [
            "-sysf", systemPromptURL.path,
        ])

        switch input {
        case let .text(userPrompt):
            arguments.append(contentsOf: [
                "-p", userPrompt,
            ])

        case let .vision(snapshotPath, userPrompt):
            arguments.append(contentsOf: [
                "--image", snapshotPath,
                "-p", userPrompt,
            ])
        }

        arguments.append(contentsOf: [
            "-cnv",
            "-st",
            "-n", String(options.maxTokens),
            "--reasoning", "off",
            "--temp", String(options.temperature),
            "--top-p", String(options.topP),
            "--top-k", String(options.topK),
            "--ctx-size", String(options.ctxSize),
            "--batch-size", String(options.batchSize),
            "--ubatch-size", String(options.ubatchSize),
            "--offline",
            "--no-display-prompt",
        ])

        return arguments
    }

    private func finalizeCLIOutput(
        stdout: Pipe,
        stderr: Pipe,
        collector: RuntimeOutputCollector
    ) -> RuntimeProcessOutput {
        stdout.fileHandleForReading.readabilityHandler = nil
        stderr.fileHandleForReading.readabilityHandler = nil
        collector.appendStdout(stdout.fileHandleForReading.readDataToEndOfFile())
        collector.appendStderr(stderr.fileHandleForReading.readDataToEndOfFile())
        return collector.output()
    }

    private func waitForTermination(
        of process: Process,
        timeoutMilliseconds: Int
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(Double(timeoutMilliseconds) / 1_000)
        while process.isRunning && Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return !process.isRunning
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

    private nonisolated static func modelArguments(
        for source: RuntimeModelSource,
        requiresVision: Bool
    ) -> [String] {
        switch source {
        case let .huggingFace(identifier):
            return ["-hf", identifier]

        case let .local(artifacts):
            var arguments = ["-m", artifacts.modelPath]
            if requiresVision, let multimodalProjectorPath = artifacts.multimodalProjectorPath {
                arguments.append(contentsOf: ["-mm", multimodalProjectorPath])
            }
            return arguments
        }
    }

    private nonisolated static func selectModelFile(
        from candidates: [URL],
        quant: String?
    ) -> URL? {
        guard let quant else {
            return candidates.sorted { $0.lastPathComponent < $1.lastPathComponent }.first
        }

        let normalizedQuant = quant.uppercased()
        let rankedCandidates = candidates.compactMap { candidate -> (Int, String, URL)? in
            let basename = candidate.deletingPathExtension().lastPathComponent.uppercased()
            let score: Int
            if basename.hasSuffix("-\(normalizedQuant)") || basename.hasSuffix("_\(normalizedQuant)") {
                score = 0
            } else if basename.contains("-\(normalizedQuant)-") || basename.contains("_\(normalizedQuant)_") {
                score = 1
            } else if basename.contains(normalizedQuant) {
                score = 2
            } else {
                return nil
            }

            return (score, candidate.lastPathComponent, candidate)
        }

        if let bestMatch = rankedCandidates
            .sorted(by: { lhs, rhs in
                if lhs.0 != rhs.0 {
                    return lhs.0 < rhs.0
                }
                return lhs.1 < rhs.1
            })
            .first?.2 {
            return bestMatch
        }

        return candidates.sorted { $0.lastPathComponent < $1.lastPathComponent }.first
    }

    private nonisolated static func makeImageDataURL(from snapshotPath: String) throws -> String {
        let data = try Data(contentsOf: URL(fileURLWithPath: snapshotPath))
        let base64 = data.base64EncodedString()

        let mimeType: String
        switch URL(fileURLWithPath: snapshotPath).pathExtension.lowercased() {
        case "jpg", "jpeg":
            mimeType = "image/jpeg"
        case "webp":
            mimeType = "image/webp"
        default:
            mimeType = "image/png"
        }

        return "data:\(mimeType);base64,\(base64)"
    }

    private nonisolated static func reserveLocalPort() throws -> Int {
        let fileDescriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard fileDescriptor >= 0 else {
            throw LLMError.commandFailed(1, "Could not allocate a local port for llama-server.")
        }
        defer {
            close(fileDescriptor)
        }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.stride)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(0).bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockAddrPointer in
                bind(fileDescriptor, sockAddrPointer, socklen_t(MemoryLayout<sockaddr_in>.stride))
            }
        }
        guard bindResult == 0 else {
            throw LLMError.commandFailed(1, "Could not bind a local port for llama-server.")
        }

        var boundAddress = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.stride)
        let nameResult = withUnsafeMutablePointer(to: &boundAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockAddrPointer in
                getsockname(fileDescriptor, sockAddrPointer, &length)
            }
        }
        guard nameResult == 0 else {
            throw LLMError.commandFailed(1, "Could not resolve the reserved llama-server port.")
        }

        return Int(UInt16(bigEndian: boundAddress.sin_port))
    }

    // MARK: - Stale-server PID file

    private nonisolated static var pidFileURL: URL {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport.appendingPathComponent("AC/llama-server.pid")
    }

    /// On launch, kill any llama-server left over from a previous crashed/force-killed session.
    private nonisolated static func killStalePIDIfNeeded() {
        let url = pidFileURL
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8),
              let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              pid > 0 else {
            return
        }
        // Verify the process is still a llama-server before killing it (guards against PID reuse).
        var pathBuffer = [CChar](repeating: 0, count: 4096)
        if proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count)) > 0,
           String(cString: pathBuffer).contains("llama-server") {
            Darwin.kill(pid, SIGKILL)
        }
        try? FileManager.default.removeItem(at: url)
    }

    private nonisolated static func writePID(_ pid: Int32) {
        let url = pidFileURL
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? String(pid).write(to: url, atomically: true, encoding: .utf8)
    }

    private nonisolated static func deletePIDFile() {
        try? FileManager.default.removeItem(at: pidFileURL)
    }

    private nonisolated static func terminate(process: Process) {
        guard process.isRunning else { return }

        process.interrupt()
        if process.isRunning {
            process.terminate()
        }
        if process.isRunning {
            Darwin.kill(process.processIdentifier, SIGKILL)
        }
    }

    nonisolated static func defaultVisionOptions(modelIdentifier: String = defaultModelIdentifier) -> RuntimeInferenceOptions {
        RuntimeInferenceOptions(
            modelIdentifier: modelIdentifier,
            maxTokens: 120,
            temperature: 0.15,
            topP: 0.95,
            topK: 64,
            ctxSize: 2048,
            batchSize: 2048,
            ubatchSize: 2048,
            timeoutSeconds: 45
        )
    }

    nonisolated static func defaultTextOptions(modelIdentifier: String = defaultModelIdentifier) -> RuntimeInferenceOptions {
        RuntimeInferenceOptions(
            modelIdentifier: modelIdentifier,
            maxTokens: 240,
            temperature: 0.4,
            topP: 0.95,
            topK: 64,
            ctxSize: 4096,
            batchSize: 1024,
            ubatchSize: 512,
            timeoutSeconds: 45
        )
    }
}

enum LLMError: LocalizedError, Equatable {
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

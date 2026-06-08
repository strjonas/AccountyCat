//
//  LocalModelRuntime.swift
//  AC
//
//  Created by Codex on 15.04.26.
//

import Darwin
import Foundation
import ImageIO

struct RuntimeProcessOutput: Sendable {
    var stdout: String
    var stderr: String
    var usedModelIdentifier: String?
    var tokenUsage: TokenUsage?
    /// True only when an image was actually sent to the runtime/provider. A
    /// screenshot path in AC's snapshot is not enough; text-only fallbacks must
    /// not be counted as vision-backed decisions.
    var imageWasProcessed: Bool
    /// Set by `OnlineModelService` (and the local-chat path) when a telemetry
    /// `.llmInteraction` event was emitted for this call. Callers should pass
    /// this id back to `LLMTelemetryRecorder.annotate(...)` once the raw text
    /// has been parsed into a domain object so the inspector can show the
    /// extracted fields alongside the raw I/O.
    var interactionID: String?

    nonisolated init(
        stdout: String,
        stderr: String,
        usedModelIdentifier: String? = nil,
        tokenUsage: TokenUsage? = nil,
        imageWasProcessed: Bool = false,
        interactionID: String? = nil
    ) {
        self.stdout = stdout
        self.stderr = stderr
        self.usedModelIdentifier = usedModelIdentifier
        self.tokenUsage = tokenUsage
        self.imageWasProcessed = imageWasProcessed
        self.interactionID = interactionID
    }
}

enum LocalModelCacheSlot: Int, Sendable {
    case decision = 0
    case chat = 1
    case auxiliary = 2
}

struct TokenUsage: Sendable, Codable, Hashable {
    var promptTokens: Int
    var completionTokens: Int
    var totalTokens: Int
    var cacheReadTokens: Int?
    var imageTokens: Int?
    var costUSD: Double?
    var estimated: Bool

    nonisolated init(
        promptTokens: Int,
        completionTokens: Int,
        totalTokens: Int? = nil,
        cacheReadTokens: Int? = nil,
        imageTokens: Int? = nil,
        costUSD: Double? = nil,
        estimated: Bool = false
    ) {
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.totalTokens = totalTokens ?? (promptTokens + completionTokens)
        self.cacheReadTokens = cacheReadTokens
        self.imageTokens = imageTokens
        self.costUSD = costUSD
        self.estimated = estimated
    }

    nonisolated static func estimate(promptText: String, completionText: String) -> TokenUsage {
        let prompt = max(1, promptText.count / 4)
        let completion = max(0, completionText.count / 4)
        return TokenUsage(
            promptTokens: prompt,
            completionTokens: completion,
            estimated: true
        )
    }
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

    var userPrompt: String {
        switch self {
        case let .text(userPrompt), let .vision(_, userPrompt):
            return userPrompt
        }
    }

    var imagePath: String? {
        switch self {
        case .text:
            return nil
        case let .vision(snapshotPath, _):
            return snapshotPath
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
    var isReady: Bool

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
        self.isReady = false
    }
}

actor LocalModelRuntime {

    private let urlSession: URLSession
    private var sharedServer: LocalModelServerHandle?
    private var activeSharedServerRequests = 0
    private var activeInteractiveRequests = 0
    private var scheduledShutdownTask: Task<Void, Never>?

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
        userPrompt: String,
        cacheSlot: LocalModelCacheSlot? = nil
    ) async throws -> RuntimeProcessOutput {
        try await runVisionInference(
            runtimePath: runtimePath,
            modelIdentifier: modelIdentifier,
            snapshotPath: snapshotPath,
            systemPrompt: systemPrompt,
            userPrompt: userPrompt,
            options: Self.defaultVisionOptions(),
            cacheSlot: cacheSlot
        )
    }

    func runVisionInference(
        runtimePath: String,
        modelIdentifier: String,
        snapshotPath: String,
        systemPrompt: String,
        userPrompt: String,
        options: RuntimeInferenceOptions,
        cacheSlot: LocalModelCacheSlot? = nil
    ) async throws -> RuntimeProcessOutput {
        try await runInference(
            runtimePath: runtimePath,
            modelIdentifier: modelIdentifier,
            input: .vision(snapshotPath: snapshotPath, userPrompt: userPrompt),
            systemPrompt: systemPrompt,
            options: options,
            cacheSlot: cacheSlot
        )
    }

    func runTextInference(
        runtimePath: String,
        modelIdentifier: String,
        systemPrompt: String,
        userPrompt: String,
        cacheSlot: LocalModelCacheSlot? = nil
    ) async throws -> RuntimeProcessOutput {
        try await runTextInference(
            runtimePath: runtimePath,
            modelIdentifier: modelIdentifier,
            systemPrompt: systemPrompt,
            userPrompt: userPrompt,
            options: Self.defaultTextOptions(),
            cacheSlot: cacheSlot
        )
    }

    func runTextInference(
        runtimePath: String,
        modelIdentifier: String,
        systemPrompt: String,
        userPrompt: String,
        options: RuntimeInferenceOptions,
        cacheSlot: LocalModelCacheSlot? = nil
    ) async throws -> RuntimeProcessOutput {
        try await runInference(
            runtimePath: runtimePath,
            modelIdentifier: modelIdentifier,
            input: .text(userPrompt: userPrompt),
            systemPrompt: systemPrompt,
            options: options,
            cacheSlot: cacheSlot
        )
    }

    /// Best-effort keep-warm: start the shared server (paying the model load once) and
    /// prime the supplied stable system-prompt prefixes so the user's first real
    /// chat/decision pays a warm prefill instead of a cold one (for 9B this turns a
    /// ~29 s cold decision into a ~7 s warm one). Never throws, yields immediately to
    /// any real request already in flight, and schedules a normal idle shutdown
    /// afterwards so an unused warm server still releases its memory.
    func prewarm(
        runtimePath: String,
        modelIdentifier: String,
        prompts: [(slot: LocalModelCacheSlot, systemPrompt: String)]
    ) async {
        for prompt in prompts where !prompt.systemPrompt.isEmpty {
            if Task.isCancelled { break }
            // A real user/monitor request always wins — never compete for the server.
            guard !hasAnyRequestInFlight(), !hasInteractiveRequestInFlight() else { break }
            _ = try? await runTextInference(
                runtimePath: runtimePath,
                modelIdentifier: modelIdentifier,
                systemPrompt: prompt.systemPrompt,
                userPrompt: "ok",
                options: Self.prewarmOptions(),
                cacheSlot: prompt.slot
            )
        }
        // Don't pin the server on forever; let it idle out if the user never engages.
        // Any real request cancels this, and the monitor's cadence keeps it warm.
        if !Task.isCancelled {
            scheduleShutdown(after: Self.prewarmIdleShutdownSeconds, reason: "post_prewarm_idle")
        }
    }

    func shutdown() async {
        scheduledShutdownTask?.cancel()
        scheduledShutdownTask = nil
        await stopSharedServer(reason: "runtime_shutdown")
    }

    func scheduleShutdown(after seconds: UInt64, reason: String) {
        scheduledShutdownTask?.cancel()
        scheduledShutdownTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: seconds * NSEC_PER_SEC)
                await self?.shutdownWhenIdle(reason: reason)
            } catch {
                return
            }
        }
    }

    func cancelScheduledShutdown() {
        scheduledShutdownTask?.cancel()
        scheduledShutdownTask = nil
    }

    func hasInteractiveRequestInFlight() -> Bool {
        activeInteractiveRequests > 0
    }

    func hasAnyRequestInFlight() -> Bool {
        activeSharedServerRequests > 0
    }

    func beginInteractiveRequestForTesting() {
        activeInteractiveRequests += 1
    }

    func endInteractiveRequestForTesting() {
        activeInteractiveRequests = max(0, activeInteractiveRequests - 1)
    }

    func isSharedServerRunning() -> Bool {
        sharedServer?.process.isRunning == true
    }

    func isSharedServerReady() -> Bool {
        sharedServer?.process.isRunning == true && sharedServer?.isReady == true
    }

    func withInteractiveRequest<T>(
        _ operation: @escaping @Sendable () async throws -> T
    ) async rethrows -> T {
        activeInteractiveRequests += 1
        defer { activeInteractiveRequests -= 1 }
        return try await operation()
    }

    private func repositoryURL(forRuntimePath runtimePath: String) -> URL {
        URL(fileURLWithPath: runtimePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func runInference(
        runtimePath: String,
        modelIdentifier: String,
        input: RuntimeInferenceInput,
        systemPrompt: String,
        options: RuntimeInferenceOptions,
        cacheSlot: LocalModelCacheSlot?
    ) async throws -> RuntimeProcessOutput {
        cancelScheduledShutdown()
        let cancellationBox = RuntimeCancellationBox()

        return try await withTaskCancellationHandler {
            try Task.checkCancellation()

            let modelSource = resolveModelSource(
                runtimePath: runtimePath,
                modelIdentifier: modelIdentifier
            )

            if case let .local(artifacts) = modelSource,
               let serverExecutablePath = serverExecutablePath(for: runtimePath),
               FileManager.default.isExecutableFile(atPath: serverExecutablePath),
               (!input.requiresVision || artifacts.multimodalProjectorPath != nil) {
                do {
                    return try await runServerInference(
                        runtimePath: runtimePath,
                        modelIdentifier: modelIdentifier,
                        serverExecutablePath: serverExecutablePath,
                        artifacts: artifacts,
                        input: input,
                        systemPrompt: systemPrompt,
                        options: options,
                        cancellationBox: cancellationBox,
                        cacheSlot: cacheSlot
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

            if case .vision = input,
               case let .local(artifacts) = modelSource,
               artifacts.multimodalProjectorPath == nil {
                throw LLMError.visionUnavailable(modelIdentifier)
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
        modelIdentifier: String,
        serverExecutablePath: String,
        artifacts: CachedModelArtifacts,
        input: RuntimeInferenceInput,
        systemPrompt: String,
        options: RuntimeInferenceOptions,
        cancellationBox: RuntimeCancellationBox,
        cacheSlot: LocalModelCacheSlot?
    ) async throws -> RuntimeProcessOutput {
        let preflight = PromptBudgetGuard.preflightPlan(
            systemPrompt: systemPrompt,
            userPrompt: input.userPrompt,
            imagePath: input.imagePath,
            ctxSize: options.ctxSize,
            maxTokens: options.maxTokens,
            maxCtxGrowth: 2_048
        )
        let effectiveOptions = RuntimeInferenceOptions(
            maxTokens: options.maxTokens,
            temperature: options.temperature,
            topP: options.topP,
            topK: options.topK,
            ctxSize: preflight.recommendedCtxSize,
            batchSize: options.batchSize,
            ubatchSize: options.ubatchSize,
            timeoutSeconds: options.timeoutSeconds,
            thinkingEnabled: options.thinkingEnabled
        )
        let server = try await ensureSharedServer(
            config: RuntimeServerConfig(
                executablePath: serverExecutablePath,
                runtimePath: runtimePath,
                modelIdentifier: modelIdentifier,
                modelPath: artifacts.modelPath,
                multimodalProjectorPath: artifacts.multimodalProjectorPath,
                ctxSize: Self.sharedServerTotalCtxSize(
                    requested: effectiveOptions.ctxSize,
                    hasVisionProjector: artifacts.multimodalProjectorPath != nil
                ),
                batchSize: max(effectiveOptions.batchSize, Self.sharedServerBatchSizeFloor),
                ubatchSize: max(effectiveOptions.ubatchSize, Self.sharedServerUBatchSizeFloor)
            ),
            startupTimeoutSeconds: Self.sharedServerStartupTimeoutSeconds(
                for: cacheSlot,
                options: effectiveOptions
            )
        )

        let requestBody = try await makeServerRequestBody(
            modelIdentifier: modelIdentifier,
            input: input,
            systemPrompt: systemPrompt,
            options: effectiveOptions,
            serverPort: server.port,
            imageMaxDimension: preflight.imageMaxDimension,
            cacheSlot: cacheSlot
        )
        activeSharedServerRequests += 1
        defer { activeSharedServerRequests -= 1 }
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
            let (data, response) = try await withTimeout(seconds: effectiveOptions.timeoutSeconds) {
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
            let usage = Self.parseLocalServerUsage(from: data)
                ?? TokenUsage.estimate(promptText: systemPrompt, completionText: assistantMessage)
            return RuntimeProcessOutput(
                stdout: assistantMessage,
                stderr: "",
                tokenUsage: usage,
                imageWasProcessed: input.imagePath != nil
            )
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
        let preflight = PromptBudgetGuard.preflightPlan(
            systemPrompt: systemPrompt,
            userPrompt: input.userPrompt,
            imagePath: input.imagePath,
            ctxSize: options.ctxSize,
            maxTokens: options.maxTokens,
            maxCtxGrowth: 2_048
        )
        let effectiveOptions = RuntimeInferenceOptions(
            maxTokens: options.maxTokens,
            temperature: options.temperature,
            topP: options.topP,
            topK: options.topK,
            ctxSize: preflight.recommendedCtxSize,
            batchSize: options.batchSize,
            ubatchSize: options.ubatchSize,
            timeoutSeconds: options.timeoutSeconds,
            thinkingEnabled: options.thinkingEnabled
        )
        let guardedPrompt = await PromptBudgetGuard.guardedUserPrompt(
            systemPrompt: systemPrompt,
            userPrompt: input.userPrompt,
            imagePath: input.imagePath,
            ctxSize: effectiveOptions.ctxSize,
            maxTokens: effectiveOptions.maxTokens,
            serverPort: 0,
            thinkingEnabled: effectiveOptions.thinkingEnabled,
            transport: { request in
                max(0, request.content.count / 4)
            }
        )
        let effectiveInput: RuntimeInferenceInput
        switch input {
        case .text:
            effectiveInput = .text(userPrompt: guardedPrompt.userPrompt)
        case let .vision(snapshotPath, _):
            effectiveInput = .vision(
                snapshotPath: snapshotPath,
                userPrompt: guardedPrompt.userPrompt
            )
        }
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
            input: effectiveInput,
            options: effectiveOptions
        )
        process.environment = Self.processEnvironment()

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
            status = try await waitForProcessExit(process, timeoutSeconds: options.timeoutSeconds)
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

        let usage = Self.parseLlamaCLIUsage(from: output.stderr)
            ?? TokenUsage.estimate(promptText: systemPrompt, completionText: output.stdout)
        return RuntimeProcessOutput(
            stdout: output.stdout,
            stderr: output.stderr,
            usedModelIdentifier: output.usedModelIdentifier,
            tokenUsage: usage,
            imageWasProcessed: input.imagePath != nil
        )
    }

    nonisolated private static func parseLocalServerUsage(from data: Data) -> TokenUsage? {
        guard
            let json = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
            let usage = json["usage"] as? [String: Any]
        else {
            return nil
        }
        let prompt = usage["prompt_tokens"] as? Int ?? 0
        let completion = usage["completion_tokens"] as? Int ?? 0
        guard prompt > 0 || completion > 0 else { return nil }
        return TokenUsage(
            promptTokens: prompt,
            completionTokens: completion,
            totalTokens: usage["total_tokens"] as? Int,
            cacheReadTokens: (usage["prompt_tokens_details"] as? [String: Any])?["cached_tokens"] as? Int,
            imageTokens: (usage["prompt_tokens_details"] as? [String: Any])?["image_tokens"] as? Int,
            estimated: false
        )
    }

    nonisolated private static func parseLlamaCLIUsage(from stderr: String) -> TokenUsage? {
        // llama.cpp prints lines like:
        //   "prompt eval time = ... ms / NN tokens"
        //   "       eval time = ... ms / MM tokens"
        var prompt = 0
        var completion = 0
        for line in stderr.split(separator: "\n") {
            let lower = line.lowercased()
            guard lower.contains("eval time"),
                  let slashIdx = line.firstIndex(of: "/") else { continue }
            let after = line[line.index(after: slashIdx)...]
            let digits = after.drop(while: { $0 == " " })
                .prefix(while: { $0.isNumber })
            guard let count = Int(digits), count > 0 else { continue }
            if lower.contains("prompt eval") {
                prompt = count
            } else {
                completion = count
            }
        }
        guard prompt > 0 || completion > 0 else { return nil }
        return TokenUsage(
            promptTokens: prompt,
            completionTokens: completion,
            estimated: false
        )
    }

    private func ensureSharedServer(
        config: RuntimeServerConfig,
        startupTimeoutSeconds: UInt64
    ) async throws -> LocalModelServerHandle {
        cancelScheduledShutdown()
        if let sharedServer {
            let sameBinary = sharedServer.config.executablePath == config.executablePath
            let sameModel = sharedServer.config.modelPath == config.modelPath
            let sameProjector = sharedServer.config.multimodalProjectorPath == config.multimodalProjectorPath
            let canReuseCapacity =
                sharedServer.config.ctxSize >= config.ctxSize &&
                sharedServer.config.batchSize >= config.batchSize &&
                sharedServer.config.ubatchSize >= config.ubatchSize

            if sharedServer.process.isRunning, sameBinary, sameModel, sameProjector, canReuseCapacity {
                if !sharedServer.isReady {
                    try await waitForServerReady(
                        sharedServer,
                        timeoutSeconds: startupTimeoutSeconds
                    )
                    sharedServer.isReady = true
                }
                return sharedServer
            }

            if activeSharedServerRequests > 0 {
                try await waitForSharedServerToBecomeIdle()
            }

            await stopSharedServer(reason: "server_reconfigure")
        }

        let port = try Self.reserveLocalPort()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: config.executablePath)
        process.currentDirectoryURL = repositoryURL(forRuntimePath: config.runtimePath)
        process.environment = Self.processEnvironment()

        var arguments = [
            "-m", config.modelPath,
            "--offline",
            "--host", "127.0.0.1",
            "--port", String(port),
            "--ctx-size", String(config.ctxSize),
            "--batch-size", String(config.batchSize),
            "--ubatch-size", String(config.ubatchSize),
            "--parallel", String(Self.sharedServerSlotCount),
            "--reasoning", "off",
            "--reasoning-format", "none",
            "--no-webui",
            "-a", config.modelIdentifier,
            "-ngl", "999",
            "--threads", String(Self.sharedServerThreadCount),
            "--threads-batch", String(Self.sharedServerThreadCount),
            "--cache-type-k", "q8_0",
            "--cache-type-v", "q8_0",
            "--ctx-checkpoints", "512",
            "--checkpoint-every-n-tokens", "512",
            "--reasoning-budget", "0",
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
            try await waitForServerReady(
                serverHandle,
                timeoutSeconds: startupTimeoutSeconds
            )
            serverHandle.isReady = true
            return serverHandle
        } catch is CancellationError {
            throw CancellationError()
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

    private func shutdownWhenIdle(reason: String) async {
        guard sharedServer != nil else { return }
        if activeSharedServerRequests > 0 {
            try? await waitForSharedServerToBecomeIdle()
        }
        guard sharedServer != nil, activeSharedServerRequests == 0 else { return }
        scheduledShutdownTask = nil
        await stopSharedServer(reason: reason)
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
        options: RuntimeInferenceOptions,
        serverPort: Int,
        imageMaxDimension: Int?,
        cacheSlot: LocalModelCacheSlot?
    ) async throws -> Data {
        let guardedPrompt: PromptBudgetGuardResult
        let messages: [[String: Any]]
        switch input {
        case let .text(userPrompt):
            guardedPrompt = await PromptBudgetGuard.guardedUserPrompt(
                systemPrompt: systemPrompt,
                userPrompt: userPrompt,
                imagePath: nil,
                ctxSize: options.ctxSize,
                maxTokens: options.maxTokens,
                serverPort: serverPort,
                thinkingEnabled: options.thinkingEnabled,
                transport: tokenizeWithServer(request:),
                chatTransport: tokenizeChatPromptWithServer(request:)
            )
            messages = Self.textChatMessages(
                systemPrompt: systemPrompt,
                userPrompt: guardedPrompt.userPrompt
            )

        case let .vision(snapshotPath, userPrompt):
            guardedPrompt = await PromptBudgetGuard.guardedUserPrompt(
                systemPrompt: systemPrompt,
                userPrompt: userPrompt,
                imagePath: snapshotPath,
                ctxSize: options.ctxSize,
                maxTokens: options.maxTokens,
                serverPort: serverPort,
                thinkingEnabled: options.thinkingEnabled,
                transport: tokenizeWithServer(request:),
                chatTransport: tokenizeChatPromptWithServer(request:)
            )
            let imageDataURL = try Self.makeImageDataURL(
                from: snapshotPath,
                maxPixelDimension: imageMaxDimension
            )
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
                            "text": guardedPrompt.userPrompt,
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

        var body: [String: Any] = [
            "model": modelIdentifier,
            "messages": messages,
            "max_tokens": options.maxTokens,
            "temperature": options.temperature,
            "top_p": options.topP,
            "top_k": options.topK,
            "cache_prompt": true,
            "stream": false,
            "chat_template_kwargs": [
                "enable_thinking": options.thinkingEnabled,
            ],
        ]
        if let cacheSlot {
            body["id_slot"] = cacheSlot.rawValue
        }
        if !options.thinkingEnabled {
            body["reasoning_format"] = "none"
        }

        if guardedPrompt.wasTruncated {
            appendPromptBudgetTruncatedMetric(
                detail:
                    "ctx=\(options.ctxSize) max=\(options.maxTokens) prompt=\(guardedPrompt.promptTokensEstimate) image=\(guardedPrompt.imageTokensEstimate)"
            )
        }
        if let warning = guardedPrompt.warning {
            Task {
                await ActivityLogService.shared.append(
                    category: "prompt-budget-warning",
                    message: warning
                )
            }
        }

        return try JSONSerialization.data(withJSONObject: body, options: [])
    }

    private nonisolated static func textChatMessages(
        systemPrompt: String,
        userPrompt: String
    ) -> [[String: Any]] {
        [
            [
                "role": "system",
                "content": systemPrompt,
            ],
            [
                "role": "user",
                "content": userPrompt,
            ],
        ]
    }

    private func tokenizeChatPromptWithServer(request: PromptBudgetGuardChatRequest) async throws -> Int {
        let renderedPrompt = try await applyChatTemplateWithServer(request: request)
        return try await tokenizeWithServer(
            request: PromptBudgetGuardRequest(
                serverPort: request.serverPort,
                content: renderedPrompt,
                timeoutSeconds: request.timeoutSeconds
            )
        )
    }

    private func applyChatTemplateWithServer(request: PromptBudgetGuardChatRequest) async throws -> String {
        guard var components = URLComponents(string: "http://127.0.0.1") else {
            throw LLMError.commandFailed(1, "Failed to construct llama-server template URL.")
        }
        components.port = request.serverPort
        components.path = "/apply-template"
        guard let templateURL = components.url else {
            throw LLMError.commandFailed(
                1,
                "Failed to construct llama-server template URL for port \(request.serverPort)."
            )
        }
        var urlRequest = URLRequest(url: templateURL)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = request.timeoutSeconds
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONSerialization.data(
            withJSONObject: [
                "messages": Self.textChatMessages(
                    systemPrompt: request.systemPrompt,
                    userPrompt: request.userPrompt
                ),
            ]
        )

        let (data, response) = try await urlSession.data(for: urlRequest)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw LLMError.commandFailed(1, "llama-server template endpoint returned a non-HTTP response.")
        }
        guard httpResponse.statusCode == 200 else {
            throw LLMError.commandFailed(
                Int32(httpResponse.statusCode),
                String(decoding: data, as: UTF8.self)
            )
        }
        guard
            let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let prompt = payload["prompt"] as? String
        else {
            throw LLMError.commandFailed(1, "llama-server template endpoint returned an unexpected payload.")
        }
        return prompt
    }

    private func tokenizeWithServer(request: PromptBudgetGuardRequest) async throws -> Int {
        guard var components = URLComponents(string: "http://127.0.0.1") else {
            throw LLMError.commandFailed(1, "Failed to construct llama-server tokenization URL.")
        }
        components.port = request.serverPort
        components.path = "/tokenize"
        guard let tokenizeURL = components.url else {
            throw LLMError.commandFailed(
                1,
                "Failed to construct llama-server tokenization URL for port \(request.serverPort)."
            )
        }
        var urlRequest = URLRequest(url: tokenizeURL)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = request.timeoutSeconds
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONSerialization.data(
            withJSONObject: [
                "content": request.content,
                "add_special": false,
                "parse_special": true,
            ]
        )

        let (data, response) = try await urlSession.data(for: urlRequest)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw LLMError.commandFailed(1, "llama-server tokenization returned a non-HTTP response.")
        }
        guard httpResponse.statusCode == 200 else {
            throw LLMError.commandFailed(
                Int32(httpResponse.statusCode),
                String(decoding: data, as: UTF8.self)
            )
        }
        guard
            let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let tokens = payload["tokens"] as? [Any]
        else {
            throw LLMError.commandFailed(1, "llama-server tokenization returned an unexpected payload.")
        }
        return tokens.count
    }

    private func appendPromptBudgetTruncatedMetric(detail: String) {
        Task {
            await ActivityLogService.shared.append(
                category: "prompt-budget-truncated",
                message: detail
            )
        }
        guard TelemetryPersistencePolicy.storesVerboseTelemetry(debugMode: ACBuild.isDebug) else {
            return
        }
        Task {
            guard let sessionID = try? await TelemetryStore.shared.ensureCurrentSession(reason: "runtime").id else {
                return
            }
            try? await TelemetryStore.shared.appendEvent(
                TelemetryEvent(
                    id: UUID().uuidString,
                    kind: .monitoringMetric,
                    timestamp: Date(),
                    sessionID: sessionID,
                    episodeID: nil,
                    episode: nil,
                    session: nil,
                    observation: nil,
                    evaluation: nil,
                    modelInput: nil,
                    modelOutput: nil,
                    parsedOutput: nil,
                    policy: nil,
                    action: nil,
                    metric: MonitoringMetricRecord(
                        kind: .promptBudgetTruncated,
                        reason: "prompt_budget_truncated",
                        activeProfileID: nil,
                        activeProfileName: nil,
                        detail: detail
                    ),
                    reaction: nil,
                    annotation: nil,
                    failure: nil,
                    llmInteraction: nil
                ),
                sessionID: sessionID
            )
        }
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
        // A user-linked `.gguf` path is its own model file. Pick up a sibling
        // `*mmproj*.gguf` as the vision projector if one sits next to it.
        let trimmedIdentifier = modelIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedIdentifier.hasPrefix("/"),
           trimmedIdentifier.lowercased().hasSuffix(".gguf"),
           FileManager.default.fileExists(atPath: trimmedIdentifier) {
            let modelURL = URL(fileURLWithPath: trimmedIdentifier)
            let projectorPath = (try? FileManager.default.contentsOfDirectory(
                at: modelURL.deletingLastPathComponent(),
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ))?.first {
                $0.pathExtension.lowercased() == "gguf"
                    && $0.lastPathComponent.lowercased().contains("mmproj")
            }?.path
            return CachedModelArtifacts(modelPath: trimmedIdentifier, multimodalProjectorPath: projectorPath)
        }

        let components = modelIdentifier.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard let repositoryComponent = components.first else {
            return nil
        }

        let repository = String(repositoryComponent)
        let quant = components.count > 1 ? String(components[1]) : nil
        for cacheRoot in modelCacheRoots(runtimePath: runtimePath, repository: repository)
        where FileManager.default.fileExists(atPath: cacheRoot.path) {
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
            let projectorPath = ggufFiles
                .first(where: { $0.lastPathComponent.lowercased().contains("mmproj") })?
                .path

            let modelCandidates = ggufFiles.filter { !$0.lastPathComponent.lowercased().contains("mmproj") }
            guard let modelURL = Self.selectModelFile(from: modelCandidates, quant: quant) else {
                continue
            }

            return CachedModelArtifacts(
                modelPath: modelURL.path,
                multimodalProjectorPath: projectorPath
            )
        }

        return nil
    }

    private func modelCacheRoots(runtimePath: String, repository: String) -> [URL] {
        let cacheDirectoryName = "models--\(repository.replacingOccurrences(of: "/", with: "--"))"
        let runtimeCacheURL = repositoryURL(forRuntimePath: runtimePath)
            .appendingPathComponent("\(repository)/\(cacheDirectoryName)", isDirectory: true)
        return [
            runtimeCacheURL,
            Self.defaultHuggingFaceCacheURL()
                .appendingPathComponent("hub", isDirectory: true)
                .appendingPathComponent(cacheDirectoryName, isDirectory: true)
        ]
    }

    private nonisolated static func defaultHuggingFaceCacheURL() -> URL {
        TelemetryPaths.applicationSupportURL()
            .appendingPathComponent("runtime", isDirectory: true)
            .appendingPathComponent("hf-cache", isDirectory: true)
    }

    private nonisolated static let sharedServerThreadCount = perfCoreCount()
    private nonisolated static let sharedServerTextCtxSizeFloor = 4_096
    private nonisolated static let sharedServerVisionCtxSizeFloor = 6_144
    private nonisolated static let sharedServerBatchSizeFloor = 512
    private nonisolated static let sharedServerUBatchSizeFloor = 512

    /// llama-server cache slots. Decision and chat get pinned hot slots; lower-priority
    /// stages use an auxiliary scratch slot so they do not deliberately evict the two
    /// latency-sensitive prefixes. `--ctx-size` is the total across slots, so it is
    /// scaled by this count (see `sharedServerTotalCtxSize`) to preserve each slot's
    /// full window.
    private nonisolated static let sharedServerSlotCount = 3

    private nonisolated static func sharedServerCtxSizeFloor(
        requested: Int,
        hasVisionProjector: Bool
    ) -> Int {
        let floor = hasVisionProjector ? sharedServerVisionCtxSizeFloor : sharedServerTextCtxSizeFloor
        return max(requested, floor)
    }

    /// Total `--ctx-size` for the shared server: the per-slot floor times the slot
    /// count, so each of the `--parallel` slots keeps the full per-request window
    /// (a naive `--parallel 2` would otherwise halve every slot and truncate the
    /// decision prompt).
    private nonisolated static func sharedServerTotalCtxSize(
        requested: Int,
        hasVisionProjector: Bool
    ) -> Int {
        sharedServerCtxSizeFloor(requested: requested, hasVisionProjector: hasVisionProjector)
            * sharedServerSlotCount
    }

    private nonisolated static func processEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let cacheURL = defaultHuggingFaceCacheURL()
        try? FileManager.default.createDirectory(at: cacheURL, withIntermediateDirectories: true)
        environment["HF_HOME"] = cacheURL.path
        return environment
    }

    private nonisolated static func perfCoreCount() -> Int {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            sysctlbyname("hw.perflevel0.physicalcpu", pointer, &size, nil, 0)
        }
        if status == 0, value > 0 {
            return Int(value)
        }
        return max(1, ProcessInfo.processInfo.activeProcessorCount)
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
            "--temp", String(options.temperature),
            "--top-p", String(options.topP),
            "--top-k", String(options.topK),
            "--ctx-size", String(options.ctxSize),
            "--batch-size", String(options.batchSize),
            "--ubatch-size", String(options.ubatchSize),
            "--offline",
            "--no-display-prompt",
        ])

        if !options.thinkingEnabled {
            arguments.append(contentsOf: ["--reasoning", "off"])
        }

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

    private func waitForProcessExit(
        _ process: Process,
        timeoutSeconds: UInt64
    ) async throws -> Int32 {
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds))
        while process.isRunning {
            try Task.checkCancellation()
            guard Date() < deadline else {
                throw LLMError.timeout
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        return process.terminationStatus
    }

    private func waitForSharedServerToBecomeIdle() async throws {
        let deadline = Date().addingTimeInterval(60)
        while activeSharedServerRequests > 0 && Date() < deadline {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 50_000_000)
        }
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

    private nonisolated static func makeImageDataURL(
        from snapshotPath: String,
        maxPixelDimension: Int?
    ) throws -> String {
        let imageURL = URL(fileURLWithPath: snapshotPath)
        let originalData = try Data(contentsOf: imageURL)
        if let downscaledPNG = downscaledPNGDataIfNeeded(
            originalData,
            maxPixelDimension: maxPixelDimension ?? 1_600
        ) {
            return "data:image/png;base64,\(downscaledPNG.base64EncodedString())"
        }

        let base64 = originalData.base64EncodedString()

        let mimeType: String
        switch imageURL.pathExtension.lowercased() {
        case "jpg", "jpeg":
            mimeType = "image/jpeg"
        case "webp":
            mimeType = "image/webp"
        default:
            mimeType = "image/png"
        }

        return "data:\(mimeType);base64,\(base64)"
    }

    private nonisolated static func downscaledPNGDataIfNeeded(
        _ data: Data,
        maxPixelDimension: Int
    ) -> Data? {
        guard
            let source = CGImageSourceCreateWithData(data as CFData, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? Int,
            let height = properties[kCGImagePropertyPixelHeight] as? Int,
            max(width, height) > maxPixelDimension
        else {
            return nil
        }

        let options: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: maxPixelDimension,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }

        let destinationData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(destinationData, "public.png" as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, thumbnail, nil)
        guard CGImageDestinationFinalize(destination) else {
            return nil
        }
        return destinationData as Data
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

    nonisolated static func defaultVisionOptions() -> RuntimeInferenceOptions {
        RuntimeInferenceOptions(
            maxTokens: 120,
            temperature: 0.15,
            topP: 0.95,
            topK: 64,
            ctxSize: 2048,
            batchSize: 512,
            ubatchSize: 512,
            timeoutSeconds: 45
        )
    }

    nonisolated static func defaultTextOptions() -> RuntimeInferenceOptions {
        RuntimeInferenceOptions(
            maxTokens: 240,
            temperature: 0.4,
            topP: 0.95,
            topK: 64,
            ctxSize: 4096,
            batchSize: 512,
            ubatchSize: 512,
            timeoutSeconds: 45
        )
    }

    /// How long an idle server lingers after a prewarm with no real activity.
    private nonisolated static let prewarmIdleShutdownSeconds: UInt64 = 240

    /// Cold local startup includes process launch, model load, and llama-server's own
    /// readiness transition. Do not use the per-request generation timeout here.
    private nonisolated static let sharedServerStartupTimeoutSeconds: UInt64 = 180

    private nonisolated static func sharedServerStartupTimeoutSeconds(
        for cacheSlot: LocalModelCacheSlot?,
        options: RuntimeInferenceOptions
    ) -> UInt64 {
        guard cacheSlot == .chat else {
            return sharedServerStartupTimeoutSeconds
        }
        return min(sharedServerStartupTimeoutSeconds, max(45, options.timeoutSeconds))
    }

    /// Generate a single token (we only want the prefill cached). Context/batch match
    /// the text-decision floors so the shared server is sized exactly as a real text
    /// request would size it, and the first decision/chat reuses it without a restart.
    private nonisolated static func prewarmOptions() -> RuntimeInferenceOptions {
        RuntimeInferenceOptions(
            maxTokens: 1,
            temperature: 0.0,
            topP: 1.0,
            topK: 1,
            ctxSize: sharedServerTextCtxSizeFloor,
            batchSize: sharedServerBatchSizeFloor,
            ubatchSize: sharedServerUBatchSizeFloor,
            timeoutSeconds: 60
        )
    }
}

enum LLMError: LocalizedError, Equatable {
    case timeout
    case commandFailed(Int32, String)
    case visionUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .timeout:
            return "llama.cpp timed out."
        case let .commandFailed(status, output):
            return "llama.cpp exited with \(status): \(output)"
        case let .visionUnavailable(modelIdentifier):
            return "Local model \(modelIdentifier) is missing a multimodal projector and cannot process screenshots."
        }
    }
}

//
//  LLMService.swift
//  AC
//
//  Created by Codex on 12.04.26.
//

import CryptoKit
import Foundation

struct LLMEvaluationAttempt: Sendable {
    var promptMode: String
    var promptVersion: String
    var template: PromptTemplateRecord
    var templateContents: String
    var payloadJSON: String
    var renderedPrompt: String
    var runtimeOutput: RuntimeProcessOutput?
    var parsedDecision: LLMDecision?
}

struct LLMEvaluationResult: Sendable {
    var runtimePath: String
    var modelIdentifier: String
    var attempts: [LLMEvaluationAttempt]
    var finalDecision: LLMDecision?
    var failureMessage: String?
}

struct RuntimeProcessOutput: Sendable {
    var stdout: String
    var stderr: String
}

private struct VisionPromptPayload: Codable, Sendable {
    var goals: String
    var frontmostApp: String
    var windowTitle: String?
    var timestamp: Date
    var recentSwitches: [TelemetryAppSwitchRecord]
    var timeByApp: [TelemetryUsageRecord]
    var recentActions: [TelemetryActionSummary]
    var heuristics: TelemetryHeuristicSnapshot
    var distraction: TelemetryDistractionState
    var responseSchema: [String: String]
}

actor LLMService {
    private var cooldownUntil: Date?

    private let modelIdentifier = "unsloth/gemma-4-E2B-it-GGUF:Q4_0"
    private let primaryPromptVersion = "focus.v2"
    private let fallbackPromptVersion = "focus-fallback.v2"

    func evaluate(
        snapshot: AppSnapshot,
        goals: String,
        recentActions: [ActionRecord],
        distraction: DistractionMetadata,
        heuristics: TelemetryHeuristicSnapshot,
        memory: String = "",
        runtimeOverride: String?
    ) async -> LLMEvaluationResult {
        let runtimePath = RuntimeSetupService.normalizedRuntimePath(from: runtimeOverride)
        let primaryAttempt = makePrimaryAttempt(
            snapshot: snapshot,
            goals: goals,
            recentActions: recentActions,
            heuristics: heuristics,
            distraction: distraction,
            memory: memory
        )
        var attempts: [LLMEvaluationAttempt] = [primaryAttempt]

        if let cooldownUntil, Date() < cooldownUntil {
            await ActivityLogService.shared.append(
                category: "llm",
                message: "Skipped evaluation because cooldown is active."
            )
            return LLMEvaluationResult(
                runtimePath: runtimePath,
                modelIdentifier: modelIdentifier,
                attempts: attempts,
                finalDecision: nil,
                failureMessage: "cooldown_active"
            )
        }

        guard FileManager.default.isExecutableFile(atPath: runtimePath) else {
            cooldownUntil = Date().addingTimeInterval(120)
            await ActivityLogService.shared.append(
                category: "llm",
                message: "Runtime missing at \(runtimePath)."
            )
            return LLMEvaluationResult(
                runtimePath: runtimePath,
                modelIdentifier: modelIdentifier,
                attempts: attempts,
                finalDecision: nil,
                failureMessage: "runtime_missing"
            )
        }

        do {
            let primaryOutput = try await runInference(
                runtimePath: runtimePath,
                snapshotPath: snapshot.screenshotPath,
                systemPrompt: primaryAttempt.templateContents,
                userPrompt: primaryAttempt.renderedPrompt
            )
            var resolvedPrimaryAttempt = attempts[0]
            resolvedPrimaryAttempt.runtimeOutput = primaryOutput
            resolvedPrimaryAttempt.parsedDecision = Self.extractDecision(
                from: primaryOutput.stdout + "\n" + primaryOutput.stderr
            )
            attempts[0] = resolvedPrimaryAttempt

            if let parsedDecision = resolvedPrimaryAttempt.parsedDecision {
                cooldownUntil = nil
                return LLMEvaluationResult(
                    runtimePath: runtimePath,
                    modelIdentifier: modelIdentifier,
                    attempts: attempts,
                    finalDecision: parsedDecision,
                    failureMessage: nil
                )
            }

            let fallbackAttempt = makeFallbackAttempt(snapshot: snapshot, goals: goals)
            attempts.append(fallbackAttempt)
            let fallbackOutput = try await runInference(
                runtimePath: runtimePath,
                snapshotPath: snapshot.screenshotPath,
                systemPrompt: fallbackAttempt.templateContents,
                userPrompt: fallbackAttempt.renderedPrompt
            )
            var resolvedFallbackAttempt = fallbackAttempt
            resolvedFallbackAttempt.runtimeOutput = fallbackOutput
            resolvedFallbackAttempt.parsedDecision = Self.extractDecision(
                from: fallbackOutput.stdout + "\n" + fallbackOutput.stderr
            )
            attempts[1] = resolvedFallbackAttempt

            let finalDecision = resolvedFallbackAttempt.parsedDecision
            if finalDecision == nil {
                cooldownUntil = Date().addingTimeInterval(120)
            } else {
                cooldownUntil = nil
            }

            return LLMEvaluationResult(
                runtimePath: runtimePath,
                modelIdentifier: modelIdentifier,
                attempts: attempts,
                finalDecision: finalDecision,
                failureMessage: finalDecision == nil ? "no_usable_decision" : nil
            )
        } catch {
            cooldownUntil = Date().addingTimeInterval(120)
            await ActivityLogService.shared.append(
                category: "llm-error",
                message: error.localizedDescription
            )
            return LLMEvaluationResult(
                runtimePath: runtimePath,
                modelIdentifier: modelIdentifier,
                attempts: attempts,
                finalDecision: nil,
                failureMessage: error.localizedDescription
            )
        }
    }

    func chat(
        userMessage: String,
        goals: String,
        recentActions: [ActionRecord],
        context: ChatContext,
        history: [ChatMessage] = [],
        memory: String = "",
        runtimeOverride: String?
    ) async -> String? {
        let runtimePath = RuntimeSetupService.normalizedRuntimePath(from: runtimeOverride)
        guard FileManager.default.isExecutableFile(atPath: runtimePath) else {
            await ActivityLogService.shared.append(
                category: "chat-error",
                message: "Runtime missing at \(runtimePath)."
            )
            return nil
        }

        let systemPrompt = Self.buildChatSystemPrompt(memory: memory)
        let prompt = Self.makeChatPrompt(
            userMessage: userMessage,
            goals: goals,
            recentActions: recentActions,
            context: context,
            history: history,
            memory: memory
        )

        do {
            let output = try await runTextInference(
                runtimePath: runtimePath,
                systemPrompt: systemPrompt,
                userPrompt: prompt
            )
            let combined = [output.stdout, output.stderr]
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            let reply = Self.extractChatReply(from: combined) ?? Self.cleanChatOutput(combined)
            return reply.isEmpty ? nil : reply
        } catch {
            await ActivityLogService.shared.append(
                category: "chat-error",
                message: error.localizedDescription
            )
            return nil
        }
    }

    /// Extracts a memorable rule or preference from a chat exchange.
    /// Returns a concise bullet string, or nil if nothing is worth remembering.
    func extractMemoryUpdate(
        userMessage: String,
        reply: String,
        currentMemory: String,
        runtimeOverride: String?
    ) async -> String? {
        let runtimePath = RuntimeSetupService.normalizedRuntimePath(from: runtimeOverride)
        guard FileManager.default.isExecutableFile(atPath: runtimePath) else { return nil }

        let systemPrompt = """
        You are a memory extractor for a focus companion app.
        Decide if the user's message contains a persistent preference, rule, or important context
        that the companion should always remember (e.g. "don't let me use Instagram today",
        "I work best in the mornings", "I'm studying for exams this week").
        If yes, return JSON: {"memory":"concise bullet under 20 words"}
        If no, return JSON: {"memory":"none"}
        Output only JSON, no other text.
        """
        let userPrompt = """
        User message: \(userMessage.cleanedSingleLine)
        Assistant reply: \(reply.cleanedSingleLine)
        Existing memory (for dedup):
        \(currentMemory.isEmpty ? "(empty)" : currentMemory)
        """

        do {
            let output = try await runTextInference(
                runtimePath: runtimePath,
                systemPrompt: systemPrompt,
                userPrompt: userPrompt
            )
            let combined = output.stdout + "\n" + output.stderr
            for json in Self.jsonObjects(in: combined) {
                guard let data = json.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let bullet = obj["memory"] as? String,
                      !bullet.isEmpty,
                      bullet.lowercased() != "none" else { continue }
                return bullet.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        } catch { }
        return nil
    }

    /// Compresses the memory string when it grows too long.
    func compressMemory(memory: String, runtimeOverride: String?) async -> String? {
        let runtimePath = RuntimeSetupService.normalizedRuntimePath(from: runtimeOverride)
        guard FileManager.default.isExecutableFile(atPath: runtimePath) else { return nil }

        let systemPrompt = """
        You are compressing a focus companion's memory log.
        Merge duplicate entries, remove outdated ones, and keep the most relevant rules/preferences.
        Return JSON: {"memory":"compressed multi-line bullet list"}
        Output only JSON, no other text.
        """
        let userPrompt = "Memory to compress:\n\(memory)"

        do {
            let output = try await runTextInference(
                runtimePath: runtimePath,
                systemPrompt: systemPrompt,
                userPrompt: userPrompt
            )
            let combined = output.stdout + "\n" + output.stderr
            for json in Self.jsonObjects(in: combined) {
                guard let data = json.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let compressed = obj["memory"] as? String,
                      !compressed.isEmpty else { continue }
                return compressed.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        } catch { }
        return nil
    }

    private func runInference(
        runtimePath: String,
        snapshotPath: String,
        systemPrompt: String,
        userPrompt: String
    ) async throws -> RuntimeProcessOutput {
        let repoURL = URL(fileURLWithPath: runtimePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()

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
            arguments: Self.arguments(
                systemPromptURL: systemPromptURL,
                snapshotPath: snapshotPath,
                userPrompt: userPrompt,
                modelIdentifier: modelIdentifier
            ),
            currentDirectoryURL: repoURL
        )
    }

    private func runTextInference(
        runtimePath: String,
        systemPrompt: String,
        userPrompt: String
    ) async throws -> RuntimeProcessOutput {
        let repoURL = URL(fileURLWithPath: runtimePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()

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
            arguments: Self.chatArguments(
                systemPromptURL: systemPromptURL,
                userPrompt: userPrompt,
                modelIdentifier: modelIdentifier
            ),
            currentDirectoryURL: repoURL
        )
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

    private func makePrimaryAttempt(
        snapshot: AppSnapshot,
        goals: String,
        recentActions: [ActionRecord],
        heuristics: TelemetryHeuristicSnapshot,
        distraction: DistractionMetadata,
        memory: String = ""
    ) -> LLMEvaluationAttempt {
        let systemPrompt = PromptLoader.load(named: "ACPromptV1System") ?? Self.defaultSystemPrompt
        let renderedPrompt = Self.makeUserPrompt(
            snapshot: snapshot,
            goals: goals,
            recentActions: recentActions,
            heuristics: heuristics,
            distraction: distraction,
            memory: memory
        )
        let payload = Self.makeVisionPayload(
            snapshot: snapshot,
            goals: goals,
            recentActions: recentActions,
            heuristics: heuristics,
            distraction: distraction
        )
        let payloadJSON = Self.encodePayload(payload)
        let template = PromptTemplateRecord(
            id: "ACPromptV1System",
            version: primaryPromptVersion,
            sha256: Self.sha256Hex(systemPrompt)
        )

        return LLMEvaluationAttempt(
            promptMode: "vision_primary",
            promptVersion: primaryPromptVersion,
            template: template,
            templateContents: systemPrompt,
            payloadJSON: payloadJSON,
            renderedPrompt: renderedPrompt,
            runtimeOutput: nil,
            parsedDecision: nil
        )
    }

    private func makeFallbackAttempt(
        snapshot: AppSnapshot,
        goals: String
    ) -> LLMEvaluationAttempt {
        let systemPrompt = PromptLoader.load(named: "ACPromptV1Fallback") ?? Self.defaultFallbackPrompt
        let renderedPrompt = Self.makeFallbackPrompt(snapshot: snapshot, goals: goals)
        let payload = [
            "goals": goals.cleanedSingleLine,
            "app": snapshot.appName,
            "window": snapshot.windowTitle ?? "None",
            "timestamp": snapshot.timestamp.ISO8601Format(),
        ]
        let payloadJSON = Self.encodePayload(payload)
        let template = PromptTemplateRecord(
            id: "ACPromptV1Fallback",
            version: fallbackPromptVersion,
            sha256: Self.sha256Hex(systemPrompt)
        )

        return LLMEvaluationAttempt(
            promptMode: "fallback",
            promptVersion: fallbackPromptVersion,
            template: template,
            templateContents: systemPrompt,
            payloadJSON: payloadJSON,
            renderedPrompt: renderedPrompt,
            runtimeOutput: nil,
            parsedDecision: nil
        )
    }

    private static func arguments(
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

    private static func chatArguments(
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

    private static func makeVisionPayload(
        snapshot: AppSnapshot,
        goals: String,
        recentActions: [ActionRecord],
        heuristics: TelemetryHeuristicSnapshot,
        distraction: DistractionMetadata
    ) -> VisionPromptPayload {
        VisionPromptPayload(
            goals: goals.cleanedSingleLine,
            frontmostApp: snapshot.appName,
            windowTitle: snapshot.windowTitle,
            timestamp: snapshot.timestamp,
            recentSwitches: snapshot.recentSwitches.prefix(4).map(\.telemetryRecord),
            timeByApp: snapshot.perAppDurations.prefix(8).map(\.telemetryRecord),
            recentActions: recentActions.prefix(6).map(\.telemetrySummary),
            heuristics: heuristics,
            distraction: distraction.telemetryState,
            responseSchema: [
                "assessment": "focused|distracted|unclear",
                "suggested_action": "none|nudge|overlay|abstain",
                "confidence": "0.0-1.0 optional",
                "reason_tags": "array of short snake_case strings",
                "nudge": "short optional nudge under 18 words",
                "abstain_reason": "optional short explanation when unsure or declining to act",
            ]
        )
    }

    private static func makeUserPrompt(
        snapshot: AppSnapshot,
        goals: String,
        recentActions: [ActionRecord],
        heuristics: TelemetryHeuristicSnapshot,
        distraction: DistractionMetadata,
        memory: String = ""
    ) -> String {
        let payload = makeVisionPayload(
            snapshot: snapshot,
            goals: goals,
            recentActions: recentActions,
            heuristics: heuristics,
            distraction: distraction
        )

        let memorySection = memory.isEmpty ? "" : """

        User rules/memory (always honour):
        \(memory)
        """

        return """
        Task:
        Judge whether the user is focused, distracted, or unclear in this exact moment.
        The screenshot is attached.\(memorySection)

        Dynamic payload:
        \(encodePayload(payload))

        Return exactly one JSON object with this schema:
        {"assessment":"focused|distracted|unclear","suggested_action":"none|nudge|overlay|abstain","confidence":0.0,"reason_tags":["tag"],"nudge":"optional short nudge","abstain_reason":"optional short reason"}
        """
    }

    private static func makeFallbackPrompt(snapshot: AppSnapshot, goals: String) -> String {
        """
        Goals: \(goals.cleanedSingleLine)
        App: \(snapshot.appName)
        Window: \(snapshot.windowTitle ?? "None")
        Return exactly:
        {"assessment":"focused|distracted|unclear","suggested_action":"none|nudge|overlay|abstain","confidence":0.0,"reason_tags":["tag"],"nudge":"optional","abstain_reason":"optional"}
        """
    }

    private static func makeChatPrompt(
        userMessage: String,
        goals: String,
        recentActions: [ActionRecord],
        context: ChatContext,
        history: [ChatMessage] = [],
        memory: String = ""
    ) -> String {
        let historySection: String
        if history.isEmpty {
            historySection = "(no prior messages)"
        } else {
            historySection = history.map { msg in
                let label = msg.role == .user ? "User" : "AccountyCat"
                return "\(label): \(msg.text.cleanedSingleLine)"
            }.joined(separator: "\n")
        }

        let memorySection = memory.isEmpty ? "(none)" : memory

        return """
        [Context — use only if directly helpful, never be invasive]
        Frontmost app: \(context.frontmostAppName)
        Window: \(context.frontmostWindowTitle ?? "—")
        Idle: \(Int(context.idleSeconds))s
        Time: \(context.timestamp.formatted(date: .abbreviated, time: .shortened))
        Apps today: \(context.perAppDurations.prefix(5).map { "\($0.appName) \(Int($0.seconds/60))m" }.joined(separator: ", "))
        Recent AC actions: \(recentActions.prefix(3).map { "\($0.kind.rawValue): \($0.message ?? "-")" }.joined(separator: ", "))

        [User goals]
        \(goals.cleanedSingleLine)

        [Persistent memory — always honour these]
        \(memorySection)

        [Recent conversation]
        \(historySection)

        [New user message]
        \(userMessage.cleanedSingleLine)

        Respond as AccountyCat. Match the energy and tone of the user's message.
        If they're casual, be casual. If they're excited, share the excitement. If they're stressed, be warm and grounding.
        Honour any rules in memory. Only reference context/app data if the user asks or it's directly useful.
        Return exactly one JSON object: {"reply":"your response"}
        No markdown. No extra keys. No other text.
        """
    }

    private static func extractChatReply(from output: String) -> String? {
        for json in jsonObjects(in: output).reversed() {
            guard let data = json.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let reply = object["reply"] as? String else {
                continue
            }

            let cleaned = reply.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleaned.isEmpty {
                return cleaned
            }
        }

        return nil
    }

    private static func extractDecision(from output: String) -> LLMDecision? {
        let candidateObjects = jsonObjects(in: output).reversed()

        for json in candidateObjects {
            guard let data = json.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }

            let assessmentString =
                (object["assessment"] as? String) ??
                (object["verdict"] as? String)
            guard let assessmentString,
                  let assessment = ModelAssessment(rawValue: assessmentString) else {
                continue
            }

            let suggestedActionString =
                (object["suggested_action"] as? String) ??
                (object["suggestedAction"] as? String) ??
                inferredSuggestedAction(
                    assessment: assessment,
                    nudge: object["nudge"] as? String
                )

            let suggestedAction = ModelSuggestedAction(rawValue: suggestedActionString) ?? .abstain
            let confidence = object["confidence"] as? Double
            let reasonTags =
                (object["reason_tags"] as? [String]) ??
                (object["reasonTags"] as? [String]) ??
                []
            let nudge = (object["nudge"] as? String)?.cleanedSingleLine
            let abstainReason =
                (object["abstain_reason"] as? String) ??
                (object["abstainReason"] as? String)

            return LLMDecision(
                assessment: assessment,
                suggestedAction: suggestedAction,
                confidence: confidence,
                reasonTags: reasonTags,
                nudge: nudge,
                abstainReason: abstainReason?.cleanedSingleLine
            )
        }

        return nil
    }

    private static func inferredSuggestedAction(
        assessment: ModelAssessment,
        nudge: String?
    ) -> String {
        switch assessment {
        case .focused:
            return "none"
        case .unclear:
            return "abstain"
        case .distracted:
            return (nudge?.cleanedSingleLine.isEmpty == false) ? "nudge" : "abstain"
        }
    }

    private static func jsonObjects(in output: String) -> [String] {
        var results: [String] = []
        var startIndex: String.Index?
        var currentIndex = output.startIndex
        var depth = 0
        var insideString = false
        var escaping = false

        while currentIndex < output.endIndex {
            let character = output[currentIndex]

            if insideString {
                if escaping {
                    escaping = false
                } else if character == "\\" {
                    escaping = true
                } else if character == "\"" {
                    insideString = false
                }

                currentIndex = output.index(after: currentIndex)
                continue
            }

            if character == "\"" {
                insideString = true
                currentIndex = output.index(after: currentIndex)
                continue
            }

            if character == "{" {
                if depth == 0 {
                    startIndex = currentIndex
                }
                depth += 1
            } else if character == "}" {
                guard depth > 0 else {
                    currentIndex = output.index(after: currentIndex)
                    continue
                }

                depth -= 1
                if depth == 0, let objectStartIndex = startIndex {
                    let endIndex = output.index(after: currentIndex)
                    results.append(String(output[objectStartIndex..<endIndex]))
                    startIndex = nil
                }
            }

            currentIndex = output.index(after: currentIndex)
        }

        return results
    }

    private static func cleanChatOutput(_ output: String) -> String {
        let normalized = output
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        let lines = normalized
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

        let runtimeNoisePrefixes = [
            "main:", "build", "model", "modalities", "available commands:",
            "loading model", "using custom system prompt",
            "/exit", "/clear", "/repl", "/image", "/audio",
            "ggml_", "llama_", "srv", "system_info", "load_backend",
            "tensor"
        ]

        let cleanedLines = lines.filter { line in
            guard !line.isEmpty else { return false }

            let lowercasedLine = line.lowercased()
            if lowercasedLine == "exiting" ||
                lowercasedLine == "exiting." ||
                lowercasedLine == "exiting..." {
                return false
            }
            if lowercasedLine.contains("prompt eval") ||
                lowercasedLine.contains("eval time") ||
                lowercasedLine.contains("generation:") {
                return false
            }

            for prefix in runtimeNoisePrefixes where lowercasedLine.hasPrefix(prefix) {
                return false
            }
            return true
        }

        let candidateLines: [String]
        if let instructionIndex = cleanedLines.lastIndex(where: { $0.lowercased().hasPrefix("reply as accountycat") }) {
            candidateLines = Array(cleanedLines.suffix(from: cleanedLines.index(after: instructionIndex)))
        } else {
            candidateLines = cleanedLines
        }

        let joined = candidateLines
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let trimmedLeadingArtifacts = joined.drop(while: { character in
            let scalar = character.unicodeScalars.first
            let isAlphaNumeric = scalar.map { CharacterSet.alphanumerics.contains($0) } ?? false
            return !isAlphaNumeric
        })
        let normalizedLeading = String(trimmedLeadingArtifacts)

        if normalizedLeading.hasPrefix("I- ") {
            return String(normalizedLeading.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return normalizedLeading
    }

    private static func encodePayload<T: Encodable>(_ payload: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(payload),
              let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return string
    }

    private static func sha256Hex(_ input: String) -> String {
        let data = Data(input.utf8)
        return data.sha256Hex
    }

    private static let defaultSystemPrompt = """
    You are AccountyCat, the user's conservative offline accountability companion.

    Priorities:
    1. False positives are expensive. If the screenshot could plausibly be productive, return focused or unclear.
    2. Keep optional nudges warm, short, and natural.
    3. Never escalate, threaten, or overstate confidence.

    Rules:
    - Output exactly one JSON object.
    - Allowed assessment values: focused, distracted, unclear.
    - Allowed suggested_action values: none, nudge, overlay, abstain.
    - If unsure, use assessment=unclear and suggested_action=abstain.
    - nudge is optional and must stay under 18 words.
    """

    private static let defaultFallbackPrompt = """
    Conservative focus classifier.
    Return only JSON.
    """

    private static let defaultChatSystemPrompt = """
    You are AccountyCat — a warm, witty, slightly cheeky focus companion who happens to live on the user's screen.
    You have access to what apps they use and when, but you're never creepy about it.
    Your superpower is matching the user's energy: if they say "hi" you say hi back simply;
    if they write "HIIII :DDD" you're hyped too. You're a friend who *gets* them, not a productivity robot.
    You remember their rules and preferences (given in the prompt) and honour them without being preachy.
    When they slip up, you nudge gently like a best friend would — curious, caring, maybe a tiny bit teasing.
    Keep replies short unless the user is clearly in conversation mode. No bullet lists unless asked.
    Always return exactly one JSON object: {"reply":"..."}. No markdown outside the JSON value.
    """

    private static func buildChatSystemPrompt(memory: String) -> String {
        defaultChatSystemPrompt
    }
}

extension Data {
    fileprivate var sha256Hex: String {
        SHA256.hash(data: self).map { String(format: "%02x", $0) }.joined()
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

enum PromptLoader {
    nonisolated static func load(named name: String) -> String? {
        let url =
            Bundle.main.url(forResource: name, withExtension: "md", subdirectory: "Prompts") ??
            Bundle.main.url(forResource: name, withExtension: "md") ??
            Bundle.main.url(forResource: name, withExtension: "md", subdirectory: "docs")

        guard let url else {
            return nil
        }

        return try? String(contentsOf: url, encoding: .utf8)
    }
}

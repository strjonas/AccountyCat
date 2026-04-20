//
//  PromptLabRunner.swift
//  ACInspector
//

import Foundation

actor PromptLabRunner {
    private let runtime = PromptLabRuntime()

    nonisolated static var defaultRuntimePath: String {
        let preferred = TelemetryPaths.applicationSupportURL()
            .appendingPathComponent("runtime", isDirectory: true)
            .appendingPathComponent("llama.cpp", isDirectory: true)
            .appendingPathComponent("build/bin/llama-cli")
            .path

        if FileManager.default.isExecutableFile(atPath: preferred) {
            return preferred
        }

        let legacy = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("accountycat", isDirectory: true)
            .appendingPathComponent("llama.cpp", isDirectory: true)
            .appendingPathComponent("build/bin/llama-cli")
            .path

        if FileManager.default.isExecutableFile(atPath: legacy) {
            return legacy
        }

        return preferred
    }

    func runMatrix(
        scenario: PromptLabScenario,
        promptSet: PromptLabPromptSet,
        pipelines: [PromptLabPipelineProfile],
        runtimeProfiles: [PromptLabRuntimeProfile],
        runtimePath: String
    ) async -> [PromptLabRunResult] {
        var results: [PromptLabRunResult] = []
        for pipeline in pipelines {
            for runtimeProfile in runtimeProfiles {
                let result = await runSingle(
                    scenario: scenario,
                    promptSet: promptSet,
                    pipeline: pipeline,
                    runtimeProfile: runtimeProfile,
                    runtimePath: runtimePath
                )
                results.append(result)
            }
        }
        return results
    }

    private func runSingle(
        scenario: PromptLabScenario,
        promptSet: PromptLabPromptSet,
        pipeline: PromptLabPipelineProfile,
        runtimeProfile: PromptLabRuntimeProfile,
        runtimePath: String
    ) async -> PromptLabRunResult {
        let startedAt = Date()
        let normalizedRuntimePath = runtimePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? Self.defaultRuntimePath
            : runtimePath.trimmingCharacters(in: .whitespacesAndNewlines)

        guard FileManager.default.isExecutableFile(atPath: normalizedRuntimePath) else {
            return PromptLabRunResult(
                scenarioID: scenario.id,
                promptSetID: promptSet.id,
                pipelineProfileID: pipeline.id,
                runtimeProfileID: runtimeProfile.id,
                startedAt: startedAt,
                finishedAt: Date(),
                assessment: nil,
                suggestedAction: nil,
                confidence: nil,
                nudge: nil,
                appealDecision: nil,
                appealMessage: nil,
                stageResults: [],
                pass: nil,
                errorSummary: "Runtime not found at \(normalizedRuntimePath)."
            )
        }

        var stageResults: [PromptLabStageRunResult] = []

        let titlePerception: PromptLabPerceptionEnvelope?
        if pipeline.usesTitlePerception {
            titlePerception = await runTextStage(
                stage: .perceptionTitle,
                prompt: promptSet.prompt(for: .perceptionTitle),
                runtimePath: normalizedRuntimePath,
                options: runtimeProfile.options(for: .perceptionTitle),
                payload: PromptLabTitlePerceptionPayload(
                    goals: scenario.goals.cleanedSingleLine,
                    appName: scenario.appName.cleanedSingleLine,
                    bundleIdentifier: scenario.bundleIdentifier.nilIfBlank,
                    windowTitle: scenario.windowTitle.nilIfBlank,
                    timestamp: scenario.timestamp,
                    recentSwitches: scenario.recentSwitches,
                    usage: scenario.usage,
                    policySummary: policySummary(for: scenario),
                    recentActions: scenario.recentActions
                ),
                stageResults: &stageResults,
                decoder: PromptLabPerceptionEnvelope.self
            )
        } else {
            titlePerception = nil
        }

        let visionPerception: PromptLabPerceptionEnvelope?
        if pipeline.usesVisionPerception {
            if let snapshotPath = scenario.screenshotPath.nilIfBlank,
               FileManager.default.fileExists(atPath: snapshotPath) {
                visionPerception = await runVisionStage(
                    stage: .perceptionVision,
                    prompt: promptSet.prompt(for: .perceptionVision),
                    runtimePath: normalizedRuntimePath,
                    snapshotPath: snapshotPath,
                    options: runtimeProfile.options(for: .perceptionVision),
                    payload: PromptLabVisionPerceptionPayload(
                        goals: scenario.goals.cleanedSingleLine,
                        appName: scenario.appName.cleanedSingleLine,
                        windowTitle: scenario.windowTitle.nilIfBlank,
                        timestamp: scenario.timestamp,
                        policySummary: policySummary(for: scenario)
                    ),
                    stageResults: &stageResults,
                    decoder: PromptLabPerceptionEnvelope.self
                )
            } else {
                stageResults.append(
                    PromptLabStageRunResult(
                        stage: .perceptionVision,
                        payloadJSON: "{}",
                        renderedPrompt: promptSet.prompt(for: .perceptionVision).userTemplate,
                        rawOutput: "",
                        parsedSummary: "Skipped: missing screenshot.",
                        latencyMS: 0,
                        errorMessage: "missing_screenshot"
                    )
                )
                visionPerception = nil
            }
        } else {
            visionPerception = nil
        }

        let decision = await runTextStage(
            stage: .decision,
            prompt: promptSet.prompt(for: .decision),
            runtimePath: normalizedRuntimePath,
            options: runtimeProfile.options(for: .decision),
            payload: PromptLabDecisionPayload(
                goals: scenario.goals.cleanedSingleLine,
                freeFormMemory: scenario.freeFormMemorySummary.cleanedSingleLine,
                policySummary: policySummary(for: scenario),
                policyMemoryJSON: scenario.policyMemoryJSON.nilIfBlank,
                timestamp: scenario.timestamp,
                appName: scenario.appName.cleanedSingleLine,
                bundleIdentifier: scenario.bundleIdentifier.nilIfBlank,
                windowTitle: scenario.windowTitle.nilIfBlank,
                recentSwitches: scenario.recentSwitches,
                usage: scenario.usage,
                recentActions: scenario.recentActions,
                heuristics: scenario.heuristics.telemetryRecord,
                distraction: scenario.distraction.telemetryRecord,
                titlePerception: titlePerception,
                visionPerception: visionPerception
            ),
            stageResults: &stageResults,
            decoder: PromptLabDecisionEnvelope.self
        )

        var finalNudge = decision?.nudge?.cleanedSingleLine
        if pipeline.splitCopyGeneration,
           decision?.suggestedAction == .nudge {
            let nudgeEnvelope = await runTextStage(
                stage: .nudgeCopy,
                prompt: promptSet.prompt(for: .nudgeCopy),
                runtimePath: normalizedRuntimePath,
                options: runtimeProfile.options(for: .nudgeCopy),
                payload: PromptLabNudgePayload(
                    goals: scenario.goals.cleanedSingleLine,
                    policySummary: policySummary(for: scenario),
                    policyMemoryJSON: scenario.policyMemoryJSON.nilIfBlank,
                    appName: scenario.appName.cleanedSingleLine,
                    windowTitle: scenario.windowTitle.nilIfBlank,
                    titlePerception: titlePerception?.activitySummary,
                    visionPerception: visionPerception?.activitySummary,
                    recentNudges: scenario.recentNudgeMessages
                ),
                stageResults: &stageResults,
                decoder: PromptLabNudgeEnvelope.self
            )
            if let nudge = nudgeEnvelope?.nudge?.cleanedSingleLine, !nudge.isEmpty {
                finalNudge = nudge
            }
        }

        let appealEnvelope: PromptLabAppealEnvelope?
        if !scenario.appealText.cleanedSingleLine.isEmpty {
            appealEnvelope = await runTextStage(
                stage: .appealReview,
                prompt: promptSet.prompt(for: .appealReview),
                runtimePath: normalizedRuntimePath,
                options: runtimeProfile.options(for: .appealReview),
                payload: PromptLabAppealPayload(
                    appealText: scenario.appealText.cleanedSingleLine,
                    goals: scenario.goals.cleanedSingleLine,
                    freeFormMemory: scenario.freeFormMemorySummary.cleanedSingleLine,
                    policySummary: policySummary(for: scenario),
                    policyMemoryJSON: scenario.policyMemoryJSON.nilIfBlank,
                    snapshotAppName: scenario.appName.cleanedSingleLine,
                    snapshotWindowTitle: scenario.windowTitle.nilIfBlank,
                    assessment: decision?.assessment,
                    suggestedAction: decision?.suggestedAction
                ),
                stageResults: &stageResults,
                decoder: PromptLabAppealEnvelope.self
            )
        } else {
            appealEnvelope = nil
        }

        let pass = scenario.matches(assessment: decision?.assessment, action: decision?.suggestedAction)

        return PromptLabRunResult(
            scenarioID: scenario.id,
            promptSetID: promptSet.id,
            pipelineProfileID: pipeline.id,
            runtimeProfileID: runtimeProfile.id,
            startedAt: startedAt,
            finishedAt: Date(),
            assessment: decision?.assessment,
            suggestedAction: decision?.suggestedAction,
            confidence: decision?.confidence,
            nudge: finalNudge,
            appealDecision: appealEnvelope?.decision.rawValue,
            appealMessage: appealEnvelope?.message.cleanedSingleLine,
            stageResults: stageResults,
            pass: pass,
            errorSummary: decision == nil ? "Decision stage did not yield a parseable JSON object." : nil
        )
    }

    private func policySummary(for scenario: PromptLabScenario) -> String {
        if !scenario.policyMemorySummary.cleanedSingleLine.isEmpty {
            return scenario.policyMemorySummary.cleanedSingleLine
        }
        if !scenario.policyMemoryJSON.cleanedSingleLine.isEmpty {
            return scenario.policyMemoryJSON.cleanedSingleLine
        }
        return "No structured policy rules."
    }

    private func runTextStage<T: Decodable, P: Encodable>(
        stage: PromptLabStage,
        prompt: PromptLabStagePrompt,
        runtimePath: String,
        options: PromptLabRuntimeOptions,
        payload: P,
        stageResults: inout [PromptLabStageRunResult],
        decoder: T.Type
    ) async -> T? {
        let payloadJSON = Self.encodePayload(payload)
        let renderedPrompt = renderPrompt(prompt, payloadJSON: payloadJSON)
        let startedAt = Date()

        do {
            let output = try await runtime.runTextInference(
                runtimePath: runtimePath,
                systemPrompt: prompt.systemPrompt,
                userPrompt: renderedPrompt,
                options: options
            )
            let rawOutput = Self.combinedOutput(output)
            let decoded = Self.decode(decoder, from: rawOutput)
            stageResults.append(
                PromptLabStageRunResult(
                    stage: stage,
                    payloadJSON: payloadJSON,
                    renderedPrompt: Self.formatRenderedPrompt(system: prompt.systemPrompt, user: renderedPrompt),
                    rawOutput: rawOutput,
                    parsedSummary: Self.summary(for: stage, decoded: decoded, rawOutput: rawOutput),
                    latencyMS: Date().timeIntervalSince(startedAt) * 1000,
                    errorMessage: decoded == nil ? "unparseable_json" : nil
                )
            )
            return decoded
        } catch {
            stageResults.append(
                PromptLabStageRunResult(
                    stage: stage,
                    payloadJSON: payloadJSON,
                    renderedPrompt: Self.formatRenderedPrompt(system: prompt.systemPrompt, user: renderedPrompt),
                    rawOutput: "",
                    parsedSummary: "Error: \(error.localizedDescription)",
                    latencyMS: Date().timeIntervalSince(startedAt) * 1000,
                    errorMessage: error.localizedDescription
                )
            )
            return nil
        }
    }

    private func runVisionStage<T: Decodable, P: Encodable>(
        stage: PromptLabStage,
        prompt: PromptLabStagePrompt,
        runtimePath: String,
        snapshotPath: String,
        options: PromptLabRuntimeOptions,
        payload: P,
        stageResults: inout [PromptLabStageRunResult],
        decoder: T.Type
    ) async -> T? {
        let payloadJSON = Self.encodePayload(payload)
        let renderedPrompt = renderPrompt(prompt, payloadJSON: payloadJSON)
        let startedAt = Date()

        do {
            let output = try await runtime.runVisionInference(
                runtimePath: runtimePath,
                snapshotPath: snapshotPath,
                systemPrompt: prompt.systemPrompt,
                userPrompt: renderedPrompt,
                options: options
            )
            let rawOutput = Self.combinedOutput(output)
            let decoded = Self.decode(decoder, from: rawOutput)
            stageResults.append(
                PromptLabStageRunResult(
                    stage: stage,
                    payloadJSON: payloadJSON,
                    renderedPrompt: Self.formatRenderedPrompt(system: prompt.systemPrompt, user: renderedPrompt),
                    rawOutput: rawOutput,
                    parsedSummary: Self.summary(for: stage, decoded: decoded, rawOutput: rawOutput),
                    latencyMS: Date().timeIntervalSince(startedAt) * 1000,
                    errorMessage: decoded == nil ? "unparseable_json" : nil
                )
            )
            return decoded
        } catch {
            stageResults.append(
                PromptLabStageRunResult(
                    stage: stage,
                    payloadJSON: payloadJSON,
                    renderedPrompt: Self.formatRenderedPrompt(system: prompt.systemPrompt, user: renderedPrompt),
                    rawOutput: "",
                    parsedSummary: "Error: \(error.localizedDescription)",
                    latencyMS: Date().timeIntervalSince(startedAt) * 1000,
                    errorMessage: error.localizedDescription
                )
            )
            return nil
        }
    }

    private func renderPrompt(_ prompt: PromptLabStagePrompt, payloadJSON: String) -> String {
        prompt.userTemplate.replacingOccurrences(of: "{{PAYLOAD_JSON}}", with: payloadJSON)
    }

    private static func combinedOutput(_ output: PromptLabRuntimeOutput) -> String {
        [output.stdout, output.stderr]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    private static func formatRenderedPrompt(system: String, user: String) -> String {
        """
        SYSTEM
        \(system)

        USER
        \(user)
        """
    }

    private static func encodePayload<P: Encodable>(_ payload: P) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(payload),
              let json = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return json
    }

    private static func decode<T: Decodable>(_ type: T.Type, from output: String) -> T? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for object in jsonObjects(in: output).reversed() {
            guard let data = object.data(using: .utf8),
                  let decoded = try? decoder.decode(type, from: data) else {
                continue
            }
            return decoded
        }
        return nil
    }

    private static func jsonObjects(in text: String) -> [String] {
        var results: [String] = []
        var startIndex: String.Index?
        var depth = 0
        var inString = false
        var escaping = false

        for index in text.indices {
            let character = text[index]

            if inString {
                if escaping {
                    escaping = false
                } else if character == "\\" {
                    escaping = true
                } else if character == "\"" {
                    inString = false
                }
                continue
            }

            if character == "\"" {
                inString = true
                continue
            }

            if character == "{" {
                if depth == 0 {
                    startIndex = index
                }
                depth += 1
            } else if character == "}" {
                guard depth > 0 else { continue }
                depth -= 1
                if depth == 0, let start = startIndex {
                    results.append(String(text[start...index]))
                    startIndex = nil
                }
            }
        }

        return results
    }

    private static func summary<T>(for stage: PromptLabStage, decoded: T?, rawOutput: String) -> String {
        switch decoded {
        case let envelope as PromptLabPerceptionEnvelope:
            let guess = envelope.focusGuess?.rawValue ?? "unknown"
            return "\(guess) • \(envelope.activitySummary.cleanedSingleLine)"
        case let envelope as PromptLabDecisionEnvelope:
            let action = envelope.suggestedAction.rawValue
            let reason = envelope.reasonTags.joined(separator: ",")
            let nudge = envelope.nudge?.cleanedSingleLine ?? "no_nudge"
            return "\(envelope.assessment.rawValue) • \(action) • \(reason) • \(nudge)"
        case let envelope as PromptLabNudgeEnvelope:
            return envelope.nudge?.cleanedSingleLine ?? "No nudge."
        case let envelope as PromptLabAppealEnvelope:
            return "\(envelope.decision.rawValue) • \(envelope.message.cleanedSingleLine)"
        default:
            return rawOutput.cleanedSingleLine.prefix(220).description
        }
    }
}

private actor PromptLabRuntime {
    func runTextInference(
        runtimePath: String,
        systemPrompt: String,
        userPrompt: String,
        options: PromptLabRuntimeOptions
    ) async throws -> PromptLabRuntimeOutput {
        let repoURL = repositoryURL(forRuntimePath: runtimePath)
        let systemPromptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ac-inspector-system-\(UUID().uuidString).txt")
        try Data(systemPrompt.utf8).write(to: systemPromptURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: systemPromptURL) }

        return try await runProcess(
            executablePath: runtimePath,
            arguments: textArguments(
                systemPromptURL: systemPromptURL,
                userPrompt: userPrompt,
                options: options
            ),
            currentDirectoryURL: repoURL,
            timeoutSeconds: options.timeoutSeconds
        )
    }

    func runVisionInference(
        runtimePath: String,
        snapshotPath: String,
        systemPrompt: String,
        userPrompt: String,
        options: PromptLabRuntimeOptions
    ) async throws -> PromptLabRuntimeOutput {
        let repoURL = repositoryURL(forRuntimePath: runtimePath)
        let systemPromptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ac-inspector-vision-\(UUID().uuidString).txt")
        try Data(systemPrompt.utf8).write(to: systemPromptURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: systemPromptURL) }

        return try await runProcess(
            executablePath: runtimePath,
            arguments: visionArguments(
                systemPromptURL: systemPromptURL,
                snapshotPath: snapshotPath,
                userPrompt: userPrompt,
                options: options
            ),
            currentDirectoryURL: repoURL,
            timeoutSeconds: options.timeoutSeconds
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
        currentDirectoryURL: URL,
        timeoutSeconds: UInt64
    ) async throws -> PromptLabRuntimeOutput {
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
            return PromptLabRuntimeOutput(
                stdout: String(decoding: stdoutData, as: UTF8.self),
                stderr: String(decoding: stderrData, as: UTF8.self)
            )
        }

        let status = try await withTimeout(seconds: timeoutSeconds) {
            process.waitUntilExit()
            return process.terminationStatus
        }

        let output = await outputTask.value
        if status != 0 {
            let combined = [output.stdout, output.stderr]
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            throw PromptLabRuntimeError.commandFailed(status, combined)
        }

        return output
    }

    private func withTimeout<T>(
        seconds: UInt64,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: seconds * NSEC_PER_SEC)
                throw PromptLabRuntimeError.timeout
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    private func visionArguments(
        systemPromptURL: URL,
        snapshotPath: String,
        userPrompt: String,
        options: PromptLabRuntimeOptions
    ) -> [String] {
        [
            "-hf", options.modelIdentifier,
            "-sysf", systemPromptURL.path,
            "--image", snapshotPath,
            "-p", userPrompt,
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
            "--no-display-prompt",
        ]
    }

    private func textArguments(
        systemPromptURL: URL,
        userPrompt: String,
        options: PromptLabRuntimeOptions
    ) -> [String] {
        [
            "-hf", options.modelIdentifier,
            "-sysf", systemPromptURL.path,
            "-p", userPrompt,
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
            "--no-display-prompt",
        ]
    }
}

private struct PromptLabRuntimeOutput: Sendable {
    var stdout: String
    var stderr: String
}

private enum PromptLabRuntimeError: LocalizedError {
    case timeout
    case commandFailed(Int32, String)

    var errorDescription: String? {
        switch self {
        case .timeout:
            return "The local model timed out."
        case let .commandFailed(status, output):
            let preview = output.cleanedSingleLine.prefix(240)
            return "Runtime failed with status \(status): \(preview)"
        }
    }
}

nonisolated private struct PromptLabTitlePerceptionPayload: Encodable {
    var goals: String
    var appName: String
    var bundleIdentifier: String?
    var windowTitle: String?
    var timestamp: Date
    var recentSwitches: [PromptLabSwitchRecord]
    var usage: [PromptLabUsageRecord]
    var policySummary: String
    var recentActions: [PromptLabActionRecord]
}

nonisolated private struct PromptLabVisionPerceptionPayload: Encodable {
    var goals: String
    var appName: String
    var windowTitle: String?
    var timestamp: Date
    var policySummary: String
}

nonisolated private struct PromptLabDecisionPayload: Encodable {
    var goals: String
    var freeFormMemory: String
    var policySummary: String
    var policyMemoryJSON: String?
    var timestamp: Date
    var appName: String
    var bundleIdentifier: String?
    var windowTitle: String?
    var recentSwitches: [PromptLabSwitchRecord]
    var usage: [PromptLabUsageRecord]
    var recentActions: [PromptLabActionRecord]
    var heuristics: TelemetryHeuristicSnapshot
    var distraction: TelemetryDistractionState
    var titlePerception: PromptLabPerceptionEnvelope?
    var visionPerception: PromptLabPerceptionEnvelope?
}

nonisolated private struct PromptLabNudgePayload: Encodable {
    var goals: String
    var policySummary: String
    var policyMemoryJSON: String?
    var appName: String
    var windowTitle: String?
    var titlePerception: String?
    var visionPerception: String?
    var recentNudges: [String]
}

nonisolated private struct PromptLabAppealPayload: Encodable {
    var appealText: String
    var goals: String
    var freeFormMemory: String
    var policySummary: String
    var policyMemoryJSON: String?
    var snapshotAppName: String
    var snapshotWindowTitle: String?
    var assessment: ModelAssessment?
    var suggestedAction: ModelSuggestedAction?
}

nonisolated private struct PromptLabPerceptionEnvelope: Codable, Sendable {
    var activitySummary: String
    var focusGuess: ModelAssessment?
    var reasonTags: [String]
    var notes: [String]

    enum CodingKeys: String, CodingKey {
        case activitySummary = "activity_summary"
        case sceneSummary = "scene_summary"
        case focusGuess = "focus_guess"
        case reasonTags = "reason_tags"
        case notes
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        activitySummary = try container.decodeIfPresent(String.self, forKey: .activitySummary)
            ?? container.decodeIfPresent(String.self, forKey: .sceneSummary)
            ?? ""
        focusGuess = try container.decodeIfPresent(ModelAssessment.self, forKey: .focusGuess)
        reasonTags = try container.decodeIfPresent([String].self, forKey: .reasonTags) ?? []
        notes = try container.decodeIfPresent([String].self, forKey: .notes) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(activitySummary, forKey: .activitySummary)
        try container.encodeIfPresent(focusGuess, forKey: .focusGuess)
        try container.encode(reasonTags, forKey: .reasonTags)
        try container.encode(notes, forKey: .notes)
    }
}

nonisolated private struct PromptLabDecisionEnvelope: Codable, Sendable {
    var assessment: ModelAssessment
    var suggestedAction: ModelSuggestedAction
    var confidence: Double?
    var reasonTags: [String]
    var nudge: String?

    enum CodingKeys: String, CodingKey {
        case assessment
        case suggestedAction = "suggested_action"
        case confidence
        case reasonTags = "reason_tags"
        case nudge
    }
}

nonisolated private struct PromptLabNudgeEnvelope: Codable, Sendable {
    var nudge: String?
}

nonisolated private struct PromptLabAppealEnvelope: Codable, Sendable {
    var decision: PromptLabAppealDecision
    var message: String
}

nonisolated private enum PromptLabAppealDecision: String, Codable, Sendable {
    case allow
    case deny
    case deferDecision = "defer"
}

private extension String {
    nonisolated var nilIfBlank: String? {
        let cleaned = cleanedSingleLine
        return cleaned.isEmpty ? nil : cleaned
    }
}

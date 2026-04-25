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
        let compactAppName = scenario.appName.truncatedForPrompt(
            maxLength: MonitoringPromptContextBudget.appNameCharacters
        )
        let compactWindowTitle = scenario.windowTitle.nilIfBlank?.truncatedForPrompt(
            maxLength: MonitoringPromptContextBudget.windowTitleCharacters
        )
        let compactPolicySummary = policySummary(for: scenario)
        let compactSwitches = compactRecentSwitches(
            scenario.recentSwitches,
            limit: MonitoringPromptContextBudget.decisionSwitchCount
        )
        let compactUsage = compactUsage(
            scenario.usage,
            limit: MonitoringPromptContextBudget.decisionUsageCount
        )
        let compactInterventions = compactInterventionSummary(scenario.recentActions)

        let titlePerception: MonitoringPerceptionEnvelope?
        if pipeline.usesTitlePerception {
            titlePerception = await runTextStage(
                stage: .perceptionTitle,
                prompt: promptSet.prompt(for: .perceptionTitle),
                runtimePath: normalizedRuntimePath,
                options: runtimeProfile.options(for: .perceptionTitle),
                payload: MonitoringTitlePerceptionPromptPayload(
                    appName: compactAppName,
                    bundleIdentifier: scenario.bundleIdentifier.nilIfBlank,
                    windowTitle: compactWindowTitle,
                    recentSwitches: Array(compactSwitches.prefix(MonitoringPromptContextBudget.titlePerceptionSwitchCount)),
                    usage: Array(compactUsage.prefix(MonitoringPromptContextBudget.titlePerceptionUsageCount))
                ),
                stageResults: &stageResults,
                decoder: MonitoringPerceptionEnvelope.self
            )
        } else {
            titlePerception = nil
        }

        let visionPerception: MonitoringPerceptionEnvelope?
        if pipeline.usesVisionPerception {
            if let snapshotPath = scenario.screenshotPath.nilIfBlank,
               FileManager.default.fileExists(atPath: snapshotPath) {
                visionPerception = await runVisionStage(
                    stage: .perceptionVision,
                    prompt: promptSet.prompt(for: .perceptionVision),
                    runtimePath: normalizedRuntimePath,
                    snapshotPath: snapshotPath,
                    options: runtimeProfile.options(for: .perceptionVision),
                    payload: MonitoringVisionPerceptionPromptPayload(
                        appName: compactAppName,
                        windowTitle: compactWindowTitle
                    ),
                    stageResults: &stageResults,
                    decoder: MonitoringPerceptionEnvelope.self
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

        var decision = await runTextStage(
            stage: .decision,
            prompt: promptSet.prompt(for: .decision),
            runtimePath: normalizedRuntimePath,
            options: runtimeProfile.options(for: .decision),
            payload: MonitoringDecisionPromptPayload(
                now: scenario.timestamp,
                goals: scenario.goals.cleanedSingleLine.truncatedForPrompt(
                    maxLength: MonitoringPromptContextBudget.goalCharacters
                ),
                freeFormMemory: scenario.freeFormMemorySummary.truncatedMultilineForPrompt(
                    maxLength: MonitoringPromptContextBudget.freeFormMemoryCharacters,
                    maxLines: MonitoringPromptContextBudget.freeFormMemoryLines
                ),
                recentUserMessages: Self.compactRecentUserMessages(scenario.recentUserMessages),
                policySummary: compactPolicySummary,
                appName: compactAppName,
                bundleIdentifier: scenario.bundleIdentifier.nilIfBlank,
                windowTitle: compactWindowTitle,
                recentSwitches: compactSwitches,
                usage: compactUsage,
                recentInterventions: compactInterventions,
                distraction: MonitoringPromptDistractionSummary(state: scenario.distraction.telemetryRecord),
                titlePerception: titlePerception,
                visionPerception: visionPerception
            ),
            stageResults: &stageResults,
            decoder: MonitoringDecisionEnvelope.self
        )
        if decision == nil,
           let rawOutput = stageResults.last?.rawOutput,
           let salvagedDecision = Self.salvageDecisionEnvelope(from: rawOutput) {
            decision = salvagedDecision
            if let lastIndex = stageResults.indices.last {
                stageResults[lastIndex].parsedSummary = Self.summary(
                    for: .decision,
                    decoded: salvagedDecision,
                    rawOutput: rawOutput
                ) + " • salvaged_partial_json"
                stageResults[lastIndex].errorMessage = nil
            }
        }

        var finalNudge = decision?.nudge?.cleanedSingleLine
        if pipeline.splitCopyGeneration,
           decision?.suggestedAction == .nudge {
            let nudgeEnvelope = await runTextStage(
                stage: .nudgeCopy,
                prompt: promptSet.prompt(for: .nudgeCopy),
                runtimePath: normalizedRuntimePath,
                options: runtimeProfile.options(for: .nudgeCopy),
                payload: MonitoringNudgePromptPayload(
                    goals: scenario.goals.cleanedSingleLine.truncatedForPrompt(
                        maxLength: MonitoringPromptContextBudget.goalCharacters
                    ),
                    freeFormMemory: scenario.freeFormMemorySummary.truncatedMultilineForPrompt(
                        maxLength: MonitoringPromptContextBudget.freeFormMemoryCharacters,
                        maxLines: MonitoringPromptContextBudget.freeFormMemoryLines
                    ),
                    characterPersonalityPrefix: "",
                    recentUserMessages: Self.compactRecentUserMessages(scenario.recentUserMessages),
                    policySummary: compactPolicySummary,
                    appName: compactAppName,
                    windowTitle: compactWindowTitle,
                    titlePerception: titlePerception?.activitySummary,
                    visionPerception: visionPerception?.activitySummary,
                    recentNudges: Array(
                        scenario.recentNudgeMessages.prefix(MonitoringPromptContextBudget.recentNudgeCount)
                    )
                ),
                stageResults: &stageResults,
                decoder: MonitoringNudgeEnvelope.self
            )
            if let nudge = nudgeEnvelope?.nudge?.cleanedSingleLine, !nudge.isEmpty {
                finalNudge = nudge
            }
        }

        let appealEnvelope: MonitoringAppealEnvelope?
        if !scenario.appealText.cleanedSingleLine.isEmpty {
            appealEnvelope = await runTextStage(
                stage: .appealReview,
                prompt: promptSet.prompt(for: .appealReview),
                runtimePath: normalizedRuntimePath,
                options: runtimeProfile.options(for: .appealReview),
                payload: MonitoringAppealPromptPayload(
                    appealText: scenario.appealText.cleanedSingleLine,
                    goals: scenario.goals.cleanedSingleLine.truncatedForPrompt(
                        maxLength: MonitoringPromptContextBudget.goalCharacters
                    ),
                    freeFormMemory: scenario.freeFormMemorySummary.truncatedMultilineForPrompt(
                        maxLength: MonitoringPromptContextBudget.freeFormMemoryCharacters,
                        maxLines: MonitoringPromptContextBudget.freeFormMemoryLines
                    ),
                    policySummary: compactPolicySummary,
                    snapshotAppName: compactAppName,
                    snapshotWindowTitle: compactWindowTitle,
                    assessment: decision?.assessment,
                    suggestedAction: decision?.suggestedAction
                ),
                stageResults: &stageResults,
                decoder: MonitoringAppealEnvelope.self
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
            return scenario.policyMemorySummary.truncatedMultilineForPrompt(
                maxLength: MonitoringPromptContextBudget.policySummaryCharacters,
                maxLines: MonitoringPromptContextBudget.policySummaryLines
            )
        }
        if !scenario.policyMemoryJSON.cleanedSingleLine.isEmpty {
            return scenario.policyMemoryJSON.cleanedSingleLine
                .truncatedForPrompt(maxLength: MonitoringPromptContextBudget.policySummaryCharacters)
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
        let payloadJSONPretty = Self.encodePayload(payload, prettyPrinted: true)
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
                    payloadJSON: payloadJSONPretty,
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
                    payloadJSON: payloadJSONPretty,
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
        let payloadJSONPretty = Self.encodePayload(payload, prettyPrinted: true)
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
                    payloadJSON: payloadJSONPretty,
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
                    payloadJSON: payloadJSONPretty,
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

    private static func encodePayload<P: Encodable>(
        _ payload: P,
        prettyPrinted: Bool = false
    ) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = prettyPrinted ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(payload),
              let json = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return json
    }

    private static func decode<T: Decodable>(_ type: T.Type, from output: String) -> T? {
        StructuredOutputJSON.decode(type, from: output)
    }

    private static func salvageDecisionEnvelope(from output: String) -> MonitoringDecisionEnvelope? {
        for object in jsonObjects(in: output).reversed() {
            guard let data = object.data(using: .utf8),
                  let dictionary = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }

            let assessmentRaw = (dictionary["assessment"] as? String) ?? (dictionary["verdict"] as? String)
            guard let assessmentRaw,
                  let assessment = ModelAssessment(rawValue: assessmentRaw) else {
                continue
            }

            let suggestedActionRaw =
                (dictionary["suggested_action"] as? String) ??
                (dictionary["suggestedAction"] as? String) ??
                inferredSuggestedAction(
                    assessment: assessment,
                    nudge: dictionary["nudge"] as? String
                )

            let suggestedAction = ModelSuggestedAction(rawValue: suggestedActionRaw) ?? .abstain
            let confidence = dictionary["confidence"] as? Double
            let reasonTags =
                (dictionary["reason_tags"] as? [String]) ??
                (dictionary["reasonTags"] as? [String]) ??
                []
            let nudge = (dictionary["nudge"] as? String)?.cleanedSingleLine
            let abstainReason =
                (dictionary["abstain_reason"] as? String) ??
                (dictionary["abstainReason"] as? String)

            return MonitoringDecisionEnvelope(
                assessment: assessment,
                suggestedAction: suggestedAction,
                confidence: confidence,
                reasonTags: reasonTags,
                nudge: nudge,
                abstainReason: abstainReason?.cleanedSingleLine,
                overlayHeadline: nil,
                overlayBody: nil,
                overlayPrompt: nil,
                submitButtonTitle: nil,
                secondaryButtonTitle: nil
            )
        }

        return nil
    }

    private static func inferredSuggestedAction(
        assessment: ModelAssessment,
        nudge: String?
    ) -> String {
        if let nudge, !nudge.cleanedSingleLine.isEmpty {
            return ModelSuggestedAction.nudge.rawValue
        }
        switch assessment {
        case .focused:
            return ModelSuggestedAction.none.rawValue
        case .distracted:
            return ModelSuggestedAction.abstain.rawValue
        case .unclear:
            return ModelSuggestedAction.abstain.rawValue
        }
    }

    private static func jsonObjects(in text: String) -> [String] {
        StructuredOutputJSON.jsonObjects(in: text)
    }

    private static func summary<T>(for stage: PromptLabStage, decoded: T?, rawOutput: String) -> String {
        switch decoded {
        case let envelope as MonitoringPerceptionEnvelope:
            let guess = envelope.focusGuess?.rawValue ?? "unknown"
            return "\(guess) • \(envelope.activitySummary.cleanedSingleLine)"
        case let envelope as MonitoringDecisionEnvelope:
            let action = envelope.suggestedAction.rawValue
            let reason = envelope.reasonTags.joined(separator: ",")
            let nudge = envelope.nudge?.cleanedSingleLine ?? "no_nudge"
            return "\(envelope.assessment.rawValue) • \(action) • \(reason) • \(nudge)"
        case let envelope as MonitoringNudgeEnvelope:
            return envelope.nudge?.cleanedSingleLine ?? "No nudge."
        case let envelope as MonitoringAppealEnvelope:
            return "\(envelope.decision.rawValue) • \(envelope.message.cleanedSingleLine)"
        default:
            return rawOutput.cleanedSingleLine.prefix(220).description
        }
    }

    private static func compactRecentUserMessages(_ messages: [String]) -> [String] {
        messages
            .map { $0.cleanedSingleLine }
            .filter { !$0.isEmpty }
            .prefix(MonitoringPromptContextBudget.recentUserChatCount)
            .map { $0.truncatedForPrompt(maxLength: MonitoringPromptContextBudget.recentUserChatCharacters) }
    }

    private func compactRecentSwitches(
        _ records: [PromptLabSwitchRecord],
        limit: Int
    ) -> [MonitoringPromptSwitchRecord] {
        records.prefix(limit).map {
            MonitoringPromptSwitchRecord(
                fromAppName: $0.fromAppName.truncatedForPrompt(maxLength: 60),
                toAppName: $0.toAppName.truncatedForPrompt(maxLength: 60),
                toWindowTitle: $0.toWindowTitle.truncatedForPrompt(maxLength: 140),
                timestamp: $0.timestamp
            )
        }
    }

    private func compactUsage(
        _ records: [PromptLabUsageRecord],
        limit: Int
    ) -> [MonitoringPromptUsageRecord] {
        records.prefix(limit).map {
            MonitoringPromptUsageRecord(
                appName: $0.appName.truncatedForPrompt(maxLength: 60),
                seconds: $0.seconds
            )
        }
    }

    private func compactInterventionSummary(
        _ records: [PromptLabActionRecord]
    ) -> MonitoringPromptInterventionSummary {
        let recentRelevant = records.prefix(MonitoringPromptContextBudget.recentNudgeCount)
        let recentNudges = recentRelevant
            .filter { $0.kind == "nudge" }
            .map { $0.message.cleanedSingleLine }
            .filter { !$0.isEmpty }

        let lastAction = recentRelevant.first
        return MonitoringPromptInterventionSummary(
            recentNudges: recentNudges,
            lastActionKind: lastAction?.kind.truncatedForPrompt(maxLength: 24),
            lastActionMessage: lastAction?.message.truncatedForPrompt(maxLength: 120)
        )
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

private extension String {
    nonisolated var nilIfBlank: String? {
        let cleaned = cleanedSingleLine
        return cleaned.isEmpty ? nil : cleaned
    }
}

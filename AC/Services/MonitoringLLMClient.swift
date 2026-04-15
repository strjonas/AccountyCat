//
//  MonitoringLLMClient.swift
//  AC
//
//  Created by Codex on 15.04.26.
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
    var promptProfileID: String
    var promptProfileVersion: String
    var attempts: [LLMEvaluationAttempt]
    var finalDecision: LLMDecision?
    var failureMessage: String?
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

protocol MonitoringLLMEvaluating: Sendable {
    func evaluate(
        snapshot: AppSnapshot,
        goals: String,
        recentActions: [ActionRecord],
        distraction: DistractionMetadata,
        heuristics: TelemetryHeuristicSnapshot,
        memory: String,
        promptProfileID: String,
        runtimeOverride: String?
    ) async -> LLMEvaluationResult
}

actor MonitoringLLMClient: MonitoringLLMEvaluating {
    private var cooldownUntil: Date?

    private let runtime: LocalModelRuntime
    private let modelIdentifier: String

    init(
        runtime: LocalModelRuntime,
        modelIdentifier: String = LocalModelRuntime.defaultModelIdentifier
    ) {
        self.runtime = runtime
        self.modelIdentifier = modelIdentifier
    }

    func evaluate(
        snapshot: AppSnapshot,
        goals: String,
        recentActions: [ActionRecord],
        distraction: DistractionMetadata,
        heuristics: TelemetryHeuristicSnapshot,
        memory: String = "",
        promptProfileID: String,
        runtimeOverride: String?
    ) async -> LLMEvaluationResult {
        let runtimePath = RuntimeSetupService.normalizedRuntimePath(from: runtimeOverride)
        let promptProfile = PromptCatalog.monitoringProfile(id: promptProfileID)
        let primaryAttempt = makePrimaryAttempt(
            snapshot: snapshot,
            goals: goals,
            recentActions: recentActions,
            heuristics: heuristics,
            distraction: distraction,
            memory: memory,
            promptProfile: promptProfile
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
                promptProfileID: promptProfile.descriptor.id,
                promptProfileVersion: promptProfile.descriptor.version,
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
                promptProfileID: promptProfile.descriptor.id,
                promptProfileVersion: promptProfile.descriptor.version,
                attempts: attempts,
                finalDecision: nil,
                failureMessage: "runtime_missing"
            )
        }

        do {
            let primaryOutput = try await runtime.runVisionInference(
                runtimePath: runtimePath,
                modelIdentifier: modelIdentifier,
                snapshotPath: snapshot.screenshotPath,
                systemPrompt: primaryAttempt.templateContents,
                userPrompt: primaryAttempt.renderedPrompt
            )
            var resolvedPrimaryAttempt = attempts[0]
            resolvedPrimaryAttempt.runtimeOutput = primaryOutput
            resolvedPrimaryAttempt.parsedDecision = LLMOutputParsing.extractDecision(
                from: primaryOutput.stdout + "\n" + primaryOutput.stderr
            )
            attempts[0] = resolvedPrimaryAttempt

            if let parsedDecision = resolvedPrimaryAttempt.parsedDecision {
                cooldownUntil = nil
                return LLMEvaluationResult(
                    runtimePath: runtimePath,
                    modelIdentifier: modelIdentifier,
                    promptProfileID: promptProfile.descriptor.id,
                    promptProfileVersion: promptProfile.descriptor.version,
                    attempts: attempts,
                    finalDecision: parsedDecision,
                    failureMessage: nil
                )
            }

            let fallbackAttempt = makeFallbackAttempt(
                snapshot: snapshot,
                goals: goals,
                promptProfile: promptProfile
            )
            attempts.append(fallbackAttempt)
            let fallbackOutput = try await runtime.runVisionInference(
                runtimePath: runtimePath,
                modelIdentifier: modelIdentifier,
                snapshotPath: snapshot.screenshotPath,
                systemPrompt: fallbackAttempt.templateContents,
                userPrompt: fallbackAttempt.renderedPrompt
            )
            var resolvedFallbackAttempt = fallbackAttempt
            resolvedFallbackAttempt.runtimeOutput = fallbackOutput
            resolvedFallbackAttempt.parsedDecision = LLMOutputParsing.extractDecision(
                from: fallbackOutput.stdout + "\n" + fallbackOutput.stderr
            )
            attempts[1] = resolvedFallbackAttempt

            let finalDecision = resolvedFallbackAttempt.parsedDecision
            if let finalDecision {
                cooldownUntil = nil
                return LLMEvaluationResult(
                    runtimePath: runtimePath,
                    modelIdentifier: modelIdentifier,
                    promptProfileID: promptProfile.descriptor.id,
                    promptProfileVersion: promptProfile.descriptor.version,
                    attempts: attempts,
                    finalDecision: finalDecision,
                    failureMessage: nil
                )
            } else {
                cooldownUntil = Date().addingTimeInterval(120)
            }

            return LLMEvaluationResult(
                runtimePath: runtimePath,
                modelIdentifier: modelIdentifier,
                promptProfileID: promptProfile.descriptor.id,
                promptProfileVersion: promptProfile.descriptor.version,
                attempts: attempts,
                finalDecision: nil,
                failureMessage: "no_usable_decision"
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
                promptProfileID: promptProfile.descriptor.id,
                promptProfileVersion: promptProfile.descriptor.version,
                attempts: attempts,
                finalDecision: nil,
                failureMessage: error.localizedDescription
            )
        }
    }

    private func makePrimaryAttempt(
        snapshot: AppSnapshot,
        goals: String,
        recentActions: [ActionRecord],
        heuristics: TelemetryHeuristicSnapshot,
        distraction: DistractionMetadata,
        memory: String,
        promptProfile: MonitoringPromptProfile
    ) -> LLMEvaluationAttempt {
        let prompt = PromptCatalog.loadMonitoringPrompt(
            profileID: promptProfile.descriptor.id,
            variant: .visionPrimary
        )
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
            id: prompt.asset.id,
            version: prompt.asset.version,
            sha256: Self.sha256Hex(prompt.contents)
        )

        return LLMEvaluationAttempt(
            promptMode: MonitoringPromptVariant.visionPrimary.rawValue,
            promptVersion: promptProfile.descriptor.version,
            template: template,
            templateContents: prompt.contents,
            payloadJSON: payloadJSON,
            renderedPrompt: renderedPrompt,
            runtimeOutput: nil,
            parsedDecision: nil
        )
    }

    private func makeFallbackAttempt(
        snapshot: AppSnapshot,
        goals: String,
        promptProfile: MonitoringPromptProfile
    ) -> LLMEvaluationAttempt {
        let prompt = PromptCatalog.loadMonitoringPrompt(
            profileID: promptProfile.descriptor.id,
            variant: .fallback
        )
        let renderedPrompt = Self.makeFallbackPrompt(snapshot: snapshot, goals: goals)
        let payload = [
            "goals": goals.cleanedSingleLine,
            "app": snapshot.appName,
            "window": snapshot.windowTitle ?? "None",
            "timestamp": snapshot.timestamp.ISO8601Format(),
        ]
        let payloadJSON = Self.encodePayload(payload)
        let template = PromptTemplateRecord(
            id: prompt.asset.id,
            version: prompt.asset.version,
            sha256: Self.sha256Hex(prompt.contents)
        )

        return LLMEvaluationAttempt(
            promptMode: MonitoringPromptVariant.fallback.rawValue,
            promptVersion: promptProfile.descriptor.version,
            template: template,
            templateContents: prompt.contents,
            payloadJSON: payloadJSON,
            renderedPrompt: renderedPrompt,
            runtimeOutput: nil,
            parsedDecision: nil
        )
    }

    nonisolated private static func makeVisionPayload(
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

    nonisolated private static func makeUserPrompt(
        snapshot: AppSnapshot,
        goals: String,
        recentActions: [ActionRecord],
        heuristics: TelemetryHeuristicSnapshot,
        distraction: DistractionMetadata,
        memory: String
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

    nonisolated private static func makeFallbackPrompt(snapshot: AppSnapshot, goals: String) -> String {
        """
        Goals: \(goals.cleanedSingleLine)
        App: \(snapshot.appName)
        Window: \(snapshot.windowTitle ?? "None")
        Return exactly:
        {"assessment":"focused|distracted|unclear","suggested_action":"none|nudge|overlay|abstain","confidence":0.0,"reason_tags":["tag"],"nudge":"optional","abstain_reason":"optional"}
        """
    }

    nonisolated private static func encodePayload<T: Encodable>(_ payload: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(payload),
              let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return string
    }

    nonisolated private static func sha256Hex(_ input: String) -> String {
        let data = Data(input.utf8)
        return data.sha256Hex
    }
}

extension Data {
    nonisolated fileprivate var sha256Hex: String {
        SHA256.hash(data: self).map { String(format: "%02x", $0) }.joined()
    }
}

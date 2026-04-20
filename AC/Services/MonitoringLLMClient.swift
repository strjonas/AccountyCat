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

nonisolated struct VisionInterventionHistoryItem: Codable, Hashable, Sendable {
    var kind: String
    var message: String?
    var timestamp: Date
}

nonisolated struct VisionInterventionHistorySummary: Codable, Hashable, Sendable {
    var recentInterventions: [VisionInterventionHistoryItem]
    var recentNudgeMessages: [String]
    var lastInterventionKind: String?
    var nudgeCount: Int
    var overlayCount: Int
    var backToWorkCount: Int
    var dismissOverlayCount: Int
}

nonisolated struct VisionPromptPayload: Codable, Sendable {
    var goals: String
    var memory: String?
    var frontmostApp: String
    var windowTitle: String?
    var timestamp: Date
    var recentSwitches: [TelemetryAppSwitchRecord]
    var timeByApp: [TelemetryUsageRecord]
    var interventionHistory: VisionInterventionHistorySummary
    var heuristics: TelemetryHeuristicSnapshot
    var distraction: TelemetryDistractionState
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

        guard let screenshotPath = snapshot.screenshotPath else {
            return LLMEvaluationResult(
                runtimePath: runtimePath,
                modelIdentifier: modelIdentifier,
                promptProfileID: promptProfile.descriptor.id,
                promptProfileVersion: promptProfile.descriptor.version,
                attempts: attempts,
                finalDecision: nil,
                failureMessage: "missing_screenshot"
            )
        }

        do {
            let primaryOutput = try await runtime.runVisionInference(
                runtimePath: runtimePath,
                modelIdentifier: modelIdentifier,
                snapshotPath: screenshotPath,
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
                recentActions: recentActions,
                heuristics: heuristics,
                distraction: distraction,
                memory: memory,
                promptProfile: promptProfile
            )
            attempts.append(fallbackAttempt)
            let fallbackOutput = try await runtime.runVisionInference(
                runtimePath: runtimePath,
                modelIdentifier: modelIdentifier,
                snapshotPath: screenshotPath,
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
            memory: memory,
            promptProfile: promptProfile
        )
        let payload = Self.makeVisionPayload(
            snapshot: snapshot,
            goals: goals,
            recentActions: recentActions,
            heuristics: heuristics,
            distraction: distraction,
            memory: memory
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
        recentActions: [ActionRecord],
        heuristics: TelemetryHeuristicSnapshot,
        distraction: DistractionMetadata,
        memory: String,
        promptProfile: MonitoringPromptProfile
    ) -> LLMEvaluationAttempt {
        let prompt = PromptCatalog.loadMonitoringPrompt(
            profileID: promptProfile.descriptor.id,
            variant: .fallback
        )
        let payload = Self.makeVisionPayload(
            snapshot: snapshot,
            goals: goals,
            recentActions: recentActions,
            heuristics: heuristics,
            distraction: distraction,
            memory: memory
        )
        let renderedPrompt = Self.makeUserPrompt(
            payloadJSON: Self.encodePayload(payload),
            promptProfile: promptProfile,
            variant: .fallbackUser
        )
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

    nonisolated static func makeVisionPayload(
        snapshot: AppSnapshot,
        goals: String,
        recentActions: [ActionRecord],
        heuristics: TelemetryHeuristicSnapshot,
        distraction: DistractionMetadata,
        memory: String = ""
    ) -> VisionPromptPayload {
        let relevantActions = monitoringRelevantActions(
            from: recentActions,
            at: snapshot.timestamp
        )
        let trimmedMemory = condensedMonitoringMemory(
            memory,
            goals: goals
        )
        return VisionPromptPayload(
            goals: goals.cleanedSingleLine,
            memory: trimmedMemory.isEmpty ? nil : trimmedMemory,
            frontmostApp: snapshot.appName,
            windowTitle: snapshot.windowTitle,
            timestamp: snapshot.timestamp,
            recentSwitches: snapshot.recentSwitches.prefix(2).map(\.telemetryRecord),
            timeByApp: snapshot.perAppDurations.prefix(4).map(\.telemetryRecord),
            interventionHistory: makeInterventionHistorySummary(from: relevantActions),
            heuristics: heuristics,
            distraction: distraction.telemetryState
        )
    }

    nonisolated static func monitoringRelevantActions(
        from recentActions: [ActionRecord],
        at now: Date
    ) -> [ActionRecord] {
        let relevanceWindow: TimeInterval = 90 * 60
        let filtered = recentActions.filter { action in
            guard now.timeIntervalSince(action.timestamp) <= relevanceWindow else {
                return false
            }
            if action.kind == .nudge,
               action.message?.lowercased().contains("debug nudge") == true {
                return false
            }
            return true
        }

        return Array(filtered.prefix(4))
    }

    nonisolated static func condensedMonitoringMemory(
        _ memory: String,
        goals: String
    ) -> String {
        let goalTokens = Set(
            goals.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { $0.count >= 4 }
        )

        var seen = Set<String>()
        var selected: [String] = []

        for line in memory.components(separatedBy: .newlines) {
            let trimmed = line.cleanedSingleLine
            guard !trimmed.isEmpty else { continue }

            let normalized = trimmed.lowercased()
            guard seen.insert(normalized).inserted else { continue }

            let lineTokens = Set(
                normalized
                    .components(separatedBy: CharacterSet.alphanumerics.inverted)
                    .filter { $0.count >= 4 }
            )

            if !lineTokens.isEmpty {
                let overlap = lineTokens.intersection(goalTokens).count
                if overlap >= min(4, lineTokens.count) {
                    continue
                }
            }

            selected.append(trimmed)
            if selected.count == 3 {
                break
            }
        }

        return selected.joined(separator: "\n")
    }

    nonisolated static func makeInterventionHistorySummary(
        from recentActions: [ActionRecord]
    ) -> VisionInterventionHistorySummary {
        let recentInterventions = recentActions
            .prefix(3)
            .map {
                VisionInterventionHistoryItem(
                    kind: $0.kind.rawValue,
                    message: $0.message?.cleanedSingleLine,
                    timestamp: $0.timestamp
                )
            }

        let recentNudgeMessages = recentActions
            .lazy
            .filter { $0.kind == .nudge }
            .compactMap { $0.message?.cleanedSingleLine }
            .filter { !$0.isEmpty }
            .prefix(2)
            .map { $0 }

        return VisionInterventionHistorySummary(
            recentInterventions: recentInterventions,
            recentNudgeMessages: Array(recentNudgeMessages),
            lastInterventionKind: recentInterventions.first?.kind,
            nudgeCount: recentActions.filter { $0.kind == .nudge }.count,
            overlayCount: recentActions.filter { $0.kind == .overlay }.count,
            backToWorkCount: recentActions.filter { $0.kind == .backToWork }.count,
            dismissOverlayCount: recentActions.filter { $0.kind == .dismissOverlay }.count
        )
    }

    /// Renders the user-turn prompt for a monitoring attempt by loading the `.md` template from
    /// `PromptCatalog` and substituting `{{PAYLOAD_JSON}}` with the serialised payload.
    nonisolated static func makeUserPrompt(
        snapshot: AppSnapshot,
        goals: String,
        recentActions: [ActionRecord],
        heuristics: TelemetryHeuristicSnapshot,
        distraction: DistractionMetadata,
        memory: String,
        promptProfile: MonitoringPromptProfile = PromptCatalog.defaultMonitoringPromptProfile
    ) -> String {
        let payload = makeVisionPayload(
            snapshot: snapshot,
            goals: goals,
            recentActions: recentActions,
            heuristics: heuristics,
            distraction: distraction,
            memory: memory
        )
        return makeUserPrompt(payloadJSON: encodePayload(payload), promptProfile: promptProfile, variant: .visionPrimaryUser)
    }

    /// Core render: injects `payloadJSON` into the template identified by `variant`.
    nonisolated static func makeUserPrompt(
        payloadJSON: String,
        promptProfile: MonitoringPromptProfile,
        variant: MonitoringPromptVariant
    ) -> String {
        PromptCatalog.renderMonitoringUserPrompt(
            profileID: promptProfile.descriptor.id,
            variant: variant,
            payloadJSON: payloadJSON
        )
    }

    nonisolated static func encodePayload<T: Encodable>(_ payload: T) -> String {
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

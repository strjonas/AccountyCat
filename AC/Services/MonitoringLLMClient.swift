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

nonisolated struct LegacyFocusPerceptionPayload: Codable, Sendable {
    var goals: String
    var memory: String?
    var frontmostApp: String
    var windowTitle: String?
    var timestamp: Date
    var recentSwitches: [TelemetryAppSwitchRecord]
    var timeByApp: [TelemetryUsageRecord]
    var heuristics: TelemetryHeuristicSnapshot
}

nonisolated struct LegacyFocusDecisionPayload: Codable, Sendable {
    var goals: String
    var memory: String?
    var frontmostApp: String
    var windowTitle: String?
    var timestamp: Date
    var activitySummary: String
    var perceptionFocusGuess: ModelAssessment?
    var perceptionReasonTags: [String]
    var recentSwitches: [TelemetryAppSwitchRecord]
    var timeByApp: [TelemetryUsageRecord]
    var interventionHistory: VisionInterventionHistorySummary
    var heuristics: TelemetryHeuristicSnapshot
    var distraction: TelemetryDistractionState
}

nonisolated struct LegacyFocusPerceptionEnvelope: Codable, Sendable {
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

    init(
        activitySummary: String,
        focusGuess: ModelAssessment?,
        reasonTags: [String],
        notes: [String]
    ) {
        self.activitySummary = activitySummary
        self.focusGuess = focusGuess
        self.reasonTags = reasonTags
        self.notes = notes
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        activitySummary = try container.decodeIfPresent(String.self, forKey: .activitySummary)
            ?? container.decodeIfPresent(String.self, forKey: .sceneSummary)
            ?? ""
        focusGuess = try container.decodeIfPresent(ModelAssessment.self, forKey: .focusGuess)
        reasonTags = try container.decodeIfPresent([String].self, forKey: .reasonTags) ?? []
        if let noteList = try? container.decode([String].self, forKey: .notes) {
            notes = noteList
        } else if let note = try? container.decode(String.self, forKey: .notes) {
            let cleaned = note.cleanedSingleLine
            notes = cleaned.isEmpty ? [] : [cleaned]
        } else {
            notes = []
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(activitySummary, forKey: .activitySummary)
        try container.encodeIfPresent(focusGuess, forKey: .focusGuess)
        try container.encode(reasonTags, forKey: .reasonTags)
        try container.encode(notes, forKey: .notes)
    }
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
    private struct FailureCooldown: Sendable {
        var until: Date
        var contextKey: String?
    }

    private var cooldown: FailureCooldown?

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
        let snapshotContextKey = Self.contextKey(for: snapshot)
        let perceptionAttempt = makePerceptionAttempt(
            snapshot: snapshot,
            goals: goals,
            recentActions: recentActions,
            heuristics: heuristics,
            memory: memory,
            promptProfile: promptProfile
        )
        var attempts: [LLMEvaluationAttempt] = [perceptionAttempt]

        if let cooldown, Date() < cooldown.until {
            let sameContext = cooldown.contextKey == nil || cooldown.contextKey == snapshotContextKey
            if sameContext {
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
            self.cooldown = nil
        }

        guard FileManager.default.isExecutableFile(atPath: runtimePath) else {
            cooldown = FailureCooldown(
                until: Date().addingTimeInterval(120),
                contextKey: nil
            )
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
            let perceptionOutput = try await runtime.runVisionInference(
                runtimePath: runtimePath,
                snapshotPath: screenshotPath,
                systemPrompt: perceptionAttempt.templateContents,
                userPrompt: perceptionAttempt.renderedPrompt,
                options: Self.legacyVisionOptions(modelIdentifier: modelIdentifier)
            )
            attempts[0].runtimeOutput = perceptionOutput
            let rawPerceptionOutput = perceptionOutput.stdout + "\n" + perceptionOutput.stderr
            let parsedPerception = Self.decode(LegacyFocusPerceptionEnvelope.self, from: rawPerceptionOutput)
            let effectivePerception = Self.resolvePerception(
                parsedPerception,
                snapshot: snapshot
            )

            let decisionAttempt = makeDecisionAttempt(
                snapshot: snapshot,
                goals: goals,
                recentActions: recentActions,
                heuristics: heuristics,
                distraction: distraction,
                memory: memory,
                perception: effectivePerception,
                promptProfile: promptProfile,
                stage: .decision
            )
            attempts.append(decisionAttempt)
            let decisionOutput = try await runtime.runTextInference(
                runtimePath: runtimePath,
                systemPrompt: decisionAttempt.templateContents,
                userPrompt: decisionAttempt.renderedPrompt,
                options: Self.legacyDecisionOptions(modelIdentifier: modelIdentifier)
            )
            attempts[1].runtimeOutput = decisionOutput
            attempts[1].parsedDecision = LLMOutputParsing.extractDecision(
                from: decisionOutput.stdout + "\n" + decisionOutput.stderr
            )

            let finalDecision = attempts[1].parsedDecision
            if let finalDecision {
                cooldown = nil
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
                let fallbackAttempt = makeDecisionAttempt(
                    snapshot: snapshot,
                    goals: goals,
                    recentActions: recentActions,
                    heuristics: heuristics,
                    distraction: distraction,
                    memory: memory,
                    perception: effectivePerception,
                    promptProfile: promptProfile,
                    stage: .decisionFallback
                )
                attempts.append(fallbackAttempt)
                let fallbackOutput = try await runtime.runTextInference(
                    runtimePath: runtimePath,
                    systemPrompt: fallbackAttempt.templateContents,
                    userPrompt: fallbackAttempt.renderedPrompt,
                    options: Self.legacyDecisionFallbackOptions(modelIdentifier: modelIdentifier)
                )
                attempts[2].runtimeOutput = fallbackOutput
                attempts[2].parsedDecision = LLMOutputParsing.extractDecision(
                    from: fallbackOutput.stdout + "\n" + fallbackOutput.stderr
                )
            }

            if let fallbackDecision = attempts.last?.parsedDecision {
                cooldown = nil
                return LLMEvaluationResult(
                    runtimePath: runtimePath,
                    modelIdentifier: modelIdentifier,
                    promptProfileID: promptProfile.descriptor.id,
                    promptProfileVersion: promptProfile.descriptor.version,
                    attempts: attempts,
                    finalDecision: fallbackDecision,
                    failureMessage: nil
                )
            }

            cooldown = FailureCooldown(
                until: Date().addingTimeInterval(120),
                contextKey: snapshotContextKey
            )

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
            cooldown = FailureCooldown(
                until: Date().addingTimeInterval(120),
                contextKey: snapshotContextKey
            )
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

    private func makePerceptionAttempt(
        snapshot: AppSnapshot,
        goals: String,
        recentActions: [ActionRecord],
        heuristics: TelemetryHeuristicSnapshot,
        memory: String,
        promptProfile: MonitoringPromptProfile
    ) -> LLMEvaluationAttempt {
        let systemPrompt = PromptCatalog.loadPolicySystemPrompt(stage: .perceptionVision)
        let payload = Self.makeLegacyPerceptionPayload(
            snapshot: snapshot,
            goals: goals,
            heuristics: heuristics,
            memory: memory
        )
        let payloadJSON = Self.encodePayload(payload)
        let renderedPrompt = PromptCatalog.renderPolicyUserPrompt(
            stage: .perceptionVision,
            payloadJSON: payloadJSON
        )
        let template = PromptTemplateRecord(
            id: "legacy_focus.perception_vision",
            version: promptProfile.descriptor.version,
            sha256: Self.sha256Hex(systemPrompt)
        )

        return LLMEvaluationAttempt(
            promptMode: "legacy_perception_vision",
            promptVersion: promptProfile.descriptor.version,
            template: template,
            templateContents: systemPrompt,
            payloadJSON: payloadJSON,
            renderedPrompt: renderedPrompt,
            runtimeOutput: nil,
            parsedDecision: nil
        )
    }

    private func makeDecisionAttempt(
        snapshot: AppSnapshot,
        goals: String,
        recentActions: [ActionRecord],
        heuristics: TelemetryHeuristicSnapshot,
        distraction: DistractionMetadata,
        memory: String,
        perception: LegacyFocusPerceptionEnvelope,
        promptProfile: MonitoringPromptProfile,
        stage: LegacyFocusPromptStage
    ) -> LLMEvaluationAttempt {
        let systemPrompt = PromptCatalog.loadLegacyFocusSystemPrompt(stage: stage)
        let payload = Self.makeLegacyDecisionPayload(
            snapshot: snapshot,
            goals: goals,
            recentActions: recentActions,
            heuristics: heuristics,
            distraction: distraction,
            memory: memory,
            perception: perception
        )
        let payloadJSON = Self.encodePayload(payload)
        let renderedPrompt = PromptCatalog.renderLegacyFocusUserPrompt(
            stage: stage,
            payloadJSON: payloadJSON
        )
        let template = PromptTemplateRecord(
            id: "legacy_focus.\(stage.rawValue)",
            version: promptProfile.descriptor.version,
            sha256: Self.sha256Hex(systemPrompt)
        )

        return LLMEvaluationAttempt(
            promptMode: "legacy_\(stage.rawValue)",
            promptVersion: promptProfile.descriptor.version,
            template: template,
            templateContents: systemPrompt,
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
            memory: trimmedMemory.isEmpty ? nil : trimmedMemory.truncatedMultilineForPrompt(maxLength: 220, maxLines: 2),
            frontmostApp: snapshot.appName.truncatedForPrompt(maxLength: 80),
            windowTitle: snapshot.windowTitle?.truncatedForPrompt(maxLength: 180),
            timestamp: snapshot.timestamp,
            recentSwitches: snapshot.recentSwitches.prefix(2).map(\.telemetryRecord),
            timeByApp: snapshot.perAppDurations.prefix(4).map(\.telemetryRecord),
            interventionHistory: makeInterventionHistorySummary(from: relevantActions),
            heuristics: heuristics,
            distraction: distraction.telemetryState
        )
    }

    nonisolated static func makeLegacyPerceptionPayload(
        snapshot: AppSnapshot,
        goals: String,
        heuristics: TelemetryHeuristicSnapshot,
        memory: String = ""
    ) -> LegacyFocusPerceptionPayload {
        let trimmedMemory = condensedMonitoringMemory(
            memory,
            goals: goals
        )
        return LegacyFocusPerceptionPayload(
            goals: goals.cleanedSingleLine.truncatedForPrompt(maxLength: 180),
            memory: trimmedMemory.isEmpty ? nil : trimmedMemory.truncatedMultilineForPrompt(maxLength: 180, maxLines: 2),
            frontmostApp: snapshot.appName.truncatedForPrompt(maxLength: 80),
            windowTitle: snapshot.windowTitle?.truncatedForPrompt(maxLength: 180),
            timestamp: snapshot.timestamp,
            recentSwitches: snapshot.recentSwitches.prefix(2).map(\.telemetryRecord),
            timeByApp: snapshot.perAppDurations.prefix(4).map(\.telemetryRecord),
            heuristics: TelemetryHeuristicSnapshot(
                clearlyProductive: heuristics.clearlyProductive,
                browser: heuristics.browser,
                helpfulWindowTitle: heuristics.helpfulWindowTitle,
                periodicVisualReason: nil
            )
        )
    }

    nonisolated static func makeLegacyDecisionPayload(
        snapshot: AppSnapshot,
        goals: String,
        recentActions: [ActionRecord],
        heuristics: TelemetryHeuristicSnapshot,
        distraction: DistractionMetadata,
        memory: String = "",
        perception: LegacyFocusPerceptionEnvelope
    ) -> LegacyFocusDecisionPayload {
        let relevantActions = monitoringRelevantActions(
            from: recentActions,
            at: snapshot.timestamp
        )
        let trimmedMemory = condensedMonitoringMemory(
            memory,
            goals: goals
        )
        return LegacyFocusDecisionPayload(
            goals: goals.cleanedSingleLine.truncatedForPrompt(maxLength: 180),
            memory: trimmedMemory.isEmpty ? nil : trimmedMemory.truncatedMultilineForPrompt(maxLength: 220, maxLines: 2),
            frontmostApp: snapshot.appName.truncatedForPrompt(maxLength: 80),
            windowTitle: snapshot.windowTitle?.truncatedForPrompt(maxLength: 180),
            timestamp: snapshot.timestamp,
            activitySummary: perception.activitySummary.truncatedForPrompt(maxLength: 220),
            perceptionFocusGuess: perception.focusGuess,
            perceptionReasonTags: Array(perception.reasonTags.prefix(4)),
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

        return Array(filtered.prefix(3))
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
        var candidates: [(line: String, score: Int, index: Int)] = []

        let restrictionMarkers = [
            "don't", "do not", "avoid", "block", "limit", "keep me off",
            "stay off", "no ", "not allow", "shouldn't", "should not"
        ]
        let timeBoundMarkers = [
            "today", "tonight", "tomorrow", "this week", "this afternoon",
            "this evening", "for now", "until"
        ]

        for (index, line) in memory.components(separatedBy: .newlines).enumerated() {
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

            var score = index
            if restrictionMarkers.contains(where: { normalized.contains($0) }) {
                score += 40
            }
            if timeBoundMarkers.contains(where: { normalized.contains($0) }) {
                score += 20
            }
            if normalized.contains(".com") || normalized.contains(".io") || normalized.contains(".org") {
                score += 15
            }

            candidates.append((line: trimmed, score: score, index: index))
        }

        return candidates
            .sorted { lhs, rhs in
                if lhs.score == rhs.score {
                    return lhs.index > rhs.index
                }
                return lhs.score > rhs.score
            }
            .prefix(2)
            .map(\.line)
            .joined(separator: "\n")
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
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(payload),
              let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return string
    }

    nonisolated private static func resolvePerception(
        _ perception: LegacyFocusPerceptionEnvelope?,
        snapshot: AppSnapshot
    ) -> LegacyFocusPerceptionEnvelope {
        guard let perception,
              !perception.activitySummary.cleanedSingleLine.isEmpty else {
            let fallbackSummary: String
            if let windowTitle = snapshot.windowTitle?.truncatedForPrompt(maxLength: 180),
               !windowTitle.isEmpty {
                fallbackSummary = "\(snapshot.appName.truncatedForPrompt(maxLength: 80)): \(windowTitle)"
            } else {
                fallbackSummary = "Using \(snapshot.appName.truncatedForPrompt(maxLength: 80)) in an unclear way."
            }
            return LegacyFocusPerceptionEnvelope(
                activitySummary: fallbackSummary,
                focusGuess: .unclear,
                reasonTags: ["perception_fallback"],
                notes: ["perception_parse_failed"]
            )
        }
        return LegacyFocusPerceptionEnvelope(
            activitySummary: perception.activitySummary.cleanedSingleLine.truncatedForPrompt(maxLength: 220),
            focusGuess: perception.focusGuess,
            reasonTags: Array(perception.reasonTags.prefix(4)),
            notes: Array(perception.notes.prefix(2)).map { $0.truncatedForPrompt(maxLength: 120) }
        )
    }

    nonisolated private static func decode<T: Decodable>(
        _ type: T.Type,
        from output: String
    ) -> T? {
        StructuredOutputJSON.decode(type, from: output)
    }

    nonisolated private static func contextKey(for snapshot: AppSnapshot) -> String {
        [snapshot.bundleIdentifier ?? "unknown", snapshot.windowTitle?.normalizedForContextKey ?? ""]
            .joined(separator: "|")
    }

    nonisolated private static func legacyVisionOptions(modelIdentifier: String) -> RuntimeInferenceOptions {
        runtimeOptions(
            sharedStage: .perceptionVision,
            modelIdentifier: modelIdentifier,
            fallback: RuntimeInferenceOptions(
                modelIdentifier: modelIdentifier,
                maxTokens: 180,
                temperature: 0.15,
                topP: 0.95,
                topK: 64,
                ctxSize: 4096,
                batchSize: 2048,
                ubatchSize: 1024,
                timeoutSeconds: 45
            )
        )
    }

    nonisolated private static func legacyDecisionOptions(modelIdentifier: String) -> RuntimeInferenceOptions {
        runtimeOptions(
            sharedStage: .legacyDecision,
            modelIdentifier: modelIdentifier,
            fallback: RuntimeInferenceOptions(
                modelIdentifier: modelIdentifier,
                maxTokens: 220,
                temperature: 0.08,
                topP: 0.9,
                topK: 40,
                ctxSize: 4096,
                batchSize: 1024,
                ubatchSize: 512,
                timeoutSeconds: 40
            )
        )
    }

    nonisolated private static func legacyDecisionFallbackOptions(modelIdentifier: String) -> RuntimeInferenceOptions {
        runtimeOptions(
            sharedStage: .legacyDecisionFallback,
            modelIdentifier: modelIdentifier,
            fallback: RuntimeInferenceOptions(
                modelIdentifier: modelIdentifier,
                maxTokens: 180,
                temperature: 0.08,
                topP: 0.9,
                topK: 32,
                ctxSize: 4096,
                batchSize: 1024,
                ubatchSize: 512,
                timeoutSeconds: 40
            )
        )
    }

    nonisolated private static func runtimeOptions(
        sharedStage: MonitoringPromptTuningStage,
        modelIdentifier: String,
        fallback: RuntimeInferenceOptions
    ) -> RuntimeInferenceOptions {
        guard let baseOptions = MonitoringPromptTuning.runtimeDefinitions
            .first(where: { $0.id == MonitoringConfiguration.defaultRuntimeProfileID })?
            .options(for: sharedStage) else {
            return fallback
        }

        return RuntimeInferenceOptions(
            modelIdentifier: modelIdentifier,
            maxTokens: baseOptions.maxTokens,
            temperature: baseOptions.temperature,
            topP: baseOptions.topP,
            topK: baseOptions.topK,
            ctxSize: baseOptions.ctxSize,
            batchSize: baseOptions.batchSize,
            ubatchSize: baseOptions.ubatchSize,
            timeoutSeconds: baseOptions.timeoutSeconds
        )
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

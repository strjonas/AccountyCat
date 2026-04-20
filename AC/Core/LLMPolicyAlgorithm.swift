//
//  LLMPolicyAlgorithm.swift
//  AC
//

import CryptoKit
import Foundation

final class LLMPolicyAlgorithm: MonitoringAlgorithm {
    let descriptor = MonitoringAlgorithmDescriptor(
        id: MonitoringConfiguration.llmPolicyAlgorithmID,
        version: "1.0",
        displayName: "LLM Policy",
        summary: "Staged local-LLM policy pipeline with structured memory and soft appeals."
    )

    private let runtime: LocalModelRuntime
    private let policyMemoryService: PolicyMemoryServicing
    private let stabilityWindow: TimeInterval = 20
    private let distractedFollowUp: TimeInterval = 180
    private let nudgeCooldown: TimeInterval = 60
    private let overlayCooldown: TimeInterval = 180

    init(
        runtime: LocalModelRuntime,
        policyMemoryService: PolicyMemoryServicing
    ) {
        self.runtime = runtime
        self.policyMemoryService = policyMemoryService
    }

    func resetState(_ state: inout AlgorithmStateEnvelope) {
        state.llmPolicy = LLMPolicyAlgorithmState()
    }

    func resetTransientState(_ state: inout AlgorithmStateEnvelope) {
        state.llmPolicy.distraction = DistractionMetadata()
        state.llmPolicy.activeAppeal = nil
    }

    func noteContext(
        _ contextKey: String?,
        at now: Date,
        state: inout AlgorithmStateEnvelope
    ) -> Bool {
        guard state.llmPolicy.currentContextKey != contextKey else {
            return false
        }

        state.llmPolicy.currentContextKey = contextKey
        state.llmPolicy.currentContextEnteredAt = contextKey == nil ? nil : now
        state.llmPolicy.activeAppeal = nil
        state.llmPolicy.distraction = DistractionMetadata(
            contextKey: contextKey,
            stableSince: contextKey == nil ? nil : now,
            lastAssessment: nil,
            consecutiveDistractedCount: 0,
            nextEvaluationAt: nil
        )
        return true
    }

    func evaluationPlan(
        state: inout AlgorithmStateEnvelope,
        context: FrontmostContext,
        heuristics: TelemetryHeuristicSnapshot,
        configuration: MonitoringConfiguration,
        now: Date
    ) -> MonitoringEvaluationPlan {
        let profile = LLMPolicyCatalog.pipelineProfile(id: configuration.pipelineProfileID)

        if heuristics.clearlyProductive && heuristics.browser == false {
            return MonitoringEvaluationPlan(
                shouldEvaluate: false,
                reason: "obviously_productive",
                visualCheckReason: nil,
                requiresScreenshot: profile.descriptor.requiresScreenshot,
                promptMode: profile.descriptor.id,
                promptVersion: descriptor.version
            )
        }

        let distraction = state.llmPolicy.distraction
        let shouldEvaluate: Bool
        let reason: String

        if distraction.lastAssessment == .distracted {
            shouldEvaluate = distraction.nextEvaluationAt.map { now >= $0 } ?? false
            reason = "distracted_follow_up"
        } else if let stableSince = state.llmPolicy.currentContextEnteredAt {
            shouldEvaluate = now.timeIntervalSince(stableSince) >= stabilityWindow
            reason = "stable_context"
        } else {
            shouldEvaluate = false
            reason = "awaiting_context"
        }

        return MonitoringEvaluationPlan(
            shouldEvaluate: shouldEvaluate,
            reason: reason,
            visualCheckReason: nil,
            requiresScreenshot: profile.descriptor.requiresScreenshot,
            promptMode: profile.descriptor.id,
            promptVersion: descriptor.version
        )
    }

    func distractionMetadata(from state: AlgorithmStateEnvelope) -> DistractionMetadata {
        state.llmPolicy.distraction
    }

    func evaluate(input: MonitoringDecisionInput) async -> MonitoringDecisionResult {
        let runtimePath = RuntimeSetupService.normalizedRuntimePath(from: input.runtimeOverride)
        let pipelineProfile = LLMPolicyCatalog.pipelineProfile(id: input.configuration.pipelineProfileID)
        let runtimeProfile = LLMPolicyCatalog.runtimeProfile(id: input.configuration.runtimeProfileID)
        let execution = MonitoringExecutionMetadata(
            algorithmID: descriptor.id,
            algorithmVersion: descriptor.version,
            promptProfileID: "llm_policy_v1",
            pipelineProfileID: pipelineProfile.descriptor.id,
            runtimeProfileID: runtimeProfile.descriptor.id,
            experimentArm: input.configuration.experimentArm
        )

        guard FileManager.default.isExecutableFile(atPath: runtimePath) else {
            return makeResult(
                input: input,
                execution: execution,
                evaluation: LLMEvaluationResult(
                    runtimePath: runtimePath,
                    modelIdentifier: runtimeProfile.descriptor.modelIdentifier,
                    promptProfileID: "llm_policy_v1",
                    promptProfileVersion: descriptor.version,
                    attempts: [],
                    finalDecision: .unclear,
                    failureMessage: "runtime_missing"
                ),
                decision: .unclear,
                action: .none,
                updatedState: input.algorithmState,
                blockReason: "runtime_missing"
            )
        }

        var attempts: [LLMEvaluationAttempt] = []
        let relevantActions = MonitoringLLMClient.monitoringRelevantActions(
            from: input.recentActions,
            at: input.now
        )
        let policySummary = makePolicySummary(
            policyMemory: input.policyMemory,
            snapshot: input.snapshot,
            now: input.now
        )

        var titlePerception: PolicyPerceptionOutput?
        if pipelineProfile.usesTitlePerception {
            titlePerception = await runTextStage(
                stage: .perceptionTitle,
                runtimePath: runtimePath,
                options: runtimeProfile.options(for: .perceptionTitle),
                payload: PolicyTitlePerceptionPayload(
                    goals: input.goals.cleanedSingleLine,
                    appName: input.snapshot.appName,
                    bundleIdentifier: input.snapshot.bundleIdentifier,
                    windowTitle: input.snapshot.windowTitle,
                    timestamp: input.now,
                    recentSwitches: Array(input.snapshot.recentSwitches.prefix(3)),
                    usage: Array(input.snapshot.perAppDurations.prefix(6)),
                    policySummary: policySummary,
                    recentActions: Array(relevantActions.prefix(3))
                ),
                attempts: &attempts,
                decoder: PolicyPerceptionOutput.self
            )
        }

        var visionPerception: PolicyPerceptionOutput?
        if pipelineProfile.usesVisionPerception,
           let screenshotPath = input.snapshot.screenshotPath {
            visionPerception = await runVisionStage(
                stage: .perceptionVision,
                runtimePath: runtimePath,
                snapshotPath: screenshotPath,
                options: runtimeProfile.options(for: .perceptionVision),
                payload: PolicyVisionPerceptionPayload(
                    goals: input.goals.cleanedSingleLine,
                    appName: input.snapshot.appName,
                    windowTitle: input.snapshot.windowTitle,
                    timestamp: input.now,
                    policySummary: policySummary
                ),
                attempts: &attempts,
                decoder: PolicyPerceptionOutput.self
            )
        }

        let decisionEnvelope = await runTextStage(
            stage: .decision,
            runtimePath: runtimePath,
            options: runtimeProfile.options(for: .decision),
            payload: PolicyDecisionPayload(
                goals: input.goals.cleanedSingleLine,
                freeFormMemory: MonitoringLLMClient.condensedMonitoringMemory(input.memory, goals: input.goals),
                policySummary: policySummary,
                timestamp: input.now,
                appName: input.snapshot.appName,
                bundleIdentifier: input.snapshot.bundleIdentifier,
                windowTitle: input.snapshot.windowTitle,
                recentSwitches: Array(input.snapshot.recentSwitches.prefix(4)),
                usage: Array(input.snapshot.perAppDurations.prefix(8)),
                recentActions: Array(relevantActions.prefix(4)),
                heuristics: input.heuristics,
                distraction: input.algorithmState.llmPolicy.distraction.telemetryState,
                titlePerception: titlePerception,
                visionPerception: visionPerception
            ),
            attempts: &attempts,
            decoder: PolicyDecisionEnvelope.self
        )

        var decision = decisionEnvelope?.decision ?? .unclear
        if pipelineProfile.splitCopyGeneration,
           decision.suggestedAction == ModelSuggestedAction.nudge {
            let nudgeEnvelope = await runTextStage(
                stage: .nudgeCopy,
                runtimePath: runtimePath,
                options: runtimeProfile.options(for: .nudgeCopy),
                payload: PolicyNudgeCopyPayload(
                    goals: input.goals.cleanedSingleLine,
                    policySummary: policySummary,
                    appName: input.snapshot.appName,
                    windowTitle: input.snapshot.windowTitle,
                    titlePerception: titlePerception?.activitySummary,
                    visionPerception: visionPerception?.activitySummary,
                    recentNudges: input.algorithmState.llmPolicy.recentNudgeMessages
                ),
                attempts: &attempts,
                decoder: PolicyNudgeEnvelope.self
            )
            if let nudge = nudgeEnvelope?.nudge?.cleanedSingleLine,
               !nudge.isEmpty {
                decision.nudge = nudge
            }
        }

        let evaluation = LLMEvaluationResult(
            runtimePath: runtimePath,
            modelIdentifier: runtimeProfile.descriptor.modelIdentifier,
            promptProfileID: "llm_policy_v1",
            promptProfileVersion: descriptor.version,
            attempts: attempts,
            finalDecision: decision,
            failureMessage: decision == .unclear ? "no_usable_decision" : nil
        )

        var updatedState = input.algorithmState
        var policyState = updatedState.llmPolicy
        var distraction = policyState.distraction
        distraction.contextKey = policyState.currentContextKey

        let action: CompanionAction
        let blockReason: String?

        switch decision.assessment {
        case .focused, .unclear:
            distraction.lastAssessment = decision.assessment
            distraction.consecutiveDistractedCount = 0
            distraction.nextEvaluationAt = nil
            policyState.activeAppeal = nil
            action = .none
            blockReason = decision.assessment == ModelAssessment.unclear ? "unclear_assessment" : nil

        case .distracted:
            distraction.lastAssessment = .distracted
            distraction.consecutiveDistractedCount += 1
            distraction.nextEvaluationAt = input.now.addingTimeInterval(distractedFollowUp)

            switch decision.suggestedAction {
            case .overlay:
                let overlayReady = policyState.lastOverlayAt.map { input.now.timeIntervalSince($0) >= overlayCooldown } ?? true
                if overlayReady {
                    let presentation = decisionEnvelope?.overlayPresentation(
                        appName: input.snapshot.appName,
                        evaluationID: input.evaluationID
                    ) ?? OverlayPresentation(
                        headline: "Pause for a second.",
                        body: "This still looks off-track in \(input.snapshot.appName).",
                        prompt: "Why should I let you continue on this?",
                        appName: input.snapshot.appName,
                        evaluationID: input.evaluationID,
                        submitButtonTitle: "Submit",
                        secondaryButtonTitle: "Back to work"
                    )
                    policyState.lastOverlayAt = input.now
                    policyState.lastInterventionAt = input.now
                    policyState.activeAppeal = MonitoringAppealSession(
                        evaluationID: input.evaluationID,
                        contextKey: distraction.contextKey ?? "unknown",
                        appName: input.snapshot.appName,
                        prompt: presentation.prompt ?? "Why should I let you continue on this?",
                        createdAt: input.now,
                        lastSubmittedAt: nil,
                        lastResult: nil
                    )
                    action = .showOverlay(presentation)
                    blockReason = nil
                } else {
                    action = .none
                    blockReason = "overlay_cooldown"
                }

            case .nudge:
                let nudgeReady = policyState.lastNudgeAt.map { input.now.timeIntervalSince($0) >= nudgeCooldown } ?? true
                if nudgeReady,
                   let nudge = decision.nudge?.cleanedSingleLine,
                   !nudge.isEmpty {
                    policyState.lastNudgeAt = input.now
                    policyState.lastInterventionAt = input.now
                    policyState.recentNudgeMessages.insert(nudge, at: 0)
                    policyState.recentNudgeMessages = Array(policyState.recentNudgeMessages.prefix(3))
                    action = .showNudge(nudge)
                    blockReason = nil
                } else if !nudgeReady {
                    action = .none
                    blockReason = "nudge_cooldown"
                } else {
                    action = .none
                    blockReason = "missing_nudge_copy"
                }

            case .none:
                action = .none
                blockReason = nil

            case .abstain:
                action = .none
                blockReason = decision.abstainReason ?? "abstained"
            }
        }

        policyState.distraction = distraction
        updatedState.llmPolicy = policyState

        return makeResult(
            input: input,
            execution: execution,
            evaluation: evaluation,
            decision: decision,
            action: action,
            updatedState: updatedState,
            blockReason: blockReason
        )
    }

    func reviewAppeal(input: MonitoringAppealReviewInput) async -> MonitoringAppealReviewOutput? {
        let runtimePath = RuntimeSetupService.normalizedRuntimePath(from: input.runtimeOverride)
        guard FileManager.default.isExecutableFile(atPath: runtimePath) else {
            return MonitoringAppealReviewOutput(
                result: AppealReviewResult(
                    decision: .deferDecision,
                    message: "I couldn't review that right now. Try again or head back to work."
                ),
                evaluation: LLMEvaluationResult(
                    runtimePath: runtimePath,
                    modelIdentifier: LLMPolicyCatalog.runtimeProfile(id: input.configuration.runtimeProfileID).descriptor.modelIdentifier,
                    promptProfileID: "llm_policy_v1",
                    promptProfileVersion: descriptor.version,
                    attempts: [],
                    finalDecision: .unclear,
                    failureMessage: "runtime_missing"
                ),
                updatedPolicyMemory: input.policyMemory,
                updatedAlgorithmState: input.algorithmState
            )
        }

        let runtimeProfile = LLMPolicyCatalog.runtimeProfile(id: input.configuration.runtimeProfileID)
        var attempts: [LLMEvaluationAttempt] = []
        let envelope = await runTextStage(
            stage: .appealReview,
            runtimePath: runtimePath,
            options: runtimeProfile.options(for: .appealReview),
            payload: PolicyAppealPayload(
                appealText: input.appealText,
                goals: input.goals.cleanedSingleLine,
                freeFormMemory: MonitoringLLMClient.condensedMonitoringMemory(input.memory, goals: input.goals),
                policySummary: makePolicySummary(
                    policyMemory: input.policyMemory,
                    snapshot: input.snapshot,
                    now: input.now
                ),
                snapshotAppName: input.snapshot?.appName,
                snapshotWindowTitle: input.snapshot?.windowTitle,
                activeAppeal: input.algorithmState.llmPolicy.activeAppeal
            ),
            attempts: &attempts,
            decoder: PolicyAppealReviewEnvelope.self
        )

        let result = envelope?.appealReviewResult ?? AppealReviewResult(
            decision: .deferDecision,
            message: "I’m not sure yet. If it really helps your goals, explain a bit more."
        )
        let evaluation = LLMEvaluationResult(
            runtimePath: runtimePath,
            modelIdentifier: runtimeProfile.descriptor.modelIdentifier,
            promptProfileID: "llm_policy_v1",
            promptProfileVersion: descriptor.version,
            attempts: attempts,
            finalDecision: .unclear,
            failureMessage: nil
        )

        var updatedPolicyMemory = input.policyMemory
        if let update = await policyMemoryService.deriveUpdate(
            request: PolicyMemoryUpdateRequest(
                now: input.now,
                goals: input.goals,
                freeFormMemory: input.memory,
                policyMemory: input.policyMemory,
                eventSummary: "User appeal: \(input.appealText.cleanedSingleLine)\nReview result: \(result.decision.rawValue) — \(result.message.cleanedSingleLine)",
                recentActions: input.recentActions,
                context: input.snapshot.map {
                    FrontmostContext(
                        bundleIdentifier: $0.bundleIdentifier,
                        appName: $0.appName,
                        windowTitle: $0.windowTitle
                    )
                },
                runtimeProfileID: input.configuration.runtimeProfileID
            ),
            runtimeOverride: input.runtimeOverride
        ) {
            updatedPolicyMemory.apply(update, now: input.now)
        }

        var updatedAlgorithmState = input.algorithmState
        updatedAlgorithmState.llmPolicy.activeAppeal?.lastSubmittedAt = input.now
        updatedAlgorithmState.llmPolicy.activeAppeal?.lastResult = result
        if result.decision == AppealReviewDecision.allow {
            updatedAlgorithmState.llmPolicy.activeAppeal = nil
            updatedAlgorithmState.llmPolicy.distraction.lastAssessment = .unclear
            updatedAlgorithmState.llmPolicy.distraction.nextEvaluationAt = input.now.addingTimeInterval(distractedFollowUp)
        }

        return MonitoringAppealReviewOutput(
            result: result,
            evaluation: evaluation,
            updatedPolicyMemory: updatedPolicyMemory,
            updatedAlgorithmState: updatedAlgorithmState
        )
    }

    private func makeResult(
        input: MonitoringDecisionInput,
        execution: MonitoringExecutionMetadata,
        evaluation: LLMEvaluationResult,
        decision: LLMDecision,
        action: CompanionAction,
        updatedState: AlgorithmStateEnvelope,
        blockReason: String?
    ) -> MonitoringDecisionResult {
        let allowIntervention: Bool
        if case .none = action {
            allowIntervention = false
        } else {
            allowIntervention = true
        }
        let allowEscalation: Bool
        if case .showOverlay = action {
            allowEscalation = true
        } else {
            allowEscalation = false
        }

        return MonitoringDecisionResult(
            execution: execution,
            evaluation: evaluation,
            decision: decision,
            policy: CompanionPolicyResult(
                action: action,
                record: PolicyDecisionRecord(
                    evaluationID: input.evaluationID,
                    model: decision.parsedRecord,
                    strategy: execution.telemetryRecord,
                    ladderSignal: "llm_policy",
                    allowIntervention: allowIntervention,
                    allowEscalation: allowEscalation,
                    blockReason: blockReason,
                    finalAction: CompanionPolicy.telemetryActionRecord(for: action),
                    distractionBefore: input.algorithmState.llmPolicy.distraction.telemetryState,
                    distractionAfter: updatedState.llmPolicy.distraction.telemetryState
                )
            ),
            updatedAlgorithmState: updatedState
        )
    }

    private func makePolicySummary(
        policyMemory: PolicyMemory,
        snapshot: AppSnapshot?,
        now: Date
    ) -> String {
        let usageByDay = [
            now.acDayKey: Dictionary(
                uniqueKeysWithValues: (snapshot?.perAppDurations ?? []).map { ($0.appName, $0.seconds) }
            )
        ]

        let context = snapshot.map {
            FrontmostContext(
                bundleIdentifier: $0.bundleIdentifier,
                appName: $0.appName,
                windowTitle: $0.windowTitle
            )
        } ?? FrontmostContext(bundleIdentifier: nil, appName: "Unknown App", windowTitle: nil)

        var policyMemory = policyMemory
        policyMemory.expireRules(at: now)
        return policyMemory.monitoringSummary(for: context, usageByDay: usageByDay, now: now, limit: 8)
    }

    private func runTextStage<T: Decodable & Sendable, P: Encodable>(
        stage: LLMPolicyStage,
        runtimePath: String,
        options: RuntimeInferenceOptions,
        payload: P,
        attempts: inout [LLMEvaluationAttempt],
        decoder: T.Type
    ) async -> T? {
        let payloadJSON = MonitoringLLMClient.encodePayload(payload)
        let systemPrompt = PromptCatalog.loadPolicySystemPrompt(stage: stage)
        let userPrompt = PromptCatalog.renderPolicyUserPrompt(stage: stage, payloadJSON: payloadJSON)
        let template = PromptTemplateRecord(
            id: "policy.\(stage.rawValue)",
            version: descriptor.version,
            sha256: Self.sha256Hex(systemPrompt)
        )

        let attemptIndex = attempts.count
        attempts.append(
            LLMEvaluationAttempt(
                promptMode: stage.rawValue,
                promptVersion: descriptor.version,
                template: template,
                templateContents: systemPrompt,
                payloadJSON: payloadJSON,
                renderedPrompt: userPrompt,
                runtimeOutput: nil,
                parsedDecision: nil
            )
        )

        do {
            let output = try await runtime.runTextInference(
                runtimePath: runtimePath,
                systemPrompt: systemPrompt,
                userPrompt: userPrompt,
                options: options
            )
            attempts[attemptIndex].runtimeOutput = output
            if stage == .decision {
                attempts[attemptIndex].parsedDecision = LLMOutputParsing.extractDecision(
                    from: output.stdout + "\n" + output.stderr
                )
            }
            return Self.decodeJSON(decoder, from: output.stdout + "\n" + output.stderr)
        } catch {
            return nil
        }
    }

    private func runVisionStage<T: Decodable & Sendable, P: Encodable>(
        stage: LLMPolicyStage,
        runtimePath: String,
        snapshotPath: String,
        options: RuntimeInferenceOptions,
        payload: P,
        attempts: inout [LLMEvaluationAttempt],
        decoder: T.Type
    ) async -> T? {
        let payloadJSON = MonitoringLLMClient.encodePayload(payload)
        let systemPrompt = PromptCatalog.loadPolicySystemPrompt(stage: stage)
        let userPrompt = PromptCatalog.renderPolicyUserPrompt(stage: stage, payloadJSON: payloadJSON)
        let template = PromptTemplateRecord(
            id: "policy.\(stage.rawValue)",
            version: descriptor.version,
            sha256: Self.sha256Hex(systemPrompt)
        )

        let attemptIndex = attempts.count
        attempts.append(
            LLMEvaluationAttempt(
                promptMode: stage.rawValue,
                promptVersion: descriptor.version,
                template: template,
                templateContents: systemPrompt,
                payloadJSON: payloadJSON,
                renderedPrompt: userPrompt,
                runtimeOutput: nil,
                parsedDecision: nil
            )
        )

        do {
            let output = try await runtime.runVisionInference(
                runtimePath: runtimePath,
                snapshotPath: snapshotPath,
                systemPrompt: systemPrompt,
                userPrompt: userPrompt,
                options: options
            )
            attempts[attemptIndex].runtimeOutput = output
            return Self.decodeJSON(decoder, from: output.stdout + "\n" + output.stderr)
        } catch {
            return nil
        }
    }

    private static func decodeJSON<T: Decodable>(
        _ type: T.Type,
        from output: String
    ) -> T? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for object in LLMOutputParsing.jsonObjects(in: output).reversed() {
            guard let data = object.data(using: .utf8),
                  let decoded = try? decoder.decode(type, from: data) else {
                continue
            }
            return decoded
        }
        return nil
    }

    private static func sha256Hex(_ input: String) -> String {
        SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

nonisolated private struct PolicyTitlePerceptionPayload: Encodable {
    var goals: String
    var appName: String
    var bundleIdentifier: String?
    var windowTitle: String?
    var timestamp: Date
    var recentSwitches: [AppSwitchRecord]
    var usage: [AppUsageRecord]
    var policySummary: String
    var recentActions: [ActionRecord]
}

nonisolated private struct PolicyVisionPerceptionPayload: Encodable {
    var goals: String
    var appName: String
    var windowTitle: String?
    var timestamp: Date
    var policySummary: String
}

nonisolated private struct PolicyDecisionPayload: Encodable {
    var goals: String
    var freeFormMemory: String
    var policySummary: String
    var timestamp: Date
    var appName: String
    var bundleIdentifier: String?
    var windowTitle: String?
    var recentSwitches: [AppSwitchRecord]
    var usage: [AppUsageRecord]
    var recentActions: [ActionRecord]
    var heuristics: TelemetryHeuristicSnapshot
    var distraction: TelemetryDistractionState
    var titlePerception: PolicyPerceptionOutput?
    var visionPerception: PolicyPerceptionOutput?
}

nonisolated private struct PolicyNudgeCopyPayload: Encodable {
    var goals: String
    var policySummary: String
    var appName: String
    var windowTitle: String?
    var titlePerception: String?
    var visionPerception: String?
    var recentNudges: [String]
}

nonisolated private struct PolicyAppealPayload: Encodable {
    var appealText: String
    var goals: String
    var freeFormMemory: String
    var policySummary: String
    var snapshotAppName: String?
    var snapshotWindowTitle: String?
    var activeAppeal: MonitoringAppealSession?
}

nonisolated private struct PolicyPerceptionOutput: Codable, Sendable {
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
        let c = try decoder.container(keyedBy: CodingKeys.self)
        activitySummary = try c.decodeIfPresent(String.self, forKey: .activitySummary)
            ?? c.decodeIfPresent(String.self, forKey: .sceneSummary)
            ?? ""
        focusGuess = try c.decodeIfPresent(ModelAssessment.self, forKey: .focusGuess)
        reasonTags = try c.decodeIfPresent([String].self, forKey: .reasonTags) ?? []
        notes = try c.decodeIfPresent([String].self, forKey: .notes) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(activitySummary, forKey: .activitySummary)
        try c.encodeIfPresent(focusGuess, forKey: .focusGuess)
        try c.encode(reasonTags, forKey: .reasonTags)
        try c.encode(notes, forKey: .notes)
    }
}

nonisolated private struct PolicyDecisionEnvelope: Codable, Sendable {
    var assessment: ModelAssessment
    var suggestedAction: ModelSuggestedAction
    var confidence: Double?
    var reasonTags: [String]
    var nudge: String?
    var abstainReason: String?
    var overlayHeadline: String?
    var overlayBody: String?
    var overlayPrompt: String?
    var submitButtonTitle: String?
    var secondaryButtonTitle: String?

    enum CodingKeys: String, CodingKey {
        case assessment
        case suggestedAction = "suggested_action"
        case confidence
        case reasonTags = "reason_tags"
        case nudge
        case abstainReason = "abstain_reason"
        case overlayHeadline = "overlay_headline"
        case overlayBody = "overlay_body"
        case overlayPrompt = "overlay_prompt"
        case submitButtonTitle = "submit_button_title"
        case secondaryButtonTitle = "secondary_button_title"
    }

    var decision: LLMDecision {
        LLMDecision(
            assessment: assessment,
            suggestedAction: suggestedAction,
            confidence: confidence,
            reasonTags: reasonTags,
            nudge: nudge?.cleanedSingleLine,
            abstainReason: abstainReason?.cleanedSingleLine
        )
    }

    func overlayPresentation(
        appName: String,
        evaluationID: String
    ) -> OverlayPresentation {
        OverlayPresentation(
            headline: overlayHeadline?.cleanedSingleLine.isEmpty == false
                ? overlayHeadline!.cleanedSingleLine
                : "Pause for a second.",
            body: overlayBody?.cleanedSingleLine.isEmpty == false
                ? overlayBody!.cleanedSingleLine
                : "This still looks off-track in \(appName).",
            prompt: overlayPrompt?.cleanedSingleLine.isEmpty == false
                ? overlayPrompt!.cleanedSingleLine
                : "Why should I let you continue on this?",
            appName: appName,
            evaluationID: evaluationID,
            submitButtonTitle: submitButtonTitle?.cleanedSingleLine.isEmpty == false
                ? submitButtonTitle!.cleanedSingleLine
                : "Submit",
            secondaryButtonTitle: secondaryButtonTitle?.cleanedSingleLine.isEmpty == false
                ? secondaryButtonTitle!.cleanedSingleLine
                : "Back to work"
        )
    }
}

nonisolated private struct PolicyNudgeEnvelope: Codable, Sendable {
    var nudge: String?
}

nonisolated private struct PolicyAppealReviewEnvelope: Codable, Sendable {
    var decision: AppealReviewDecision
    var message: String

    var appealReviewResult: AppealReviewResult {
        AppealReviewResult(
            decision: decision,
            message: message.cleanedSingleLine
        )
    }
}

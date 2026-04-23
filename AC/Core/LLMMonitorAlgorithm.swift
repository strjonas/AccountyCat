//
//  LLMMonitorAlgorithm.swift
//  AC
//

import CryptoKit
import Foundation

final class LLMMonitorAlgorithm: MonitoringAlgorithm {
    let descriptor = MonitoringAlgorithmDescriptor(
        id: MonitoringConfiguration.currentLLMMonitorAlgorithmID,
        version: "1.0",
        displayName: "LLM Monitor",
        summary: "Current staged LLM monitor with structured policy memory, perception, decisions, and typed appeals."
    )

    private let runtime: LocalModelRuntime
    private let policyMemoryService: PolicyMemoryServicing
    private let stabilityWindow: TimeInterval = 6
    private let focusedFollowUp: TimeInterval = 10 * 60
    private let unclearFollowUp: TimeInterval = 2 * 60
    private let distractedFollowUp: TimeInterval = 45

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
        policyMemory: PolicyMemory,
        configuration: MonitoringConfiguration,
        now: Date
    ) -> MonitoringEvaluationPlan {
        let profile = LLMPolicyCatalog.pipelineProfile(id: configuration.pipelineProfileID)
        let matchingRules = policyMemory.activeRules(at: now, matching: context)
        let hasExplicitAllowRule = matchingRules.contains { $0.kind == .allow }
        let hasRestrictiveRule = matchingRules.contains {
            $0.kind == .disallow || $0.kind == .discourage || $0.kind == .limit
        }

        if !hasRestrictiveRule,
           ((heuristics.clearlyProductive && heuristics.browser == false) || hasExplicitAllowRule) {
            return MonitoringEvaluationPlan(
                shouldEvaluate: false,
                reason: hasExplicitAllowRule ? "explicit_allow_rule" : "obviously_productive",
                visualCheckReason: nil,
                requiresScreenshot: profile.descriptor.requiresScreenshot,
                promptMode: profile.descriptor.id,
                promptVersion: descriptor.version
            )
        }

        let distraction = state.llmPolicy.distraction
        let shouldEvaluate: Bool
        let reason: String

        if let nextEvaluationAt = distraction.nextEvaluationAt,
           now < nextEvaluationAt {
            shouldEvaluate = false
            reason = "scheduled_recheck"
        } else if distraction.lastAssessment == nil,
                  let stableSince = state.llmPolicy.currentContextEnteredAt {
            shouldEvaluate = now.timeIntervalSince(stableSince) >= stabilityWindow
            reason = "stable_context"
        } else if distraction.lastAssessment != nil {
            shouldEvaluate = true
            reason = "scheduled_recheck"
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
            promptProfileID: descriptor.id,
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
                    promptProfileID: descriptor.id,
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
        let compactAppName = input.snapshot.appName.truncatedForPrompt(maxLength: 80)
        let compactWindowTitle = input.snapshot.windowTitle?.truncatedForPrompt(
            maxLength: MonitoringPromptContextBudget.windowTitleCharacters
        )
        let compactSwitches = compactRecentSwitches(
            input.snapshot.recentSwitches,
            limit: MonitoringPromptContextBudget.decisionSwitchCount
        )
        let compactUsage = compactUsage(
            input.snapshot.perAppDurations,
            limit: MonitoringPromptContextBudget.decisionUsageCount
        )
        let compactInterventions = compactInterventionSummary(relevantActions)
        let policySummary = makePolicySummary(
            policyMemory: input.policyMemory,
            snapshot: input.snapshot,
            now: input.now
        )
        // `input.memory` is already pre-rendered with timestamps at the caller. We only
        // cap it to the byte budget (a last-resort guard — normally consolidation keeps it
        // under budget). No heuristic scoring or keyword filtering: AC decides what's relevant.
        let freeFormMemory = input.memory.truncatedMultilineForPrompt(
            maxLength: MonitoringPromptContextBudget.freeFormMemoryCharacters,
            maxLines: MonitoringPromptContextBudget.freeFormMemoryLines
        )
        let recentUserMessages = Self.compactRecentUserMessages(input.recentUserMessages)

        var titlePerception: MonitoringPerceptionEnvelope?
        if pipelineProfile.usesTitlePerception {
            titlePerception = await runTextStage(
                stage: .perceptionTitle,
                runtimePath: runtimePath,
                options: runtimeProfile.options(for: .perceptionTitle),
                payload: MonitoringTitlePerceptionPromptPayload(
                    appName: compactAppName,
                    bundleIdentifier: input.snapshot.bundleIdentifier,
                    windowTitle: compactWindowTitle,
                    recentSwitches: Array(compactSwitches.prefix(MonitoringPromptContextBudget.titlePerceptionSwitchCount)),
                    usage: Array(compactUsage.prefix(MonitoringPromptContextBudget.titlePerceptionUsageCount))
                ),
                attempts: &attempts,
                decoder: MonitoringPerceptionEnvelope.self
            )
        }

        var visionPerception: MonitoringPerceptionEnvelope?
        if pipelineProfile.usesVisionPerception,
           let screenshotPath = input.snapshot.screenshotPath {
            visionPerception = await runVisionStage(
                stage: .perceptionVision,
                runtimePath: runtimePath,
                snapshotPath: screenshotPath,
                options: runtimeProfile.options(for: .perceptionVision),
                payload: MonitoringVisionPerceptionPromptPayload(
                    appName: compactAppName,
                    windowTitle: compactWindowTitle
                ),
                attempts: &attempts,
                decoder: MonitoringPerceptionEnvelope.self
            )
        }

        let decisionEnvelope = await runTextStage(
            stage: .decision,
            runtimePath: runtimePath,
            options: runtimeProfile.options(for: .decision),
            payload: MonitoringDecisionPromptPayload(
                now: input.now,
                goals: input.goals.cleanedSingleLine.truncatedForPrompt(
                    maxLength: MonitoringPromptContextBudget.goalCharacters
                ),
                freeFormMemory: freeFormMemory,
                recentUserMessages: recentUserMessages,
                policySummary: policySummary,
                appName: compactAppName,
                bundleIdentifier: input.snapshot.bundleIdentifier,
                windowTitle: compactWindowTitle,
                recentSwitches: compactSwitches,
                usage: compactUsage,
                recentInterventions: compactInterventions,
                distraction: MonitoringPromptDistractionSummary(
                    state: input.algorithmState.llmPolicy.distraction.telemetryState
                ),
                titlePerception: titlePerception,
                visionPerception: visionPerception
            ),
            attempts: &attempts,
            decoder: MonitoringDecisionEnvelope.self
        )

        let effectiveDecisionEnvelope = decisionEnvelope ?? attempts.last?.parsedDecision.map(Self.makeDecisionEnvelope)
        var decision = effectiveDecisionEnvelope?.asLLMDecision ?? .unclear
        if pipelineProfile.splitCopyGeneration,
           decision.suggestedAction == ModelSuggestedAction.nudge {
            let nudgeEnvelope = await runTextStage(
                stage: .nudgeCopy,
                runtimePath: runtimePath,
                options: runtimeProfile.options(for: .nudgeCopy),
                payload: MonitoringNudgePromptPayload(
                    goals: input.goals.cleanedSingleLine.truncatedForPrompt(
                        maxLength: MonitoringPromptContextBudget.goalCharacters
                    ),
                    freeFormMemory: freeFormMemory,
                    recentUserMessages: recentUserMessages,
                    policySummary: policySummary,
                    appName: compactAppName,
                    windowTitle: compactWindowTitle,
                    titlePerception: titlePerception?.activitySummary,
                    visionPerception: visionPerception?.activitySummary,
                    recentNudges: Array(
                        input.algorithmState.llmPolicy.recentNudgeMessages
                            .prefix(MonitoringPromptContextBudget.recentNudgeCount)
                    )
                ),
                attempts: &attempts,
                decoder: MonitoringNudgeEnvelope.self
            )
            if let nudge = nudgeEnvelope?.nudge?.cleanedSingleLine,
               !nudge.isEmpty {
                decision.nudge = nudge
            }
        }

        let evaluation = LLMEvaluationResult(
            runtimePath: runtimePath,
            modelIdentifier: runtimeProfile.descriptor.modelIdentifier,
            promptProfileID: descriptor.id,
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
        case .focused:
            distraction.lastAssessment = .focused
            distraction.consecutiveDistractedCount = 0
            distraction.nextEvaluationAt = input.now.addingTimeInterval(focusedFollowUp)
            policyState.activeAppeal = nil
            action = .none
            blockReason = nil

        case .unclear:
            distraction.lastAssessment = .unclear
            distraction.consecutiveDistractedCount = 0
            distraction.nextEvaluationAt = input.now.addingTimeInterval(unclearFollowUp)
            policyState.activeAppeal = nil
            action = .none
            blockReason = "unclear_assessment"

        case .distracted:
            distraction.lastAssessment = .distracted
            distraction.consecutiveDistractedCount += 1
            distraction.nextEvaluationAt = input.now.addingTimeInterval(distractedFollowUp)

            switch decision.suggestedAction {
            case .overlay:
                let presentation = effectiveDecisionEnvelope?.asOverlayPresentation(
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

            case .nudge:
                if let nudge = decision.nudge?.cleanedSingleLine,
                   !nudge.isEmpty {
                    policyState.lastNudgeAt = input.now
                    policyState.lastInterventionAt = input.now
                    policyState.recentNudgeMessages.insert(nudge, at: 0)
                    policyState.recentNudgeMessages = Array(policyState.recentNudgeMessages.prefix(3))
                    action = .showNudge(nudge)
                    blockReason = nil
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
                    promptProfileID: descriptor.id,
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
            payload: MonitoringAppealPromptPayload(
                appealText: input.appealText,
                goals: input.goals.cleanedSingleLine.truncatedForPrompt(
                    maxLength: MonitoringPromptContextBudget.goalCharacters
                ),
                freeFormMemory: input.memory.truncatedMultilineForPrompt(
                    maxLength: MonitoringPromptContextBudget.freeFormMemoryCharacters,
                    maxLines: MonitoringPromptContextBudget.freeFormMemoryLines
                ),
                policySummary: makePolicySummary(
                    policyMemory: input.policyMemory,
                    snapshot: input.snapshot,
                    now: input.now
                ),
                snapshotAppName: input.snapshot?.appName,
                snapshotWindowTitle: input.snapshot?.windowTitle,
                assessment: input.algorithmState.llmPolicy.distraction.lastAssessment,
                suggestedAction: nil
            ),
            attempts: &attempts,
            decoder: MonitoringAppealEnvelope.self
        )

        let result = envelope?.asAppealReviewResult ?? AppealReviewResult(
            decision: .deferDecision,
            message: "I’m not sure yet. If it really helps your goals, explain a bit more."
        )
        let evaluation = LLMEvaluationResult(
            runtimePath: runtimePath,
            modelIdentifier: runtimeProfile.descriptor.modelIdentifier,
            promptProfileID: descriptor.id,
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
        return policyMemory
            .monitoringSummary(for: context, usageByDay: usageByDay, now: now, limit: 5)
            .truncatedMultilineForPrompt(
                maxLength: MonitoringPromptContextBudget.policySummaryCharacters,
                maxLines: MonitoringPromptContextBudget.policySummaryLines
            )
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
        StructuredOutputJSON.decode(type, from: output)
    }

    private static func sha256Hex(_ input: String) -> String {
        SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func compactRecentSwitches(
        _ records: [AppSwitchRecord],
        limit: Int
    ) -> [MonitoringPromptSwitchRecord] {
        records.prefix(limit).map {
            MonitoringPromptSwitchRecord(
                fromAppName: $0.fromAppName?.truncatedForPrompt(maxLength: 60),
                toAppName: $0.toAppName.truncatedForPrompt(maxLength: 60),
                toWindowTitle: $0.toWindowTitle?.truncatedForPrompt(maxLength: 140),
                timestamp: $0.timestamp
            )
        }
    }

    private func compactUsage(
        _ records: [AppUsageRecord],
        limit: Int
    ) -> [MonitoringPromptUsageRecord] {
        records.prefix(limit).map {
            MonitoringPromptUsageRecord(
                appName: $0.appName.truncatedForPrompt(maxLength: 60),
                seconds: $0.seconds
            )
        }
    }

    static func compactRecentUserMessages(_ messages: [String]) -> [String] {
        // Newest-first from the caller; take the last `recentUserChatCount` and render short.
        messages
            .map { $0.cleanedSingleLine }
            .filter { !$0.isEmpty }
            .prefix(MonitoringPromptContextBudget.recentUserChatCount)
            .map { $0.truncatedForPrompt(maxLength: MonitoringPromptContextBudget.recentUserChatCharacters) }
    }

    private func compactInterventionSummary(_ records: [ActionRecord]) -> MonitoringPromptInterventionSummary {
        let recentRelevant = records.prefix(MonitoringPromptContextBudget.recentNudgeCount)
        let recentNudges = recentRelevant
            .filter { $0.kind == .nudge }
            .compactMap { $0.message?.cleanedSingleLine }
            .filter { !$0.isEmpty }

        let lastAction = recentRelevant.first
        return MonitoringPromptInterventionSummary(
            recentNudges: recentNudges,
            lastActionKind: lastAction?.kind.rawValue,
            lastActionMessage: lastAction?.message?.truncatedForPrompt(maxLength: 120)
        )
    }

    private static func makeDecisionEnvelope(from decision: LLMDecision) -> MonitoringDecisionEnvelope {
        MonitoringDecisionEnvelope(
            assessment: decision.assessment,
            suggestedAction: decision.suggestedAction,
            confidence: decision.confidence,
            reasonTags: decision.reasonTags,
            nudge: decision.nudge,
            abstainReason: decision.abstainReason,
            overlayHeadline: nil,
            overlayBody: nil,
            overlayPrompt: nil,
            submitButtonTitle: nil,
            secondaryButtonTitle: nil
        )
    }
}

private extension MonitoringDecisionEnvelope {
    var asLLMDecision: LLMDecision {
        LLMDecision(
            assessment: assessment,
            suggestedAction: suggestedAction,
            confidence: confidence,
            reasonTags: reasonTags,
            nudge: nudge?.cleanedSingleLine,
            abstainReason: abstainReason?.cleanedSingleLine
        )
    }

    func asOverlayPresentation(
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

private extension MonitoringAppealEnvelope {
    var asAppealReviewResult: AppealReviewResult {
        let mappedDecision: AppealReviewDecision
        switch decision {
        case .allow:
            mappedDecision = .allow
        case .deny:
            mappedDecision = .deny
        case .deferDecision:
            mappedDecision = .deferDecision
        }

        return AppealReviewResult(
            decision: mappedDecision,
            message: message.cleanedSingleLine
        )
    }
}

//
//  LLMMonitorAlgorithm.swift
//  AC
//

import CryptoKit
import Foundation

struct MonitoringRequestScopeContext: Sendable, Equatable {
    var goals: String
    var freeFormMemory: String
    var recentUserMessages: [String]
    var policySummary: String
    var activeProfile: MonitoringActiveProfilePromptPayload

    init(input: MonitoringDecisionInput) {
        goals = input.goals.cleanedSingleLine.truncatedForPrompt(
            maxLength: MonitoringPromptContextBudget.goalCharacters
        )
        freeFormMemory = input.memory.truncatedMultilineForPrompt(
            maxLength: MonitoringPromptContextBudget.freeFormMemoryCharacters,
            maxLines: MonitoringPromptContextBudget.freeFormMemoryLines
        )
        recentUserMessages = LLMMonitorAlgorithm.compactRecentUserMessages(input.recentUserMessages)
        policySummary = LLMMonitorAlgorithm.makePolicySummary(
            policyMemory: input.policyMemory,
            snapshot: input.snapshot,
            now: input.now
        )
        activeProfile = MonitoringActiveProfilePromptPayload(
            id: input.activeProfileID,
            name: input.activeProfileName,
            isDefault: input.activeProfileID == PolicyRule.defaultProfileID,
            description: input.activeProfileDescription,
            expiresAt: input.activeProfileExpiresAt
        )
    }
}

final class LLMMonitorAlgorithm: MonitoringAlgorithm {
    let descriptor = MonitoringAlgorithmDescriptor(
        id: MonitoringConfiguration.currentLLMMonitorAlgorithmID,
        version: "1.0",
        displayName: "LLM Monitor",
        summary: "Current staged LLM monitor with structured policy memory, perception, decisions, and typed appeals."
    )

    private let runtime: LocalModelRuntime
    private let onlineModelService: any OnlineModelServing
    private let policyMemoryService: PolicyMemoryServicing
    private let safelistAppealService: any SafelistAppealEvaluating
    private let minimumDistractedConfidence = 0.60
    /// Re-using a recently-confirmed focused decision is OK only inside this window.
    /// Beyond it the user may have moved on within the same app, so re-evaluate.
    /// Keep the per-context decision cache bounded so state.json stays small.
    private let decisionCacheCapacity = 32
    /// Keep observation history bounded — evict by least recently seen.
    private let observationCapacity = 64

    init(
        runtime: LocalModelRuntime,
        onlineModelService: any OnlineModelServing,
        policyMemoryService: PolicyMemoryServicing,
        safelistAppealService: (any SafelistAppealEvaluating)? = nil
    ) {
        self.runtime = runtime
        self.onlineModelService = onlineModelService
        self.policyMemoryService = policyMemoryService
        self.safelistAppealService = safelistAppealService
            ?? SafelistAppealService(runtime: runtime, onlineModelService: onlineModelService)
    }

    func resetState(_ state: inout AlgorithmStateEnvelope) {
        state.llmPolicy = LLMPolicyAlgorithmState()
    }

    func resetTransientState(_ state: inout AlgorithmStateEnvelope) {
        state.llmPolicy.distraction = DistractionMetadata()
        state.llmPolicy.activeAppeal = nil
        state.llmPolicy.focusSignal = FocusSignalState()
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
        let canSkipScreenshot = MonitoringHeuristics.canRelyOnTitleAlone(
            bundleIdentifier: context.bundleIdentifier,
            appName: context.appName,
            windowTitle: context.windowTitle,
            isBrowser: heuristics.browser,
            titleLengthThreshold: configuration.titleLengthForTextOnly
        )
        let requiresScreenshot = profile.descriptor.requiresScreenshot && !canSkipScreenshot
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
                requiresScreenshot: requiresScreenshot,
                promptMode: profile.descriptor.id,
                promptVersion: descriptor.version
            )
        }

        // Per-context short-term cache: a recently-confirmed focused decision in the exact same
        // context can be reused, sparing the LLM call on rapid A→B→A switching.
        let contextKey = state.llmPolicy.currentContextKey
        if !hasRestrictiveRule,
           let key = contextKey,
           let cached = state.llmPolicy.decisionCacheByContext[key],
           cached.contextKey == key,
           cached.assessment == .focused,
           state.llmPolicy.distraction.lastAssessment == nil,
           now.timeIntervalSince(cached.decidedAt) < configuration.cadenceMode.focusedDecisionCacheTTL {
            return MonitoringEvaluationPlan(
                shouldEvaluate: false,
                reason: "cached_focused",
                visualCheckReason: nil,
                requiresScreenshot: requiresScreenshot,
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
            shouldEvaluate = now.timeIntervalSince(stableSince) >= configuration.cadenceMode.stableContextDelay
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
            requiresScreenshot: requiresScreenshot,
            promptMode: profile.descriptor.id,
            promptVersion: descriptor.version
        )
    }

    func distractionMetadata(from state: AlgorithmStateEnvelope) -> DistractionMetadata {
        state.llmPolicy.distraction
    }

    func evaluate(input: MonitoringDecisionInput) async -> MonitoringDecisionResult {
        let cadence = input.configuration.cadenceMode
        let runtimePath = RuntimeSetupService.normalizedRuntimePath(from: input.runtimeOverride)
        let pipelineProfile = LLMPolicyCatalog.pipelineProfile(id: input.configuration.pipelineProfileID)
        let runtimeProfile = LLMPolicyCatalog.runtimeProfile(id: input.configuration.runtimeProfileID)
        let usesOnlineInference = input.configuration.usesOnlineInference
        let effectiveModelIdentifier = selectedModelIdentifier(
            for: input.configuration,
            isTextOnly: !pipelineProfile.descriptor.requiresScreenshot
        )
        let runtimeLocation = usesOnlineInference ? OnlineModelService.endpointURLString : runtimePath
        let execution = MonitoringExecutionMetadata(
            algorithmID: descriptor.id,
            algorithmVersion: descriptor.version,
            promptProfileID: descriptor.id,
            pipelineProfileID: pipelineProfile.descriptor.id,
            runtimeProfileID: runtimeProfile.descriptor.id,
            experimentArm: input.configuration.experimentArm
        )

        if !usesOnlineInference && !FileManager.default.isExecutableFile(atPath: runtimePath) {
            return makeResult(
                input: input,
                execution: execution,
                evaluation: LLMEvaluationResult(
                    runtimePath: runtimeLocation,
                    modelIdentifier: effectiveModelIdentifier,
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
        let requestScope = MonitoringRequestScopeContext(input: input)
        let compactAppName = input.snapshot.appName.truncatedForPrompt(
            maxLength: MonitoringPromptContextBudget.appNameCharacters
        )
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
        if Self.hasActiveExplicitAllowanceOverride(
            snapshot: input.snapshot,
            now: input.now,
            recentUserMessages: requestScope.recentUserMessages,
            freeFormMemory: requestScope.freeFormMemory
        ) {
            var updatedState = input.algorithmState
            updatedState.llmPolicy.activeAppeal = nil
            updatedState.llmPolicy.distraction.contextKey = updatedState.llmPolicy.currentContextKey
            updatedState.llmPolicy.distraction.lastAssessment = .focused
            updatedState.llmPolicy.distraction.consecutiveDistractedCount = 0
            updatedState.llmPolicy.distraction.nextEvaluationAt = input.now.addingTimeInterval(cadence.focusedFollowUp)
            updatedState.llmPolicy.focusSignal.record(
                assessment: .focused,
                confidence: 1.0,
                at: input.now
            )

            let decision = LLMDecision(
                assessment: .focused,
                suggestedAction: .none,
                confidence: 1.0,
                reasonTags: ["recent_allow_override"],
                nudge: nil,
                abstainReason: nil
            )
            return makeResult(
                input: input,
                execution: execution,
                evaluation: LLMEvaluationResult(
                    runtimePath: runtimeLocation,
                    modelIdentifier: effectiveModelIdentifier,
                    promptProfileID: descriptor.id,
                    promptProfileVersion: descriptor.version,
                    attempts: [],
                    finalDecision: decision,
                    failureMessage: nil
                ),
                decision: decision,
                action: .none,
                updatedState: updatedState,
                blockReason: "recent_allow_override"
            )
        }

        var titlePerception: MonitoringPerceptionEnvelope?
        var visionPerception: MonitoringPerceptionEnvelope?
        let effectiveDecisionEnvelope: MonitoringDecisionEnvelope?
        var decision: LLMDecision

        if usesOnlineInference {
            let onlineDecisionEnvelope = await runOnlineDecisionStage(
                input: input,
                compactAppName: compactAppName,
                compactWindowTitle: compactWindowTitle,
                compactSwitches: compactSwitches,
                compactUsage: compactUsage,
                compactInterventions: compactInterventions,
                requestScope: requestScope,
                runtimeProfile: runtimeProfile,
                attempts: &attempts
            )
            effectiveDecisionEnvelope = onlineDecisionEnvelope ?? attempts.last?.parsedDecision.map(Self.makeDecisionEnvelope)
            decision = confidenceAdjustedDecision(effectiveDecisionEnvelope?.asLLMDecision ?? .unclear)
        } else {
            if pipelineProfile.usesTitlePerception {
                titlePerception = await runTextStage(
                    stage: .perceptionTitle,
                    runtimePath: runtimePath,
                    modelIdentifier: selectedModelIdentifier(for: input.configuration, isTextOnly: true),
                    configuration: input.configuration,
                    options: applyOverrides(runtimeProfile.options(for: .perceptionTitle), configuration: input.configuration),
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

            if pipelineProfile.usesVisionPerception,
               let screenshotPath = input.snapshot.screenshotPath {
                visionPerception = await runVisionStage(
                    stage: .perceptionVision,
                    runtimePath: runtimePath,
                    modelIdentifier: selectedModelIdentifier(for: input.configuration, isTextOnly: false),
                    configuration: input.configuration,
                    snapshotPath: screenshotPath,
                    options: applyOverrides(runtimeProfile.options(for: .perceptionVision), configuration: input.configuration),
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
                modelIdentifier: selectedModelIdentifier(for: input.configuration, isTextOnly: true),
                configuration: input.configuration,
                options: applyOverrides(runtimeProfile.options(for: .decision), configuration: input.configuration),
                payload: MonitoringDecisionPromptPayload(
                    now: input.now,
                    goals: requestScope.goals,
                    freeFormMemory: requestScope.freeFormMemory,
                    recentUserMessages: requestScope.recentUserMessages,
                    policySummary: requestScope.policySummary,
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
                    visionPerception: visionPerception,
                    calendarContext: input.calendarContext,
                    activeProfile: requestScope.activeProfile
                ),
                attempts: &attempts,
                decoder: MonitoringDecisionEnvelope.self
            )

            effectiveDecisionEnvelope = decisionEnvelope ?? attempts.last?.parsedDecision.map(Self.makeDecisionEnvelope)
            decision = confidenceAdjustedDecision(effectiveDecisionEnvelope?.asLLMDecision ?? .unclear)
            if pipelineProfile.splitCopyGeneration,
               decision.suggestedAction == ModelSuggestedAction.nudge {
                if let nudge = await generateNudgeCopy(
                    input: input,
                    runtimePath: runtimePath,
                    runtimeProfile: runtimeProfile,
                    titlePerception: titlePerception,
                    visionPerception: visionPerception,
                    requestScope: requestScope,
                    compactAppName: compactAppName,
                    compactWindowTitle: compactWindowTitle,
                    attempts: &attempts
                ) {
                    decision.nudge = nudge
                }
            }
        }

        // Free online models (and small local models) sometimes return
        // suggested_action="nudge" without filling the nudge field. One extra
        // focused nudge-copy call beats silently dropping to no-action.
        // Skipped when split-copy already attempted above for this evaluation.
        if decision.assessment == .distracted,
           decision.suggestedAction == ModelSuggestedAction.nudge,
           (decision.nudge?.cleanedSingleLine.isEmpty ?? true),
           !attempts.contains(where: { $0.promptMode == LLMPolicyStage.nudgeCopy.rawValue }) {
            if let nudge = await generateNudgeCopy(
                input: input,
                runtimePath: runtimePath,
                runtimeProfile: runtimeProfile,
                titlePerception: titlePerception,
                visionPerception: visionPerception,
                requestScope: requestScope,
                compactAppName: compactAppName,
                compactWindowTitle: compactWindowTitle,
                attempts: &attempts
            ) {
                decision.nudge = nudge
            }
        }

        let evaluation = LLMEvaluationResult(
            runtimePath: runtimeLocation,
            modelIdentifier: Self.resolvedModelIdentifier(from: attempts, fallback: effectiveModelIdentifier),
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
            distraction.nextEvaluationAt = input.now.addingTimeInterval(cadence.focusedFollowUp)
            policyState.activeAppeal = nil
            action = .none
            blockReason = nil

        case .unclear:
            distraction.lastAssessment = .unclear
            distraction.consecutiveDistractedCount = 0
            distraction.nextEvaluationAt = input.now.addingTimeInterval(cadence.unclearFollowUp)
            policyState.activeAppeal = nil
            action = .none
            blockReason = "unclear_assessment"

        case .distracted:
            distraction.lastAssessment = .distracted
            distraction.consecutiveDistractedCount += 1
            distraction.nextEvaluationAt = input.now.addingTimeInterval(cadence.distractedFollowUp)

            switch decision.suggestedAction {
            case .overlay:
                let isHard = shouldTriggerHardEscalation(input: input, distraction: distraction)
                let presentation = effectiveDecisionEnvelope?.asOverlayPresentation(
                    appName: input.snapshot.appName,
                    evaluationID: input.evaluationID
                ) ?? OverlayPresentation(
                    headline: "Pause for a second.",
                    body: "This still looks off-track in \(input.snapshot.appName).",
                    prompt: "This looks a bit off-track — what's going on?",
                    appName: input.snapshot.appName,
                    evaluationID: input.evaluationID,
                    submitButtonTitle: "Explain",
                    secondaryButtonTitle: "Back to work"
                )
                let finalPresentation = isHard
                    ? presentation.withHardEscalation
                    : presentation
                policyState.lastOverlayAt = input.now
                policyState.lastInterventionAt = input.now
                policyState.activeAppeal = MonitoringAppealSession(
                    evaluationID: input.evaluationID,
                    contextKey: distraction.contextKey ?? "unknown",
                    appName: input.snapshot.appName,
                    prompt: finalPresentation.prompt ?? "This looks a bit off-track — what's going on?",
                    createdAt: input.now,
                    lastSubmittedAt: nil,
                    lastResult: nil
                )
                action = .showOverlay(finalPresentation)
                blockReason = nil

            case .nudge:
                if shouldEscalateRepeatedNudgeToOverlay(
                    input: input,
                    relevantActions: relevantActions,
                    distraction: distraction,
                    decision: decision
                ) {
                    let isHard = shouldTriggerHardEscalation(input: input, distraction: distraction)
                    let basePresentation = OverlayPresentation.defaultRepeatedDistraction(
                        appName: input.snapshot.appName,
                        evaluationID: input.evaluationID
                    )
                    let presentation = isHard
                        ? basePresentation.withHardEscalation
                        : basePresentation
                    policyState.lastOverlayAt = input.now
                    policyState.lastInterventionAt = input.now
                    policyState.activeAppeal = MonitoringAppealSession(
                        evaluationID: input.evaluationID,
                        contextKey: distraction.contextKey ?? "unknown",
                        appName: input.snapshot.appName,
                        prompt: presentation.prompt ?? "This looks a bit off-track — what's going on?",
                        createdAt: input.now,
                        lastSubmittedAt: nil,
                        lastResult: nil
                    )
                    action = .showOverlay(presentation)
                    blockReason = isHard ? "repeated_nudge_hard_escalation" : "repeated_nudge_escalation"
                } else if let nudge = decision.nudge?.cleanedSingleLine,
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
        policyState.focusSignal.record(
            assessment: decision.assessment,
            confidence: decision.confidence,
            at: input.now
        )

        // Per-context decision cache (Optimization 2) — short-term reuse of focused outcomes.
        if let contextKey = policyState.currentContextKey {
            policyState.decisionCacheByContext[contextKey] = CachedDecision(
                assessment: decision.assessment,
                decidedAt: input.now,
                contextKey: contextKey
            )
            evictOldestDecisionCacheEntries(from: &policyState.decisionCacheByContext)
        }

        // Observation tracking + safelist auto-promotion / revocation (Optimization 1).
        let frontmost = FrontmostContext(
            bundleIdentifier: input.snapshot.bundleIdentifier,
            appName: input.snapshot.appName,
            windowTitle: input.snapshot.windowTitle
        )
        let isBrowser = MonitoringHeuristics.isBrowser(bundleIdentifier: frontmost.bundleIdentifier)
        let observationContext = SafelistPromotionPolicy.makeContext(
            from: frontmost,
            isBrowser: isBrowser,
            now: input.now
        )

        var policyMemoryUpdate: PolicyMemoryUpdateResponse?

        // Determine whether a user-issued (non-system) allow rule is currently active for this
        // context. If yes, any "focused" observations we record would be tainted — the user
        // explicitly granted a temporary window (e.g. "let me watch Instagram for 30 min") and
        // we must not let that accumulate toward safelist promotion.
        let activeRulesForObservation: [PolicyRule]
        if observationContext != nil {
            activeRulesForObservation = input.policyMemory.activeRules(
                at: input.now,
                matching: frontmost
            )
        } else {
            activeRulesForObservation = []
        }
        let hasUserGrantedAllow = activeRulesForObservation.contains {
            $0.kind == .allow && $0.source != .system
        }

        if let observationContext {
            switch decision.assessment {
            case .focused:
                // Skip recording when the "focused" outcome is gated by a temporary user-issued
                // allow (e.g. chat rule "let me watch Instagram for 30 min"). The rule will expire;
                // we must not let observations taken under it count toward promotion.
                guard !hasUserGrantedAllow else { break }

                var stat = policyState.focusedObservations[observationContext.fingerprint]
                    ?? FocusedObservationStat(
                        contextFingerprint: observationContext.fingerprint,
                        appName: observationContext.appName,
                        bundleIdentifier: observationContext.bundleIdentifier,
                        titleSignature: observationContext.titleSignature,
                        firstSeenAt: input.now,
                        lastSeenAt: input.now
                    )
                SafelistPromotionPolicy.recordFocused(
                    stat: &stat,
                    windowTitle: frontmost.windowTitle,
                    now: input.now,
                    dayKey: observationContext.dayKey
                )
                policyState.focusedObservations[observationContext.fingerprint] = stat
                evictLeastRecentObservations(from: &policyState.focusedObservations)

                if let update = await maybePromote(
                    stat: stat,
                    observation: observationContext,
                    frontmost: frontmost,
                    input: input,
                    requestScope: requestScope,
                    policyMemory: input.policyMemory,
                    policyState: &policyState
                ) {
                    policyMemoryUpdate = update
                }

            case .distracted:
                if var stat = policyState.focusedObservations[observationContext.fingerprint] {
                    stat.distractedCount += 1
                    stat.lastSeenAt = input.now
                    if let ruleID = stat.lastAutoAllowRuleID,
                       input.policyMemory.rules.contains(where: { $0.id == ruleID && $0.active }) {
                        // Revoke the auto-allow rule we previously issued for this fingerprint —
                        // the user being distracted contradicts the safelist promotion.
                        policyMemoryUpdate = PolicyMemoryUpdateResponse(operations: [
                            PolicyMemoryOperation(
                                type: .expireRule,
                                rule: nil,
                                ruleID: ruleID,
                                patch: nil,
                                reason: "auto_allow_revoked_by_distracted"
                            )
                        ])
                        stat.previousAutoAllowOutcome = .revokedByDistracted
                        stat.lastAutoAllowRuleID = nil
                    }
                    policyState.focusedObservations[observationContext.fingerprint] = stat
                }

            case .unclear:
                if var stat = policyState.focusedObservations[observationContext.fingerprint] {
                    stat.lastSeenAt = input.now
                    policyState.focusedObservations[observationContext.fingerprint] = stat
                }
            }
        }

        updatedState.llmPolicy = policyState

        return makeResult(
            input: input,
            execution: execution,
            evaluation: evaluation,
            decision: decision,
            action: action,
            updatedState: updatedState,
            blockReason: blockReason,
            policyMemoryUpdate: policyMemoryUpdate
        )
    }

    private func maybePromote(
        stat: FocusedObservationStat,
        observation: SafelistObservationContext,
        frontmost: FrontmostContext,
        input: MonitoringDecisionInput,
        requestScope: MonitoringRequestScopeContext,
        policyMemory: PolicyMemory,
        policyState: inout LLMPolicyAlgorithmState
    ) async -> PolicyMemoryUpdateResponse? {
        // Recover a stat that may have had a previously-issued auto-allow rule expire cleanly
        // since we last looked. If the recorded ruleID is no longer in the active rules and
        // wasn't revoked by a `.distracted`, treat it as expired clean.
        var workingStat = stat
        if let ruleID = workingStat.lastAutoAllowRuleID,
           !policyMemory.rules.contains(where: { $0.id == ruleID && $0.active }),
           workingStat.previousAutoAllowOutcome != .revokedByDistracted {
            workingStat.previousAutoAllowOutcome = .expiredClean
            workingStat.lastAutoAllowRuleID = nil
            policyState.focusedObservations[observation.fingerprint] = workingStat
        }

        let eligibility = SafelistPromotionPolicy.eligibility(
            for: workingStat,
            policyMemory: policyMemory,
            context: frontmost,
            now: input.now,
            inNamedProfile: input.activeProfileID != PolicyRule.defaultProfileID
        )
        guard case .eligible(let tier) = eligibility else {
            if case .ineligible(let reason) = eligibility {
                workingStat.lastPromotionOutcome = .ineligible
                workingStat.lastPromotionReason = reason
                workingStat.lastPromotionCheckedAt = input.now
                policyState.focusedObservations[observation.fingerprint] = workingStat
            }
            return nil
        }

        // Mark attempt time before the LLM call so a denial counts as a throttled attempt.
        workingStat.promotionAttemptedAt = input.now
        policyState.focusedObservations[observation.fingerprint] = workingStat

        guard let envelope = await safelistAppealService.runAppeal(
            observation: observation,
            sampleWindowTitles: workingStat.sampleWindowTitles,
            focusedCount: workingStat.focusedCount,
            distinctDays: workingStat.distinctDayCount,
            goals: requestScope.goals,
            freeFormMemory: requestScope.freeFormMemory,
            configuration: input.configuration,
            runtimeOverride: input.runtimeOverride,
            screenshotPath: visionEnabled(for: input.configuration) ? input.snapshot.screenshotPath : nil
        ) else {
            workingStat.lastPromotionOutcome = .error
            workingStat.lastPromotionReason = "Safelist appeal failed or returned invalid JSON."
            workingStat.lastPromotionCheckedAt = input.now
            policyState.focusedObservations[observation.fingerprint] = workingStat
            await ActivityLogService.shared.append(
                category: "safelist-promotion-denied",
                message: "\(observation.appName): appeal failed for \(observation.titleSignature ?? observation.fingerprint)"
            )
            return nil
        }

        guard envelope.approve else {
            workingStat.lastPromotionOutcome = .denied
            workingStat.lastPromotionReason = Self.cleanedPromotionReason(
                envelope.reason,
                fallback: "LLM denied safelist promotion."
            )
            workingStat.lastPromotionCheckedAt = input.now
            policyState.focusedObservations[observation.fingerprint] = workingStat
            await ActivityLogService.shared.append(
                category: "safelist-promotion-denied",
                message: "\(observation.appName): \(workingStat.lastPromotionReason ?? "denied")"
            )
            return nil
        }

        guard let rule = SafelistPromotionPolicy.buildRule(
            from: envelope,
            observation: observation,
            tier: tier,
            now: input.now
        ) else {
            workingStat.lastPromotionOutcome = .invalid
            workingStat.lastPromotionReason = Self.cleanedPromotionReason(
                envelope.reason,
                fallback: "LLM approved promotion, but returned an unsafe or invalid safelist scope."
            )
            workingStat.lastPromotionCheckedAt = input.now
            policyState.focusedObservations[observation.fingerprint] = workingStat
            await ActivityLogService.shared.append(
                category: "safelist-promotion-denied",
                message: "\(observation.appName): invalid scope for \(observation.titleSignature ?? observation.fingerprint)"
            )
            return nil
        }

        var stored = workingStat
        stored.lastAutoAllowRuleID = rule.id
        stored.previousAutoAllowOutcome = nil
        stored.lastPromotionOutcome = .approved
        stored.lastPromotionReason = Self.cleanedPromotionReason(
            envelope.reason,
            fallback: "Approved by safelist appeal."
        )
        stored.lastPromotionCheckedAt = input.now
        policyState.focusedObservations[observation.fingerprint] = stored

        await ActivityLogService.shared.append(
            category: "safelist-promotion",
            message: "auto-allowed \(observation.appName) (\(tier.rawValue), ttl=\(Int(tier.ttl))s)"
        )

        return PolicyMemoryUpdateResponse(operations: [
            PolicyMemoryOperation(
                type: .addRule,
                rule: rule,
                ruleID: nil,
                patch: nil,
                reason: "safelist_promotion_\(tier.rawValue)"
            )
        ])
    }

    private static func cleanedPromotionReason(_ reason: String?, fallback: String) -> String {
        let trimmed = reason?.cleanedSingleLine ?? ""
        return trimmed.isEmpty ? fallback : trimmed
    }

    private func evictOldestDecisionCacheEntries(from cache: inout [String: CachedDecision]) {
        guard cache.count > decisionCacheCapacity else { return }
        let sorted = cache.sorted { $0.value.decidedAt < $1.value.decidedAt }
        let removeCount = cache.count - decisionCacheCapacity
        for (key, _) in sorted.prefix(removeCount) {
            cache.removeValue(forKey: key)
        }
    }

    private func evictLeastRecentObservations(from observations: inout [String: FocusedObservationStat]) {
        guard observations.count > observationCapacity else { return }
        let sorted = observations.sorted { $0.value.lastSeenAt < $1.value.lastSeenAt }
        let removeCount = observations.count - observationCapacity
        for (key, _) in sorted.prefix(removeCount) {
            observations.removeValue(forKey: key)
        }
    }

    private func confidenceAdjustedDecision(_ decision: LLMDecision) -> LLMDecision {
        guard decision.assessment == .distracted else {
            return decision
        }

        let effectiveConfidence = decision.confidence ?? 0.75
        guard effectiveConfidence < minimumDistractedConfidence else {
            return decision
        }

        var tags = decision.reasonTags
        if !tags.contains("low_confidence_distracted") {
            tags.append("low_confidence_distracted")
        }
        return LLMDecision(
            assessment: .unclear,
            suggestedAction: .abstain,
            confidence: decision.confidence,
            reasonTags: tags,
            nudge: nil,
            abstainReason: "insufficient_distracted_confidence"
        )
    }

    func reviewAppeal(input: MonitoringAppealReviewInput) async -> MonitoringAppealReviewOutput? {
        let runtimePath = RuntimeSetupService.normalizedRuntimePath(from: input.runtimeOverride)
        let usesOnlineInference = input.configuration.usesOnlineInference
        let runtimeLocation = usesOnlineInference ? OnlineModelService.endpointURLString : runtimePath
        let runtimeProfile = LLMPolicyCatalog.runtimeProfile(id: input.configuration.runtimeProfileID)
        let effectiveModelIdentifier = selectedModelIdentifier(
            for: input.configuration,
            isTextOnly: true
        )

        if !usesOnlineInference && !FileManager.default.isExecutableFile(atPath: runtimePath) {
            return MonitoringAppealReviewOutput(
                result: AppealReviewResult(
                    decision: .deferDecision,
                    message: "I couldn't review that right now. Try again or head back to work."
                ),
                evaluation: LLMEvaluationResult(
                    runtimePath: runtimeLocation,
                    modelIdentifier: effectiveModelIdentifier,
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

        var attempts: [LLMEvaluationAttempt] = []
        let envelope = await runTextStage(
            stage: .appealReview,
            runtimePath: runtimePath,
            modelIdentifier: effectiveModelIdentifier,
            configuration: input.configuration,
            options: applyOverrides(runtimeProfile.options(for: .appealReview), configuration: input.configuration),
            payload: MonitoringAppealPromptPayload(
                appealText: input.appealText,
                goals: input.goals.cleanedSingleLine.truncatedForPrompt(
                    maxLength: MonitoringPromptContextBudget.goalCharacters
                ),
                freeFormMemory: input.memory.truncatedMultilineForPrompt(
                    maxLength: MonitoringPromptContextBudget.freeFormMemoryCharacters,
                    maxLines: MonitoringPromptContextBudget.freeFormMemoryLines
                ),
                policySummary: Self.makePolicySummary(
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
            runtimePath: runtimeLocation,
            modelIdentifier: Self.resolvedModelIdentifier(from: attempts, fallback: effectiveModelIdentifier),
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
                runtimeProfileID: input.configuration.runtimeProfileID,
                inferenceBackend: input.configuration.inferenceBackend,
                onlineModelIdentifier: input.configuration.onlineModelIdentifier,
                onlineTextModelIdentifier: input.configuration.onlineModelIdentifierText,
                localModelIdentifier: input.configuration.localModelIdentifierText,
                activeProfile: ProfilePromptSummary(
                    id: PolicyRule.defaultProfileID,
                    name: FocusProfile.defaultDisplayName,
                    isDefault: true
                ),
                availableProfiles: []
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
            updatedAlgorithmState.llmPolicy.distraction.nextEvaluationAt = input.now.addingTimeInterval(45)
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
        blockReason: String?,
        policyMemoryUpdate: PolicyMemoryUpdateResponse? = nil
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
                    distractionAfter: updatedState.llmPolicy.distraction.telemetryState,
                    activeProfileID: input.activeProfileID,
                    activeProfileName: input.activeProfileName
                )
            ),
            updatedAlgorithmState: updatedState,
            policyMemoryUpdate: policyMemoryUpdate
        )
    }

    static func makePolicySummary(
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

    private func runOnlineDecisionStage(
        input: MonitoringDecisionInput,
        compactAppName: String,
        compactWindowTitle: String?,
        compactSwitches: [MonitoringPromptSwitchRecord],
        compactUsage: [MonitoringPromptUsageRecord],
        compactInterventions: MonitoringPromptInterventionSummary,
        requestScope: MonitoringRequestScopeContext,
        runtimeProfile: MonitoringRuntimeProfile,
        attempts: inout [LLMEvaluationAttempt]
    ) async -> MonitoringDecisionEnvelope? {
        let payload = MonitoringOnlineDecisionPromptPayload(
            now: input.now,
            goals: requestScope.goals,
            freeFormMemory: requestScope.freeFormMemory,
            recentUserMessages: requestScope.recentUserMessages,
            policySummary: requestScope.policySummary,
            appName: compactAppName,
            bundleIdentifier: input.snapshot.bundleIdentifier,
            windowTitle: compactWindowTitle,
            recentSwitches: compactSwitches,
            usage: compactUsage,
            recentInterventions: compactInterventions,
            distraction: MonitoringPromptDistractionSummary(
                state: input.algorithmState.llmPolicy.distraction.telemetryState
            ),
            heuristics: MonitoringPromptHeuristicSummary(heuristics: input.heuristics),
            calendarContext: input.calendarContext,
            screenshotIncluded: input.snapshot.screenshotPath != nil && visionEnabled(for: input.configuration),
            activeProfile: requestScope.activeProfile
        )

        let screenshotPath = visionEnabled(for: input.configuration)
            ? input.snapshot.screenshotPath
            : nil

        if let screenshotPath {
            return await runVisionStage(
                stage: .onlineDecision,
                runtimePath: RuntimeSetupService.normalizedRuntimePath(from: input.runtimeOverride),
                modelIdentifier: selectedModelIdentifier(for: input.configuration, isTextOnly: false),
                configuration: input.configuration,
                snapshotPath: screenshotPath,
                options: applyOverrides(runtimeProfile.options(for: .onlineDecision), configuration: input.configuration),
                payload: payload,
                attempts: &attempts,
                decoder: MonitoringDecisionEnvelope.self,
                systemPromptPrefix: input.characterPersonalityPrefix
            )
        }

        return await runTextStage(
            stage: .onlineDecision,
            runtimePath: RuntimeSetupService.normalizedRuntimePath(from: input.runtimeOverride),
            modelIdentifier: selectedModelIdentifier(for: input.configuration, isTextOnly: true),
            configuration: input.configuration,
            options: applyOverrides(runtimeProfile.options(for: .onlineDecision), configuration: input.configuration),
            payload: payload,
            attempts: &attempts,
            decoder: MonitoringDecisionEnvelope.self,
            systemPromptPrefix: input.characterPersonalityPrefix
        )
    }

    private func visionEnabled(for configuration: MonitoringConfiguration) -> Bool {
        LLMPolicyCatalog.pipelineProfile(id: configuration.pipelineProfileID)
            .descriptor
            .requiresScreenshot
    }

    private func generateNudgeCopy(
        input: MonitoringDecisionInput,
        runtimePath: String,
        runtimeProfile: MonitoringRuntimeProfile,
        titlePerception: MonitoringPerceptionEnvelope?,
        visionPerception: MonitoringPerceptionEnvelope?,
        requestScope: MonitoringRequestScopeContext,
        compactAppName: String,
        compactWindowTitle: String?,
        attempts: inout [LLMEvaluationAttempt]
    ) async -> String? {
        let nudgeEnvelope = await runTextStage(
            stage: .nudgeCopy,
            runtimePath: runtimePath,
            modelIdentifier: selectedModelIdentifier(for: input.configuration, isTextOnly: true),
            configuration: input.configuration,
            options: applyOverrides(runtimeProfile.options(for: .nudgeCopy), configuration: input.configuration),
            payload: MonitoringNudgePromptPayload(
                goals: requestScope.goals,
                freeFormMemory: requestScope.freeFormMemory,
                recentUserMessages: requestScope.recentUserMessages,
                policySummary: requestScope.policySummary,
                appName: compactAppName,
                windowTitle: compactWindowTitle,
                titlePerception: titlePerception?.activitySummary,
                visionPerception: visionPerception?.activitySummary,
                recentNudges: Array(
                    input.algorithmState.llmPolicy.recentNudgeMessages
                        .prefix(MonitoringPromptContextBudget.recentNudgeCount)
                ),
                calendarContext: input.calendarContext,
                activeProfileName: input.activeProfileName
            ),
            attempts: &attempts,
            decoder: MonitoringNudgeEnvelope.self,
            systemPromptPrefix: input.characterPersonalityPrefix
        )
        guard let nudge = nudgeEnvelope?.nudge?.cleanedSingleLine, !nudge.isEmpty else {
            return nil
        }
        return nudge
    }

    private func runTextStage<T: Decodable & Sendable, P: Encodable>(
        stage: LLMPolicyStage,
        runtimePath: String,
        modelIdentifier: String,
        configuration: MonitoringConfiguration,
        options: RuntimeInferenceOptions,
        payload: P,
        attempts: inout [LLMEvaluationAttempt],
        decoder: T.Type,
        systemPromptPrefix: String = ""
    ) async -> T? {
        let payloadJSON = MonitoringLLMClient.encodePayload(payload)
        let promptStage = ACPromptStage(rawValue: stage.rawValue)!
        let baseSystemPrompt = ACPromptSets.systemPrompt(for: promptStage)
        let systemPrompt = systemPromptPrefix.isEmpty ? baseSystemPrompt : "\(systemPromptPrefix)\n\n\(baseSystemPrompt)"
        let userPrompt = ACPromptSets.renderUserPrompt(for: promptStage, payloadJSON: payloadJSON)
        // SHA256 is only used by verbose-telemetry artifact filenames (debug builds).
        // Skipping it saves ~0.5 ms per stage — trivial alone, but adds up across stages.
        let templateSHA = ACBuild.isDebug ? Self.sha256Hex(systemPrompt) : stage.rawValue

        let template = PromptTemplateRecord(
            id: "policy.\(stage.rawValue)",
            version: descriptor.version,
            sha256: templateSHA
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
                runtimeOptions: TelemetryRuntimeOptions(options, modelIdentifier: modelIdentifier),
                runtimeOutput: nil,
                parsedDecision: nil
            )
        )

        let startTime = Date()

        do {
            let output: RuntimeProcessOutput
            let runtimeLabel: String
            if configuration.usesOnlineInference {
                runtimeLabel = "openrouter"
                output = try await onlineModelService.runInference(
                    OnlineModelRequest(
                        source: .monitoringText,
                        modelIdentifier: modelIdentifier,
                        systemPrompt: systemPrompt,
                        userPrompt: userPrompt,
                        imagePath: nil,
                        options: options
                    )
                )
            } else {
                runtimeLabel = "llama.cpp"
                output = try await runtime.runTextInference(
                    runtimePath: runtimePath,
                    modelIdentifier: modelIdentifier,
                    systemPrompt: systemPrompt,
                    userPrompt: userPrompt,
                    options: options
                )
            }
            let elapsedMs = Int(Date().timeIntervalSince(startTime) * 1000)
            let servedModel = output.usedModelIdentifier ?? modelIdentifier
            let tokenSummary = output.tokenUsage.map { "\($0.promptTokens)p/\($0.completionTokens)c" } ?? "— tok"
            let stdoutPreview = output.stdout.cleanedSingleLine.truncatedForPrompt(maxLength: 400)

            await ActivityLogService.shared.append(level: .verbose, category: "llm:\(stage.rawValue)",
                message: "─── Request → \(runtimeLabel)/\(modelIdentifier) ───\n"
                    + "system: \(systemPrompt.cleanedSingleLine.truncatedForPrompt(maxLength: 2000))\n"
                    + "user: \(userPrompt.cleanedSingleLine.truncatedForPrompt(maxLength: 2000))"
            )
            await ActivityLogService.shared.append(level: .verbose, category: "llm:\(stage.rawValue)",
                message: "← \(runtimeLabel) · \(elapsedMs)ms · \(tokenSummary) · \(servedModel)\n"
                    + "stdout: \(stdoutPreview)"
            )

            attempts[attemptIndex].runtimeOutput = output
            if stage == .decision || stage == .onlineDecision {
                attempts[attemptIndex].parsedDecision = LLMOutputParsing.extractDecision(
                    from: output.stdout + "\n" + output.stderr
                )
            }
            return Self.decodeJSON(decoder, from: output.stdout + "\n" + output.stderr)
        } catch {
            let elapsedMs = Int(Date().timeIntervalSince(startTime) * 1000)
            await ActivityLogService.shared.append(level: .verbose, category: "llm:\(stage.rawValue)",
                message: "✗ \(configuration.usesOnlineInference ? "openrouter" : "llama.cpp") · \(elapsedMs)ms · error: \(error.localizedDescription)"
            )
            return nil
        }
    }

    private func runVisionStage<T: Decodable & Sendable, P: Encodable>(
        stage: LLMPolicyStage,
        runtimePath: String,
        modelIdentifier: String,
        configuration: MonitoringConfiguration,
        snapshotPath: String,
        options: RuntimeInferenceOptions,
        payload: P,
        attempts: inout [LLMEvaluationAttempt],
        decoder: T.Type,
        systemPromptPrefix: String = ""
    ) async -> T? {
        let payloadJSON = MonitoringLLMClient.encodePayload(payload)
        let promptStage = ACPromptStage(rawValue: stage.rawValue)!
        let baseSystemPrompt = ACPromptSets.systemPrompt(for: promptStage)
        let systemPrompt = systemPromptPrefix.isEmpty ? baseSystemPrompt : "\(systemPromptPrefix)\n\n\(baseSystemPrompt)"
        let userPrompt = ACPromptSets.renderUserPrompt(for: promptStage, payloadJSON: payloadJSON)

        let templateSHA = ACBuild.isDebug ? Self.sha256Hex(systemPrompt) : stage.rawValue
        let template = PromptTemplateRecord(
            id: "policy.\(stage.rawValue)",
            version: descriptor.version,
            sha256: templateSHA
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
                runtimeOptions: TelemetryRuntimeOptions(options, modelIdentifier: modelIdentifier),
                runtimeOutput: nil,
                parsedDecision: nil
            )
        )

        let startTime = Date()

        do {
            let output: RuntimeProcessOutput
            let runtimeLabel: String
            if configuration.usesOnlineInference {
                runtimeLabel = "openrouter"
                output = try await onlineModelService.runInference(
                    OnlineModelRequest(
                        source: .monitoringVision,
                        modelIdentifier: modelIdentifier,
                        systemPrompt: systemPrompt,
                        userPrompt: userPrompt,
                        imagePath: snapshotPath,
                        options: options
                    )
                )
            } else {
                runtimeLabel = "llama.cpp"
                output = try await runtime.runVisionInference(
                    runtimePath: runtimePath,
                    modelIdentifier: modelIdentifier,
                    snapshotPath: snapshotPath,
                    systemPrompt: systemPrompt,
                    userPrompt: userPrompt,
                    options: options
                )
            }
            let elapsedMs = Int(Date().timeIntervalSince(startTime) * 1000)
            let servedModel = output.usedModelIdentifier ?? modelIdentifier
            let tokenSummary = output.tokenUsage.map { "\($0.promptTokens)p/\($0.completionTokens)c" } ?? "— tok"
            let stdoutPreview = output.stdout.cleanedSingleLine.truncatedForPrompt(maxLength: 400)

            await ActivityLogService.shared.append(level: .verbose, category: "llm:\(stage.rawValue)",
                message: "─── Request → \(runtimeLabel)/\(modelIdentifier) ───\n"
                    + "system: \(systemPrompt.cleanedSingleLine.truncatedForPrompt(maxLength: 2000))\n"
                    + "user: \(userPrompt.cleanedSingleLine.truncatedForPrompt(maxLength: 2000))"
            )
            await ActivityLogService.shared.append(level: .verbose, category: "llm:\(stage.rawValue)",
                message: "← \(runtimeLabel) · \(elapsedMs)ms · \(tokenSummary) · \(servedModel)\n"
                    + "stdout: \(stdoutPreview)"
            )

            attempts[attemptIndex].runtimeOutput = output
            if stage == .onlineDecision {
                attempts[attemptIndex].parsedDecision = LLMOutputParsing.extractDecision(
                    from: output.stdout + "\n" + output.stderr
                )
            }
            return Self.decodeJSON(decoder, from: output.stdout + "\n" + output.stderr)
        } catch {
            let elapsedMs = Int(Date().timeIntervalSince(startTime) * 1000)
            await ActivityLogService.shared.append(level: .verbose, category: "llm:\(stage.rawValue)",
                message: "✗ \(configuration.usesOnlineInference ? "openrouter" : "llama.cpp") · \(elapsedMs)ms · error: \(error.localizedDescription)"
            )
            return nil
        }
    }

    private static func decodeJSON<T: Decodable>(
        _ type: T.Type,
        from output: String
    ) -> T? {
        StructuredOutputJSON.decode(type, from: output)
    }

    private func selectedModelIdentifier(
        for configuration: MonitoringConfiguration,
        isTextOnly: Bool
    ) -> String {
        if configuration.usesOnlineInference {
            if isTextOnly {
                return configuration.onlineModelIdentifierText
                    ?? configuration.onlineModelIdentifierImage
                    ?? configuration.onlineModelIdentifier
            }
            return configuration.onlineModelIdentifierImage
                ?? configuration.onlineModelIdentifierText
                ?? configuration.onlineModelIdentifier
        }

        if isTextOnly {
            return configuration.localModelIdentifierText
                ?? configuration.localModelIdentifierImage
                ?? AITier.balanced.localModelIdentifierText
        }
        return configuration.localModelIdentifierImage
            ?? configuration.localModelIdentifierText
            ?? AITier.balanced.localModelIdentifierImage
    }

    private func applyOverrides(
        _ opts: RuntimeInferenceOptions,
        configuration: MonitoringConfiguration
    ) -> RuntimeInferenceOptions {
        var result = opts
        result.thinkingEnabled = configuration.thinkingEnabled
        return result
    }

    private static func resolvedModelIdentifier(
        from attempts: [LLMEvaluationAttempt],
        fallback: String
    ) -> String {
        attempts
            .reversed()
            .compactMap { attempt in
                attempt.runtimeOutput?.usedModelIdentifier ?? attempt.runtimeOptions?.modelIdentifier
            }
            .first ?? fallback
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
        // Caller already passes the last few user messages oldest→newest; keep that order so
        // "newest wins" is visually obvious at the tail of the list.
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

    private func shouldEscalateRepeatedNudgeToOverlay(
        input: MonitoringDecisionInput,
        relevantActions: [ActionRecord],
        distraction: DistractionMetadata,
        decision: LLMDecision
    ) -> Bool {
        guard decision.assessment == .distracted,
              decision.suggestedAction == .nudge,
              (decision.confidence ?? 0.75) >= 0.75,
              input.algorithmState.llmPolicy.activeAppeal == nil else {
            return false
        }

        // Much shorter cooldown: only 3 minutes. If user keeps getting distracted after overlay,
        // they need escalation, not a long wait period.
        if let lastOverlayAt = input.algorithmState.llmPolicy.lastOverlayAt,
           input.now.timeIntervalSince(lastOverlayAt) < 3 * 60 {
            return false
        }

        // Escalate if already 2+ consecutive distractions in this context
        if distraction.consecutiveDistractedCount >= 2 {
            return true
        }

        // Escalate if 3+ recent nudges for the same context in 30 mins (was 2 before)
        let matchingRecentNudges = relevantActions
            .filter { $0.kind == .nudge }
            .filter { input.now.timeIntervalSince($0.timestamp) <= 30 * 60 }
            .filter { actionMentionsCurrentContext($0, snapshot: input.snapshot) }
            .count
        return matchingRecentNudges >= 3
    }

    private func shouldTriggerHardEscalation(
        input: MonitoringDecisionInput,
        distraction: DistractionMetadata
    ) -> Bool {
        // Hard escalation fires when we'd already escalate to overlay AND:
        // - 3+ consecutive distracted counts (user really won't stop), OR
        // - An overlay was already shown for this context (user ignored the gentler escalation)
        let hadPriorOverlay = input.algorithmState.llmPolicy.lastOverlayAt != nil

        // Check if the user ignored the last intervention (no feedback)
        let hasIgnoredIntervention = input.algorithmState.llmPolicy.activeAppeal == nil

        return distraction.consecutiveDistractedCount >= 3
            || (hadPriorOverlay && hasIgnoredIntervention)
    }

    private func actionMentionsCurrentContext(_ action: ActionRecord, snapshot: AppSnapshot) -> Bool {
        guard let message = action.message?.cleanedSingleLine.lowercased(),
              !message.isEmpty else {
            return false
        }

        let aliases = Self.contextAliases(for: snapshot)
        return aliases.contains { alias in
            alias.count > 1 && message.contains(alias)
        }
    }

    nonisolated private static func hasActiveExplicitAllowanceOverride(
        snapshot: AppSnapshot,
        now: Date,
        recentUserMessages: [String],
        freeFormMemory: String
    ) -> Bool {
        let recentDirectives = recentUserMessages.enumerated().compactMap { index, message in
            // If a caller passes plain chat text without a stamped prefix, synthesise
            // an ordering timestamp so newer chat lines still outrank older memory.
            let fallbackTimestamp = now.addingTimeInterval(-Double(max(recentUserMessages.count - index, 1)))
            return parseExplicitDirective(from: message, fallbackTimestamp: fallbackTimestamp)
        }
        let memoryDirectives = freeFormMemory
            .split(separator: "\n")
            .compactMap { parseExplicitDirective(from: String($0), fallbackTimestamp: nil) }
        let directives = recentDirectives + memoryDirectives

        let matchingAllows = directives
            .filter { $0.kind == .allow }
            .filter { $0.isActive(at: now) }
            .filter { directiveMatchesContext($0.target, snapshot: snapshot) }
            .sorted { $0.sourceTime > $1.sourceTime }
        guard let newestAllow = matchingAllows.first else { return false }

        let matchingBlocks = directives
            .filter { $0.kind == .block }
            .filter { $0.isActive(at: now) }
            .filter { directiveMatchesContext($0.target, snapshot: snapshot) }
            .sorted { $0.sourceTime > $1.sourceTime }

        guard let newestBlock = matchingBlocks.first else { return true }
        return newestAllow.sourceTime >= newestBlock.sourceTime
    }

    nonisolated private static func parseExplicitDirective(
        from line: String,
        fallbackTimestamp: Date?
    ) -> ExplicitDirective? {
        let trimmed = line.cleanedSingleLine
        let parsed = parseStampedLine(trimmed)
        let sourceTime = parsed?.timestamp ?? fallbackTimestamp
        let body = parsed?.body ?? trimmed
        guard let sourceTime else { return nil }
        let lowerBody = body.lowercased()

        if let absoluteAllow = parseAbsoluteDirective(
            body: body,
            lowerBody: lowerBody,
            separator: " is allowed until "
        ) {
            return ExplicitDirective(
                kind: .allow,
                target: absoluteAllow.target,
                sourceTime: sourceTime,
                expiresAt: absoluteAllow.expiresAt
            )
        }
        if let absoluteOkay = parseAbsoluteDirective(
            body: body,
            lowerBody: lowerBody,
            separator: " is okay until "
        ) {
            return ExplicitDirective(
                kind: .allow,
                target: absoluteOkay.target,
                sourceTime: sourceTime,
                expiresAt: absoluteOkay.expiresAt
            )
        }
        if let relativeAllow = parseRelativeAllowance(body: body, lowerBody: lowerBody, sourceTime: sourceTime) {
            return relativeAllow
        }
        if let simpleAllowTarget = parseSimpleAllowTarget(body: body, lowerBody: lowerBody) {
            return ExplicitDirective(
                kind: .allow,
                target: simpleAllowTarget,
                sourceTime: sourceTime,
                expiresAt: nil
            )
        }
        if let blockUntil = parseAbsoluteDirective(
            body: body,
            lowerBody: lowerBody,
            separator: "do not allow use of ",
            trailingSeparator: " until "
        ) {
            return ExplicitDirective(
                kind: .block,
                target: blockUntil.target,
                sourceTime: sourceTime,
                expiresAt: blockUntil.expiresAt
            )
        }
        if let blockUntil = parseAbsoluteDirective(
            body: body,
            lowerBody: lowerBody,
            separator: "do not allow ",
            trailingSeparator: " until "
        ) {
            return ExplicitDirective(
                kind: .block,
                target: blockUntil.target,
                sourceTime: sourceTime,
                expiresAt: blockUntil.expiresAt
            )
        }
        if let blockToday = parseTodayBlock(body: body, lowerBody: lowerBody, sourceTime: sourceTime) {
            return blockToday
        }
        if let simpleBlockTarget = parseSimpleBlockTarget(body: body, lowerBody: lowerBody) {
            return ExplicitDirective(
                kind: .block,
                target: simpleBlockTarget,
                sourceTime: sourceTime,
                expiresAt: nil
            )
        }

        return nil
    }

    nonisolated private static func parseSimpleAllowTarget(body: String, lowerBody: String) -> String? {
        if let target = parsePrefixedTarget(
            body: body,
            lowerBody: lowerBody,
            prefixes: ["allow ", "let me use "]
        ) {
            return target
        }

        let suffixes = [" is okay", " is allowed"]
        for suffix in suffixes where lowerBody.contains(suffix) {
            guard let range = lowerBody.range(of: suffix) else { continue }
            let target = body[..<range.lowerBound]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !target.isEmpty else { continue }
            return cleanedDirectiveTarget(target)
        }

        if let target = parseNoInterventionAllowTarget(body: body, lowerBody: lowerBody) {
            return target
        }

        return nil
    }

    nonisolated private static func parseNoInterventionAllowTarget(body: String, lowerBody: String) -> String? {
        let disturbPrefixes = [
            "do not disturb me on ",
            "don't disturb me on ",
            "dont disturb me on ",
            "do not distrub me on ",
            "don't distrub me on ",
            "dont distrub me on ",
        ]
        if let target = parsePrefixedTarget(body: body, lowerBody: lowerBody, prefixes: disturbPrefixes) {
            return target
        }

        let flagPrefixes = [
            "never again flag ",
            "never flag ",
            "do not flag ",
            "don't flag ",
            "dont flag ",
        ]
        for prefix in flagPrefixes where lowerBody.hasPrefix(prefix) {
            guard let suffixRange = lowerBody.range(of: " as a distraction"),
                  suffixRange.lowerBound > lowerBody.index(lowerBody.startIndex, offsetBy: prefix.count) else {
                continue
            }
            let startIndex = body.index(body.startIndex, offsetBy: prefix.count)
            let suffixOffset = lowerBody.distance(from: lowerBody.startIndex, to: suffixRange.lowerBound)
            let endIndex = body.index(body.startIndex, offsetBy: suffixOffset)
            let target = body[startIndex..<endIndex]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !target.isEmpty else { continue }
            return cleanedDirectiveTarget(target)
        }

        return nil
    }

    nonisolated private static func parseSimpleBlockTarget(body: String, lowerBody: String) -> String? {
        parsePrefixedTarget(
            body: body,
            lowerBody: lowerBody,
            prefixes: ["do not allow use of ", "do not allow ", "don't let me use ", "dont let me use "]
        )
    }

    nonisolated private static func parsePrefixedTarget(
        body: String,
        lowerBody: String,
        prefixes: [String]
    ) -> String? {
        for prefix in prefixes where lowerBody.hasPrefix(prefix) {
            let start = body.index(body.startIndex, offsetBy: prefix.count)
            let target = body[start...].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !target.isEmpty else { continue }
            return cleanedDirectiveTarget(target)
        }
        return nil
    }

    nonisolated private static func cleanedDirectiveTarget(_ text: String) -> String {
        var result = text
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        let lower = result.lowercased()
        for suffix in [" for now", " right now"] where lower.hasSuffix(suffix) {
            result = String(result.dropLast(suffix.count))
                .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            break
        }
        return result
    }

    nonisolated private static func parseStampedLine(_ line: String) -> (timestamp: Date, body: String)? {
        guard line.hasPrefix("["),
              let closingBracket = line.firstIndex(of: "]") else {
            return nil
        }
        let label = String(line[line.index(after: line.startIndex)..<closingBracket])
        let body = String(line[line.index(after: closingBracket)...]).trimmingCharacters(in: .whitespaces)
        guard !body.isEmpty,
              let timestamp = makeLocalPromptDateFormatter().date(from: label) else {
            return nil
        }
        return (timestamp, body)
    }

    nonisolated private static func parseAbsoluteDirective(
        body: String,
        lowerBody: String,
        separator: String
    ) -> (target: String, expiresAt: Date)? {
        guard let range = lowerBody.range(of: separator) else { return nil }
        let target = body[..<range.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        let timeText = body[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        guard !target.isEmpty,
              let expiresAt = makeLocalPromptDateFormatter().date(from: timeText) else {
            return nil
        }
        return (target, expiresAt)
    }

    nonisolated private static func parseAbsoluteDirective(
        body: String,
        lowerBody: String,
        separator: String,
        trailingSeparator: String
    ) -> (target: String, expiresAt: Date)? {
        guard let prefixRange = lowerBody.range(of: separator),
              prefixRange.lowerBound == lowerBody.startIndex,
              let trailingRange = lowerBody.range(of: trailingSeparator),
              trailingRange.lowerBound > prefixRange.upperBound else {
            return nil
        }
        let target = body[prefixRange.upperBound..<trailingRange.lowerBound]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let timeText = body[trailingRange.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        guard !target.isEmpty,
              let expiresAt = makeLocalPromptDateFormatter().date(from: timeText) else {
            return nil
        }
        return (target, expiresAt)
    }

    nonisolated private static func parseRelativeAllowance(
        body: String,
        lowerBody: String,
        sourceTime: Date
    ) -> ExplicitDirective? {
        if let range = lowerBody.range(of: " is okay for the next ") {
            let target = body[..<range.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
            let remainder = lowerBody[range.upperBound...]
            guard !target.isEmpty,
                  let duration = parseDuration(from: String(remainder)) else {
                return nil
            }
            return ExplicitDirective(
                kind: .allow,
                target: target,
                sourceTime: sourceTime,
                expiresAt: sourceTime.addingTimeInterval(duration.seconds)
            )
        }

        let prefixes = ["the next ", "for the next "]
        for prefix in prefixes where lowerBody.hasPrefix(prefix) {
            let remainder = String(lowerBody.dropFirst(prefix.count))
            guard let duration = parseDuration(from: remainder),
                  let okayRange = remainder.range(of: " is okay") else {
                continue
            }
            let targetStart = remainder.index(remainder.startIndex, offsetBy: duration.offset)
            let target = String(remainder[targetStart..<okayRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !target.isEmpty else { continue }
            return ExplicitDirective(
                kind: .allow,
                target: target,
                sourceTime: sourceTime,
                expiresAt: sourceTime.addingTimeInterval(duration.seconds)
            )
        }

        return nil
    }

    nonisolated private static func parseDuration(from text: String) -> (seconds: TimeInterval, offset: Int)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2,
              let amount = Double(parts[0]) else {
            return nil
        }
        let unit = String(parts[1]).lowercased()
        let seconds: TimeInterval
        if unit.hasPrefix("hour") {
            seconds = amount * 60 * 60
        } else if unit.hasPrefix("minute") {
            seconds = amount * 60
        } else {
            return nil
        }
        let prefix = "\(parts[0]) \(parts[1])"
        return (seconds, prefix.count + 1)
    }

    nonisolated private static func parseTodayBlock(
        body: String,
        lowerBody: String,
        sourceTime: Date
    ) -> ExplicitDirective? {
        let prefixes = ["do not allow use of ", "do not allow "]
        let hasTodaySuffix = lowerBody.hasSuffix(" today.") || lowerBody.hasSuffix(" today")
        for prefix in prefixes where lowerBody.hasPrefix(prefix) && hasTodaySuffix {
            let suffixLength = lowerBody.hasSuffix(" today.") ? " today.".count : " today".count
            let endIndex = body.index(body.endIndex, offsetBy: -suffixLength)
            let startIndex = body.index(body.startIndex, offsetBy: prefix.count)
            guard startIndex < endIndex else { continue }
            let target = body[startIndex..<endIndex].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !target.isEmpty else { continue }
            return ExplicitDirective(
                kind: .block,
                target: target,
                sourceTime: sourceTime,
                expiresAt: endOfDay(for: sourceTime)
            )
        }
        return nil
    }

    nonisolated private static func directiveMatchesContext(_ target: String, snapshot: AppSnapshot) -> Bool {
        let contextText = contextText(for: snapshot)
        let tokenSet = contextTokenSet(for: contextText)
        let aliases = targetAliases(for: target)

        for alias in aliases {
            if alias.count <= 1 {
                if tokenSet.contains(alias) {
                    return true
                }
            } else if tokenSet.contains(alias) || contextText.contains(alias) {
                return true
            }
        }

        return false
    }

    nonisolated private static func contextAliases(for snapshot: AppSnapshot) -> [String] {
        let contextText = contextText(for: snapshot)
        let tokenSet = contextTokenSet(for: contextText)
        var aliases = Set(tokenSet.filter { $0.count > 2 })

        if let host = snapshot.bundleIdentifier?.split(separator: ".").last {
            aliases.insert(String(host).lowercased())
        }
        if let windowTitle = snapshot.windowTitle {
            aliases.formUnion(targetAliases(for: windowTitle))
        }
        aliases.formUnion(targetAliases(for: snapshot.appName))

        return Array(aliases.filter { !$0.isEmpty })
    }

    nonisolated private static func contextText(for snapshot: AppSnapshot) -> String {
        [
            snapshot.appName,
            snapshot.windowTitle ?? "",
            snapshot.bundleIdentifier ?? "",
        ]
        .joined(separator: " ")
        .lowercased()
    }

    nonisolated private static func contextTokenSet(for contextText: String) -> Set<String> {
        Set(
            contextText.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                .map(String.init)
        )
    }

    nonisolated private static func targetAliases(for target: String) -> [String] {
        let lowered = target.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let sanitized = lowered.replacingOccurrences(
            of: #"[^a-z0-9.]+"#,
            with: " ",
            options: .regularExpression
        )
        let parts = sanitized.split(separator: " ").map(String.init)
        var aliases = Set(parts)

        if let domain = parts.first(where: { $0.contains(".") }),
           let root = domain.split(separator: ".").first {
            aliases.insert(String(root))
        }
        if !sanitized.isEmpty {
            aliases.insert(sanitized.replacingOccurrences(of: " ", with: ""))
        }
        return Array(aliases.filter { !$0.isEmpty })
    }

    nonisolated private static func endOfDay(for date: Date) -> Date? {
        let calendar = Calendar.current
        guard let startOfNextDay = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: date)) else {
            return nil
        }
        return startOfNextDay.addingTimeInterval(-60)
    }

    nonisolated private static func makeLocalPromptDateFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
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

private struct ExplicitDirective: Sendable {
    nonisolated enum Kind: Sendable {
        case allow
        case block
    }

    var kind: Kind
    var target: String
    var sourceTime: Date
    var expiresAt: Date?

    nonisolated func isActive(at now: Date) -> Bool {
        guard let expiresAt else { return true }
        return expiresAt >= now
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
                : "This looks a bit off-track — what's going on?",
            appName: appName,
            evaluationID: evaluationID,
            submitButtonTitle: submitButtonTitle?.cleanedSingleLine.isEmpty == false
                ? submitButtonTitle!.cleanedSingleLine
                : "Explain",
            secondaryButtonTitle: secondaryButtonTitle?.cleanedSingleLine.isEmpty == false
                ? secondaryButtonTitle!.cleanedSingleLine
                : "Back to work"
        )
    }
}

private extension OverlayPresentation {
    static func defaultRepeatedDistraction(
        appName: String,
        evaluationID: String
    ) -> OverlayPresentation {
        OverlayPresentation(
            headline: "Pause for a second.",
            body: "This still looks off-track in \(appName), even after a few nudges.",
            prompt: "This looks a bit off-track — what's going on?",
            appName: appName,
            evaluationID: evaluationID,
            submitButtonTitle: "Explain",
            secondaryButtonTitle: "Back to work"
        )
    }

    var withHardEscalation: OverlayPresentation {
        OverlayPresentation(
            headline: "I need to ask…",
            body: "Tell me why I should let you continue on \(appName). Does it really serve your goals?",
            prompt: "Explain why \(appName) is actually helping right now…",
            appName: appName,
            evaluationID: evaluationID,
            submitButtonTitle: "Submit",
            secondaryButtonTitle: "Back to work",
            isHardEscalation: true
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

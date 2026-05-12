//
//  BrainService+Telemetry.swift
//  AC
//

import Foundation

@MainActor
extension BrainService {
    func shouldPersistVerboseTelemetry(state: ACState? = nil) -> Bool {
        let resolvedState = state ?? stateProvider?()
        guard let resolvedState else {
            return false
        }
        return TelemetryPersistencePolicy.storesVerboseTelemetry(debugMode: resolvedState.debugMode)
    }

    func appendObservationEvent(
        context: FrontmostContext,
        state: ACState,
        idleSeconds: TimeInterval,
        heuristics: TelemetryHeuristicSnapshot,
        shouldEvaluateNow: Bool,
        transition: ObservationTransition,
        endReason: EpisodeEndReason?
    ) async {
        guard shouldPersistVerboseTelemetry(state: state) else {
            return
        }
        guard let sessionID = try? await telemetryStore.ensureCurrentSession(reason: "runtime").id else {
            return
        }

        let event = TelemetryEvent(
            id: UUID().uuidString,
            kind: .observation,
            timestamp: Date(),
            sessionID: sessionID,
            episodeID: activeEpisode?.id,
            episode: activeEpisode,
            session: nil,
            observation: ObservationRecord(
                context: context.telemetryContext(
                    idleSeconds: idleSeconds,
                    recentSwitches: recentSwitches,
                    perAppDurations: currentUsageRecords(from: state, now: Date()),
                    recentActions: state.recentActions,
                    timestamp: Date()
                ),
                heuristics: heuristics,
                distraction: currentDistractionMetadata(from: state).telemetryState,
                visualCheckReason: heuristics.periodicVisualReason,
                shouldEvaluateNow: shouldEvaluateNow,
                transition: transition,
                endReason: endReason
            ),
            evaluation: nil,
            modelInput: nil,
            modelOutput: nil,
            parsedOutput: nil,
            policy: nil,
            action: nil,
            reaction: nil,
            annotation: nil,
            failure: nil
        )

        try? await telemetryStore.appendEvent(event, sessionID: sessionID)
    }

    func appendEvaluationRequestedEvent(
        sessionID: String?,
        evaluationID: String,
        episode: EpisodeRecord?,
        reason: String,
        promptMode: String,
        promptVersion: String,
        execution: MonitoringExecutionMetadata,
        activeProfile: FocusProfile
    ) async {
        guard shouldPersistVerboseTelemetry() else { return }
        guard let sessionID else { return }
        try? await telemetryStore.appendEvent(
            TelemetryEvent(
                id: UUID().uuidString,
                kind: .evaluationRequested,
                timestamp: Date(),
                sessionID: sessionID,
                episodeID: episode?.id,
                episode: episode,
                session: nil,
                observation: nil,
                evaluation: EvaluationRequestRecord(
                    evaluationID: evaluationID,
                    reason: reason,
                    promptMode: promptMode,
                    promptVersion: promptVersion,
                    strategy: execution.telemetryRecord,
                    activeProfileID: activeProfile.id,
                    activeProfileName: activeProfile.name
                ),
                modelInput: nil,
                modelOutput: nil,
                parsedOutput: nil,
                policy: nil,
                action: nil,
                reaction: nil,
                annotation: nil,
                failure: nil
            ),
            sessionID: sessionID
        )
    }

    func appendEvaluationArtifacts(
        _ evaluation: LLMEvaluationResult,
        evaluationID: String,
        sessionID: String?,
        episode: EpisodeRecord?,
        snapshot: AppSnapshot,
        state: ACState,
        heuristics: TelemetryHeuristicSnapshot,
        distraction: DistractionMetadata
    ) async {
        guard shouldPersistVerboseTelemetry(state: state) else { return }
        guard let sessionID else { return }

        let contextRecord = TelemetryContextRecord(
            bundleIdentifier: snapshot.bundleIdentifier,
            appName: snapshot.appName,
            windowTitle: snapshot.windowTitle,
            contextKey: [snapshot.bundleIdentifier ?? "unknown", snapshot.windowTitle?.normalizedForContextKey ?? ""].joined(separator: "|"),
            idleSeconds: SnapshotService.idleSeconds(),
            recentSwitches: snapshot.recentSwitches.map(\.telemetryRecord),
            perAppDurations: snapshot.perAppDurations.map(\.telemetryRecord),
            recentActions: state.recentActions.map(\.telemetrySummary),
            timestamp: snapshot.timestamp
        )

        for attempt in evaluation.attempts {
            let templateArtifact = try? await telemetryStore.writePromptTemplateArtifact(
                contents: attempt.templateContents,
                sessionID: sessionID,
                template: attempt.template
            )
            let payloadArtifact = try? await telemetryStore.writeTextArtifact(
                attempt.payloadJSON,
                sessionID: sessionID,
                prefix: "eval-\(evaluationID)-payload-\(attempt.promptMode)",
                kind: .promptPayload
            )
            let renderedPromptArtifact = try? await telemetryStore.writeTextArtifact(
                attempt.renderedPrompt,
                sessionID: sessionID,
                prefix: "eval-\(evaluationID)-prompt-\(attempt.promptMode)",
                kind: .renderedPrompt
            )

            try? await telemetryStore.appendEvent(
                TelemetryEvent(
                    id: UUID().uuidString,
                    kind: .modelInputSaved,
                    timestamp: Date(),
                    sessionID: sessionID,
                    episodeID: episode?.id,
                    episode: episode,
                    session: nil,
                    observation: nil,
                    evaluation: nil,
                    modelInput: ModelInputRecord(
                        evaluationID: evaluationID,
                        goalsSummary: state.goalsText.cleanedSingleLine,
                        screenshot: snapshot.screenshotArtifact,
                        screenshotThumbnail: snapshot.screenshotThumbnail,
                        promptMode: attempt.promptMode,
                        promptTemplate: attempt.template,
                        promptTemplateArtifact: templateArtifact,
                        promptPayloadArtifact: payloadArtifact,
                        renderedPromptArtifact: renderedPromptArtifact,
                        context: contextRecord,
                        heuristics: heuristics,
                        distraction: distraction.telemetryState
                    ),
                    modelOutput: nil,
                    parsedOutput: nil,
                    policy: nil,
                    action: nil,
                    reaction: nil,
                    annotation: nil,
                    failure: nil
                ),
                sessionID: sessionID
            )

            if let output = attempt.runtimeOutput {
                let stdoutArtifact = output.stdout.isEmpty ? nil : try? await telemetryStore.writeTextArtifact(
                    output.stdout,
                    sessionID: sessionID,
                    prefix: "eval-\(evaluationID)-stdout-\(attempt.promptMode)",
                    kind: .rawStdout
                )
                let stderrArtifact = output.stderr.isEmpty ? nil : try? await telemetryStore.writeTextArtifact(
                    output.stderr,
                    sessionID: sessionID,
                    prefix: "eval-\(evaluationID)-stderr-\(attempt.promptMode)",
                    kind: .rawStderr
                )

                try? await telemetryStore.appendEvent(
                    TelemetryEvent(
                        id: UUID().uuidString,
                        kind: .modelOutputReceived,
                        timestamp: Date(),
                        sessionID: sessionID,
                        episodeID: episode?.id,
                        episode: episode,
                        session: nil,
                        observation: nil,
                        evaluation: nil,
                        modelInput: nil,
                        modelOutput: ModelOutputRecord(
                            evaluationID: evaluationID,
                            runtimePath: evaluation.runtimePath,
                            modelIdentifier: evaluation.modelIdentifier,
                            promptMode: attempt.promptMode,
                            runtimeOptions: attempt.runtimeOptions,
                            stdoutArtifact: stdoutArtifact,
                            stderrArtifact: stderrArtifact,
                            stdoutPreview: output.stdout.cleanedSingleLine.prefix(220).description,
                            stderrPreview: output.stderr.cleanedSingleLine.prefix(220).description,
                            tokenUsage: output.tokenUsage.map { usage in
                                TokenUsageRecord(
                                    promptTokens: usage.promptTokens,
                                    completionTokens: usage.completionTokens,
                                    totalTokens: usage.totalTokens,
                                    cacheReadTokens: usage.cacheReadTokens,
                                    imageTokens: usage.imageTokens,
                                    costUSD: usage.costUSD,
                                    estimated: usage.estimated,
                                    includesScreenshot: snapshot.screenshotArtifact != nil
                                )
                            }
                        ),
                        parsedOutput: nil,
                        policy: nil,
                        action: nil,
                        reaction: nil,
                        annotation: nil,
                        failure: nil
                    ),
                    sessionID: sessionID
                )
            }

            if let parsedDecision = attempt.parsedDecision {
                try? await telemetryStore.appendEvent(
                    TelemetryEvent(
                        id: UUID().uuidString,
                        kind: .modelOutputParsed,
                        timestamp: Date(),
                        sessionID: sessionID,
                        episodeID: episode?.id,
                        episode: episode,
                        session: nil,
                        observation: nil,
                        evaluation: nil,
                        modelInput: nil,
                        modelOutput: nil,
                        parsedOutput: parsedDecision.parsedRecord,
                        policy: nil,
                        action: nil,
                        reaction: nil,
                        annotation: nil,
                        failure: nil
                    ),
                    sessionID: sessionID
                )
            }
        }

        if let failureMessage = evaluation.failureMessage {
            await appendFailureIfNeeded(
                domain: "llm",
                message: failureMessage,
                evaluationID: evaluationID,
                episode: episode
            )
        }
    }

    func appendPolicyDecisionEvent(
        sessionID: String?,
        episode: EpisodeRecord?,
        policy: PolicyDecisionRecord
    ) async {
        guard shouldPersistVerboseTelemetry() else { return }
        guard let sessionID else { return }
        try? await telemetryStore.appendEvent(
            TelemetryEvent(
                id: UUID().uuidString,
                kind: .policyDecided,
                timestamp: Date(),
                sessionID: sessionID,
                episodeID: episode?.id,
                episode: episode,
                session: nil,
                observation: nil,
                evaluation: nil,
                modelInput: nil,
                modelOutput: nil,
                parsedOutput: nil,
                policy: policy,
                action: nil,
                reaction: nil,
                annotation: nil,
                failure: nil
            ),
            sessionID: sessionID
        )
    }

    func appendActionExecutedEvent(
        sessionID: String?,
        episode: EpisodeRecord?,
        evaluationID: String,
        action: CompanionAction,
        execution: MonitoringExecutionMetadata
    ) async {
        guard shouldPersistVerboseTelemetry() else { return }
        guard let sessionID else { return }
        guard action != .none else { return }
        try? await telemetryStore.appendEvent(
            TelemetryEvent(
                id: UUID().uuidString,
                kind: .actionExecuted,
                timestamp: Date(),
                sessionID: sessionID,
                episodeID: episode?.id,
                episode: episode,
                session: nil,
                observation: nil,
                evaluation: nil,
                modelInput: nil,
                modelOutput: nil,
                parsedOutput: nil,
                policy: nil,
                action: ActionExecutionRecord(
                    evaluationID: evaluationID,
                    strategy: execution.telemetryRecord,
                    action: CompanionPolicy.telemetryActionRecord(for: action),
                    source: "policy",
                    succeeded: true
                ),
                reaction: nil,
                annotation: nil,
                failure: nil
            ),
            sessionID: sessionID
        )
    }

    func recordImplicitReaction(_ reaction: UserReactionRecord, at now: Date) async {
        guard shouldPersistVerboseTelemetry() else {
            return
        }
        guard let sessionID = try? await telemetryStore.ensureCurrentSession(reason: "runtime").id else {
            return
        }

        try? await telemetryStore.appendEvent(
            TelemetryEvent(
                id: UUID().uuidString,
                kind: .userReaction,
                timestamp: now,
                sessionID: sessionID,
                episodeID: activeEpisode?.id,
                episode: activeEpisode,
                session: nil,
                observation: nil,
                evaluation: nil,
                modelInput: nil,
                modelOutput: nil,
                parsedOutput: nil,
                policy: nil,
                action: nil,
                reaction: reaction,
                annotation: nil,
                failure: nil
            ),
            sessionID: sessionID
        )
    }

    func resolvePendingReactionIfNeeded(now: Date, context: FrontmostContext) async {
        let expiredReactions = pendingReactionsByEvaluationID.values
            .filter {
                now.timeIntervalSince($0.issuedAt) > 150
                && context.contextKey == $0.sourceContextKey
            }
            .sorted { $0.issuedAt < $1.issuedAt }

        for pendingReaction in expiredReactions {
            await recordImplicitReaction(
                UserReactionRecord(
                    kind: .nudgeIgnored,
                    relatedAction: CompanionPolicy.telemetryActionRecord(for: pendingReaction.action),
                    positive: false,
                    details: context.appName
                ),
                at: now
            )
            pendingReactionsByEvaluationID.removeValue(forKey: pendingReaction.evaluationID)
        }
    }

    func appendFailureIfNeeded(
        domain: String,
        message: String,
        evaluationID: String?,
        episode: EpisodeRecord? = nil
    ) async {
        guard shouldPersistVerboseTelemetry() else {
            return
        }
        guard let sessionID = try? await telemetryStore.ensureCurrentSession(reason: "runtime").id else {
            return
        }
        let resolvedEpisode = episode ?? activeEpisode
        try? await telemetryStore.appendEvent(
            TelemetryEvent(
                id: UUID().uuidString,
                kind: .failure,
                timestamp: Date(),
                sessionID: sessionID,
                episodeID: resolvedEpisode?.id,
                episode: resolvedEpisode,
                session: nil,
                observation: nil,
                evaluation: nil,
                modelInput: nil,
                modelOutput: nil,
                parsedOutput: nil,
                policy: nil,
                action: nil,
                reaction: nil,
                annotation: nil,
                failure: FailureRecord(domain: domain, message: message, evaluationID: evaluationID)
            ),
            sessionID: sessionID
        )
    }

    func appendMonitoringMetric(
        kind: MonitoringMetricKind,
        reason: String,
        state: ACState,
        detail: String? = nil
    ) async {
        guard shouldPersistVerboseTelemetry(state: state) else {
            return
        }
        guard let sessionID = try? await telemetryStore.ensureCurrentSession(reason: "runtime").id else {
            return
        }
        let active = state.activeProfile
        try? await telemetryStore.appendEvent(
            TelemetryEvent(
                id: UUID().uuidString,
                kind: .monitoringMetric,
                timestamp: Date(),
                sessionID: sessionID,
                episodeID: activeEpisode?.id,
                episode: activeEpisode,
                session: nil,
                observation: nil,
                evaluation: nil,
                modelInput: nil,
                modelOutput: nil,
                parsedOutput: nil,
                policy: nil,
                action: nil,
                metric: MonitoringMetricRecord(
                    kind: kind,
                    reason: reason,
                    activeProfileID: active.id,
                    activeProfileName: active.name,
                    detail: detail
                ),
                reaction: nil,
                annotation: nil,
                failure: nil
            ),
            sessionID: sessionID
        )
    }

    func currentUsageRecords(from state: ACState, now: Date) -> [AppUsageRecord] {
        let dayUsage = state.usageByDay[now.acDayKey] ?? [:]
        return dayUsage
            .map { AppUsageRecord(appName: $0.key, seconds: $0.value) }
            .sorted { $0.seconds > $1.seconds }
    }

    func currentDistractionMetadata(from state: ACState) -> DistractionMetadata {
        (try? monitoringAlgorithmRegistry.distractionMetadata(
            configuration: state.monitoringConfiguration,
            state: state.algorithmState
        )) ?? DistractionMetadata()
    }
}

//
//  AppController+ConversationLearning.swift
//  AC
//

import Foundation

@MainActor
extension AppController {
    func clearChatHistory() {
        chatMessages = Self.makeChatMessages(from: [])
        persistState()
        logActivity("chat", "Chat history cleared")
    }

    @discardableResult
    func deleteChatMessage(id: UUID) -> (message: ChatMessage, index: Int)? {
        guard let index = chatMessages.firstIndex(where: { $0.id == id && $0.role != .system }) else {
            return nil
        }
        let removed = chatMessages.remove(at: index)
        persistState()
        logActivity("chat", "Deleted chat message (\(removed.role.rawValue))")
        return (removed, index)
    }

    func restoreChatMessage(_ message: ChatMessage, at index: Int) {
        guard message.role != .system else { return }
        let clampedIndex = min(max(1, index), chatMessages.count)
        chatMessages.insert(message, at: clampedIndex)
        persistState()
        logActivity("chat", "Restored chat message (\(message.role.rawValue))")
    }

    func clearMemory() {
        state.memoryEntries = []
        state.lastMemoryConsolidationAt = nil
        state.policyMemory = PolicyMemory()
        persistState()
        logActivity("memory", "Memory cleared")
    }

    func deleteMemoryEntry(id: UUID) {
        state.memoryEntries.removeAll { $0.id == id }
        persistState()
    }

    func toggleMemoryEntryLocked(id: UUID) {
        guard let index = state.memoryEntries.firstIndex(where: { $0.id == id }) else { return }
        state.memoryEntries[index].isLocked.toggle()
        persistState()
        logActivity("memory", "Toggled lock for memory entry \(id)")
    }

    func addMemoryEntry(text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        state.memoryEntries.insert(MemoryEntry(text: trimmed), at: 0)
        persistState()
        logActivity("memory", "Added memory entry")
    }

    var canConsolidateMemory: Bool {
        guard !state.memoryEntries.isEmpty,
              state.setupStatus == .ready,
              !consolidatingMemory else {
            return false
        }
        // Online mode does not need a local runtime to consolidate; the call
        // routes through OpenRouter.
        return state.monitoringConfiguration.usesOnlineInference || setupDiagnostics.runtimePresent
    }

    func consolidateMemoryNow() {
        guard !state.memoryEntries.isEmpty else { return }
        guard state.setupStatus == .ready else {
            setupErrorMessage = "Finish setup before AC can run memory consolidation."
            return
        }
        if !state.monitoringConfiguration.usesOnlineInference, !setupDiagnostics.runtimePresent {
            setupErrorMessage = "Install the local runtime first, or switch to online mode."
            return
        }
        startMemoryConsolidation(now: Date(), reason: "manual")
    }

    func sendChatMessage(_ draft: String) {
        let trimmedDraft = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedDraft.isEmpty, !sendingChatMessage else { return }

        chatMessages.append(ChatMessage(role: .user, text: trimmedDraft))
        persistState()
        sendingChatMessage = true
        logActivity("chat", "User: \(trimmedDraft)")

        if AppControllerChatSupport.looksLikeNegativeChatFeedback(trimmedDraft) {
            brainService?.recordUserReaction(
                UserReactionRecord(
                    kind: .negativeChatFeedback,
                    relatedAction: nil,
                    positive: false,
                    details: trimmedDraft.cleanedSingleLine
                )
            )
            appendMemoryLine("• User disliked AC behavior: \"\(trimmedDraft.cleanedSingleLine)\"", notify: false)
        }
        if let correctionMatch = distractionCorrectionMatch(for: trimmedDraft) {
            recordDistractionCorrection(trimmedDraft, match: correctionMatch)
        }
        if AppControllerChatSupport.looksLikeImmediateMonitoringAllowance(trimmedDraft) {
            recordImmediateMonitoringAllowance(trimmedDraft)
        }

        let cappedDraft = AppControllerChatSupport.cappedChatText(
            trimmedDraft,
            limit: AppControllerChatSupport.maxChatMessageLength
        )

        // Rolling context window: last N non-system messages
        let historyWindow = chatMessages
            .filter { $0.role != .system }
            .suffix(Self.chatContextWindow)
            .dropLast()  // exclude the message we just appended (it's the userMessage arg)
            .map { $0 }
        let cappedHistory = historyWindow.map {
            AppControllerChatSupport.cappedMessageForContext(
                $0,
                limit: AppControllerChatSupport.maxChatMessageLength
            )
        }
        let historyBudget = max(0, AppControllerChatSupport.maxChatContextCharacters - cappedDraft.count)
        let boundedHistory = AppControllerChatSupport.limitMessagesByCharacterBudget(
            cappedHistory,
            budget: historyBudget
        )
        let renderedMemory = state.memoryForPrompt(now: Date())
        let renderedPolicyRules = state.policyRulesForChatPrompt(now: Date())

        let profileContext = AppControllerChatSupport.makeProfileContextForChatPrompt(
            activeProfile: state.activeProfile,
            availableProfiles: state.profiles.filter { $0.id != state.activeProfileID }
        )

        let backend = state.monitoringConfiguration.inferenceBackend
        let chatWorkflow: CompanionChatWorkflow = backend == .openRouter ? .direct : .staged
        let onlineModelIdentifier = state.monitoringConfiguration.onlineModelIdentifier
        let onlineTextModelIdentifier = state.monitoringConfiguration.onlineModelIdentifierText
        let localTextModelIdentifier = state.monitoringConfiguration.localModelIdentifierText
        let usingOnline = state.monitoringConfiguration.usesOnlineInference
        let chatReady = state.setupStatus == .ready &&
            (usingOnline || setupDiagnostics.runtimePresent)

        Task {
            let result: CompanionChatResult
            if !chatReady {
                result = CompanionChatResult(
                    reply: usingOnline
                        ? (directOpenAIEnabled
                            ? "Enable direct OpenAI mode with an OpenAI API key in Settings, then I can chat."
                            : "Add your OpenRouter API key in Settings, then I can chat.")
                        : "Finish local setup first, or switch to online mode in Settings.",
                    actions: [],
                    schedule: nil
                )
            } else if let response = await companionChatService.chat(
                userMessage: cappedDraft,
                goals: state.goalsText,
                recentActions: state.recentActions,
                context: makeChatContext(),
                history: boundedHistory,
                memory: renderedMemory,
                policyRules: renderedPolicyRules,
                character: state.character,
                activeProfileContext: profileContext,
                runtimeOverride: state.runtimePathOverride,
                inferenceBackend: backend,
                onlineModelIdentifier: onlineModelIdentifier,
                onlineTextModelIdentifier: onlineTextModelIdentifier,
                localTextModelIdentifier: localTextModelIdentifier,
                workflow: chatWorkflow
            ) {
                result = response
            } else {
                result = CompanionChatResult(
                    reply: usingOnline
                        ? (directOpenAIEnabled
                            ? "Couldn't reach OpenAI. Check the API key, your connection, and the model name."
                            : "Couldn't reach OpenRouter. Check the API key, your connection, and the model name.")
                        : "I couldn't answer just now. Check the logs and local runtime status.",
                    actions: [],
                    schedule: nil
                )
            }

            await MainActor.run {
                self.chatMessages.append(ChatMessage(role: .assistant, text: result.reply))
                self.noteUsedModel(result.usedModelIdentifier)
                if let schedule = result.schedule {
                    let fireAt = Date().addingTimeInterval(Double(schedule.delayMinutes) * 60)
                    let action = ScheduledAction(
                        type: schedule.kind == .nudge ? .nudge : .profileActivation,
                        fireAt: fireAt,
                        message: schedule.message,
                        profileName: schedule.profileName
                    )
                    self.state.scheduledActions.append(action)
                    self.scheduleActionTimer(action)
                    self.logActivity("schedule", "Scheduled \(schedule.kind) in \(schedule.delayMinutes)m")
                }

                self.persistState()
                self.sendingChatMessage = false
            }
            self.logActivity("chat", "Assistant: \(result.reply)")

            self.processChatActions(
                result.actions,
                workflow: chatWorkflow,
                latestUserMessage: trimmedDraft,
                recentMessages: boundedHistory,
                context: SnapshotService.frontmostContext(),
                parentInteractionID: result.interactionID
            )

            // Backstop: when the chat returns no actions but the reply commits to remembering
            // something (e.g. "I'll keep that in mind"), the model has promised a memory write
            // it didn't perform. Run a single policy_memory pass over the exchange so the
            // preference still lands. Cheap insurance against the chat model's "actions:[]" bias.
            await MainActor.run {
                if result.actions.isEmpty,
                   AppController.replyPromisesMemory(reply: result.reply) {
                    self.schedulePolicyMemoryUpdate(
                        eventSummary: "Chat exchange — extract any preference the user stated. "
                            + "User said: \(trimmedDraft). AC replied: \(result.reply)",
                        context: SnapshotService.frontmostContext()
                    )
                }
            }

            // Run consolidation lazily so the chat reply never waits for it.
            self.maybeConsolidateMemory()
        }
    }

    func makeChatContext() -> ChatContext {
        AppControllerChatSupport.makeChatContext(from: state)
    }

    func persistedChatHistory() -> [ChatMessage] {
        AppControllerChatSupport.persistedChatHistory(from: chatMessages)
    }

    static func makeChatMessages(from persistedHistory: [ChatMessage]) -> [ChatMessage] {
        AppControllerChatSupport.makeChatMessages(from: persistedHistory)
    }

    // MARK: - Memory helpers

    func appendMemoryLine(_ line: String, notify: Bool = true) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Avoid exact-duplicate entries from noisy call sites (e.g. repeated feedback).
        if state.memoryEntries.contains(where: { $0.text.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            return
        }
        let entry = MemoryEntry(text: trimmed)
        state.memoryEntries.append(entry)
        persistState()
        maybeConsolidateMemory()
        if notify {
            let summary = trimmed.hasPrefix("• ")
                ? String(trimmed.dropFirst(2))
                : trimmed
            presentLearnedToast(
                LearnedToast(
                    detail: summary,
                    subject: .memory(entryID: entry.id, text: trimmed)
                )
            )
        }
    }

    /// Activity identity for an allowance install. When the user is correcting a recent
    /// nudge by typing in the AC chat, the frontmost app is AC itself — the allowance
    /// must target the *intervened* activity, not the chat window. Callers pass an
    /// explicit `target` when they know which activity to allow.
    struct AllowanceTarget {
        var bundleIdentifier: String?
        var appName: String?
        var windowTitle: String?
        var contextKey: String?
    }

    /// After a user correction or approved appeal, install a short cooldown so AC
    /// doesn't immediately re-evaluate (and re-flag) the same activity.
    /// `RecentInteractionAllowance.make` widens to the whole app for browsers
    /// (tab-hopping research) and stays window-specific elsewhere.
    func installRecentInteractionAllowanceOverride(
        reason: String,
        now: Date = Date(),
        target: AllowanceTarget? = nil,
        fallbackAppName: String? = nil
    ) {
        let cadenceMode = state.monitoringConfiguration.cadenceMode
        let duration = cadenceMode.recentInteractionAllowanceDuration

        let resolvedTarget: AllowanceTarget?
        if let target {
            resolvedTarget = target
        } else if let current = SnapshotService.frontmostContext() {
            resolvedTarget = AllowanceTarget(
                bundleIdentifier: current.bundleIdentifier,
                appName: current.appName,
                windowTitle: current.windowTitle,
                contextKey: current.contextKey
            )
            state.algorithmState.llmPolicy.currentContextKey = current.contextKey
            state.algorithmState.llmPolicy.distraction.contextKey = current.contextKey
        } else if let fallbackAppName {
            resolvedTarget = AllowanceTarget(appName: fallbackAppName)
        } else {
            resolvedTarget = nil
        }

        state.algorithmState.llmPolicy.pruneRecentInteractionAllowances(at: now)
        if let resolvedTarget,
           let allowance = RecentInteractionAllowance.make(
            bundleIdentifier: resolvedTarget.bundleIdentifier,
            appName: resolvedTarget.appName,
            windowTitle: resolvedTarget.windowTitle,
            contextKey: resolvedTarget.contextKey,
            now: now,
            duration: duration,
            reason: reason
           ) {
            state.algorithmState.llmPolicy.upsertRecentInteractionAllowance(allowance)
        }

        let isDefaultProfile = state.activeProfileID == PolicyRule.defaultProfileID
        state.algorithmState.llmPolicy.activeAppeal = nil
        state.algorithmState.llmPolicy.distraction.lastAssessment = .focused
        state.algorithmState.llmPolicy.distraction.consecutiveDistractedCount = 0
        state.algorithmState.llmPolicy.distraction.nextEvaluationAt = now.addingTimeInterval(
            cadenceMode.adjustedDelay(
                cadenceMode.focusedFollowUp,
                isDefaultProfile: isDefaultProfile
            )
        )
        state.algorithmState.llmPolicy.focusSignal.record(
            assessment: .focused,
            confidence: 1.0,
            at: now
        )
    }

    /// `ActionRecord.contextKey` is `"<bundleIdentifier>|<normalized windowTitle>"`.
    /// Recover the bundle so we can route through the browser-widening branch of
    /// `RecentInteractionAllowance.make` even though `ActionRecord` doesn't store it.
    static func bundleIdentifier(fromContextKey contextKey: String?) -> String? {
        guard let contextKey, let separator = contextKey.firstIndex(of: "|") else { return nil }
        let prefix = String(contextKey[..<separator])
        guard !prefix.isEmpty, prefix != "unknown" else { return nil }
        return prefix
    }

    private enum DistractionCorrectionMatch {
        case explicit
        case contextualJustification

        var recentInterventionWindow: TimeInterval {
            switch self {
            case .explicit:
                return 30 * 60
            case .contextualJustification:
                return 5 * 60
            }
        }
    }

    private func distractionCorrectionMatch(
        for text: String,
        now: Date = Date()
    ) -> DistractionCorrectionMatch? {
        if AppControllerChatSupport.looksLikeExplicitDistractionCorrection(text) {
            return .explicit
        }
        guard AppControllerChatSupport.looksLikeWorkJustificationCorrection(text) else {
            return nil
        }
        let hasVeryRecentIntervention = state.recentActions.contains { action in
            (action.kind == .nudge || action.kind == .overlay)
                && now.timeIntervalSince(action.timestamp) <= DistractionCorrectionMatch.contextualJustification.recentInterventionWindow
        }
        return hasVeryRecentIntervention ? .contextualJustification : nil
    }

    private func recordDistractionCorrection(
        _ text: String,
        match: DistractionCorrectionMatch
    ) {
        let now = Date()
        guard let action = state.recentActions.first(where: {
            ($0.kind == .nudge || $0.kind == .overlay)
                && now.timeIntervalSince($0.timestamp) <= match.recentInterventionWindow
        }) else {
            return
        }

        let appName = action.appName ?? SnapshotService.frontmostContext()?.appName ?? "the recent activity"
        let title = action.windowTitle?.cleanedSingleLine
        let scope = title.map { "\(appName) (\($0))" } ?? appName
        appendMemoryLine("• Correction: \(scope) was not a distraction. User said: \(text.cleanedSingleLine)")

        if let actionID = action.id,
           let index = state.focusSegments.lastIndex(where: { $0.interventionID == actionID }) {
            state.focusSegments[index].assessment = .focused
            state.focusSegments[index].driftScore = 0
        } else if let index = state.focusSegments.lastIndex(where: {
            abs($0.endAt.timeIntervalSince(action.timestamp)) <= 10 * 60
        }) {
            state.focusSegments[index].assessment = .focused
            state.focusSegments[index].driftScore = 0
        }

        state.algorithmState.llmPolicy.distraction.lastAssessment = .focused
        state.algorithmState.llmPolicy.distraction.consecutiveDistractedCount = 0
        state.algorithmState.llmPolicy.focusSignal.resetFlow(at: now)
        installRecentInteractionAllowanceOverride(
            reason: "user correction: \(text.cleanedSingleLine)",
            now: now,
            target: AllowanceTarget(
                bundleIdentifier: Self.bundleIdentifier(fromContextKey: action.contextKey),
                appName: action.appName,
                windowTitle: action.windowTitle,
                contextKey: action.contextKey
            ),
            fallbackAppName: action.appName
        )
        schedulePolicyMemoryUpdate(
            eventSummary: "User corrected a recent intervention: \(text.cleanedSingleLine)",
            context: SnapshotService.frontmostContext()
        )
        persistState()
    }

    private func recordImmediateMonitoringAllowance(_ text: String) {
        let now = Date()
        let recentIntervention = state.recentActions.first {
            ($0.kind == .nudge || $0.kind == .overlay)
                && now.timeIntervalSince($0.timestamp) <= 30 * 60
        }

        if overlayVisible {
            executiveArm?.dismissOverlay()
            overlayVisible = false
            activeOverlay = nil
            overlayAppealDraft = ""
        }
        latestNudge = nil
        state.hardEscalation = nil
        companionMood = state.isPaused ? .paused : .watching
        state.algorithmState.llmPolicy.focusSignal.resetFlow(at: now)

        if let recentIntervention {
            installRecentInteractionAllowanceOverride(
                reason: "user asked AC to back off: \(text.cleanedSingleLine)",
                now: now,
                target: AllowanceTarget(
                    bundleIdentifier: Self.bundleIdentifier(fromContextKey: recentIntervention.contextKey),
                    appName: recentIntervention.appName,
                    windowTitle: recentIntervention.windowTitle,
                    contextKey: recentIntervention.contextKey
                ),
                fallbackAppName: recentIntervention.appName
            )
        } else {
            installRecentInteractionAllowanceOverride(
                reason: "user asked AC to back off: \(text.cleanedSingleLine)",
                now: now
            )
        }

        schedulePolicyMemoryUpdate(
            eventSummary: "User asked AC to back off or clarified the focus session is no longer active: \(text.cleanedSingleLine). Treat this as an immediate temporary allowance, not as evidence the user is distracted.",
            context: SnapshotService.frontmostContext(),
            allowMemoryOperations: false
        )
        persistState()
    }

    func schedulePolicyMemoryUpdate(
        eventSummary: String,
        context: FrontmostContext?,
        allowMemoryOperations: Bool = true
    ) {
        let now = Date()
        let request = PolicyMemoryUpdateRequest(
            now: now,
            goals: state.goalsText,
            freeFormMemory: state.memoryForPrompt(now: now),
            policyMemory: state.policyMemory,
            eventSummary: eventSummary,
            recentActions: state.recentActions,
            context: context,
            runtimeProfileID: state.monitoringConfiguration.runtimeProfileID,
            inferenceBackend: state.monitoringConfiguration.inferenceBackend,
            onlineModelIdentifier: state.monitoringConfiguration.onlineModelIdentifier,
            onlineTextModelIdentifier: state.monitoringConfiguration.onlineModelIdentifierText,
            localModelIdentifier: state.monitoringConfiguration.localModelIdentifierText,
            activeProfile: makeProfilePromptSummary(state.activeProfile),
            availableProfiles: state.profiles
                .filter { $0.id != state.activeProfileID }
                .map { makeProfilePromptSummary($0) },
            recentBehavioralSignals: state.recentBehavioralSignals
        )

        Task {
            guard let response = await policyMemoryService.deriveUpdate(
                request: request,
                runtimeOverride: state.runtimePathOverride
            ) else { return }

            await MainActor.run {
                let scopedResponse = self.scopePolicyRulesToActiveProfile(response)
                let beforeIDs = Set(self.state.policyMemory.rules.map(\.id))
                self.state.policyMemory.apply(scopedResponse, now: request.now)
                self.applyProfileOperations(scopedResponse.operations)
                self.routeProposalOperations(
                    scopedResponse.operations,
                    now: request.now,
                    context: context,
                    allowMemoryOperations: allowMemoryOperations
                )
                self.surfaceAutoLearnedRules(addedSince: beforeIDs)
                self.persistState()
            }
        }
    }

    /// Diff `state.policyMemory.rules` against the IDs we knew before the policy_memory
    /// pipeline applied an update. Any newly-added rule whose source is *not* a direct
    /// user statement (`userChat` / `explicitFeedback`) becomes a one-line "AC learned…"
    /// toast with an Undo affordance — the audit-trail surface from the plan.
    func surfaceAutoLearnedRules(addedSince beforeIDs: Set<String>) {
        for rule in state.policyMemory.rules where !beforeIDs.contains(rule.id) {
            switch rule.source {
            case .userChat, .explicitFeedback:
                continue
            case .implicitFeedback, .appeal, .system:
                let detail = ruleToastDetail(for: rule)
                presentLearnedToast(
                    LearnedToast(
                        detail: detail,
                        subject: .rule(id: rule.id, summary: rule.summary)
                    )
                )
            }
        }
    }

    func ruleToastDetail(for rule: PolicyRule) -> String {
        let target = rule.scope.appName
            ?? rule.scope.bundleIdentifier
            ?? rule.scope.titleContains.first
            ?? rule.summary
        let kind: String
        switch rule.kind {
        case .allow: kind = "allowed"
        case .disallow: kind = "blocked"
        case .discourage: kind = "discouraged"
        case .limit: kind = "limited"
        case .tonePreference: kind = "tone preference"
        }
        if let profileID = rule.profileID,
           profileID != PolicyRule.defaultProfileID,
           let profile = state.profile(withID: profileID) {
            return "\(target) is \(kind) during \(profile.name)"
        }
        return "\(target) is \(kind)"
    }

    /// Show a learned-toast; cancels any in-flight auto-dismiss and starts a new timer.
    func presentLearnedToast(_ toast: LearnedToast) {
        learnedToastDismissTask?.cancel()
        learnedToast = toast
        let duration = LearnedToast.defaultDuration
        learnedToastDismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            await MainActor.run {
                guard let self else { return }
                if self.learnedToast?.id == toast.id {
                    self.learnedToast = nil
                }
            }
        }
    }

    /// Hide the learned-toast without undoing — user clicked the close affordance or it timed out.
    func dismissLearnedToast() {
        learnedToastDismissTask?.cancel()
        learnedToast = nil
    }

    /// Reverse what the toast announced. For rules, expire the rule so it stops applying.
    /// For memory, delete the entry. Either way the toast disappears.
    func undoLearnedToast() {
        guard let toast = learnedToast else { return }
        let now = Date()
        switch toast.subject {
        case .rule(let ruleID, _):
            state.policyMemory.apply(
                PolicyMemoryUpdateResponse(operations: [
                    PolicyMemoryOperation(type: .expireRule, ruleID: ruleID, reason: "user_undo")
                ]),
                now: now
            )
            logActivity("policy-memory", "Undo: expired auto-added rule \(ruleID)")
        case .memory(let entryID, _):
            state.memoryEntries.removeAll { $0.id == entryID }
            logActivity("memory", "Undo: removed auto-added memory entry")
        }
        dismissLearnedToast()
        persistState()
    }

    /// Routes the controller-side operations out of a policy_memory response:
    /// - `propose_rule` / `propose_memory` → parked in `state.proposedChanges` for approval.
    /// - `add_memory` → directly appended to `state.memoryEntries` with a learned-toast.
    /// Stale proposals are pruned at the same time so the queue never grows unbounded.
    func routeProposalOperations(
        _ operations: [PolicyMemoryOperation],
        now: Date,
        context: FrontmostContext?,
        allowMemoryOperations: Bool = true
    ) {
        state.proposedChanges.removeAll { $0.isStale(at: now) }

        for op in operations {
            switch op.type {
            case .proposeRule:
                guard var rule = op.rule else { continue }
                if rule.profileID == nil, rule.kind != .tonePreference {
                    rule.profileID = state.activeProfileID
                }
                let proposal = ProposedPolicyChange(
                    kind: .rule,
                    proposedRule: rule,
                    reason: op.reason,
                    createdAt: now,
                    sourceContextKey: context?.contextKey
                )
                state.proposedChanges.append(proposal)
                logActivity(
                    "policy-memory",
                    "Proposed rule (\(rule.kind.rawValue)): \(rule.summary)"
                )

            case .proposeMemory:
                guard allowMemoryOperations else { continue }
                let trimmed = op.memoryNote?.cleanedSingleLine ?? ""
                guard !trimmed.isEmpty else { continue }
                let proposal = ProposedPolicyChange(
                    kind: .memory,
                    proposedMemoryNote: trimmed,
                    reason: op.reason,
                    createdAt: now,
                    sourceContextKey: context?.contextKey
                )
                state.proposedChanges.append(proposal)
                logActivity("policy-memory", "Proposed memory: \(trimmed)")

            case .addMemory:
                guard allowMemoryOperations else { continue }
                let trimmed = op.memoryNote?.cleanedSingleLine ?? ""
                guard !trimmed.isEmpty else { continue }
                let line = trimmed.hasPrefix("• ") ? trimmed : "• " + trimmed
                appendMemoryLine(line)
                logActivity("policy-memory", "Auto-added memory: \(trimmed)")

            default:
                continue
            }
        }
    }

    /// Accept a parked proposal — adds the rule/memory and removes the proposal.
    func acceptProposedChange(id: String) {
        guard let index = state.proposedChanges.firstIndex(where: { $0.id == id }) else { return }
        let proposal = state.proposedChanges.remove(at: index)
        let now = Date()
        switch proposal.kind {
        case .rule:
            guard let rule = proposal.proposedRule else { break }
            state.policyMemory.apply(
                PolicyMemoryUpdateResponse(operations: [
                    PolicyMemoryOperation(type: .addRule, rule: rule, reason: proposal.reason)
                ]),
                now: now
            )
            logActivity("policy-memory", "Accepted proposed rule: \(rule.summary)")
        case .memory:
            if let note = proposal.proposedMemoryNote, !note.isEmpty {
                // Suppress the "AC learned" toast — the user just clicked Accept; they
                // already know what they accepted.
                appendMemoryLine("• " + note, notify: false)
                logActivity("policy-memory", "Accepted proposed memory: \(note)")
            }
        }
        persistState()
    }

    /// Drop a parked proposal without applying it.
    func dismissProposedChange(id: String) {
        guard let index = state.proposedChanges.firstIndex(where: { $0.id == id }) else { return }
        let removed = state.proposedChanges.remove(at: index)
        logActivity("policy-memory", "Dismissed proposed \(removed.kind.rawValue)")
        persistState()
    }

    /// True when an assistant chat reply commits to remembering something. Used as a backstop
    /// signal: if the chat workflow returns `actions:[]` but the reply contains a phrase like
    /// "I'll keep that in mind" / "noted" / "I'll go easy on...", the model has promised a
    /// memory write it didn't perform. We then re-run the exchange through policy_memory to
    /// extract the preference. Returning true on these phrases is intentionally conservative —
    /// false positives just trigger one extra cheap LLM call.
    nonisolated static func replyPromisesMemory(reply: String) -> Bool {
        let lowered = reply.lowercased()
        let phrases = [
            "i'll keep that in mind",
            "i will keep that in mind",
            "keep that in mind",
            "i'll remember",
            "i will remember",
            "noted",
            "got it",
            "good to know",
            "i'll go easy",
            "won't bug you",
            "won't nudge you",
            "i'll lay off",
            "duly noted",
            "sounds like a deal",
            "it's a deal",
        ]
        return phrases.contains(where: lowered.contains)
    }

    /// Build a coarse `PolicyRuleScope` from a frontmost context — bundle id when known,
    /// app name otherwise. Behavioral signals don't need title precision; the model
    /// decides whether to widen or tighten the proposal scope at apply time.
    nonisolated static func scopeForContext(
        _ context: FrontmostContext?,
        fallbackAppName: String?
    ) -> PolicyRuleScope? {
        var scope = PolicyRuleScope()
        if let bundleIdentifier = context?.bundleIdentifier, !bundleIdentifier.isEmpty {
            scope.bundleIdentifier = bundleIdentifier
            return scope
        }
        if let appName = context?.appName.cleanedSingleLine, !appName.isEmpty {
            scope.appName = appName
            return scope
        }
        if let fallback = fallbackAppName?.cleanedSingleLine, !fallback.isEmpty {
            scope.appName = fallback
            return scope
        }
        return nil
    }

    /// Append a behavioral signal for the next policy_memory pass to weigh.
    /// Bounded to the last `recentBehavioralSignalsCap` entries within a 7-day window.
    func recordBehavioralSignal(_ signal: BehavioralSignalSummary) {
        let now = Date()
        state.recentBehavioralSignals.append(signal)
        state.recentBehavioralSignals.removeAll { $0.isStale(at: now) }
        if state.recentBehavioralSignals.count > ACState.recentBehavioralSignalsCap {
            state.recentBehavioralSignals.removeFirst(
                state.recentBehavioralSignals.count - ACState.recentBehavioralSignalsCap
            )
        }
    }

    func processChatActions(
        _ actions: [CompanionChatAction],
        workflow: CompanionChatWorkflow,
        latestUserMessage: String,
        recentMessages: [ChatMessage],
        context: FrontmostContext?,
        parentInteractionID: String?
    ) {
        guard !actions.isEmpty else { return }

        let recentUserMessages = recentMessages
            .filter { $0.role == .user }
            .suffix(MonitoringPromptContextBudget.recentUserChatCount)
            .map { $0.text.cleanedSingleLine }

        for action in actions {
            if workflow == .direct, applyChatAction(action, context: context) {
                logActivity("chat-action", "Applied direct \(action.kind.rawValue) action")
                recordExplicitChatStatementSignal(for: action, context: context)
                continue
            }

            resolveChatAction(
                action,
                latestUserMessage: latestUserMessage,
                recentUserMessages: recentUserMessages,
                context: context,
                parentInteractionID: parentInteractionID
            )
        }
    }

    func recordExplicitChatStatementSignal(
        for action: CompanionChatAction,
        context: FrontmostContext?
    ) {
        let detail = "chat \(action.kind.rawValue)"
            + (action.target?.value?.cleanedSingleLine.isEmpty == false
                ? " — " + (action.target?.value?.cleanedSingleLine ?? "")
                : "")
        recordBehavioralSignal(BehavioralSignalSummary(
            kind: "userExplicitChatStatement",
            observedAt: Date(),
            scope: AppController.scopeForContext(context, fallbackAppName: action.target?.value),
            detail: detail
        ))
    }

    func resolveChatAction(
        _ action: CompanionChatAction,
        latestUserMessage: String,
        recentUserMessages: [String],
        context: FrontmostContext?,
        parentInteractionID: String?
    ) {
        let now = Date()
        let request = ChatActionResolutionRequest(
            action: action,
            latestUserMessage: latestUserMessage.cleanedSingleLine,
            recentUserMessages: recentUserMessages,
            goals: state.goalsText,
            freeFormMemory: state.memoryForPrompt(now: now),
            policyRules: state.policyRulesForChatPrompt(now: now),
            context: context,
            activeProfile: makeProfilePromptSummary(state.activeProfile),
            availableProfiles: state.profiles
                .filter { $0.id != state.activeProfileID }
                .map { makeProfilePromptSummary($0) },
            runtimeOverride: state.runtimePathOverride,
            inferenceBackend: state.monitoringConfiguration.inferenceBackend,
            onlineModelIdentifier: state.monitoringConfiguration.onlineModelIdentifier,
            onlineTextModelIdentifier: state.monitoringConfiguration.onlineModelIdentifierText,
            localTextModelIdentifier: state.monitoringConfiguration.localModelIdentifierText,
            parentInteractionID: parentInteractionID
        )

        Task { [weak self, companionChatService] in
            let resolved = await companionChatService.resolveAction(request)
            await MainActor.run {
                guard let self, let resolved else { return }
                if self.applyChatAction(resolved, context: context) {
                    self.logActivity("chat-action", "Applied resolved \(resolved.kind.rawValue) action")
                    self.recordExplicitChatStatementSignal(for: resolved, context: context)
                }
            }
        }
    }

    @discardableResult
    func applyChatAction(_ action: CompanionChatAction, context: FrontmostContext?) -> Bool {
        switch action.kind {
        case .memory:
            return applyMemoryChatAction(action)
        case .profile:
            return applyProfileChatAction(action)
        case .focusPolicy:
            return applyFocusPolicyChatAction(action, context: context)
        case .recurringNudge:
            return applyRecurringNudgeChatAction(action)
        }
    }

    @discardableResult
    func applyRecurringNudgeChatAction(_ action: CompanionChatAction) -> Bool {
        let schedule = action.recurringSchedule
        let hour = schedule?.hour ?? action.hour
        let minute = schedule?.minute ?? action.minute
        guard let hour, let minute else { return false }
        let text = action.text?.cleanedSingleLine
        let reason = action.reason?.cleanedSingleLine
        let message = (text?.isEmpty == false ? text : nil)
            ?? (reason?.isEmpty == false ? reason : nil)
            ?? "Time to check your focus."
        let nudge = RecurringNudge(
            hour: hour,
            minute: minute,
            weekdays: schedule?.weekdays ?? action.weekdays,
            message: message
        )
        state.recurringNudges.append(nudge)
        logActivity("recurring-nudge", "Added recurring nudge \(nudge.scheduleDescription())")
        persistState()
        return true
    }

    @discardableResult
    func applyMemoryChatAction(_ action: CompanionChatAction) -> Bool {
        guard let text = action.text?.cleanedSingleLine, !text.isEmpty else { return false }
        if state.memoryEntries.contains(where: { $0.text.caseInsensitiveCompare(text) == .orderedSame }) {
            return true
        }
        state.memoryEntries.append(MemoryEntry(
            text: text,
            isLocked: action.locked == true
        ))
        logActivity("memory", "Remembered: \(text)")
        persistState()
        maybeConsolidateMemory()
        return true
    }

    @discardableResult
    func applyProfileChatAction(_ action: CompanionChatAction) -> Bool {
        let intent = action.intent?.cleanedSingleLine.lowercased() ?? ""
        switch intent {
        case "end", "stop", "end_active", "end_active_profile":
            applyProfileOperations([PolicyMemoryOperation(type: .endActiveProfile, reason: action.reason)])
            persistState()
            return true

        case "activate", "switch", "start":
            let profileID = action.profileID
                ?? action.profileName.flatMap { name in
                    state.profiles.first {
                        $0.name.cleanedSingleLine.caseInsensitiveCompare(name.cleanedSingleLine) == .orderedSame
                    }?.id
                }
            guard let profileID else { return false }
            var ops = [
                PolicyMemoryOperation(
                    type: .activateProfile,
                    reason: action.reason,
                    profileID: profileID,
                    profileDurationMinutes: action.durationMinutes
                )
            ]
            if let schedule = action.recurringSchedule.map({
                RecurringSchedule(hour: $0.hour, minute: $0.minute, weekdays: $0.weekdays)
            }) {
                ops[0].recurringSchedule = schedule
            }
            applyProfileOperations(ops)
            persistState()
            return true

        case "create", "create_and_activate":
            guard let name = action.profileName?.cleanedSingleLine, !name.isEmpty else { return false }
            var ops = [
                PolicyMemoryOperation(
                    type: .createAndActivateProfile,
                    reason: action.reason,
                    profileName: name,
                    profileDescription: action.profileDescription,
                    profileDurationMinutes: action.durationMinutes
                )
            ]
            if let schedule = action.recurringSchedule.map({
                RecurringSchedule(hour: $0.hour, minute: $0.minute, weekdays: $0.weekdays)
            }) {
                ops[0].recurringSchedule = schedule
            }
            applyProfileOperations(ops)
            persistState()
            return true

        case "update":
            let profileID = action.profileID ?? state.activeProfileID
            guard let current = state.profile(withID: profileID) else { return false }
            let schedule: RecurringSchedule?
            if let sched = action.recurringSchedule {
                schedule = RecurringSchedule(hour: sched.hour, minute: sched.minute, weekdays: sched.weekdays)
            } else {
                schedule = current.recurringSchedule
            }
            updateProfile(
                id: profileID,
                name: action.profileName?.cleanedSingleLine.isEmpty == false ? action.profileName! : current.name,
                description: action.profileDescription ?? current.description,
                defaultDurationMin: action.durationMinutes ?? current.defaultDurationMin,
                recurringSchedule: schedule
            )
            return true

        default:
            if let instruction = action.instruction,
               let ops = ProfileActionParser.parse(
                    action: instruction,
                    availableProfiles: state.profiles,
                    activeProfileID: state.activeProfileID
                ), !ops.isEmpty {
                applyProfileOperations(ops)
                persistState()
                return true
            }
            return false
        }
    }

    @discardableResult
    func applyFocusPolicyChatAction(
        _ action: CompanionChatAction,
        context: FrontmostContext?
    ) -> Bool {
        let intent = normalizedFocusPolicyIntent(action.intent)
        guard let kind = intent.kind else { return false }

        if kind == .disallow,
           let target = action.target,
           !["current_context", "currentcontext"].contains(target.type.cleanedSingleLine.lowercased()),
           let value = target.value?.cleanedSingleLine,
           !value.isEmpty {
            return addProfileBlocklistEntry(value, scope: action.scope)
        }

        guard let scope = makePolicyRuleScope(for: action, context: context, kind: kind) else {
            return false
        }

        let now = Date()
        let profileID = resolvedPolicyProfileID(scope: action.scope)
        let expiresAt = expirationDate(for: action, kind: kind, now: now, profileID: profileID)
        let targetSummary = policyRuleTargetSummary(scope: scope, fallback: action.target?.value ?? context?.appName)
        var schedule = PolicyRuleSchedule()
        schedule.expiresAt = expiresAt
        let rule = PolicyRule(
            kind: kind,
            summary: "\(intent.summaryVerb) \(targetSummary)",
            source: .userChat,
            createdAt: now,
            updatedAt: now,
            priority: 60,
            scope: scope,
            schedule: schedule,
            active: true,
            isLocked: action.locked == true,
            profileID: profileID
        )
        state.policyMemory.apply(
            PolicyMemoryUpdateResponse(operations: [
                PolicyMemoryOperation(type: .addRule, rule: rule, reason: action.reason)
            ]),
            now: now
        )
        persistState()
        return true
    }

    func removeRecurringNudge(id: UUID) {
        state.recurringNudges.removeAll { $0.id == id }
        persistState()
    }

    func fireRecurringNudge(_ nudge: RecurringNudge) {
        let message = nudge.message
        executiveArm?.perform(.showNudge(message))
        recordDisplayedNudge(message)
        logActivity("recurring_nudge", "Fired recurring nudge: \(message)")
        if let index = state.recurringNudges.firstIndex(where: { $0.id == nudge.id }) {
            state.recurringNudges[index].lastFiredAt = Date()
            persistState()
        }
    }

    func normalizedFocusPolicyIntent(_ intent: String?) -> (kind: PolicyRuleKind?, summaryVerb: String) {
        switch intent?.cleanedSingleLine.lowercased() {
        case "allow", "safelist", "safe", "ok", "okay":
            return (.allow, "Allow")
        case "block", "disallow", "badlist", "deny":
            return (.disallow, "Block")
        case "discourage", "nudge":
            return (.discourage, "Discourage")
        case "limit":
            return (.limit, "Limit")
        default:
            return (nil, "")
        }
    }

    func resolvedPolicyProfileID(scope: String?) -> String? {
        let normalized = scope?.cleanedSingleLine.lowercased()
        if normalized == "global" || normalized == "all_profiles" {
            return nil
        }
        if let normalized,
           let profile = state.profiles.first(where: {
               $0.id.lowercased() == normalized ||
               $0.name.cleanedSingleLine.lowercased() == normalized
           }) {
            return profile.id
        }
        return state.activeProfileID
    }

    func expirationDate(
        for action: CompanionChatAction,
        kind: PolicyRuleKind,
        now: Date,
        profileID: String?
    ) -> Date? {
        if let minutes = action.durationMinutes, minutes > 0 {
            return now.addingTimeInterval(TimeInterval(minutes) * 60)
        }
        switch action.duration?.cleanedSingleLine.lowercased() {
        case "profile_session", "session", "right_now":
            if let profileID,
               let profile = state.profile(withID: profileID),
               let expiresAt = profile.expiresAt {
                return expiresAt
            }
            return now.addingTimeInterval(2 * 60 * 60)
        case "today":
            return Calendar.current.date(
                byAdding: .day,
                value: 1,
                to: Calendar.current.startOfDay(for: now)
            )
        case "permanent", "forever", "always":
            return nil
        default:
            return kind == .allow
                ? now.addingTimeInterval(2 * 60 * 60)
                : nil
        }
    }

    func makePolicyRuleScope(
        for action: CompanionChatAction,
        context: FrontmostContext?,
        kind: PolicyRuleKind
    ) -> PolicyRuleScope? {
        let target = action.target
        let targetType = target?.type.cleanedSingleLine.lowercased()
        if target == nil || targetType == "current_context" || targetType == "currentcontext" {
            guard let context else { return nil }
            var scope = PolicyRuleScope()
            let shouldUseTitle = MonitoringHeuristics.isBrowser(bundleIdentifier: context.bundleIdentifier)
                || MonitoringHeuristics.titleScopedBundleIdentifiers.contains(context.bundleIdentifier ?? "")
            if shouldUseTitle, let signature = BrowserTitleSignature.derive(from: context.windowTitle) {
                scope.bundleIdentifier = context.bundleIdentifier
                scope.titleContains = [signature]
                return scope
            }
            if let bundleIdentifier = context.bundleIdentifier {
                scope.bundleIdentifier = bundleIdentifier
            } else {
                scope.appName = context.appName
            }
            return scope
        }

        guard let target else { return nil }
        let value = target.value?.cleanedSingleLine ?? ""
        guard !value.isEmpty else { return nil }
        var scope = PolicyRuleScope()
        switch target.type.cleanedSingleLine.lowercased() {
        case "app":
            scope.appName = value
        case "site", "domain", "title":
            scope.titleContains = [value]
        case "bundle":
            scope.bundleIdentifier = value
        default:
            scope.appName = value
        }
        return scope
    }

    func policyRuleTargetSummary(scope: PolicyRuleScope, fallback: String?) -> String {
        if let appName = scope.appName, !appName.isEmpty { return appName }
        if let bundleIdentifier = scope.bundleIdentifier, !bundleIdentifier.isEmpty {
            if let title = scope.titleContains.first, !title.isEmpty {
                return "\(bundleIdentifier) / \(title)"
            }
            return bundleIdentifier
        }
        if let title = scope.titleContains.first, !title.isEmpty { return title }
        return fallback?.cleanedSingleLine.isEmpty == false ? fallback!.cleanedSingleLine : "requested context"
    }

    @discardableResult
    func addProfileBlocklistEntry(_ value: String, scope: String?) -> Bool {
        guard let profileID = resolvedPolicyProfileID(scope: scope),
              let index = state.profiles.firstIndex(where: { $0.id == profileID }) else {
            return false
        }
        if !state.profiles[index].blocklist.contains(where: { $0.caseInsensitiveCompare(value) == .orderedSame }) {
            state.profiles[index].blocklist.append(value)
            persistState()
        }
        logActivity("profile", "Added blocklist entry \(value) to profile \(state.profiles[index].name)")
        return true
    }

    func scopePolicyRulesToActiveProfile(
        _ response: PolicyMemoryUpdateResponse
    ) -> PolicyMemoryUpdateResponse {
        let activeProfileID = state.activeProfileID
        let operations = response.operations.map { operation in
            guard operation.type == .addRule || operation.type == .updateRule else {
                return operation
            }
            var scoped = operation
            if var rule = scoped.rule,
               rule.kind != .tonePreference,
               rule.profileID == nil {
                rule.profileID = activeProfileID
                scoped.rule = rule
            }
            return scoped
        }
        return PolicyMemoryUpdateResponse(operations: operations)
    }

    /// Mark every chat message read. Called when the popover opens (the user is looking)
    /// and when a deferred suggestion is resolved.

    func markAllChatMessagesRead() {
        guard hasUnreadChatMessages || chatMessages.contains(where: { $0.isUnread })
            || state.chatHistory.contains(where: { $0.isUnread }) else { return }
        for index in chatMessages.indices where chatMessages[index].isUnread {
            chatMessages[index].isUnread = false
        }
        for index in state.chatHistory.indices where state.chatHistory[index].isUnread {
            state.chatHistory[index].isUnread = false
        }
        hasUnreadChatMessages = false
        persistState()
    }

    /// Recompute `hasUnreadChatMessages` after any chat-history mutation.
    func recomputeUnreadChatBadge() {
        hasUnreadChatMessages = chatMessages.contains(where: { $0.isUnread })
            || state.chatHistory.contains(where: { $0.isUnread })
    }

    func syncChatMessagesFromState() {
        let rendered = Self.makeChatMessages(from: state.chatHistory)
        if rendered.map(\.id) != chatMessages.map(\.id) {
            chatMessages = rendered
        }
        recomputeUnreadChatBadge()
    }

    /// BrainService works on whole-state snapshots. Merge its result against the original
    /// snapshot so concurrent chat/profile edits are preserved instead of being replaced by
    /// a stale monitoring copy.

    func maybeConsolidateMemory(now: Date = Date()) {
        guard state.setupStatus == .ready else { return }
        if !state.monitoringConfiguration.usesOnlineInference, !setupDiagnostics.runtimePresent {
            return
        }
        let overCap = state.memoryExceedsSoftCap
        let staleSinceLastRun: Bool = {
            guard let last = state.lastMemoryConsolidationAt else { return !state.memoryEntries.isEmpty }
            return now.timeIntervalSince(last) >= 24 * 60 * 60
        }()
        guard overCap || staleSinceLastRun else { return }
        startMemoryConsolidation(now: now, reason: overCap ? "overflow" : "stale")
    }

    func startMemoryConsolidation(now: Date, reason: String) {
        guard state.setupStatus == .ready else { return }
        if !state.monitoringConfiguration.usesOnlineInference, !setupDiagnostics.runtimePresent {
            return
        }
        guard !consolidatingMemory else { return }
        guard !state.memoryEntries.isEmpty else { return }

        consolidatingMemory = true
        let entriesSnapshot = state.memoryEntries
        let goalsSnapshot = state.goalsText
        let recentUserMessagesSnapshot = BrainService.recentUserMessages(
            chatHistory: state.chatHistory,
            limit: max(MonitoringPromptContextBudget.recentUserChatCount, 6)
        )
        let runtimeOverride = state.runtimePathOverride
        let backend = state.monitoringConfiguration.inferenceBackend
        let onlineModelIdentifier = state.monitoringConfiguration.onlineModelIdentifier
        let onlineTextModelIdentifier = state.monitoringConfiguration.onlineModelIdentifierText
        let localTextModelIdentifier = state.monitoringConfiguration.localModelIdentifierText

        Task { [weak self, memoryConsolidationService] in
            let consolidated = await memoryConsolidationService.consolidate(
                entries: entriesSnapshot,
                goals: goalsSnapshot,
                recentUserMessages: recentUserMessagesSnapshot,
                now: now,
                runtimeOverride: runtimeOverride,
                inferenceBackend: backend,
                onlineModelIdentifier: onlineModelIdentifier,
                onlineTextModelIdentifier: onlineTextModelIdentifier,
                localTextModelIdentifier: localTextModelIdentifier
            )
            await MainActor.run {
                guard let self else { return }
                self.consolidatingMemory = false
                self.state.lastMemoryConsolidationAt = now
                if let consolidated {
                    self.state.memoryEntries = consolidated
                    self.persistState()
                    self.logActivity(
                        "memory",
                        "Consolidated \(entriesSnapshot.count) → \(consolidated.count) entries (\(reason))"
                    )
                } else {
                    // Keep whatever is there; just record that we tried, so we back off a day.
                    if reason == "manual" {
                        self.setupErrorMessage = "Memory consolidation did not return a usable result."
                    }
                    self.persistState()
                }
            }
        }
    }
}

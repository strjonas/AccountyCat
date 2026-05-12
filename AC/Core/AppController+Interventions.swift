//
//  AppController+Interventions.swift
//  AC
//

import AppKit
import Foundation
import UniformTypeIdentifiers

@MainActor
extension AppController {
    func sendTestNudge() {
        let message = "Debug nudge: time to check that the panel is visible."
        let context = SnapshotService.frontmostContext()
        state.recentActions.insert(ActionRecord(
            id: UUID().uuidString,
            kind: .nudge,
            message: message,
            timestamp: Date(),
            contextKey: context?.contextKey,
            appName: context?.appName,
            windowTitle: context?.windowTitle
        ), at: 0)
        state.recentActions = Array(state.recentActions.prefix(12))
        companionMood = .nudging
        logActivity("debug", "Triggered test nudge")
        executiveArm?.perform(.showNudge(message))
        persistState()
    }

    /// Called when the user taps 👍 or 👎 on the nudge speech bubble.
    func rateNudge(positive: Bool, nudgeText: String) {
        let kind: UserReactionKind = positive ? .nudgeRatedPositive : .nudgeRatedNegative
        brainService?.recordUserReaction(
            UserReactionRecord(
                kind: kind,
                relatedAction: TelemetryCompanionActionRecord(kind: .nudge, message: nudgeText),
                positive: positive,
                details: nudgeText.cleanedSingleLine
            )
        )
        // Write to persistent memory so future nudges adapt
        let note = positive
            ? "• User liked nudge: \"\(nudgeText.cleanedSingleLine)\""
            : "• User disliked nudge: \"\(nudgeText.cleanedSingleLine)\""
        appendMemoryLine(note)
        schedulePolicyMemoryUpdate(
            eventSummary: positive
                ? "User explicitly liked this nudge: \(nudgeText.cleanedSingleLine)"
                : "User explicitly disliked this nudge: \(nudgeText.cleanedSingleLine)",
            context: SnapshotService.frontmostContext()
        )
        logActivity("feedback", positive ? "👍 nudge: \(nudgeText)" : "👎 nudge: \(nudgeText)")

        // Dismiss the nudge after rating
        clearTransientUI()
    }

    func showTestOverlay() {
        let context = SnapshotService.frontmostContext()
        state.recentActions.insert(ActionRecord(
            id: UUID().uuidString,
            kind: .overlay,
            message: "debug",
            timestamp: Date(),
            contextKey: context?.contextKey,
            appName: context?.appName,
            windowTitle: context?.windowTitle
        ), at: 0)
        state.recentActions = Array(state.recentActions.prefix(12))
        activeOverlay = OverlayPresentation(
            headline: "Pause for a second.",
            body: "Debug overlay for \(state.rescueApp.displayName).",
            prompt: "This looks a bit off-track — what's going on?",
            appName: "Debug",
            evaluationID: nil,
            submitButtonTitle: "Submit",
            secondaryButtonTitle: "Back to work"
        )
        overlayVisible = true
        companionMood = .escalated
        logActivity("debug", "Triggered test overlay")
        if let activeOverlay {
            executiveArm?.perform(.showOverlay(activeOverlay))
        }
        persistState()
    }

    func chooseRescueApp() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false

        if panel.runModal() == .OK, let url = panel.url {
            let bundle = Bundle(url: url)
            state.rescueApp = RescueAppTarget(
                displayName: url.deletingPathExtension().lastPathComponent,
                bundleIdentifier: bundle?.bundleIdentifier ?? state.rescueApp.bundleIdentifier,
                applicationPath: url.path
            )
            logActivity("app", "Selected rescue app: \(state.rescueApp.displayName)")
            persistState()
        }
    }

    func openRescueApp() {
        logActivity("action", "Opened rescue app: \(state.rescueApp.displayName)")
        executiveArm?.openRescueApp(state.rescueApp)
    }

    func handleBackToWork() {
        executiveArm?.dismissOverlay()
        overlayVisible = false
        let overlayMessage = activeOverlay.map { "\($0.headline) — \($0.body)" }
        activeOverlay = nil
        overlayAppealDraft = ""
        state.hardEscalation = nil
        brainService?.recordUserReaction(
            UserReactionRecord(
                kind: .backToWorkSelected,
                relatedAction: TelemetryCompanionActionRecord(kind: .overlay, message: overlayMessage),
                positive: true,
                details: state.rescueApp.displayName
            ),
            endEpisodeReason: .rescueReturn
        )
        openRescueApp()
        let context = SnapshotService.frontmostContext()
        state.recentActions.insert(ActionRecord(
            id: UUID().uuidString,
            kind: .backToWork,
            message: state.rescueApp.displayName,
            timestamp: Date(),
            contextKey: context?.contextKey,
            appName: context?.appName,
            windowTitle: context?.windowTitle
        ), at: 0)
        state.recentActions = Array(state.recentActions.prefix(12))
        logActivity("action", "Back to Work selected")
        persistState()
    }

    func dismissOverlay() {
        // Don't clear hard escalation on dismiss — user must convince AC or go back to work
        let wasHard = activeOverlay?.isHardEscalation == true
        executiveArm?.dismissOverlay()
        overlayVisible = false
        let overlayMessage = activeOverlay.map { "\($0.headline) — \($0.body)" }
        let dismissedAppName = activeOverlay?.appName
        activeOverlay = nil
        overlayAppealDraft = ""
        if !wasHard {
            state.hardEscalation = nil
        }
        brainService?.recordUserReaction(
            UserReactionRecord(
                kind: .overlayDismissed,
                relatedAction: TelemetryCompanionActionRecord(kind: .overlay, message: overlayMessage),
                positive: false,
                details: nil
            )
        )
        let context = SnapshotService.frontmostContext()
        let now = Date()
        state.recentActions.insert(ActionRecord(
            id: UUID().uuidString,
            kind: .dismissOverlay,
            message: nil,
            timestamp: now,
            contextKey: context?.contextKey,
            appName: context?.appName,
            windowTitle: context?.windowTitle
        ), at: 0)
        state.recentActions = Array(state.recentActions.prefix(12))
        if let scope = AppController.scopeForContext(context, fallbackAppName: dismissedAppName) {
            recordRepeatedDismissalIfWarranted(scope: scope, now: now)
        }
        logActivity("action", "Overlay dismissed")
        persistState()
    }

    /// Count overlay dismisses + ignored nudges in the last 4h on the same scope key. When
    /// we cross 3, append a `repeatedDismissal` behavioral signal so the next policy_memory
    /// pass can decide whether to propose a discourage rule (or just remember the pattern).
    /// Only fires once per 4h-window per scope.
    func recordRepeatedDismissalIfWarranted(scope: PolicyRuleScope, now: Date) {
        let windowSeconds: TimeInterval = 4 * 60 * 60
        guard let scopeKey = (scope.bundleIdentifier ?? scope.appName)?.cleanedSingleLine,
              !scopeKey.isEmpty else { return }

        let dismissCount = state.recentActions.lazy
            .filter { now.timeIntervalSince($0.timestamp) <= windowSeconds }
            .filter { $0.kind == .dismissOverlay || $0.kind == .nudge }
            .filter { record in
                guard let appName = record.appName?.cleanedSingleLine else { return false }
                return appName.caseInsensitiveCompare(scopeKey) == .orderedSame
            }
            .count
        guard dismissCount >= 3 else { return }

        let alreadyEmitted = state.recentBehavioralSignals.contains { signal in
            guard signal.kind == "repeatedDismissal",
                  now.timeIntervalSince(signal.observedAt) <= windowSeconds else { return false }
            let signalKey = signal.scope?.bundleIdentifier ?? signal.scope?.appName ?? ""
            return signalKey.caseInsensitiveCompare(scopeKey) == .orderedSame
        }
        guard !alreadyEmitted else { return }

        recordBehavioralSignal(BehavioralSignalSummary(
            kind: "repeatedDismissal",
            observedAt: now,
            scope: scope,
            detail: "\(dismissCount) dismisses/ignored nudges in last 4h",
            occurrences: dismissCount
        ))
    }

    func showHardEscalationOnReopen(appName: String) {
        guard overlayVisible == false else { return }
        let escalation = state.hardEscalation
        activeOverlay = OverlayPresentation(
            headline: "No.",
            body: "I minimized \(appName) because you haven't convinced me it serves your goals. Tell me why you need it.",
            prompt: "Explain why \(appName) is actually helping right now…",
            appName: appName,
            evaluationID: escalation?.evaluationID,
            submitButtonTitle: "Submit",
            secondaryButtonTitle: "I'll get back to work",
            isHardEscalation: true
        )
        overlayVisible = true
        companionMood = .escalatedHard
        executiveArm?.perform(.showOverlay(activeOverlay!))
    }

    func clearTransientUI() {
        latestNudge = nil
        if !overlayVisible {
            companionMood = state.isPaused ? .paused : .watching
        }
    }

    func submitOverlayAppeal() {
        guard !sendingOverlayAppeal,
              let presentation = activeOverlay else { return }

        let trimmedAppeal = overlayAppealDraft.cleanedSingleLine
        guard !trimmedAppeal.isEmpty else { return }

        sendingOverlayAppeal = true

        Task {
            let reviewNow = Date()
            let reviewInput = MonitoringAppealReviewInput(
                now: reviewNow,
                appealText: trimmedAppeal,
                snapshot: currentMonitoringPromptSnapshot(now: reviewNow),
                goals: state.goalsText,
                recentActions: state.recentActions,
                memory: state.memoryForPrompt(now: reviewNow),
                recentUserMessages: BrainService.recentUserMessages(
                    chatHistory: state.chatHistory,
                    limit: MonitoringPromptContextBudget.recentUserChatCount
                ),
                policyMemory: state.policyMemory,
                configuration: state.monitoringConfiguration,
                algorithmState: state.algorithmState,
                runtimeOverride: state.runtimePathOverride
            )

            let output = try? await monitoringAlgorithmRegistry.reviewAppeal(input: reviewInput)

            await MainActor.run {
                self.sendingOverlayAppeal = false

                guard let output else {
                    self.activeOverlay = OverlayPresentation(
                        headline: presentation.headline,
                        body: "I couldn't review that just now. Try again or head back to work.",
                        prompt: presentation.prompt,
                        appName: presentation.appName,
                        evaluationID: presentation.evaluationID,
                        submitButtonTitle: presentation.submitButtonTitle,
                        secondaryButtonTitle: presentation.secondaryButtonTitle,
                        isHardEscalation: presentation.isHardEscalation
                    )
                    return
                }

                self.noteUsedModel(output.evaluation.lastUsedModelIdentifier)
                self.state.policyMemory = output.updatedPolicyMemory
                self.state.algorithmState = output.updatedAlgorithmState

                // Hard escalation deny → minimize the app
                if presentation.isHardEscalation && output.result.decision == .deny {
                    self.state.hardEscalation?.lastAppealText = trimmedAppeal
                    self.state.hardEscalation?.lastAppealResult = output.result.decision
                    self.state.hardEscalation?.denialCount += 1
                    let denialCount = self.state.hardEscalation?.denialCount ?? 1

                    // Auto-release after 3 consecutive denials — the user really wants this app
                    if denialCount >= 3 {
                        self.appendMemoryLine("• AC released hard escalation on \(presentation.appName) after \(denialCount) denials. User appeal: \"\(trimmedAppeal)\"")
                        self.schedulePolicyMemoryUpdate(
                            eventSummary: "AC gave up on hard escalation for \(presentation.appName) after \(denialCount) denied appeals. User's last explanation: \(trimmedAppeal).",
                            context: SnapshotService.frontmostContext(),
                            allowMemoryOperations: false
                        )
                        self.state.hardEscalation = nil
                        self.activeOverlay = nil
                        self.overlayVisible = false
                        self.executiveArm?.dismissOverlay()
                        self.overlayAppealDraft = ""
                        self.companionMood = .watching
                        self.persistState()
                        return
                    }

                    // Find and minimize the app
                    if let escalation = self.state.hardEscalation,
                       let bid = escalation.bundleIdentifier ?? SnapshotService.frontmostContext()?.bundleIdentifier {
                        self.executiveArm?.hideApp(bundleIdentifier: bid)
                        self.state.hardEscalation?.timesMinimized += 1
                        self.state.hardEscalation?.lastMinimizedAt = Date()
                        self.state.recentActions.insert(ActionRecord(
                            kind: .minimizeApp,
                            message: "Minimized \(escalation.appName) after unconvincing appeal",
                            timestamp: Date(),
                            appName: escalation.appName
                        ), at: 0)
                        self.state.recentActions = Array(self.state.recentActions.prefix(12))
                    }
                    // Save appeal to memory
                    self.appendMemoryLine("• User appealed hard escalation on \(presentation.appName): \"\(trimmedAppeal)\" — denied")
                    self.schedulePolicyMemoryUpdate(
                        eventSummary: "User appealed hard escalation on \(presentation.appName) saying: \(trimmedAppeal). AC denied the appeal.",
                        context: SnapshotService.frontmostContext(),
                        allowMemoryOperations: false
                    )
                    self.activeOverlay = OverlayPresentation(
                        headline: "I'm not convinced.",
                        body: output.result.message.isEmpty
                            ? "I've minimized \(presentation.appName). If you open it again, I'll minimize it again. Convince me."
                            : output.result.message,
                        prompt: "Try again — why is \(presentation.appName) actually helping right now?",
                        appName: presentation.appName,
                        evaluationID: presentation.evaluationID,
                        submitButtonTitle: "Submit",
                        secondaryButtonTitle: "I'll get back to work",
                        isHardEscalation: true
                    )
                } else if presentation.isHardEscalation && output.result.decision == .allow {
                    // User convinced AC — save to memory, clear hard escalation
                    self.state.hardEscalation = nil
                    self.appendMemoryLine("• User convinced AC to allow \(presentation.appName): \"\(trimmedAppeal)\"")
                    self.installRecentInteractionAllowanceOverride(
                        reason: "appeal approved: \(trimmedAppeal)",
                        fallbackAppName: presentation.appName
                    )
                    self.recordBehavioralSignal(BehavioralSignalSummary(
                        kind: "appealApproved",
                        observedAt: Date(),
                        scope: AppController.scopeForContext(SnapshotService.frontmostContext(), fallbackAppName: presentation.appName),
                        detail: "\(presentation.appName): \(trimmedAppeal)"
                    ))
                    self.schedulePolicyMemoryUpdate(
                        eventSummary: "User convinced AC to allow \(presentation.appName): \(trimmedAppeal). Safe to let them continue.",
                        context: SnapshotService.frontmostContext(),
                        allowMemoryOperations: false
                    )
                    self.activeOverlay = nil
                    self.overlayVisible = false
                    self.executiveArm?.dismissOverlay()
                    self.overlayAppealDraft = ""
                    self.companionMood = .watching
                } else if output.result.decision == .allow {
                    self.appendMemoryLine("• Correction: \(presentation.appName) was okay. User said: \"\(trimmedAppeal)\"")
                    self.installRecentInteractionAllowanceOverride(
                        reason: "appeal approved: \(trimmedAppeal)",
                        fallbackAppName: presentation.appName
                    )
                    self.recordBehavioralSignal(BehavioralSignalSummary(
                        kind: "appealApproved",
                        observedAt: Date(),
                        scope: AppController.scopeForContext(SnapshotService.frontmostContext(), fallbackAppName: presentation.appName),
                        detail: "\(presentation.appName): \(trimmedAppeal)"
                    ))
                    self.schedulePolicyMemoryUpdate(
                        eventSummary: "User explained that \(presentation.appName) was okay and AC accepted the appeal: \(trimmedAppeal). Learn this as a correction and avoid nudging similar legitimate activity.",
                        context: SnapshotService.frontmostContext(),
                        allowMemoryOperations: false
                    )
                    self.brainService?.recordUserReaction(
                        UserReactionRecord(
                            kind: .overlayDismissed,
                            relatedAction: TelemetryCompanionActionRecord(
                                kind: .overlay,
                                message: "\(presentation.headline) — \(presentation.body)"
                            ),
                            positive: true,
                            details: trimmedAppeal
                        )
                    )
                    self.activeOverlay = nil
                    self.overlayVisible = false
                    self.executiveArm?.dismissOverlay()
                    self.overlayAppealDraft = ""
                    self.state.hardEscalation = nil
                    self.companionMood = .watching
                } else if output.result.decision == .deny {
                    self.activeOverlay = OverlayPresentation(
                        headline: "Not convinced yet.",
                        body: output.result.message,
                        prompt: nil,
                        appName: presentation.appName,
                        evaluationID: presentation.evaluationID,
                        submitButtonTitle: "Switch back",
                        secondaryButtonTitle: "Dismiss",
                        isHardEscalation: presentation.isHardEscalation
                    )
                } else {
                    self.activeOverlay = OverlayPresentation(
                        headline: "Tell me a bit more.",
                        body: output.result.message,
                        prompt: presentation.prompt,
                        appName: presentation.appName,
                        evaluationID: presentation.evaluationID,
                        submitButtonTitle: "Submit",
                        secondaryButtonTitle: presentation.secondaryButtonTitle,
                        isHardEscalation: presentation.isHardEscalation
                    )
                }
                self.overlayAppealDraft = ""
                self.persistState()
            }

            self.logActivity("appeal", "Overlay appeal reviewed: \(trimmedAppeal)")
        }
    }

    func currentMonitoringPromptSnapshot(now: Date) -> AppSnapshot? {
        guard let context = SnapshotService.frontmostContext() else {
            return nil
        }

        let dayUsage = state.usageByDay[now.acDayKey] ?? [:]
        let perAppDurations = dayUsage
            .map { AppUsageRecord(appName: $0.key, seconds: $0.value) }
            .sorted { $0.seconds > $1.seconds }

        return AppSnapshot(
            bundleIdentifier: context.bundleIdentifier,
            appName: context.appName,
            windowTitle: context.windowTitle,
            recentSwitches: Array(state.recentSwitches.prefix(4)),
            perAppDurations: Array(perAppDurations.prefix(6)),
            screenshotArtifact: nil,
            screenshotThumbnail: nil,
            screenshotPath: nil,
            idle: false,
            timestamp: now
        )
    }

    func recordDisplayedNudge(_ message: String, timestamp: Date = Date()) {
        latestNudge = message

        let shouldAppend = chatMessages.last.map {
            !($0.role == .assistant && $0.style == .nudge && $0.text == message)
        } ?? true
        guard shouldAppend else { return }

        chatMessages.append(
            ChatMessage(
                role: .assistant,
                text: message,
                timestamp: timestamp,
                style: .nudge
            )
        )
        persistState()
    }

    func maybeCelebrateFocusProgress(now: Date = Date()) {
        guard state.setupStatus == .ready,
              state.isPaused == false,
              state.algorithmState.llmPolicy.distraction.lastAssessment != .distracted else {
            return
        }

        let stats = todayStats
        guard stats.focusedSeconds >= 45 * 60 else { return }
        if let lastCelebrationAt = state.algorithmState.llmPolicy.focusSignal.lastCelebrationAt,
           now.timeIntervalSince(lastCelebrationAt) < 2 * 60 * 60 {
            return
        }

        let message: String
        let focused = formatCompactDuration(stats.focusedSeconds)
        let best = formatCompactDuration(stats.longestFocusedBlockSeconds)
        switch state.character {
        case .mochi:
            message = "You’ve already protected \(focused) of focus today. Best block: \(best). I’m proud of that."
        case .nova:
            message = "\(focused) focused today. Best block: \(best). Strong signal; keep the line."
        case .sage:
            message = "\(focused) of focused work today. Your best block is \(best). Notice the steadiness."
        }

        chatMessages.append(ChatMessage(role: .assistant, text: message, timestamp: now, style: .celebration))
        state.algorithmState.llmPolicy.focusSignal.lastCelebrationAt = now
        persistState()
    }

    func formatCompactDuration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        let h = total / 3600
        let m = (total % 3600) / 60
        if h > 0, m > 0 { return "\(h)h \(m)m" }
        if h > 0 { return "\(h)h" }
        return "\(m)m"
    }
}

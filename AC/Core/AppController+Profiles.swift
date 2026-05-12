//
//  AppController+Profiles.swift
//  AC
//

import Foundation

@MainActor
extension AppController {
    // MARK: - Brain — rule management

    func addUserRule(
        _ summary: String,
        kind: PolicyRuleKind,
        appName: String? = nil,
        profileID: String? = nil
    ) {
        let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var scope = PolicyRuleScope()
        if let name = appName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            scope.appName = name
        }
        let rule = PolicyRule(
            kind: kind,
            summary: trimmed,
            source: .explicitFeedback,
            priority: 75,
            scope: scope,
            profileID: profileID ?? state.activeProfileID
        )
        state.policyMemory.apply(PolicyMemoryUpdateResponse(operations: [
            PolicyMemoryOperation(type: .addRule, rule: rule)
        ]))
        persistState()
        logActivity("brain", "User added rule: \(trimmed)")
    }

    func deleteRule(id: String) {
        let removedRule = state.policyMemory.rules.first { $0.id == id }
        if let removedRule, removedRule.isAutoSafelistRule {
            let now = Date()
            let scope = removedRule.safelistMemoryScopeDescription
            appendMemoryLine("• Safelist correction: Do not auto-safelist \(scope). User manually removed this safelist rule.")
            for key in Array(state.algorithmState.llmPolicy.focusedObservations.keys) {
                guard state.algorithmState.llmPolicy.focusedObservations[key]?.lastAutoAllowRuleID == id else { continue }
                state.algorithmState.llmPolicy.focusedObservations[key]?.previousAutoAllowOutcome = .revokedByUser
                state.algorithmState.llmPolicy.focusedObservations[key]?.lastAutoAllowRuleID = nil
                state.algorithmState.llmPolicy.focusedObservations[key]?.lastPromotionOutcome = .denied
                state.algorithmState.llmPolicy.focusedObservations[key]?.lastPromotionReason = "User manually removed this safelist rule."
                state.algorithmState.llmPolicy.focusedObservations[key]?.lastPromotionCheckedAt = now
            }
        }
        state.policyMemory.rules.removeAll { $0.id == id }
        state.policyMemory.lastUpdatedAt = Date()
        persistState()
        logActivity("brain", "User deleted rule: \(id)")
    }

    nonisolated static func importModelToOllama(
        ollamaPath: String,
        modelPath: String,
        modelName: String
    ) async throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AC-Ollama-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let modelfileURL = tempDirectory.appendingPathComponent("Modelfile")
        let modelfileContents = "FROM \(modelPath)\n"
        try modelfileContents.write(to: modelfileURL, atomically: true, encoding: .utf8)

        _ = try await runProcess(
            launchPath: ollamaPath,
            arguments: ["create", modelName, "-f", modelfileURL.path],
            currentDirectory: tempDirectory
        )
    }

    nonisolated static func ollamaModelName(for modelIdentifier: String) -> String {
        let repository = RuntimeSetupService.repositoryIdentifier(for: modelIdentifier)
        let quant = modelIdentifier.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).dropFirst().first.map(String.init) ?? ""
        let rawName = "ac-\(repository)-\(quant)"
        let lower = rawName.lowercased()
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-._")
        let scalars = lower.unicodeScalars.map { scalar -> Character in
            allowed.contains(scalar) ? Character(scalar) : "-"
        }
        let collapsed = String(scalars)
            .replacingOccurrences(of: "--", with: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return collapsed.isEmpty ? "ac-local-model" : collapsed
    }

    nonisolated static func resolvedExecutablePath(_ tool: String) -> String? {
        let commonLocations = [
            "/usr/bin/\(tool)",
            "/usr/local/bin/\(tool)",
            "/opt/homebrew/bin/\(tool)",
        ]
        if let match = commonLocations.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return match
        }

        return ProcessInfo.processInfo.environment["PATH"]?
            .split(separator: ":")
            .map(String.init)
            .map { "\($0)/\(tool)" }
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) })
    }

    nonisolated static func runProcess(
        launchPath: String,
        arguments: [String],
        currentDirectory: URL
    ) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectory

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let stdoutBuffer = ProcessOutputBuffer()
        let stderrBuffer = ProcessOutputBuffer()

        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            stdoutBuffer.append(data)
        }

        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            stderrBuffer.append(data)
        }

        try process.run()
        let status = await withCheckedContinuation { continuation in
            process.terminationHandler = { finishedProcess in
                continuation.resume(returning: finishedProcess.terminationStatus)
            }
        }

        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        let stdout = String(decoding: stdoutBuffer.snapshot(), as: UTF8.self)
        let stderr = String(decoding: stderrBuffer.snapshot(), as: UTF8.self)

        guard status == 0 else {
            throw LocalModelStorageActionError.commandFailed(
                command: ([launchPath] + arguments).joined(separator: " "),
                status: status,
                output: stderr.isEmpty ? stdout : stderr
            )
        }

        return stdout
    }

    func toggleRuleLocked(id: String) {
        guard let i = state.policyMemory.rules.firstIndex(where: { $0.id == id }) else { return }
        state.policyMemory.rules[i].isLocked.toggle()
        state.policyMemory.rules[i].updatedAt = Date()
        persistState()
        logActivity("brain", "Rule \(state.policyMemory.rules[i].isLocked ? "locked" : "unlocked"): \(id)")
    }

    // MARK: - Focus profiles

    /// Activate an existing profile by id with an optional explicit expiry.
    /// When `expiresAt` is nil, AC picks a 90-minute default for named profiles.
    /// No-op for unknown ids; default profile activations always succeed.
    @discardableResult
    func activateProfile(
        id: String,
        expiresAt: Date? = nil,
        reason: String? = nil,
        announce: Bool = false
    ) -> Bool {
        let now = Date()
        state.ensureDefaultProfileExists()
        guard let index = state.profiles.firstIndex(where: { $0.id == id }) else {
            logActivity("profile", "Activate failed — unknown profile id: \(id)")
            return false
        }
        var profile = state.profiles[index]
        profile.activatedAt = now
        profile.lastUsedAt = now
        // Each activation is a fresh session: clear any soft-expiry bookkeeping
        // from the previous run so the next pre-warn / auto-extend cycle works.
        profile.autoExtendedAt = nil
        profile.prewarnSentAt = nil
        if profile.isDefault {
            profile.expiresAt = nil
        } else {
            profile.expiresAt = expiresAt ?? now.addingTimeInterval(90 * 60)
        }
        if let reason, !reason.isEmpty {
            profile.createdReason = reason
        }
        state.profiles[index] = profile
        // Activating any named profile clears the recently-ended session — the
        // user's anchor has moved on. (Activating Everyday keeps it so the
        // model still sees the prior session's goal context for ~30 min.)
        if !profile.isDefault {
            state.recentlyEndedSession = nil
        }
        state.activeProfileID = profile.id
        persistState()
        logActivity("profile", "Activated profile '\(profile.name)' until \(profile.expiresAt.map { ISO8601DateFormatter().string(from: $0) } ?? "default-no-expiry")")
        appendMonitoringMetric(kind: .profileChanged, reason: "activated", profile: profile, detail: reason)
        if announce {
            announceProfileSwitch(reason: reason)
        }
        return true
    }

    /// Activate an existing profile for a specific number of minutes from now.
    @discardableResult
    func activateProfile(
        id: String,
        durationMinutes: Int,
        reason: String? = nil,
        announce: Bool = false
    ) -> Bool {
        guard durationMinutes > 0 else { return false }
        let expiresAt = Date().addingTimeInterval(TimeInterval(durationMinutes) * 60)
        return activateProfile(
            id: id,
            expiresAt: expiresAt,
            reason: reason,
            announce: announce
        )
    }

    /// Create and activate a new named profile.
    /// If there is no room (profile count is at cap), returns nil and posts a chat message
    /// asking the user to remove a profile first, suggesting the least-recently-used one.
    @discardableResult
    func createAndActivateProfile(
        name: String,
        description: String? = nil,
        duration: TimeInterval? = nil,
        reason: String? = nil
    ) -> FocusProfile? {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return nil }
        state.ensureDefaultProfileExists()
        let namedCount = state.profiles.filter { !$0.isDefault }.count
        if namedCount >= FocusProfile.maximumProfileCount - 1 {
            suggestProfileRemoval(newProfileName: trimmedName)
            return nil
        }
        let now = Date()
        let durationToUse = duration ?? 90 * 60
        let profile = FocusProfile(
            name: trimmedName,
            description: description,
            createdAt: now,
            lastUsedAt: now,
            activatedAt: now,
            expiresAt: now.addingTimeInterval(durationToUse),
            createdReason: reason
        )
        state.profiles.append(profile)
        // New named profile: prior recently-ended anchor is no longer relevant.
        state.recentlyEndedSession = nil
        state.activeProfileID = profile.id
        persistState()
        logActivity("profile", "Created+activated profile '\(profile.name)' for \(Int(durationToUse / 60))m")
        appendMonitoringMetric(kind: .profileChanged, reason: "created", profile: profile, detail: reason)
        return profile
    }

    /// End the active profile and switch back to default. No-op when default is already active.
    /// Sets `recentlyEndedSession` so the next ~30 min of monitoring evals retain the
    /// just-ended goal anchor in the prompt payload.
    func endActiveProfile(announce: Bool = false) {
        guard state.activeProfileID != PolicyRule.defaultProfileID else { return }
        state.ensureDefaultProfileExists()
        let endedSnapshot: RecentlyEndedSession?
        if let i = state.profiles.firstIndex(where: { $0.id == state.activeProfileID }) {
            let ended = state.profiles[i]
            endedSnapshot = RecentlyEndedSession(
                name: ended.name,
                description: ended.description,
                endedAt: Date(),
                goalSummary: ended.createdReason
            )
            state.profiles[i].activatedAt = nil
            state.profiles[i].expiresAt = nil
            state.profiles[i].autoExtendedAt = nil
            state.profiles[i].prewarnSentAt = nil
        } else {
            endedSnapshot = nil
        }
        state.activeProfileID = PolicyRule.defaultProfileID
        if let endedSnapshot {
            state.recentlyEndedSession = endedSnapshot
            state.sessionCelebrationPending = true
        }
        persistState()
        logActivity("profile", "Ended active profile, back to default")
        appendMonitoringMetric(kind: .profileChanged, reason: "ended", profile: state.activeProfile, detail: nil)
        if announce {
            announceProfileSwitch(reason: "ended")
        }
    }

    /// Extend the currently active named profile by the given number of minutes.
    @discardableResult
    func extendActiveProfile(
        byMinutes minutes: Int,
        reason: String? = "user_extended",
        announce: Bool = false
    ) -> Bool {
        guard minutes > 0 else { return false }
        let active = state.activeProfile
        guard !active.isDefault else { return false }
        let baseline = max(active.expiresAt ?? Date(), Date())
        let newExpiry = baseline.addingTimeInterval(TimeInterval(minutes) * 60)
        return activateProfile(
            id: active.id,
            expiresAt: newExpiry,
            reason: reason,
            announce: announce
        )
    }

    // MARK: - Scheduled actions

    func scheduleActionTimer(_ action: ScheduledAction) {
        let delay = action.fireAt.timeIntervalSince(Date())
        guard delay > 0 else {
            executeScheduledAction(action)
            return
        }
        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                self?.executeScheduledAction(action)
            }
        }
        activeScheduledTimers[action.id] = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    func executeScheduledAction(_ action: ScheduledAction) {
        guard let index = state.scheduledActions.firstIndex(where: { $0.id == action.id }),
              !state.scheduledActions[index].fired else { return }
        state.scheduledActions[index].fired = true

        switch action.type {
        case .nudge:
            let message = action.message ?? "Reminder from AccountyCat"
            executiveArm?.perform(.showNudge(message))
            recordDisplayedNudge(message)
            logActivity("schedule", "Fired scheduled nudge: \(message)")
        case .profileActivation:
            let name = action.profileName ?? ""
            if let profile = state.profiles.first(where: {
                $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame
            }) {
                activateProfile(id: profile.id)
            } else {
                createAndActivateProfile(name: name, duration: 90 * 60)
            }
            logActivity("schedule", "Fired scheduled profile activation: \(name)")
        }

        activeScheduledTimers.removeValue(forKey: action.id)
        persistState()
    }

    func restorePendingScheduledActions() {
        let now = Date()
        for index in state.scheduledActions.indices where !state.scheduledActions[index].fired {
            if state.scheduledActions[index].fireAt <= now {
                executeScheduledAction(state.scheduledActions[index])
            } else {
                scheduleActionTimer(state.scheduledActions[index])
            }
        }
    }

    /// Called by BrainService at the top of every monitoring tick. If the active profile has
    /// expired, swap to default and persist. Returns true when a swap happened (so the caller
    /// can post a deferred chat note).
    @discardableResult
    func pruneExpiredProfileIfActive(now: Date = Date()) -> FocusProfile? {
        let active = state.activeProfile
        guard !active.isDefault, active.isExpired(at: now) else { return nil }
        let expired = active
        endActiveProfile()
        return expired
    }

    /// Rename a profile. Cannot rename the default profile's id, but its display name is editable.
    func renameProfile(id: String, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let index = state.profiles.firstIndex(where: { $0.id == id }) else { return }
        state.profiles[index].name = trimmed
        persistState()
    }

    /// Update editable profile metadata from the Brain tab.
    func updateProfile(
        id: String,
        name: String,
        description: String? = nil,
        emoji: String? = nil,
        color: String? = nil,
        blocklist: [String]? = nil,
        defaultDurationMin: Int? = nil,
        recurringSchedule: RecurringSchedule? = nil
    ) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty,
              let index = state.profiles.firstIndex(where: { $0.id == id }) else { return }
        let trimmedDescription = description?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        state.profiles[index].name = trimmedName
        state.profiles[index].description = (trimmedDescription?.isEmpty == false)
            ? trimmedDescription
            : nil
        if let emoji { state.profiles[index].emoji = emoji }
        if let color { state.profiles[index].color = color }
        if let blocklist { state.profiles[index].blocklist = blocklist }
        if let defaultDurationMin { state.profiles[index].defaultDurationMin = defaultDurationMin }
        state.profiles[index].recurringSchedule = recurringSchedule
        persistState()
        logActivity("profile", "Updated profile metadata: \(id)")
    }

    func lockedRuleCount(forProfileID id: String) -> Int {
        state.policyMemory.rules.filter { $0.profileID == id && $0.isLocked }.count
    }

    func canDeleteProfile(id: String) -> Bool {
        id != PolicyRule.defaultProfileID && lockedRuleCount(forProfileID: id) == 0
    }

    /// Delete a non-default profile. Also deletes any rules scoped to it.
    func deleteProfile(id: String) {
        guard id != PolicyRule.defaultProfileID else { return }
        guard canDeleteProfile(id: id) else {
            logActivity("profile", "Delete blocked — profile \(id) still has locked scoped rules")
            return
        }
        state.profiles.removeAll { $0.id == id }
        state.policyMemory.rules.removeAll { $0.profileID == id && !$0.isLocked }
        if state.activeProfileID == id {
            state.activeProfileID = PolicyRule.defaultProfileID
        }
        persistState()
        logActivity("profile", "Deleted profile: \(id)")
    }

    /// Suggests that the user remove a profile before creating a new one.
    /// Posts a deferred chat message naming the least-recently-used non-active, non-default profile
    /// and listing all removable profiles.
    func suggestProfileRemoval(newProfileName: String) {
        let candidates = state.profiles
            .filter { !$0.isDefault && $0.id != state.activeProfileID && canDeleteProfile(id: $0.id) }
            .sorted { $0.lastUsedAt < $1.lastUsedAt }
        guard !candidates.isEmpty else {
            let chatMessage = ChatMessage(
                role: .assistant,
                text: "You have too many profiles to add \"\(newProfileName)\" right now. Remove a profile first via Settings → Profiles.",
                timestamp: Date(),
                interruptionPolicy: .deferred
            )
            state.chatHistory.append(chatMessage)
            chatMessages.append(chatMessage)
            recomputeUnreadChatBadge()
            return
        }
        let suggestion = candidates.first!
        let suggestionSchedule = suggestion.recurringSchedule.map { " (has a recurring schedule at \($0.scheduleDescription()))" } ?? ""
        let names = candidates.prefix(5).map { "\($0.name)\($0.recurringSchedule != nil ? " *" : "")" }.joined(separator: ", ")
        let chatMessage = ChatMessage(
            role: .assistant,
            text: "You have \(FocusProfile.maximumProfileCount - 1) profiles already. Remove one first to make room for \"\(newProfileName)\" — I'd suggest \"\(suggestion.name)\" since you haven't used it recently\(suggestionSchedule). Removable: \(names).\(!candidates.contains(where: { $0.recurringSchedule != nil }) ? "" : " * = has recurring schedule")",
            timestamp: Date(),
            interruptionPolicy: .deferred
        )
        state.chatHistory.append(chatMessage)
        chatMessages.append(chatMessage)
        recomputeUnreadChatBadge()
        logActivity("profile", "Suggested removing '\(suggestion.name)' to make room for '\(newProfileName)'")
    }

    func makeProfilePromptSummary(_ profile: FocusProfile) -> ProfilePromptSummary {
        let rules = state.policyMemory.rules
            .filter { $0.profileID == profile.id && $0.active }
            .prefix(6)
            .map { rule in
                let kindShort: String
                switch rule.kind {
                case .allow: kindShort = "allow"
                case .disallow: kindShort = "disallow"
                case .discourage: kindShort = "discourage"
                case .limit: kindShort = "limit"
                case .tonePreference: kindShort = "tone"
                }
                let target = rule.scope.appName
                    ?? rule.scope.bundleIdentifier
                    ?? (rule.scope.titleContains.first.map { "title:\($0)" })
                    ?? rule.summary
                return "\(kindShort):\(target)"
            }
        let rulesSummary = rules.isEmpty ? nil : rules.joined(separator: ", ")
        return ProfilePromptSummary(
            id: profile.id,
            name: profile.name,
            isDefault: profile.isDefault,
            description: profile.description,
            rulesSummary: rulesSummary,
            lastUsedAt: profile.lastUsedAt,
            expiresAt: profile.expiresAt
        )
    }

    /// Route profile lifecycle ops emitted by the policy_memory pipeline through the
    /// AppController helpers so persistence, eviction, and announcement happen consistently.
    /// If multiple profile ops appear in one response, only the final effective state is
    /// announced so the user does not get spammed by contradictory deferred messages.
    func applyProfileOperations(_ operations: [PolicyMemoryOperation]) {
        var announcementReason: String?
        var shouldAnnounce = false

        for op in operations {
            switch op.type {
            case .activateProfile:
                guard let profileID = op.profileID else { continue }
                let expiresAt: Date?
                if let mins = op.profileDurationMinutes, mins > 0 {
                    expiresAt = Date().addingTimeInterval(TimeInterval(mins) * 60)
                } else {
                    expiresAt = nil
                }
                if activateProfile(id: profileID, expiresAt: expiresAt, reason: op.reason) {
                    if let schedule = op.recurringSchedule,
                       let index = state.profiles.firstIndex(where: { $0.id == profileID }) {
                        state.profiles[index].recurringSchedule = schedule
                        persistState()
                    }
                    announcementReason = op.reason
                    shouldAnnounce = true
                }

            case .createAndActivateProfile:
                guard let name = op.profileName?.cleanedSingleLine, !name.isEmpty else { continue }
                let duration: TimeInterval? = (op.profileDurationMinutes ?? 0) > 0
                    ? TimeInterval(op.profileDurationMinutes!) * 60
                    : nil
                if let newProfile = createAndActivateProfile(
                    name: name,
                    description: op.profileDescription,
                    duration: duration,
                    reason: op.reason
                ) {
                    if let schedule = op.recurringSchedule,
                       let index = state.profiles.firstIndex(where: { $0.id == newProfile.id }) {
                        state.profiles[index].recurringSchedule = schedule
                        persistState()
                    }
                    announcementReason = op.reason
                    shouldAnnounce = true
                }

            case .endActiveProfile:
                guard state.activeProfileID != PolicyRule.defaultProfileID else { continue }
                endActiveProfile()
                announcementReason = op.reason ?? "ended"
                shouldAnnounce = true

            default:
                continue
            }
        }

        if shouldAnnounce {
            announceProfileSwitch(reason: announcementReason)
        }
    }

    /// Post a deferred chat note announcing a profile change. Non-interrupting: relies on the
    /// existing chat history (the orb is reserved for nudges, not profile announcements).
    func announceProfileSwitch(reason: String?) {
        let active = state.activeProfile
        let trimmedReason = reason?.cleanedSingleLine ?? ""
        let message: String
        if active.isDefault {
            if trimmedReason == "ended", let sessionName = state.recentlyEndedSession?.name {
                message = "You wrapped \(sessionName) — nice work. Back to Everyday mode now."
            } else if trimmedReason.isEmpty {
                message = "Switched back to your Everyday profile."
            } else {
                message = "Switched back to Everyday — \(trimmedReason)"
            }
        } else {
            let untilText: String
            if let exp = active.expiresAt {
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.dateFormat = "HH:mm"
                untilText = " until \(formatter.string(from: exp))"
            } else {
                untilText = ""
            }
            let suffix = trimmedReason.isEmpty ? "" : " — \(trimmedReason)"
            message = "Switching to your \(active.name) profile\(untilText).\(suffix)"
        }
        let chatMessage = ChatMessage(
            role: .assistant,
            text: message,
            timestamp: Date(),
            interruptionPolicy: .deferred
        )
        state.chatHistory.append(chatMessage)
        chatMessages.append(chatMessage)
        recomputeUnreadChatBadge()
        logActivity("profile", "Announced profile switch: \(message)")
    }

    /// Trigger the consolidation pass if the memory exceeds the soft cap, or if a full
    /// day has passed since the last consolidation (stale "today" entries etc. get pruned).
    /// Runs asynchronously; the chat reply never waits for it.
}

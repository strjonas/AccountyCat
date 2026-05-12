//
//  AppControllerSupport.swift
//  AC
//

import Foundation

enum AppControllerSetupSupport {
    static func activityStatusText(
        state: ACState,
        diagnostics: RuntimeDiagnostics,
        installingRuntime: Bool,
        installingDependencies: Bool
    ) -> String {
        let requirements = LLMPolicyCatalog.permissionRequirements(for: state.monitoringConfiguration)
        let usesOnlineInference = state.monitoringConfiguration.usesOnlineInference
        let directOpenAIEnabled = OnlineProviderRoutingStore.loadDirectOpenAIEnabled()
        let hasOnlineAPIKey = OnlineProviderRouting.hasActiveAPIKeyConfigured(
            openRouterAPIKey: OnlineProviderCredentialStore.loadOpenRouterAPIKey() ?? "",
            directOpenAIAPIKey: OnlineProviderCredentialStore.loadDirectOpenAIAPIKey() ?? "",
            directOpenAIEnabled: directOpenAIEnabled
        )
        if installingDependencies {
            return "Installing missing dependencies."
        } else if installingRuntime {
            if diagnostics.runtimePresent {
                return "Downloading and warming the selected local model."
            }
            return "Building and warming the local runtime."
        } else if !state.permissions.satisfies(requirements) {
            if requirements.requiresScreenRecording {
                return "Waiting for Screen Recording and Accessibility permissions."
            }
            return "Waiting for Accessibility permission."
        } else if usesOnlineInference && !hasOnlineAPIKey {
            return directOpenAIEnabled
                ? "Add your OpenAI API key in Settings before AC can monitor online."
                : "Add your OpenRouter API key in Settings before AC can monitor online."
        } else if usesOnlineInference && state.isPaused {
            return "Monitoring is paused."
        } else if usesOnlineInference {
            let providerName = OnlineProviderRouting.activeProvider(directOpenAIEnabled: directOpenAIEnabled).displayName
            return requirements.requiresScreenRecording
                ? "Monitoring is active via \(providerName) with screenshot upload."
                : "Monitoring is active via \(providerName) without screenshot upload."
        } else if !diagnostics.missingTools.isEmpty {
            return "Install the missing build tools before AC can finish setup."
        } else if !diagnostics.runtimePresent || !diagnostics.modelCachePresent {
            return "Install and warm up the local runtime before AC can watch or chat."
        } else if !diagnostics.modelArtifactsPresent {
            return "Model files are downloading or warming up. AC will start monitoring automatically when ready."
        } else if state.isPaused {
            return "Monitoring is paused."
        } else {
            return "Monitoring is active."
        }
    }
}

enum AppControllerChatSupport {
    private static let systemMessage = "I'm AC, your calm focus companion. I watch what you're doing and gently nudge you when you drift. You can chat with me anytime — tell me your goals, start a focus session, or ask why I nudged."
    static let maxChatMessageLength = 1000
    static let maxChatContextCharacters = 4000

    static func cappedChatText(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit))
    }

    static func cappedMessageForContext(_ message: ChatMessage, limit: Int) -> ChatMessage {
        var trimmed = message
        trimmed.text = cappedChatText(message.text, limit: limit)
        return trimmed
    }

    static func limitMessagesByCharacterBudget(_ messages: [ChatMessage], budget: Int) -> [ChatMessage] {
        guard budget > 0 else { return [] }
        var total = 0
        var kept: [ChatMessage] = []
        for message in messages.reversed() {
            let length = message.text.count
            guard total + length <= budget else { continue }
            kept.append(message)
            total += length
        }
        return kept.reversed()
    }

    static func makeChatMessages(from persistedHistory: [ChatMessage]) -> [ChatMessage] {
        [ChatMessage(role: .system, text: systemMessage)]
            + persistedHistory
                .filter { $0.role != .system }
                .map(sanitizedPersistedChatMessage)
    }

    static func persistedChatHistory(from messages: [ChatMessage]) -> [ChatMessage] {
        messages
            .filter { $0.role != .system }
            .map(sanitizedPersistedChatMessage)
    }

    nonisolated private static func sanitizedPersistedChatMessage(_ message: ChatMessage) -> ChatMessage {
        guard message.role == .assistant else { return message }
        let trimmed = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercased = trimmed.lowercased()
        let looksLikeLeakedRuntimeOutput = lowercased.contains("prompt_tokens=") ||
            lowercased.contains("completion_tokens=") ||
            lowercased.hasPrefix("reply:") ||
            lowercased.hasPrefix("reply\":") ||
            lowercased.hasPrefix("\"reply\":")
        guard looksLikeLeakedRuntimeOutput else { return message }

        let cleaned = LLMOutputParsing.cleanChatOutput(trimmed)
        guard !cleaned.isEmpty else { return message }
        var sanitized = message
        sanitized.text = cleaned
        return sanitized
    }

    // `immediateMemoryLine` and `appendingMemoryLine` are gone. Chat messages now emit
    // optional actions; memory writes happen only through direct or staged action handling.

    static func makeChatContext(from state: ACState) -> ChatContext {
        let now = Date()
        let frontmost = SnapshotService.frontmostContext()
        let dayUsage = state.usageByDay[now.acDayKey] ?? [:]
        let perAppDurations = dayUsage
            .map { AppUsageRecord(appName: $0.key, seconds: $0.value) }
            .sorted { $0.seconds > $1.seconds }

        return ChatContext(
            frontmostAppName: frontmost?.appName ?? "Unknown App",
            frontmostWindowTitle: frontmost?.windowTitle,
            idleSeconds: SnapshotService.idleSeconds(),
            timestamp: now,
            recentSwitches: Array(state.recentSwitches.prefix(6)),
            perAppDurations: Array(perAppDurations.prefix(8))
        )
    }

    static func looksLikeNegativeChatFeedback(_ text: String) -> Bool {
        let lowered = text.cleanedSingleLine.lowercased()
        let markers = [
            "annoying",
            "dislike",
            "didn't like",
            "did not like",
            "stop nudging",
            "too much",
            "interrupt",
            "leave me alone",
            "not helpful",
            "wrong",
        ]
        return markers.contains { lowered.contains($0) }
    }

    static func looksLikeExplicitDistractionCorrection(_ text: String) -> Bool {
        let lowered = text.cleanedSingleLine.lowercased()
        let markers = [
            "wasn't a distraction",
            "was not a distraction",
            "wasnt a distraction",
            "not a distraction",
            "wrong nudge",
            "false positive",
            "that was work",
            "that was focused",
            "actually productive",
        ]
        return markers.contains { lowered.contains($0) }
    }

    static func looksLikeWorkJustificationCorrection(_ text: String) -> Bool {
        let lowered = text.cleanedSingleLine.lowercased()
        let markers = [
            "part of my project",
            "part of my task",
            "belongs to my project",
            "belongs to the project",
            "belongs to it",
            "for my project",
            "for the project",
            "needed for my project",
            "need this for my project",
            "this is work",
        ]
        return markers.contains { lowered.contains($0) }
    }

    static func makeProfileContextForChatPrompt(
        activeProfile: FocusProfile,
        availableProfiles: [FocusProfile]
    ) -> String {
        let expiryLabel: String?
        if let exp = activeProfile.expiresAt {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "HH:mm"
            expiryLabel = formatter.string(from: exp)
        } else {
            expiryLabel = nil
        }
        let scheduleLabel = activeProfile.recurringSchedule?.scheduleDescription()

        let availableText = availableProfiles
            .map { profile in
                let desc = profile.description.map { " — \($0)" } ?? ""
                let sched = profile.recurringSchedule.map { " [scheduled: \($0.scheduleDescription())]" } ?? ""
                return "- \(profile.name) (id: \(profile.id))\(desc)\(sched)"
            }
            .joined(separator: "\n")

        return ACPromptSets.chatProfileContextSection(
            activeProfileID: activeProfile.id,
            activeProfileName: activeProfile.name,
            activeProfileDescription: activeProfile.description,
            activeProfileIsDefault: activeProfile.isDefault,
            activeProfileExpiresAtLabel: expiryLabel,
            activeProfileScheduleLabel: scheduleLabel,
            availableProfiles: availableText
        )
    }
}

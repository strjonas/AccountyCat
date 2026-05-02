//
//  CompanionChatService.swift
//  AC
//
//  Created by Codex on 15.04.26.
//

import Foundation

/// Combined chat reply + memory update + optional profile action.
/// AC decides all three in one call.
struct CompanionChatResult: Sendable {
    var reply: String
    /// When non-nil, a single bullet to append to persistent memory (AC's choice).
    var memoryUpdate: String?
    /// When non-nil, a short instruction for profile operations (switch, create, end).
    /// Processed through the policy-memory pipeline.
    var profileAction: String?
    var usedModelIdentifier: String? = nil
}

actor CompanionChatService {
    private let runtime: LocalModelRuntime
    private let onlineModelService: any OnlineModelServing

    init(
        runtime: LocalModelRuntime,
        onlineModelService: any OnlineModelServing
    ) {
        self.runtime = runtime
        self.onlineModelService = onlineModelService
    }

    nonisolated static func fallbackReply(for error: Error) -> String {
        if let onlineError = error as? OnlineModelError,
           case let .httpFailure(statusCode, _, rawBody) = onlineError,
           statusCode == 429 || rawBody.localizedCaseInsensitiveContains("rate-limit") || rawBody.localizedCaseInsensitiveContains("rate limited") {
            return "OpenRouter is overloaded right now. I tried the backup path, but this turn still failed. Send that again in a moment."
        }
        return "Couldn't reach OpenRouter. Check the API key, your connection, and the model name."
    }

    func chat(
        userMessage: String,
        goals: String,
        recentActions: [ActionRecord],
        context: ChatContext,
        history: [ChatMessage] = [],
        memory: String = "",
        policyRules: String = "",
        character: ACCharacter = .mochi,
        activeProfileContext: String = "",
        runtimeOverride: String?,
        inferenceBackend: MonitoringInferenceBackend = .local,
        onlineModelIdentifier: String = MonitoringConfiguration.defaultOnlineModelIdentifier,
        onlineTextModelIdentifier: String? = nil,
        localTextModelIdentifier: String? = nil
    ) async -> CompanionChatResult? {
        let systemPrompt = ACPromptSets.chatSystemPrompt(withPersonality: character.personalityPrefix)
        let prompt = Self.makeChatPrompt(
            userMessage: userMessage,
            goals: goals,
            recentActions: recentActions,
            context: context,
            history: history,
            memory: memory,
            policyRules: policyRules,
            profileContext: activeProfileContext
        )

        let output: RuntimeProcessOutput
        do {
            if inferenceBackend == .openRouter {
                let resolvedOnlineModelIdentifier = onlineTextModelIdentifier ?? onlineModelIdentifier
                output = try await onlineModelService.runInference(
                    OnlineModelRequest(
                        source: .chat,
                        modelIdentifier: resolvedOnlineModelIdentifier,
                        systemPrompt: systemPrompt,
                        userPrompt: prompt,
                        imagePath: nil,
                        options: Self.onlineChatOptions()
                    )
                )
            } else {
                let runtimePath = RuntimeSetupService.normalizedRuntimePath(from: runtimeOverride)
                guard FileManager.default.isExecutableFile(atPath: runtimePath) else {
                    await ActivityLogService.shared.append(
                        category: "chat-error",
                        message: "Runtime missing at \(runtimePath)."
                    )
                    return nil
                }
                guard let localTextModelIdentifier, !localTextModelIdentifier.isEmpty else {
                    await ActivityLogService.shared.append(
                        category: "chat-error",
                        message: "No local text model configured."
                    )
                    return nil
                }
                output = try await runtime.runTextInference(
                    runtimePath: runtimePath,
                    modelIdentifier: localTextModelIdentifier,
                    systemPrompt: systemPrompt,
                    userPrompt: prompt
                )
            }
        } catch {
            await ActivityLogService.shared.append(
                category: "chat-error",
                message: error.localizedDescription
            )
            if inferenceBackend == .openRouter {
                return CompanionChatResult(
                    reply: Self.fallbackReply(for: error),
                    memoryUpdate: nil,
                    profileAction: nil
                )
            }
            return nil
        }

        let combined = [output.stdout, output.stderr]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        if let parsed = LLMOutputParsing.extractChatResult(from: combined) {
            return CompanionChatResult(
                reply: parsed.reply,
                memoryUpdate: parsed.memoryUpdate,
                profileAction: parsed.profileAction,
                usedModelIdentifier: output.usedModelIdentifier
                    ?? resolvedModelIdentifier(
                        for: inferenceBackend,
                        onlineModelIdentifier: onlineTextModelIdentifier ?? onlineModelIdentifier,
                        localModelIdentifier: localTextModelIdentifier
                    )
            )
        }
        // Legacy/fallback: pull a plain reply, no memory update.
        let reply = LLMOutputParsing.cleanChatOutput(combined)
        return reply.isEmpty
            ? nil
            : CompanionChatResult(
                reply: reply,
                memoryUpdate: nil,
                profileAction: nil,
                usedModelIdentifier: output.usedModelIdentifier
                    ?? resolvedModelIdentifier(
                        for: inferenceBackend,
                        onlineModelIdentifier: onlineTextModelIdentifier ?? onlineModelIdentifier,
                        localModelIdentifier: localTextModelIdentifier
                    )
            )
    }

    nonisolated private static func onlineChatOptions() -> RuntimeInferenceOptions {
        RuntimeInferenceOptions(
            maxTokens: 320,
            temperature: 0.5,
            topP: 0.95,
            topK: 64,
            ctxSize: 4096,
            batchSize: 1024,
            ubatchSize: 512,
            timeoutSeconds: 60
        )
    }

    private static func makeChatPrompt(
        userMessage: String,
        goals: String,
        recentActions: [ActionRecord],
        context: ChatContext,
        history: [ChatMessage],
        memory: String,
        policyRules: String,
        profileContext: String
    ) -> String {
        let historySection: String
        if history.isEmpty {
            historySection = "(no prior messages)"
        } else {
            historySection = history.map { msg in
                let label = msg.role == .user ? "User" : "AccountyCat"
                return "[\(msg.promptTimestampLabel)] \(label): \(msg.text.cleanedSingleLine)"
            }.joined(separator: "\n")
        }

        let memorySection = memory.isEmpty ? "(none)" : memory
        let policyRulesSection = policyRules.isEmpty ? "(none)" : policyRules

        return """
        [Context — use only if directly helpful, never be invasive]
        Frontmost app: \(context.frontmostAppName)
        Window: \(context.frontmostWindowTitle ?? "—")
        Idle: \(Int(context.idleSeconds))s
        Local time now: \(PromptTimestampFormatting.absoluteLabel(for: context.timestamp))
        Apps today: \(context.perAppDurations.prefix(5).map { "\($0.appName) \(Int($0.seconds/60))m" }.joined(separator: ", "))
        Recent AC actions: \(recentActions.prefix(3).map { "\($0.kind.rawValue): \($0.message ?? "-")" }.joined(separator: ", "))

        \(profileContext)
        [User goals]
        \(goals.cleanedSingleLine)

        [Persistent memory — lines are stamped with local time; honour them and treat later lines as overriding earlier ones]
        \(memorySection)

        [Brain rules — fixed rules from the Brain tab and learned policy rules; follow them unless the newest user message clearly updates them]
        \(policyRulesSection)

        [Recent conversation — each line is stamped with local time; if the user contradicts older chat or memory, the newest user statement wins]
        \(historySection)

        [New user message]
        \(userMessage.cleanedSingleLine)

        Respond as AccountyCat. Match the energy and tone of the user's message.
        Honour any rules in memory. Only reference context/app data if the user asks or it's directly useful.
        Use the profile_action field when the user explicitly asks to switch/create/end a profile.

        Return exactly one JSON object: {"reply":"your response","memory":null,"profile_action":null}
        or with memory: {"reply":"your response","memory":"single concise bullet under 20 words","profile_action":null}
        or with profile: {"reply":"your response","memory":null,"profile_action":"activate Coding profile for 60 min, allow Xcode and Terminal"}
        No markdown outside the JSON value. No other keys.
        """
    }

    private func resolvedModelIdentifier(
        for inferenceBackend: MonitoringInferenceBackend,
        onlineModelIdentifier: String,
        localModelIdentifier: String?
    ) -> String {
        switch inferenceBackend {
        case .openRouter:
            return onlineModelIdentifier
        case .local:
            return localModelIdentifier ?? ""
        }
    }
}

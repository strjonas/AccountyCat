//
//  CompanionChatService.swift
//  AC
//
//  Created by Codex on 15.04.26.
//

import Foundation

/// Combined chat reply + memory update. AC decides both in one call so the user never
/// receives a reply that "promises" to remember something AC doesn't actually commit.
struct CompanionChatResult: Sendable {
    var reply: String
    /// When non-nil, a single bullet to append to persistent memory (AC's choice).
    var memoryUpdate: String?
    var usedModelIdentifier: String? = nil
}

actor CompanionChatService {
    private let runtime: LocalModelRuntime
    private let onlineModelService: any OnlineModelServing
    private let modelIdentifier: String

    init(
        runtime: LocalModelRuntime,
        onlineModelService: any OnlineModelServing,
        modelIdentifier: String = LocalModelRuntime.defaultModelIdentifier
    ) {
        self.runtime = runtime
        self.onlineModelService = onlineModelService
        self.modelIdentifier = modelIdentifier
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
        runtimeOverride: String?,
        inferenceBackend: MonitoringInferenceBackend = .local,
        onlineModelIdentifier: String = MonitoringConfiguration.defaultOnlineModelIdentifier
    ) async -> CompanionChatResult? {
        let systemPrompt = PromptCatalog.loadChatSystemPrompt(character: character)
        let prompt = Self.makeChatPrompt(
            userMessage: userMessage,
            goals: goals,
            recentActions: recentActions,
            context: context,
            history: history,
            memory: memory,
            policyRules: policyRules
        )

        let output: RuntimeProcessOutput
        do {
            if inferenceBackend == .openRouter {
                output = try await onlineModelService.runInference(
                    OnlineModelRequest(
                        modelIdentifier: onlineModelIdentifier,
                        systemPrompt: systemPrompt,
                        userPrompt: prompt,
                        imagePath: nil,
                        options: Self.onlineChatOptions(modelIdentifier: onlineModelIdentifier)
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
                output = try await runtime.runTextInference(
                    runtimePath: runtimePath,
                    modelIdentifier: modelIdentifier,
                    systemPrompt: systemPrompt,
                    userPrompt: prompt
                )
            }
        } catch {
            await ActivityLogService.shared.append(
                category: "chat-error",
                message: error.localizedDescription
            )
            return nil
        }

        let combined = [output.stdout, output.stderr]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        if let parsed = LLMOutputParsing.extractChatResult(from: combined) {
            return CompanionChatResult(
                reply: parsed.reply,
                memoryUpdate: parsed.memoryUpdate,
                usedModelIdentifier: output.usedModelIdentifier
                    ?? resolvedModelIdentifier(for: inferenceBackend, onlineModelIdentifier: onlineModelIdentifier)
            )
        }
        // Legacy/fallback: pull a plain reply, no memory update.
        let reply = LLMOutputParsing.cleanChatOutput(combined)
        return reply.isEmpty
            ? nil
            : CompanionChatResult(
                reply: reply,
                memoryUpdate: nil,
                usedModelIdentifier: output.usedModelIdentifier
                    ?? resolvedModelIdentifier(for: inferenceBackend, onlineModelIdentifier: onlineModelIdentifier)
            )
    }

    nonisolated private static func onlineChatOptions(modelIdentifier: String) -> RuntimeInferenceOptions {
        RuntimeInferenceOptions(
            modelIdentifier: modelIdentifier,
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
        policyRules: String
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
        If they're casual, be casual. If they're excited, share the excitement. If they're stressed, be warm and grounding.
        Honour any rules in memory. Only reference context/app data if the user asks or it's directly useful.

        You also maintain persistent memory. If — and only if — this message contains something worth
        remembering across future sessions (a new rule like "don't let me use Instagram today", an
        explicit allowance like "WhatsApp is okay for the next hour", a lasting preference, or
        something that would clearly contradict a future nudge otherwise), include a `memory` field.
        Otherwise set `memory` to null. Be conservative — do NOT add a memory for every message.
        Add one memory only when it clearly adds value on top of what's already remembered, and
        phrase it so it still makes sense on its own days from now.
        If the user gives a time-boxed rule or allowance, rewrite it with an explicit local expiry
        time instead of relative words like "today", "tonight", or "for the next hour".
        Good: "X.com is allowed until 2026-04-23 17:15"
        Good: "Do not allow Instagram until 2026-04-23 23:59"
        Bad: "X.com is okay for a bit"
        Bad: "No Instagram today"

        Return exactly one JSON object: {"reply":"your response","memory":null}
        or {"reply":"your response","memory":"single concise bullet under 20 words"}
        No markdown outside the JSON value. No other keys.
        """
    }

    private func resolvedModelIdentifier(
        for inferenceBackend: MonitoringInferenceBackend,
        onlineModelIdentifier: String
    ) -> String {
        switch inferenceBackend {
        case .openRouter:
            return onlineModelIdentifier
        case .local:
            return modelIdentifier
        }
    }
}

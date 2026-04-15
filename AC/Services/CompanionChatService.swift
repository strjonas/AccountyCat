//
//  CompanionChatService.swift
//  AC
//
//  Created by Codex on 15.04.26.
//

import Foundation

actor CompanionChatService {
    private let runtime: LocalModelRuntime
    private let modelIdentifier: String

    init(
        runtime: LocalModelRuntime,
        modelIdentifier: String = LocalModelRuntime.defaultModelIdentifier
    ) {
        self.runtime = runtime
        self.modelIdentifier = modelIdentifier
    }

    func chat(
        userMessage: String,
        goals: String,
        recentActions: [ActionRecord],
        context: ChatContext,
        history: [ChatMessage] = [],
        memory: String = "",
        runtimeOverride: String?
    ) async -> String? {
        let runtimePath = RuntimeSetupService.normalizedRuntimePath(from: runtimeOverride)
        guard FileManager.default.isExecutableFile(atPath: runtimePath) else {
            await ActivityLogService.shared.append(
                category: "chat-error",
                message: "Runtime missing at \(runtimePath)."
            )
            return nil
        }

        let systemPrompt = PromptCatalog.loadChatSystemPrompt()
        let prompt = Self.makeChatPrompt(
            userMessage: userMessage,
            goals: goals,
            recentActions: recentActions,
            context: context,
            history: history,
            memory: memory
        )

        do {
            let output = try await runtime.runTextInference(
                runtimePath: runtimePath,
                modelIdentifier: modelIdentifier,
                systemPrompt: systemPrompt,
                userPrompt: prompt
            )
            let combined = [output.stdout, output.stderr]
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            let reply = LLMOutputParsing.extractChatReply(from: combined) ?? LLMOutputParsing.cleanChatOutput(combined)
            return reply.isEmpty ? nil : reply
        } catch {
            await ActivityLogService.shared.append(
                category: "chat-error",
                message: error.localizedDescription
            )
            return nil
        }
    }

    private static func makeChatPrompt(
        userMessage: String,
        goals: String,
        recentActions: [ActionRecord],
        context: ChatContext,
        history: [ChatMessage],
        memory: String
    ) -> String {
        let historySection: String
        if history.isEmpty {
            historySection = "(no prior messages)"
        } else {
            historySection = history.map { msg in
                let label = msg.role == .user ? "User" : "AccountyCat"
                return "\(label): \(msg.text.cleanedSingleLine)"
            }.joined(separator: "\n")
        }

        let memorySection = memory.isEmpty ? "(none)" : memory

        return """
        [Context — use only if directly helpful, never be invasive]
        Frontmost app: \(context.frontmostAppName)
        Window: \(context.frontmostWindowTitle ?? "—")
        Idle: \(Int(context.idleSeconds))s
        Time: \(context.timestamp.formatted(date: .abbreviated, time: .shortened))
        Apps today: \(context.perAppDurations.prefix(5).map { "\($0.appName) \(Int($0.seconds/60))m" }.joined(separator: ", "))
        Recent AC actions: \(recentActions.prefix(3).map { "\($0.kind.rawValue): \($0.message ?? "-")" }.joined(separator: ", "))

        [User goals]
        \(goals.cleanedSingleLine)

        [Persistent memory — always honour these]
        \(memorySection)

        [Recent conversation]
        \(historySection)

        [New user message]
        \(userMessage.cleanedSingleLine)

        Respond as AccountyCat. Match the energy and tone of the user's message.
        If they're casual, be casual. If they're excited, share the excitement. If they're stressed, be warm and grounding.
        Honour any rules in memory. Only reference context/app data if the user asks or it's directly useful.
        Return exactly one JSON object: {"reply":"your response"}
        No markdown. No extra keys. No other text.
        """
    }
}

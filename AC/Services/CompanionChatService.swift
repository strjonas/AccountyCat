//
//  CompanionChatService.swift
//  AC
//
//  Created by Codex on 15.04.26.
//

import Foundation

/// Combined chat reply + optional side-effect actions + optional scheduled action.
/// AC uses a direct workflow for capable online models and a staged workflow for
/// smaller/local models. Staged chat only emits action hints; dedicated executors
/// turn those hints into profile, memory, or focus-policy mutations.
struct CompanionChatResult: Sendable {
    var reply: String
    /// Optional side effects requested by the chat model. Online/direct models may
    /// include executable fields; local/staged models should emit only kind + instruction.
    var actions: [CompanionChatAction]
    /// When non-nil, a scheduled action parsed from the LLM output (timed nudge or delayed profile).
    var schedule: ScheduledActionCandidate?
    var usedModelIdentifier: String? = nil
    /// Telemetry id of the chat-turn LLM call. Pass back to `resolveAction` so
    /// the inspector can group action resolutions under their originating chat.
    var interactionID: String? = nil
}

struct ChatActionResolutionRequest: Sendable {
    var action: CompanionChatAction
    var latestUserMessage: String
    var recentUserMessages: [String]
    var goals: String
    var freeFormMemory: String
    var policyRules: String
    var context: FrontmostContext?
    var activeProfile: ProfilePromptSummary
    var availableProfiles: [ProfilePromptSummary]
    var runtimeOverride: String?
    var inferenceBackend: MonitoringInferenceBackend
    var onlineModelIdentifier: String
    var onlineTextModelIdentifier: String?
    var localTextModelIdentifier: String?
    /// Telemetry id of the originating chat-turn LLM call. The inspector
    /// groups action resolutions under their parent chat episode.
    var parentInteractionID: String? = nil
}

/// Lightweight representation of a schedule request from the LLM before conversion to
/// a persisted `ScheduledAction` with a resolved `fireAt` date.
struct ScheduledActionCandidate: Sendable {
    enum Kind: String, Sendable {
        case nudge
        case profileActivation = "profile"
    }

    var kind: Kind
    var delayMinutes: Int
    var message: String?
    var profileName: String?
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
        onlineModelIdentifier: String = AITier.balanced.byokModelIdentifierImage,
        onlineTextModelIdentifier: String? = nil,
        localTextModelIdentifier: String? = nil,
        workflow: CompanionChatWorkflow
    ) async -> CompanionChatResult? {
        let systemPrompt = ACPromptSets.chatSystemPrompt(
            withPersonality: character.personalityPrefix,
            workflow: workflow
        )
        let prompt = Self.makeChatPrompt(
            userMessage: userMessage,
            goals: goals,
            recentActions: recentActions,
            context: context,
            history: history,
            memory: memory,
            policyRules: policyRules,
            profileContext: activeProfileContext,
            workflow: workflow
        )

        let output: RuntimeProcessOutput
        do {
            if inferenceBackend == .openRouter {
                let resolvedOnlineModelIdentifier = onlineTextModelIdentifier ?? onlineModelIdentifier
                let hadSuccessfulChat = await onlineModelService.hasHadSuccessfulChat()
                if !hadSuccessfulChat {
                    // Parallel safety net for the very first chat message
                    var seen: Set<String> = []
                    let parallelModels = [resolvedOnlineModelIdentifier, OnlineModelService.premiumFallbackModelIdentifier, AITier.smartest.byokModelIdentifierText]
                        .filter { seen.insert($0).inserted }
                        .prefix(3)
                        .map { $0 }
                    let parallelRequests = parallelModels.map { model in
                        OnlineModelRequest(
                            source: .chat,
                            modelIdentifier: model,
                            systemPrompt: systemPrompt,
                            userPrompt: prompt,
                            imagePath: nil,
                            options: Self.onlineChatOptions()
                        )
                    }
                    await ActivityLogService.shared.append(level: .verbose,
                        category: "llm:chat",
                        message: "─── Parallel safety net → \(parallelModels.joined(separator: ", ")) ───\n"
                            + "system: \(systemPrompt.cleanedSingleLine.truncatedForPrompt(maxLength: 1500))\n"
                            + "user: \(prompt.cleanedSingleLine.truncatedForPrompt(maxLength: 1500))"
                    )
                    output = try await onlineModelService.runFirstSuccessfulInference(from: parallelRequests)
                } else {
                    await ActivityLogService.shared.append(level: .verbose,
                        category: "llm:chat",
                        message: "─── Request → openrouter/\(resolvedOnlineModelIdentifier) ───\n"
                            + "system: \(systemPrompt.cleanedSingleLine.truncatedForPrompt(maxLength: 1500))\n"
                            + "user: \(prompt.cleanedSingleLine.truncatedForPrompt(maxLength: 1500))"
                    )
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
                }
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
                await ActivityLogService.shared.append(level: .verbose,
                    category: "llm:chat",
                    message: "─── Request → llama.cpp/\(localTextModelIdentifier) ───\n"
                        + "system: \(systemPrompt.cleanedSingleLine.truncatedForPrompt(maxLength: 1500))\n"
                        + "user: \(prompt.cleanedSingleLine.truncatedForPrompt(maxLength: 1500))"
                )
                let localStartedAt = Date()
                do {
                    var localOutput = try await runtime.runTextInference(
                        runtimePath: runtimePath,
                        modelIdentifier: localTextModelIdentifier,
                        systemPrompt: systemPrompt,
                        userPrompt: prompt
                    )
                    let interactionID = await LLMTelemetryRecorder.shared.record(
                        LLMTelemetryCall(
                            kind: .localChat,
                            parentInteractionID: nil,
                            runtime: .llamaCpp,
                            modelIdentifier: localOutput.usedModelIdentifier ?? localTextModelIdentifier,
                            promptMode: "chat",
                            systemPrompt: systemPrompt,
                            userPrompt: prompt,
                            requestPayloadJSON: nil,
                            imagePath: nil,
                            startedAt: localStartedAt,
                            endedAt: Date(),
                            rawStdout: localOutput.stdout,
                            rawStderr: localOutput.stderr,
                            tokenUsage: localOutput.tokenUsage,
                            failure: nil,
                            summary: ""
                        )
                    )
                    localOutput.interactionID = interactionID
                    output = localOutput
                } catch {
                    await LLMTelemetryRecorder.shared.record(
                        LLMTelemetryCall(
                            kind: .localChat,
                            parentInteractionID: nil,
                            runtime: .llamaCpp,
                            modelIdentifier: localTextModelIdentifier,
                            promptMode: "chat",
                            systemPrompt: systemPrompt,
                            userPrompt: prompt,
                            requestPayloadJSON: nil,
                            imagePath: nil,
                            startedAt: localStartedAt,
                            endedAt: Date(),
                            rawStdout: nil,
                            rawStderr: nil,
                            tokenUsage: nil,
                            failure: LLMInteractionFailure(
                                domain: String(describing: type(of: error)),
                                message: error.localizedDescription
                            ),
                            summary: "local chat failed"
                        )
                    )
                    throw error
                }
                await ActivityLogService.shared.append(level: .verbose,
                    category: "llm:chat",
                    message: "← llama.cpp · \(output.usedModelIdentifier ?? localTextModelIdentifier)"
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
                    actions: [],
                    schedule: nil
                )
            }
            return nil
        }

        let combined = [output.stdout, output.stderr]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        let modelText = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let parseText = modelText.isEmpty ? combined : modelText
        if let parsed = LLMOutputParsing.extractChatResult(from: parseText) {
            await annotateChatInteraction(
                interactionID: output.interactionID,
                isLocalChat: inferenceBackend == .local,
                userMessage: userMessage,
                reply: parsed.reply,
                actions: parsed.actions,
                schedule: parsed.schedule
            )
            return CompanionChatResult(
                reply: parsed.reply,
                actions: parsed.actions,
                schedule: parsed.schedule,
                usedModelIdentifier: output.usedModelIdentifier
                    ?? resolvedModelIdentifier(
                        for: inferenceBackend,
                        onlineModelIdentifier: onlineTextModelIdentifier ?? onlineModelIdentifier,
                        localModelIdentifier: localTextModelIdentifier
                    ),
                interactionID: output.interactionID
            )
        }

        await ActivityLogService.shared.append(
            category: "chat-parse-error",
            message: "Could not parse chat JSON from \(output.usedModelIdentifier ?? "unknown model"). stdout: \(modelText.cleanedSingleLine.truncatedForPrompt(maxLength: 700))"
        )

        // Legacy/fallback: pull a plain reply, no memory update.
        let reply = LLMOutputParsing.cleanChatOutput(parseText)
        if reply.isEmpty {
            return nil
        }
        await annotateChatInteraction(
            interactionID: output.interactionID,
            isLocalChat: inferenceBackend == .local,
            userMessage: userMessage,
            reply: reply,
            actions: [],
            schedule: nil
        )
        return CompanionChatResult(
            reply: reply,
            actions: [],
            schedule: nil,
            usedModelIdentifier: output.usedModelIdentifier
                ?? resolvedModelIdentifier(
                    for: inferenceBackend,
                    onlineModelIdentifier: onlineTextModelIdentifier ?? onlineModelIdentifier,
                    localModelIdentifier: localTextModelIdentifier
                ),
            interactionID: output.interactionID
        )
    }

    private func annotateChatInteraction(
        interactionID: String?,
        isLocalChat: Bool,
        userMessage: String,
        reply: String,
        actions: [CompanionChatAction],
        schedule: ScheduledActionCandidate?
    ) async {
        guard let interactionID else { return }
        var fields: [String: String] = [
            "userMessage": userMessage.cleanedSingleLine.truncatedForPrompt(maxLength: 500),
            "replyPreview": reply.cleanedSingleLine.truncatedForPrompt(maxLength: 500),
            "actionsCount": String(actions.count),
        ]
        if !actions.isEmpty {
            fields["actionKinds"] = actions.map { $0.kind.rawValue }.joined(separator: ", ")
        }
        if let schedule {
            fields["scheduleKind"] = schedule.kind.rawValue
            fields["scheduleDelayMinutes"] = String(schedule.delayMinutes)
        }
        let parsed: String? = {
            struct ParsedSummary: Encodable {
                var reply: String
                var actions: [CompanionChatAction]
                var scheduleKind: String?
                var scheduleDelayMinutes: Int?
            }
            let p = ParsedSummary(
                reply: reply,
                actions: actions,
                scheduleKind: schedule?.kind.rawValue,
                scheduleDelayMinutes: schedule?.delayMinutes
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            guard let data = try? encoder.encode(p) else { return nil }
            return String(data: data, encoding: .utf8)
        }()
        await LLMTelemetryRecorder.shared.annotate(
            LLMTelemetryAnnotation(
                interactionID: interactionID,
                kind: isLocalChat ? .localChat : .chat,
                parsedOutputJSON: parsed,
                summary: reply.cleanedSingleLine.truncatedForPrompt(maxLength: 140),
                extractedFields: fields
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
        profileContext: String,
        workflow: CompanionChatWorkflow
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

        let workflowInstruction: String
        switch workflow {
        case .direct:
            workflowInstruction = """
            Action workflow: direct.
            Return executable minimal action fields when you know them. If an action is needed
            but you are missing exact fields, return kind + instruction and AC will resolve it.
            """
        case .staged:
            workflowInstruction = """
            Action workflow: staged.
            Do NOT output executable fields. For every needed action, return only kind + instruction.
            Dedicated executor calls will resolve the details.
            """
        }

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
        \(workflowInstruction)

        Scheduled actions:
        When the user asks for a *timed* action ("nudge me in 2 min" / "remind me to focus in 10 min" / "start Coding profile in 15 min"), include a `schedule` field. The app will execute the action at the right time.
        Schedule format: {"type":"nudge","delay_minutes":2,"message":"Focus reminder!"}
        or for profiles: {"type":"profile","delay_minutes":10,"profile_name":"Coding"}
        delay_minutes max 1440 (24h). Only schedule when the user explicitly asks with a time.
        Do NOT schedule for things you can't actually do (calendar events, persistent alarms, app-restart-surviving reminders). If asked for something impossible, say so politely instead of pretending.

        Return exactly one JSON object: {"reply":"your response","actions":[],"schedule":null}
        or with actions: {"reply":"your response","actions":[{"kind":"profile","instruction":"start coding for one hour"}],"schedule":null}
        or with schedule: {"reply":"Sure, I'll nudge you in 5 min!","actions":[],"schedule":{"type":"nudge","delay_minutes":5,"message":"Focus reminder!"}}
        No markdown outside the JSON value. No other keys.
        """
    }

    func resolveAction(
        _ request: ChatActionResolutionRequest
    ) async -> CompanionChatAction? {
        let systemPrompt: String
        let maxTokens: Int
        switch request.action.kind {
        case .profile:
            systemPrompt = ACPromptSets.profileActionExecutorSystemPrompt
            maxTokens = 400
        case .memory:
            systemPrompt = ACPromptSets.memoryActionExecutorSystemPrompt
            maxTokens = 500
        case .focusPolicy:
            systemPrompt = ACPromptSets.focusPolicyActionExecutorSystemPrompt
            maxTokens = 700
        case .recurringNudge:
            return request.action
        }

        let userPrompt = ACPromptSets.renderChatActionExecutorUserPrompt(
            payloadJSON: Self.makeActionPayloadJSON(request)
        )
        let options = RuntimeInferenceOptions(
            maxTokens: maxTokens,
            temperature: 0.08,
            topP: 0.9,
            topK: 40,
            ctxSize: 4096,
            batchSize: 1024,
            ubatchSize: 512,
            timeoutSeconds: 35
        )

        let output: RuntimeProcessOutput
        let resolveStartedAt = Date()
        do {
            if request.inferenceBackend == .openRouter {
                output = try await onlineModelService.runInference(
                    OnlineModelRequest(
                        source: .chatAction,
                        modelIdentifier: request.onlineTextModelIdentifier ?? request.onlineModelIdentifier,
                        systemPrompt: systemPrompt,
                        userPrompt: userPrompt,
                        imagePath: nil,
                        options: options
                    ),
                    parentInteractionID: request.parentInteractionID
                )
            } else {
                let runtimePath = RuntimeSetupService.normalizedRuntimePath(from: request.runtimeOverride)
                guard FileManager.default.isExecutableFile(atPath: runtimePath),
                      let localTextModelIdentifier = request.localTextModelIdentifier,
                      !localTextModelIdentifier.isEmpty else {
                    return nil
                }
                do {
                    var localOutput = try await runtime.runTextInference(
                        runtimePath: runtimePath,
                        modelIdentifier: localTextModelIdentifier,
                        systemPrompt: systemPrompt,
                        userPrompt: userPrompt,
                        options: options
                    )
                    let interactionID = await LLMTelemetryRecorder.shared.record(
                        LLMTelemetryCall(
                            kind: .chatAction,
                            parentInteractionID: request.parentInteractionID,
                            runtime: .llamaCpp,
                            modelIdentifier: localOutput.usedModelIdentifier ?? localTextModelIdentifier,
                            promptMode: "chat-action",
                            systemPrompt: systemPrompt,
                            userPrompt: userPrompt,
                            requestPayloadJSON: nil,
                            imagePath: nil,
                            startedAt: resolveStartedAt,
                            endedAt: Date(),
                            rawStdout: localOutput.stdout,
                            rawStderr: localOutput.stderr,
                            tokenUsage: localOutput.tokenUsage,
                            failure: nil,
                            summary: ""
                        )
                    )
                    localOutput.interactionID = interactionID
                    output = localOutput
                } catch {
                    await LLMTelemetryRecorder.shared.record(
                        LLMTelemetryCall(
                            kind: .chatAction,
                            parentInteractionID: request.parentInteractionID,
                            runtime: .llamaCpp,
                            modelIdentifier: localTextModelIdentifier,
                            promptMode: "chat-action",
                            systemPrompt: systemPrompt,
                            userPrompt: userPrompt,
                            requestPayloadJSON: nil,
                            imagePath: nil,
                            startedAt: resolveStartedAt,
                            endedAt: Date(),
                            rawStdout: nil,
                            rawStderr: nil,
                            tokenUsage: nil,
                            failure: LLMInteractionFailure(
                                domain: String(describing: type(of: error)),
                                message: error.localizedDescription
                            ),
                            summary: "local chat-action failed"
                        )
                    )
                    throw error
                }
            }
        } catch {
            await ActivityLogService.shared.append(
                category: "chat-action-error",
                message: error.localizedDescription
            )
            return nil
        }

        let combined = [output.stdout, output.stderr].filter { !$0.isEmpty }.joined(separator: "\n")
        if let action = LLMOutputParsing.extractChatAction(from: combined, expectedKind: request.action.kind) {
            await annotateChatActionInteraction(
                interactionID: output.interactionID,
                parentInteractionID: request.parentInteractionID,
                request: request,
                resolved: action
            )
            return action
        }
        await ActivityLogService.shared.append(
            category: "chat-action-parse-error",
            message: "Could not parse \(request.action.kind.rawValue) action JSON. Raw output: \(combined.cleanedSingleLine.truncatedForPrompt(maxLength: 700))"
        )
        return nil
    }

    nonisolated private static func makeActionPayloadJSON(_ request: ChatActionResolutionRequest) -> String {
        struct Payload: Encodable {
            var actionHint: CompanionChatAction
            var latestUserMessage: String
            var recentUserMessages: [String]
            var goals: String
            var freeFormMemory: String
            var policyRules: String
            var context: FrontmostContext?
            var activeProfile: ProfilePromptSummary
            var availableProfiles: [ProfilePromptSummary]
        }

        let payload = Payload(
            actionHint: request.action,
            latestUserMessage: request.latestUserMessage,
            recentUserMessages: request.recentUserMessages,
            goals: request.goals,
            freeFormMemory: request.freeFormMemory,
            policyRules: request.policyRules,
            context: request.context,
            activeProfile: request.activeProfile,
            availableProfiles: request.availableProfiles
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(payload),
              let json = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return json
    }

    private func annotateChatActionInteraction(
        interactionID: String?,
        parentInteractionID: String?,
        request: ChatActionResolutionRequest,
        resolved: CompanionChatAction
    ) async {
        guard let interactionID else { return }
        var fields: [String: String] = [
            "actionKind": resolved.kind.rawValue,
            "instruction": (request.action.instruction ?? "").cleanedSingleLine.truncatedForPrompt(maxLength: 300),
        ]
        if let intent = resolved.intent { fields["intent"] = intent }
        if let id = resolved.profileID { fields["profileID"] = id }
        if let name = resolved.profileName { fields["profileName"] = name }
        if let scope = resolved.scope { fields["scope"] = scope }
        if let target = resolved.target?.value ?? resolved.target?.type { fields["target"] = target }
        if let text = resolved.text { fields["text"] = text.truncatedForPrompt(maxLength: 200) }
        if let duration = resolved.durationMinutes { fields["durationMinutes"] = String(duration) }
        if let parent = parentInteractionID { fields["parentInteractionID"] = parent }
        let parsed: String? = {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            guard let data = try? encoder.encode(resolved) else { return nil }
            return String(data: data, encoding: .utf8)
        }()
        await LLMTelemetryRecorder.shared.annotate(
            LLMTelemetryAnnotation(
                interactionID: interactionID,
                kind: .chatAction,
                parentInteractionID: parentInteractionID,
                parsedOutputJSON: parsed,
                summary: "\(resolved.kind.rawValue): \(resolved.intent ?? resolved.profileName ?? "—")",
                extractedFields: fields
            )
        )
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

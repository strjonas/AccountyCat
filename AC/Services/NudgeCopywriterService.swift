//
//  NudgeCopywriterService.swift
//  AC
//

import Foundation

// MARK: - NudgeCopywriting

/// Crafts the actual text of a nudge once the bandit has chosen a tone.
///
/// The bandit decides *whether* and with *what intensity* to intervene; this service
/// decides *exactly what to say*. Splitting these responsibilities keeps the bandit's
/// learning signal clean: the arm encodes the intervention class, the LLM fills in
/// natural-language content that matches the arm's tone and the current context.
protocol NudgeCopywriting: Sendable {
    /// Returns a short nudge string matching the tone of `arm`, or nil if generation
    /// fails (callers should fall back to a pre-written `candidateNudge`).
    func craftNudge(
        arm: BanditArm,
        request: NudgeCopywriteRequest,
        runtimePath: String
    ) async -> String?
}

// MARK: - NudgeCopywriteRequest

struct NudgeCopywriteRequest: Sendable {
    var goals: String
    var memory: String
    var appName: String
    var windowTitle: String?
    var contentSummary: String
    var recentNudgeMessages: [String]
    var candidateNudge: String?
    var timestamp: Date
    /// Personality prefix from the selected ACCharacter — prepended to the system prompt.
    var characterPersonalityPrefix: String = ""
}

// MARK: - Service

/// Local-LLM-backed nudge copywriter. Calls the runtime with a tone-specific prompt per arm.
actor NudgeCopywriterService: NudgeCopywriting {
    private let runtime: LocalModelRuntime
    private let modelIdentifier: String

    init(
        runtime: LocalModelRuntime,
        modelIdentifier: String = LocalModelRuntime.defaultModelIdentifier
    ) {
        self.runtime = runtime
        self.modelIdentifier = modelIdentifier
    }

    func craftNudge(
        arm: BanditArm,
        request: NudgeCopywriteRequest,
        runtimePath: String
    ) async -> String? {
        guard let toneKey = arm.toneKey else { return nil }
        guard FileManager.default.isExecutableFile(atPath: runtimePath) else { return nil }

        let baseSystem = PromptCatalog.loadNudgeCopywriterSystemPrompt(tone: toneKey)
        let system = request.characterPersonalityPrefix.isEmpty
            ? baseSystem
            : request.characterPersonalityPrefix + "\n\n" + baseSystem
        let payload = Self.makePayloadJSON(request: request)
        let user = PromptCatalog.loadNudgeCopywriterUserPrompt(
            tone: toneKey,
            replacingPayloadWith: payload
        )

        let output: RuntimeProcessOutput
        do {
            output = try await runtime.runTextInference(
                runtimePath: runtimePath,
                modelIdentifier: modelIdentifier,
                systemPrompt: system,
                userPrompt: user
            )
        } catch {
            await ActivityLogService.shared.append(
                category: "copywriter-error",
                message: error.localizedDescription
            )
            return nil
        }

        return Self.extractNudge(from: output.stdout + "\n" + output.stderr)
    }

    // MARK: - Payload + parsing

    static func makePayloadJSON(request: NudgeCopywriteRequest) -> String {
        let payload: [String: Any] = [
            "goals": request.goals,
            "memory": request.memory,
            "frontmost_app": request.appName,
            "window_title": request.windowTitle ?? "",
            "content_summary": request.contentSummary,
            "recent_nudge_messages": request.recentNudgeMessages,
            "candidate_nudge": request.candidateNudge ?? "",
            "timestamp": ISO8601DateFormatter().string(from: request.timestamp),
        ]
        guard
            let data = try? JSONSerialization.data(
                withJSONObject: payload,
                options: .sortedKeys
            ),
            let json = String(data: data, encoding: .utf8)
        else { return "{}" }
        return json
    }

    /// Extracts the nudge string from model output. The prompt instructs the model to
    /// return `{"nudge":"..."}`; if that isn't found we fall back to the last quoted
    /// line, and ultimately to nil (caller uses `candidateNudge`).
    static func extractNudge(from output: String) -> String? {
        for json in LLMOutputParsing.jsonObjects(in: output).reversed() {
            guard
                let data = json.data(using: .utf8),
                let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let nudge = obj["nudge"] as? String
            else { continue }
            let trimmed = nudge.cleanedSingleLine
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }
}

// MARK: - BanditArm ↔ prompt tone mapping

extension BanditArm {
    /// Tone directory name — matches the subdirectory under `AC/Resources/Prompts/Nudge/`.
    /// `.none` and `.overlay` don't require text generation.
    var toneKey: String? {
        switch self {
        case .supportiveNudge:  return "supportive"
        case .challengingNudge: return "challenging"
        case .none, .overlay:   return nil
        }
    }
}

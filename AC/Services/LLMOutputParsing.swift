//
//  LLMOutputParsing.swift
//  AC
//
//  Created by Codex on 15.04.26.
//

import Foundation

enum LLMOutputParsing {
    nonisolated static func extractChatReply(from output: String) -> String? {
        extractChatResult(from: output)?.reply
    }

    /// Parses the combined chat reply object:
    /// `{"reply":"...", "actions": [], "schedule": null}`.
    nonisolated static func extractChatResult(from output: String) -> CompanionChatResult? {
        for json in jsonObjects(in: output).reversed() {
            guard let data = json.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let reply = object["reply"] as? String else {
                continue
            }

            let cleanedReply = reply.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleanedReply.isEmpty else { continue }

            let actions = decodeActions(from: object["actions"])

            let scheduleCandidate = Self.parseScheduleCandidate(from: object)

            return CompanionChatResult(
                reply: cleanedReply,
                actions: actions,
                schedule: scheduleCandidate
            )
        }

        return nil
    }

    nonisolated static func extractChatAction(
        from output: String,
        expectedKind: CompanionChatActionKind
    ) -> CompanionChatAction? {
        let decoder = JSONDecoder()
        for json in jsonObjects(in: output).reversed() {
            guard let data = json.data(using: .utf8) else { continue }
            if let payload = try? decoder.decode(CompanionChatActionResolutionPayload.self, from: data),
               payload.action.kind == expectedKind || (expectedKind == .focusPolicy && payload.action.kind == .memory) {
                return payload.action
            }
            if let action = try? decoder.decode(CompanionChatAction.self, from: data),
               action.kind == expectedKind || (expectedKind == .focusPolicy && action.kind == .memory) {
                return action
            }
            // Tolerant fallback: model collapsed kind + intent into the kind slot,
            // e.g. {"action":{"kind":"end"}} instead of {"action":{"kind":"profile","intent":"end"}}.
            if let salvaged = salvageCollapsedAction(data: data, expectedKind: expectedKind) {
                return salvaged
            }
        }
        return nil
    }

    /// Handles the case where a small model emits the intent value in the `kind` field instead of
    /// using a separate `intent` field. Remaps known intent literals to the correct kind + intent.
    nonisolated private static func salvageCollapsedAction(
        data: Data,
        expectedKind: CompanionChatActionKind
    ) -> CompanionChatAction? {
        guard let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

        let inner: [String: Any]
        if let wrapped = raw["action"] as? [String: Any] {
            inner = wrapped
        } else {
            inner = raw
        }

        guard let kindValue = (inner["kind"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !kindValue.isEmpty else { return nil }

        // Map known intent literals back to their parent action kind.
        let profileIntents: Set<String> = ["end", "stop", "end_active", "end_active_profile",
                                           "activate", "switch", "start",
                                           "create", "create_and_activate", "update"]
        let focusPolicyIntents: Set<String> = ["allow", "disallow", "discourage", "limit"]

        let remappedKind: CompanionChatActionKind
        switch expectedKind {
        case .profile where profileIntents.contains(kindValue):
            remappedKind = .profile
        case .focusPolicy where focusPolicyIntents.contains(kindValue):
            remappedKind = .focusPolicy
        default:
            return nil
        }

        // Reconstruct with the correct kind and the collapsed value as intent.
        var rebuilt = inner
        rebuilt["kind"] = remappedKind.rawValue
        // Only set intent if there isn't already one.
        if rebuilt["intent"] == nil {
            rebuilt["intent"] = kindValue
        }

        guard let rebuiltData = try? JSONSerialization.data(withJSONObject: rebuilt),
              let action = try? JSONDecoder().decode(CompanionChatAction.self, from: rebuiltData) else { return nil }
        return action
    }

    nonisolated static func extractDecision(from output: String) -> LLMDecision? {
        let candidateObjects = jsonObjects(in: output).reversed()

        for json in candidateObjects {
            guard let data = json.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }

            let assessmentString =
                (object["assessment"] as? String) ??
                                (object["verdict"] as? String) ??
                                (object["focus_guess"] as? String)
            guard let assessmentString,
                                    let assessment = parsedAssessment(from: assessmentString) else {
                continue
            }

            let suggestedActionString =
                (object["suggested_action"] as? String) ??
                (object["suggestedAction"] as? String) ??
                (object["action"] as? String) ??
                inferredSuggestedAction(
                    assessment: assessment,
                    nudge: object["nudge"] as? String
                )

            let suggestedAction = parsedSuggestedAction(from: suggestedActionString)
            let confidence = object["confidence"] as? Double
            let reasonTags =
                (object["reason_tags"] as? [String]) ??
                (object["reasonTags"] as? [String]) ??
                []
            let nudge = (object["nudge"] as? String)?.cleanedSingleLine
            let abstainReason =
                (object["abstain_reason"] as? String) ??
                (object["abstainReason"] as? String)
            let normalizedSuggestedAction = normalizedSuggestedAction(
                suggestedAction,
                assessment: assessment,
                nudge: nudge
            )

            return LLMDecision(
                assessment: assessment,
                suggestedAction: normalizedSuggestedAction,
                confidence: confidence,
                reasonTags: reasonTags,
                nudge: nudge,
                abstainReason: abstainReason?.cleanedSingleLine
            )
        }

        return nil
    }

    nonisolated static func jsonObjects(in output: String) -> [String] {
        StructuredOutputJSON.jsonObjects(in: output)
    }

    nonisolated private static func decodeActions(from value: Any?) -> [CompanionChatAction] {
        guard let rawActions = value as? [[String: Any]], !rawActions.isEmpty else {
            return []
        }
        let decoder = JSONDecoder()
        return rawActions.compactMap { raw in
            guard JSONSerialization.isValidJSONObject(raw),
                  let data = try? JSONSerialization.data(withJSONObject: raw),
                  let action = try? decoder.decode(CompanionChatAction.self, from: data) else {
                return nil
            }
            let hasInstruction = action.instruction?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            let hasExecutableField = action.intent?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ||
                action.text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            return hasInstruction || hasExecutableField ? action : nil
        }
    }

    nonisolated static func cleanChatOutput(_ output: String) -> String {
        if isLikelyMonitoringOutput(output) {
            return "I had trouble understanding that. Could you rephrase?"
        }

        if let partialReply = extractPartialChatReply(from: output) {
            return partialReply
        }

        let normalized = output
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        let lines = normalized
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

        let runtimeNoisePrefixes = [
            "main:", "build", "model", "modalities", "available commands:",
            "loading model", "using custom system prompt",
            "/exit", "/clear", "/repl", "/image", "/audio",
            "ggml_", "llama_", "srv", "system_info", "load_backend",
            "tensor"
        ]

        let cleanedLines = lines.filter { line in
            guard !line.isEmpty else { return false }

            let lowercasedLine = line.lowercased()
            if lowercasedLine == "exiting" ||
                lowercasedLine == "exiting." ||
                lowercasedLine == "exiting..." {
                return false
            }
            if lowercasedLine.contains("prompt eval") ||
                lowercasedLine.contains("eval time") ||
                lowercasedLine.contains("generation:") ||
                lowercasedLine.hasPrefix("usage prompt_tokens=") {
                return false
            }

            for prefix in runtimeNoisePrefixes where lowercasedLine.hasPrefix(prefix) {
                return false
            }
            return true
        }

        let candidateLines: [String]
        if let instructionIndex = cleanedLines.lastIndex(where: { $0.lowercased().hasPrefix("reply as accountycat") }) {
            candidateLines = Array(cleanedLines.suffix(from: cleanedLines.index(after: instructionIndex)))
        } else {
            candidateLines = cleanedLines
        }

        let joined = candidateLines
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let trimmedLeadingArtifacts = joined.drop(while: { character in
            let scalar = character.unicodeScalars.first
            let isAlphaNumeric = scalar.map { CharacterSet.alphanumerics.contains($0) } ?? false
            return !isAlphaNumeric
        })
        let normalizedLeading = String(trimmedLeadingArtifacts)

        if normalizedLeading.hasPrefix("I- ") {
            return String(normalizedLeading.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let lowercasedLeading = normalizedLeading.lowercased()
        if lowercasedLeading.localizedCaseInsensitiveContains("prompt_tokens=") ||
            lowercasedLeading.localizedCaseInsensitiveContains("completion_tokens=") {
            return "I had trouble formatting that reply. Send it again and I'll keep it short."
        }
        if lowercasedLeading.hasPrefix("reply:") ||
            lowercasedLeading.hasPrefix("reply\":") ||
            lowercasedLeading.hasPrefix("\"reply\":") {
            return "I had trouble formatting that reply. Send it again and I'll keep it short."
        }

        return normalizedLeading
    }

    nonisolated private static func extractPartialChatReply(from output: String) -> String? {
        let normalized = output
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        guard let keyRange = normalized.range(of: #""?reply"?\s*:\s*""#, options: .regularExpression) else {
            return nil
        }

        let valueStart = keyRange.upperBound
        var current = valueStart
        var result = ""
        var escaping = false

        while current < normalized.endIndex {
            let character = normalized[current]
            if escaping {
                switch character {
                case "n": result.append("\n")
                case "r": result.append("\r")
                case "t": result.append("\t")
                case "\"": result.append("\"")
                case "\\": result.append("\\")
                default: result.append(character)
                }
                escaping = false
            } else if character == "\\" {
                escaping = true
            } else if character == "\"" {
                break
            } else {
                result.append(character)
            }
            current = normalized.index(after: current)
        }

        let cleaned = result
            .components(separatedBy: .newlines)
            .filter {
                let line = $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                return !line.hasPrefix("usage prompt_tokens=")
            }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty,
              !cleaned.localizedCaseInsensitiveContains("prompt_tokens="),
              !cleaned.localizedCaseInsensitiveContains("completion_tokens=") else {
            return nil
        }
        return cleaned
    }

    nonisolated private static func inferredSuggestedAction(
        assessment: ModelAssessment,
        nudge: String?
    ) -> String {
        switch assessment {
        case .focused:
            return "none"
        case .unclear:
            return "abstain"
        case .distracted:
            return (nudge?.cleanedSingleLine.isEmpty == false) ? "nudge" : "abstain"
        }
    }

    nonisolated private static func normalizedSuggestedAction(
        _ suggestedAction: ModelSuggestedAction,
        assessment: ModelAssessment,
        nudge: String?
    ) -> ModelSuggestedAction {
        switch assessment {
        case .focused:
            return .none
        case .unclear:
            return .abstain
        case .distracted:
            if suggestedAction == .overlay || suggestedAction == .nudge {
                return suggestedAction
            }
            return (nudge?.cleanedSingleLine.isEmpty == false) ? .nudge : .abstain
        }
    }

    nonisolated private static func parsedAssessment(from rawValue: String) -> ModelAssessment? {
        let normalized = rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        if let direct = ModelAssessment(rawValue: normalized) {
            return direct
        }

        switch normalized {
        case "focus", "on_task":
            return .focused
        case "off_task", "distract", "distracted":
            return .distracted
        case "unknown", "abstain":
            return .unclear
        default:
            return nil
        }
    }

    nonisolated private static func isLikelyMonitoringOutput(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let monitoringKeys = ["activity_summary", "focus_guess", "reason_tags"]
        return monitoringKeys.contains { trimmed.contains("\"\($0)\"") }
    }

    nonisolated private static func parsedSuggestedAction(from rawValue: String) -> ModelSuggestedAction {
        let normalized = rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        if let direct = ModelSuggestedAction(rawValue: normalized) {
            return direct
        }

        switch normalized {
        case "no_action", "no-action":
            return .none
        case "escalate", "interrupt":
            return .overlay
        default:
            return .abstain
        }
    }

    nonisolated private static func parseScheduleCandidate(from object: [String: Any]) -> ScheduledActionCandidate? {
        guard let scheduleDict = object["schedule"] as? [String: Any] else { return nil }

        let kindString = (scheduleDict["type"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            ?? (scheduleDict["kind"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let kindString,
              let kind = ScheduledActionCandidate.Kind(rawValue: kindString) else { return nil }

        let delayMinutes: Int
        if let d = scheduleDict["delay_minutes"] as? Int {
            delayMinutes = d
        } else if let d = scheduleDict["delayMinutes"] as? Int {
            delayMinutes = d
        } else if let d = scheduleDict["delay"] as? Int {
            delayMinutes = d
        } else {
            return nil
        }

        guard delayMinutes > 0, delayMinutes <= 1440 else { return nil } // max 24h

        let message = (scheduleDict["message"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let profileName = (scheduleDict["profile_name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? (scheduleDict["profileName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)

        return ScheduledActionCandidate(
            kind: kind,
            delayMinutes: delayMinutes,
            message: message.flatMap { $0.isEmpty ? nil : $0 },
            profileName: profileName.flatMap { $0.isEmpty ? nil : $0 }
        )
    }
}

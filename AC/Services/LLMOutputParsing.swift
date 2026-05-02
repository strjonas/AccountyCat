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
    /// `{"reply":"...", "memory": null | "short bullet", "profile_action": null | "instruction"}`.
    /// Falls back to a reply-only shape if the `memory` key is missing.
    nonisolated static func extractChatResult(from output: String) -> CompanionChatResult? {
        for json in jsonObjects(in: output).reversed() {
            guard let data = json.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let reply = object["reply"] as? String else {
                continue
            }

            let cleanedReply = reply.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleanedReply.isEmpty else { continue }

            let memoryValue = (object["memory"] as? String)
                ?? (object["memory_update"] as? String)
                ?? (object["memoryUpdate"] as? String)
            let trimmedMemory = memoryValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedMemory: String?
            if let trimmedMemory,
               !trimmedMemory.isEmpty,
               trimmedMemory.lowercased() != "none",
               trimmedMemory.lowercased() != "null" {
                normalizedMemory = trimmedMemory
            } else {
                normalizedMemory = nil
            }

            let profileActionValue = (object["profile_action"] as? String)
                ?? (object["profileAction"] as? String)
            let trimmedProfileAction = profileActionValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedProfileAction: String?
            if let trimmedProfileAction,
               !trimmedProfileAction.isEmpty,
               trimmedProfileAction.lowercased() != "none",
               trimmedProfileAction.lowercased() != "null" {
                normalizedProfileAction = trimmedProfileAction
            } else {
                normalizedProfileAction = nil
            }

            return CompanionChatResult(
                reply: cleanedReply,
                memoryUpdate: normalizedMemory,
                profileAction: normalizedProfileAction
            )
        }

        return nil
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

    nonisolated static func cleanChatOutput(_ output: String) -> String {
        if isLikelyMonitoringOutput(output) {
            return "I had trouble understanding that. Could you rephrase?"
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
                lowercasedLine.contains("generation:") {
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

        return normalizedLeading
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
}

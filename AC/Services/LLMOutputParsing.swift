//
//  LLMOutputParsing.swift
//  AC
//
//  Created by Codex on 15.04.26.
//

import Foundation

enum LLMOutputParsing {
    nonisolated static func extractChatReply(from output: String) -> String? {
        for json in jsonObjects(in: output).reversed() {
            guard let data = json.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let reply = object["reply"] as? String else {
                continue
            }

            let cleaned = reply.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleaned.isEmpty {
                return cleaned
            }
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
                (object["verdict"] as? String)
            guard let assessmentString,
                  let assessment = ModelAssessment(rawValue: assessmentString) else {
                continue
            }

            let suggestedActionString =
                (object["suggested_action"] as? String) ??
                (object["suggestedAction"] as? String) ??
                inferredSuggestedAction(
                    assessment: assessment,
                    nudge: object["nudge"] as? String
                )

            let suggestedAction = ModelSuggestedAction(rawValue: suggestedActionString) ?? .abstain
            let confidence = object["confidence"] as? Double
            let reasonTags =
                (object["reason_tags"] as? [String]) ??
                (object["reasonTags"] as? [String]) ??
                []
            let nudge = (object["nudge"] as? String)?.cleanedSingleLine
            let abstainReason =
                (object["abstain_reason"] as? String) ??
                (object["abstainReason"] as? String)

            return LLMDecision(
                assessment: assessment,
                suggestedAction: suggestedAction,
                confidence: confidence,
                reasonTags: reasonTags,
                nudge: nudge,
                abstainReason: abstainReason?.cleanedSingleLine
            )
        }

        return nil
    }

    nonisolated static func jsonObjects(in output: String) -> [String] {
        var results: [String] = []
        var startIndex: String.Index?
        var currentIndex = output.startIndex
        var depth = 0
        var insideString = false
        var escaping = false

        while currentIndex < output.endIndex {
            let character = output[currentIndex]

            if insideString {
                if escaping {
                    escaping = false
                } else if character == "\\" {
                    escaping = true
                } else if character == "\"" {
                    insideString = false
                }

                currentIndex = output.index(after: currentIndex)
                continue
            }

            if character == "\"" {
                insideString = true
                currentIndex = output.index(after: currentIndex)
                continue
            }

            if character == "{" {
                if depth == 0 {
                    startIndex = currentIndex
                }
                depth += 1
            } else if character == "}" {
                guard depth > 0 else {
                    currentIndex = output.index(after: currentIndex)
                    continue
                }

                depth -= 1
                if depth == 0, let objectStartIndex = startIndex {
                    let endIndex = output.index(after: currentIndex)
                    results.append(String(output[objectStartIndex..<endIndex]))
                    startIndex = nil
                }
            }

            currentIndex = output.index(after: currentIndex)
        }

        return results
    }

    nonisolated static func cleanChatOutput(_ output: String) -> String {
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
}

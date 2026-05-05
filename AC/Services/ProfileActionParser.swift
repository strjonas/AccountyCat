//
//  ProfileActionParser.swift
//  AC
//
//  Fast-path parser for common natural-language profile actions emitted by the chat LLM.
//  Bypasses the policy-memory LLM pipeline for well-understood profile lifecycle commands,
//  which makes profile switching reliable on small local models that struggle with the
//  full structured-policy-memory JSON schema.
//

import Foundation

enum ProfileActionParser {
    /// Attempts to parse a natural-language profile action into structured operations.
    /// Returns `nil` when the phrase does not look like a recognised profile lifecycle
    /// command, so the caller can fall back to the policy-memory LLM pipeline.
    static func parse(
        action: String,
        availableProfiles: [FocusProfile],
        activeProfileID: String
    ) -> [PolicyMemoryOperation]? {
        let cleaned = action.cleanedSingleLine
        let lower = cleaned.lowercased()

        // ── End profile ──
        if lower.contains("end active") || lower.contains("end profile") || lower == "end" {
            return [PolicyMemoryOperation(type: .endActiveProfile)]
        }

        // ── Determine intent ──
        let isCreate = lower.contains("create") || lower.contains("set up") || lower.contains("setup")
        let isLifecycle = isCreate
            || lower.contains("activate")
            || lower.contains("switch to")
            || lower.contains("start")

        guard isLifecycle else { return nil }

        guard let profileName = extractProfileName(from: cleaned) else { return nil }
        let trimmedName = profileName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return nil }

        let durationMinutes = extractDuration(from: lower)

        // Try to match an existing profile (case-insensitive, generous substring match).
        let matchedProfile = availableProfiles.first { p in
            p.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                == trimmedName.lowercased()
        } ?? availableProfiles.first { p in
            let pName = p.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let query = trimmedName.lowercased()
            return pName.contains(query) || query.contains(pName)
        }

        if let matched = matchedProfile, !isCreate {
            return [PolicyMemoryOperation(
                type: .activateProfile,
                profileID: matched.id,
                profileDurationMinutes: durationMinutes
            )]
        }

        return [PolicyMemoryOperation(
            type: .createAndActivateProfile,
            profileName: trimmedName,
            profileDurationMinutes: durationMinutes
        )]
    }

    // MARK: - Private helpers

    private static func extractProfileName(from text: String) -> String? {
        let lower = text.lowercased()

        // Pattern: "… Name profile …"  (e.g. "activate Coding profile for 60 min")
        // We intentionally capture only the single word directly before "profile"
        // so we don't accidentally suck in leading verbs like "create and activate".
        if let regex = try? NSRegularExpression(pattern: #"\b([A-Za-z][A-Za-z0-9]*)\s+profile\b"#, options: .caseInsensitive),
           let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let nameRange = Range(match.range(at: 1), in: text) {
            let name = String(text[nameRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            if name.count >= 2,
               !["activate", "create", "switch", "start", "set", "and"].contains(name.lowercased()) {
                return name
            }
        }

        // Pattern: "… profile Name …"  (e.g. "create and activate profile Coding for 60 min")
        if let profileRange = lower.range(of: "profile") {
            let after = String(text[profileRange.upperBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let words = after.split(separator: " ", omittingEmptySubsequences: true)
            if let first = words.first {
                let candidate = String(first)
                    .trimmingCharacters(in: CharacterSet(charactersIn: ",.;:!"))
                if candidate.count >= 2 {
                    return candidate
                }
            }
        }

        // Fallback: grab the first real word after a known verb.
        let verbs = ["activate", "switch to", "start", "create and activate", "set up"]
        for verb in verbs {
            guard let range = lower.range(of: verb) else { continue }
            let remainder = String(text[range.upperBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let words = remainder.split(separator: " ", omittingEmptySubsequences: true)
            if let first = words.first {
                let candidate = String(first)
                    .trimmingCharacters(in: CharacterSet(charactersIn: ",.;:!"))
                if candidate.count >= 2, candidate.lowercased() != "profile" {
                    return candidate
                }
            }
        }

        return nil
    }

    private static func extractDuration(from text: String) -> Int? {
        let patterns: [(String, Int)] = [
            (#"for\s+(\d+)\s*(hour|hours|h)\b"#, 60),
            (#"for\s+(\d+)\s*(min|minute|minutes|m)\b"#, 1),
            (#"(\d+)\s*(hour|hours|h)\b"#, 60),
            (#"(\d+)\s*(min|minute|minutes|m)\b"#, 1),
        ]

        for (pattern, multiplier) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
                  let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let numberRange = Range(match.range(at: 1), in: text),
                  let number = Int(text[numberRange]) else { continue }
            return number * multiplier
        }
        return nil
    }
}

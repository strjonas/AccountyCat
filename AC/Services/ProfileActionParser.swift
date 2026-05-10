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
        if looksLikeEndProfileCommand(lower) {
            return [PolicyMemoryOperation(type: .endActiveProfile)]
        }

        // ── Determine intent ──
        let isCreate = lower.contains("create") || lower.contains("set up") || lower.contains("setup")
        let isLifecycle = isCreate
            || lower.contains("activate")
            || lower.contains("switch to")
            || lower.contains("start")
            || lower.contains("schedule")

        guard isLifecycle else { return nil }

        guard let profileName = extractProfileName(from: cleaned, preferVerbFallback: isCreate) else { return nil }
        let trimmedName = profileName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return nil }

        let durationMinutes = extractDuration(from: lower)
        let recurringSchedule = extractRecurringSchedule(from: cleaned)

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
                profileDurationMinutes: durationMinutes,
                recurringSchedule: recurringSchedule
            )]
        }

        return [PolicyMemoryOperation(
            type: .createAndActivateProfile,
            profileName: trimmedName,
            profileDurationMinutes: durationMinutes,
            recurringSchedule: recurringSchedule
        )]
    }

    // MARK: - Private helpers

    private static func looksLikeEndProfileCommand(_ lower: String) -> Bool {
        if lower == "end" { return true }
        let patterns = [
            #"\bend\s+active\b"#,
            #"\bend\s+(the\s+)?profile\b"#,
            #"\bstop\s+(the\s+)?profile\b"#,
        ]
        return patterns.contains { pattern in
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
                return false
            }
            return regex.firstMatch(in: lower, range: NSRange(lower.startIndex..., in: lower)) != nil
        }
    }

    private static func extractProfileName(from text: String, preferVerbFallback: Bool = false) -> String? {
        let lower = text.lowercased()

        if preferVerbFallback, let name = extractProfileNameAfterVerb(from: text, lower: lower) {
            return name
        }

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
        return extractProfileNameAfterVerb(from: text, lower: lower)
    }

    private static func extractProfileNameAfterVerb(from text: String, lower: String) -> String? {
        let verbs = ["create and activate", "activate", "switch to", "start", "set up", "schedule"]
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

    // MARK: - Recurring schedule extraction

    private static func extractRecurringSchedule(from text: String) -> RecurringSchedule? {
        let lower = text.lowercased()

        // Must have a recurring signal word
        let recurringWords = ["always", "every day", "everyday", "daily", "each day", "every morning",
                              "every evening", "every night", "every weekday", "every week", "regularly",
                              "on weekdays", "on weekday", "on weekends", "on weekend", "recurring", "schedule"]
        guard recurringWords.contains(where: lower.contains) else { return nil }

        guard let (hour, minute) = extractTimeOfDay(from: text) else { return nil }

        let weekdays = extractWeekdays(from: text)

        return RecurringSchedule(hour: hour, minute: minute, weekdays: weekdays)
    }

    private static func extractTimeOfDay(from text: String) -> (hour: Int, minute: Int)? {
        // 24-hour format: "at 21:00", "at 09:30"
        if let regex = try? NSRegularExpression(pattern: #"\b(\d{1,2}):(\d{2})\b"#, options: []),
           let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let hourRange = Range(match.range(at: 1), in: text),
           let minuteRange = Range(match.range(at: 2), in: text),
           let hour = Int(text[hourRange]), let minute = Int(text[minuteRange]),
           (0...23).contains(hour), (0...59).contains(minute) {
            return (hour, minute)
        }

        // 12-hour format: "at 9PM", "at 9 pm", "at 9:00 AM", "at 7:30pm"
        let patterns: [(String, Int)] = [
            (#"(\d{1,2})\s*(pm|p\.m\.|am|a\.m\.|p\.m|a\.m)\b"#, 0),
            (#"(\d{1,2}):(\d{2})\s*(pm|p\.m\.|am|a\.m\.|p\.m|a\.m)\b"#, 0),
        ]

        for (pattern, _) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
                  let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { continue }

            let hourStr: Substring
            let minuteVal: Int
            let isPM: Bool

            if match.numberOfRanges >= 4,
               let hRange = Range(match.range(at: 1), in: text),
               let mRange = Range(match.range(at: 2), in: text),
               let ampmRange = Range(match.range(at: 3), in: text) {
                hourStr = text[hRange]
                minuteVal = Int(text[mRange]) ?? 0
                isPM = text[ampmRange].lowercased().hasPrefix("p")
            } else if match.numberOfRanges >= 3,
                      let hRange = Range(match.range(at: 1), in: text),
                      let ampmRange = Range(match.range(at: 2), in: text) {
                hourStr = text[hRange]
                minuteVal = 0
                isPM = text[ampmRange].lowercased().hasPrefix("p")
            } else {
                continue
            }

            guard var hour = Int(hourStr), (1...12).contains(hour) else { continue }
            if isPM && hour != 12 { hour += 12 }
            if !isPM && hour == 12 { hour = 0 }
            return (hour, minuteVal)
        }

        return nil
    }

    private static func extractWeekdays(from text: String) -> [Int]? {
        let lower = text.lowercased()

        // "every day" / "daily" → nil (every day)
        if lower.contains("every day") || lower.contains("daily") || lower.contains("everyday")
            || lower.contains("each day") || lower.contains("always") {
            // Check if there's also a specific weekday mention
        }

        let weekdayMap: [String: Int] = [
            "sunday": 1, "monday": 2, "tuesday": 3, "wednesday": 4,
            "thursday": 5, "friday": 6, "saturday": 7,
            "sundays": 1, "mondays": 2, "tuesdays": 3, "wednesdays": 4,
            "thursdays": 5, "fridays": 6, "saturdays": 7,
            "sun": 1, "mon": 2, "tue": 3, "wed": 4, "thu": 5, "fri": 6, "sat": 7,
        ]

        var found: Set<Int> = []
        for (key, value) in weekdayMap {
            if lower.contains(key) {
                found.insert(value)
            }
        }

        // "on weekdays" → Mon–Fri
        if lower.contains("weekday") && !lower.contains("weekends") {
            found.formUnion([2, 3, 4, 5, 6])
        }

        // "on weekends" → Sat, Sun
        if lower.contains("weekend") {
            found.formUnion([1, 7])
        }

        return found.isEmpty ? nil : found.sorted()
    }
}

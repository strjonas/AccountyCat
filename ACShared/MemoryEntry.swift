//
//  MemoryEntry.swift
//  ACShared
//
//  Timestamped memory entries for AC's persistent free-form memory.
//  The LLM is the authority for what goes in and what gets consolidated out —
//  this type just provides timestamps so stale "today" rules can be pruned
//  and recency is visible in the prompt.
//

import Foundation

public struct MemoryDisplayContent: Hashable, Sendable {
    public var category: String
    public var headline: String
    public var detail: String?

    nonisolated public init(category: String, headline: String, detail: String? = nil) {
        self.category = category
        self.headline = headline
        self.detail = detail
    }
}

public enum PromptTimestampFormatting {
    /// Local wall-clock timestamp format used inside prompts and inspector memory.
    /// Keep it absolute and compact so the model never has to interpret "today" /
    /// "yesterday" relative to a separate hidden clock.
    nonisolated public static func absoluteLabel(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }
}

public enum MemoryHeuristics {
    nonisolated public static func isUsefulLearnedMemory(_ rawText: String) -> Bool {
        let cleaned = rawText.cleanedSingleLine
        guard !cleaned.isEmpty else { return false }

        let lower = cleaned.lowercased()
        if looksLikeCasualGreeting(lower) {
            return false
        }
        if looksLikeEphemeralToneInference(lower) {
            return false
        }
        return true
    }

    nonisolated static func looksLikeCasualGreeting(_ lowercasedText: String) -> Bool {
        let trimmed = lowercasedText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".,!?;:\"'`~*-()[]"))
        let compact = trimmed.replacingOccurrences(of: "...", with: "")
        let tokens = compact.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        guard !tokens.isEmpty, tokens.count <= 4 else { return false }

        let greetingLexicon: Set<String> = [
            "hey", "heyy", "hello", "hi", "hiya", "yo", "sup", "wsup", "wassup",
            "whatsup", "whatsup", "morning", "evening", "afternoon", "there"
        ]
        return tokens.allSatisfy { greetingLexicon.contains($0) }
    }

    nonisolated private static func looksLikeEphemeralToneInference(_ lowercasedText: String) -> Bool {
        let mentionsConversationStyle =
            lowercasedText.contains("greet")
            || lowercasedText.contains("greeting")
            || lowercasedText.contains("tone")
            || lowercasedText.contains("upbeat")
            || lowercasedText.contains("high energy")
            || lowercasedText.contains("friendly")
            || lowercasedText.contains("casual")

        guard mentionsConversationStyle else { return false }

        let durableMarkers = [
            "prefer", "prefers", "always", "usually", "in general", "every time",
            "wants", "likes", "works best", "does best work", "should", "please"
        ]
        return !durableMarkers.contains(where: lowercasedText.contains)
    }
}

public struct MemoryEntry: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var createdAt: Date
    public var text: String
    /// Legacy capture context. Free-form memory is global; structured policy rules carry
    /// profile scoping. These fields remain for old state files but are not rendered.
    public var profileID: String?
    /// Display name of the profile at capture time. Stored alongside the id so renaming a
    /// profile doesn't desync the memory prefix.
    public var profileName: String?
    /// When true, this entry survives automatic memory consolidation cleanup.
    public var isLocked: Bool

    private enum CodingKeys: String, CodingKey {
        case id, createdAt, text, profileID, profileName, isLocked
    }

    nonisolated public init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        text: String,
        profileID: String? = nil,
        profileName: String? = nil,
        isLocked: Bool = false
    ) {
        self.id = id
        self.createdAt = createdAt
        self.text = text
        self.profileID = profileID
        self.profileName = profileName
        self.isLocked = isLocked
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        text = try c.decode(String.self, forKey: .text)
        profileID = try? c.decodeIfPresent(String.self, forKey: .profileID)
        profileName = try? c.decodeIfPresent(String.self, forKey: .profileName)
        isLocked = try c.decodeIfPresent(Bool.self, forKey: .isLocked) ?? false
    }
}

public enum MemoryRendering {
    /// Prompt-facing timestamp format: local wall-clock absolute time.
    /// We intentionally avoid relative labels like "today" / "yesterday" because they
    /// force the model to do extra temporal reasoning on every request.
    nonisolated public static func timestampLabel(for date: Date, now: Date) -> String {
        let _ = now
        return PromptTimestampFormatting.absoluteLabel(for: date)
    }

    /// Render entries to the compact bullet format the LLM sees.
    /// Returns empty string if no entries. Most recent entries come last
    /// (the LLM prefers recency for this kind of memory — it mimics natural chat order).
    public static func renderForPrompt(
        entries: [MemoryEntry],
        now: Date,
        maxLines: Int,
        maxCharacters: Int
    ) -> String {
        guard !entries.isEmpty else { return "" }
        let sorted = entries.sorted { $0.createdAt < $1.createdAt }
        let tail = Array(sorted.suffix(maxLines))
        var lines: [String] = []
        var totalChars = 0
        for entry in tail.reversed() {
            let cleaned = entry.text.cleanedSingleLine
            guard !cleaned.isEmpty else { continue }
            let label = timestampLabel(for: entry.createdAt, now: now)
            let profile = entry.profileName?.cleanedSingleLine
            let profileLabel = profile?.isEmpty == false ? " [\(profile ?? "")]" : ""
            let line = "[\(label)]\(profileLabel) \(cleaned)"
            let prospective = totalChars + line.count + 1
            if prospective > maxCharacters { break }
            lines.insert(line, at: 0)
            totalChars = prospective
        }
        return lines.joined(separator: "\n")
    }

    /// For UI display (inspector, chat view). Full list, chronological, newest first.
    public static func renderForDisplay(entries: [MemoryEntry], now: Date) -> String {
        guard !entries.isEmpty else { return "" }
        let sorted = entries.sorted { $0.createdAt > $1.createdAt }
        return sorted.map { entry in
            let label = timestampLabel(for: entry.createdAt, now: now)
            return "[\(label)] \(entry.text.cleanedSingleLine)"
        }.joined(separator: "\n")
    }

    public static func displayContent(for entry: MemoryEntry) -> MemoryDisplayContent {
        let raw = entry.text.cleanedSingleLine
        let strippedBullet = raw.hasPrefix("• ") ? String(raw.dropFirst(2)) : raw
        let lower = strippedBullet.lowercased()

        if MemoryHeuristics.looksLikeCasualGreeting(lower) {
            return MemoryDisplayContent(
                category: "Saved phrase",
                headline: "One-off wording from an older chat",
                detail: "\"\(strippedBullet)\""
            )
        }

        if let toneContent = toneDisplayContent(from: strippedBullet, lowercased: lower) {
            return toneContent
        }

        if lower.hasPrefix("correction:") {
            return MemoryDisplayContent(
                category: "Correction",
                headline: strippedBullet,
                detail: nil
            )
        }

        return MemoryDisplayContent(
            category: inferredCategory(for: lower),
            headline: humanize(strippedBullet),
            detail: nil
        )
    }

    nonisolated private static func toneDisplayContent(
        from text: String,
        lowercased: String
    ) -> MemoryDisplayContent? {
        let parts = text.split(separator: ";", maxSplits: 1).map {
            String($0).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard parts.count == 2 else { return nil }

        let source = parts[0].lowercased()
        let instruction = parts[1]
        guard source.contains("greet") || source.contains("chat") || source.contains("tone") else {
            return nil
        }

        var body = instruction
        for prefix in ["maintain ", "keep ", "use ", "stay ", "be "] {
            if body.lowercased().hasPrefix(prefix) {
                body = String(body.dropFirst(prefix.count))
                break
            }
        }
        body = body.replacingOccurrences(of: " tone", with: "", options: .caseInsensitive)
        body = body.trimmingCharacters(in: .whitespacesAndNewlines)
        body = body.hasSuffix(".") ? String(body.dropLast()) : body

        guard !body.isEmpty else { return nil }
        return MemoryDisplayContent(
            category: "Reply style",
            headline: "Reply tone: \(body).",
            detail: humanize(parts[0])
        )
    }

    nonisolated private static func inferredCategory(for lowercased: String) -> String {
        if lowercased.contains("prefer")
            || lowercased.contains("wants")
            || lowercased.contains("likes")
            || lowercased.contains("okay")
            || lowercased.contains("allow")
            || lowercased.contains("block") {
            return "Preference"
        }
        if lowercased.contains("every ")
            || lowercased.contains("usually")
            || lowercased.contains("night owl")
            || lowercased.contains("after ")
            || lowercased.contains("before ")
            || lowercased.contains("does best work") {
            return "Habit"
        }
        return "Memory"
    }

    nonisolated private static func humanize(_ text: String) -> String {
        var value = text
        if value.lowercased().hasPrefix("user ") {
            value = String(value.dropFirst(5))
        }
        guard let first = value.first else { return value }
        return String(first).uppercased() + value.dropFirst()
    }
}

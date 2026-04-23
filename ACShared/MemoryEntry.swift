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

public struct MemoryEntry: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var createdAt: Date
    public var text: String

    public init(id: UUID = UUID(), createdAt: Date = Date(), text: String) {
        self.id = id
        self.createdAt = createdAt
        self.text = text
    }
}

public enum MemoryRendering {
    /// Prompt-facing timestamp format: short, unambiguous, under 20 chars.
    /// Uses local time of the device. The decision prompt is told the current time
    /// so the LLM can reason about "today" / "yesterday" etc. relative to these stamps.
    public static func timestampLabel(for date: Date, now: Date) -> String {
        let calendar = Calendar.current
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")

        if calendar.isDate(date, inSameDayAs: now) {
            formatter.dateFormat = "HH:mm"
            return "today \(formatter.string(from: date))"
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            formatter.dateFormat = "HH:mm"
            return "yesterday \(formatter.string(from: date))"
        }
        formatter.dateFormat = "MMM d HH:mm"
        return formatter.string(from: date)
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
            let line = "[\(label)] \(cleaned)"
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
}

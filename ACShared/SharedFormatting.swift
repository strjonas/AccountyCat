//
//  SharedFormatting.swift
//  ACShared
//
//  Created by Codex on 13.04.26.
//

import Foundation

enum TelemetryTimestampCodec {
    nonisolated(unsafe) private static let fractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    nonisolated(unsafe) private static let internetDateTimeFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    nonisolated static func string(from date: Date) -> String {
        fractionalFormatter.string(from: date)
    }

    nonisolated static func date(from rawValue: String?) -> Date? {
        guard let rawValue, rawValue.isEmpty == false else {
            return nil
        }
        return fractionalFormatter.date(from: rawValue)
            ?? internetDateTimeFormatter.date(from: rawValue)
    }
}

extension Date {
    nonisolated var acDayKey: String {
        Self.acDayFormatter.string(from: self)
    }

    nonisolated static let acDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

extension String {
    nonisolated var normalizedForContextKey: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    nonisolated var cleanedSingleLine: String {
        split(whereSeparator: \.isNewline)
            .joined(separator: " ")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated func truncatedForPrompt(maxLength: Int) -> String {
        let cleaned = cleanedSingleLine
        guard maxLength > 0, cleaned.count > maxLength else {
            return cleaned
        }

        let prefixLength = max(0, maxLength - 3)
        return cleaned.prefix(prefixLength).trimmingCharacters(in: .whitespacesAndNewlines) + "..."
    }

    nonisolated func truncatedMultilineForPrompt(
        maxLength: Int,
        maxLines: Int? = nil
    ) -> String {
        guard maxLength > 0 else {
            return ""
        }

        let lines = components(separatedBy: .newlines)
            .map(\.cleanedSingleLine)
            .filter { !$0.isEmpty }

        if lines.isEmpty {
            return ""
        }

        let limitedLines = maxLines.map { Array(lines.prefix($0)) } ?? lines
        var resultLines: [String] = []
        var remaining = maxLength

        for line in limitedLines {
            let separatorCost = resultLines.isEmpty ? 0 : 1
            guard remaining > separatorCost else { break }

            let lineBudget = remaining - separatorCost
            let truncatedLine = line.truncatedForPrompt(maxLength: lineBudget)
            guard !truncatedLine.isEmpty else { continue }

            resultLines.append(truncatedLine)
            remaining -= separatorCost + truncatedLine.count

            if truncatedLine.hasSuffix("...") {
                break
            }
        }

        return resultLines.joined(separator: "\n")
    }
}

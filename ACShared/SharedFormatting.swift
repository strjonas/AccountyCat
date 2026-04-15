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
    var acDayKey: String {
        Self.acDayFormatter.string(from: self)
    }

    static let acDayFormatter: DateFormatter = {
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
}

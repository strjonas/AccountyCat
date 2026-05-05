//
//  ActivityLogService.swift
//  AC
//
//  Created by Codex on 12.04.26.
//

import Foundation
import os.log

extension Notification.Name {
    static let acActivityLogDidChange = Notification.Name("acActivityLogDidChange")
}

actor ActivityLogService {
    static let shared = ActivityLogService()

    private static let log = Logger(subsystem: "dev.accountycat", category: "activity-log")

    private let logURL: URL
    private let formatter: ISO8601DateFormatter

    private var _minimumLogLevel: LogLevel = LogLevel.defaultForBuild

    init(fileManager: FileManager = .default) {
        let supportURL = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent("AC", isDirectory: true)
            .appendingPathComponent("logs", isDirectory: true)
        self.logURL = supportURL.appendingPathComponent("activity.log")

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        self.formatter = formatter
    }

    var minimumLogLevel: LogLevel {
        _minimumLogLevel
    }

    func setMinimumLogLevel(_ level: LogLevel) {
        _minimumLogLevel = level
    }

    /// Maximum size before rotation kicks in (~512 KB).
    private static let maxLogSizeBytes: UInt64 = 524_288

    func append(level: LogLevel = .standard, category: String, message: String) async {
        let trimmedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedMessage.isEmpty else { return }

        guard level == .error || level.ordinal <= _minimumLogLevel.ordinal else {
            return
        }

        let entry = "[\(formatter.string(from: Date()))] [\(category)] \(trimmedMessage)\n\n"

        do {
            try FileManager.default.createDirectory(
                at: logURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )

            if FileManager.default.fileExists(atPath: logURL.path) {
                let handle = try FileHandle(forWritingTo: logURL)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: Data(entry.utf8))
            } else {
                try Data(entry.utf8).write(to: logURL, options: .atomic)
            }

            await enforceLogSizeLimit()

            await MainActor.run {
                NotificationCenter.default.post(name: .acActivityLogDidChange, object: nil)
            }
        } catch {
            Self.log.error("failed to append activity log: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func enforceLogSizeLimit() async {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: logURL.path),
              let size = attributes[.size] as? UInt64,
              size > Self.maxLogSizeBytes else {
            return
        }

        do {
            let data = try Data(contentsOf: logURL)
            let targetSize = Int(Self.maxLogSizeBytes / 2)
            let trimmed = Data(data.suffix(targetSize))
            // Drop until the first newline so we don't start mid-line.
            if let firstNewline = trimmed.firstIndex(of: UInt8(ascii: "\n")) {
                let cleanStart = trimmed.index(after: firstNewline)
                let clean = trimmed[cleanStart...]
                try clean.write(to: logURL, options: .atomic)
            } else {
                try trimmed.write(to: logURL, options: .atomic)
            }
        } catch {
            Self.log.error("failed to rotate activity log: \(error.localizedDescription, privacy: .public)")
        }
    }

    func loadRecentContents(maxBytes: Int = 32_768) -> String {
        guard let handle = try? FileHandle(forReadingFrom: logURL) else {
            return ""
        }
        defer { try? handle.close() }

        let fileSize = (try? handle.seekToEnd()) ?? 0
        let readOffset = max(0, Int64(fileSize) - Int64(maxBytes))
        try? handle.seek(toOffset: UInt64(readOffset))
        let data = try? handle.readToEnd()

        guard let data else {
            return ""
        }

        let contents = String(decoding: data, as: UTF8.self)
        if readOffset == 0 {
            return contents
        }
        return contents.components(separatedBy: "\n").dropFirst().joined(separator: "\n")
    }

    func fileURL() -> URL {
        logURL
    }
}

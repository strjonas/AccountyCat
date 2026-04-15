//
//  ActivityLogService.swift
//  AC
//
//  Created by Codex on 12.04.26.
//

import Foundation

extension Notification.Name {
    static let acActivityLogDidChange = Notification.Name("acActivityLogDidChange")
}

actor ActivityLogService {
    static let shared = ActivityLogService()

    private let logURL: URL
    private let formatter: ISO8601DateFormatter

    init(fileManager: FileManager = .default) {
        let supportURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("AC", isDirectory: true)
            .appendingPathComponent("logs", isDirectory: true)
        self.logURL = supportURL.appendingPathComponent("activity.log")

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        self.formatter = formatter
    }

    func append(category: String, message: String) async {
        let trimmedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedMessage.isEmpty else { return }

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

            await MainActor.run {
                NotificationCenter.default.post(name: .acActivityLogDidChange, object: nil)
            }
        } catch {
            NSLog("AC failed to append activity log: %@", error.localizedDescription)
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

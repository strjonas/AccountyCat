//
//  StorageService.swift
//  AC
//
//  Created by Codex on 12.04.26.
//

import Foundation
import os.log

@MainActor
final class StorageService {
    private static let log = Logger(subsystem: "dev.accountycat", category: "storage")

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let stateURL: URL

    private var backupURL: URL {
        stateURL.appendingPathExtension("backup")
    }

    init(fileManager: FileManager = .default) {
        let supportURL = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent("AC", isDirectory: true)
        self.stateURL = supportURL.appendingPathComponent("state.json")
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    init(stateURL: URL) {
        self.stateURL = stateURL
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    static func temporary() -> StorageService {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ac-test-state-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("state.json")
        return StorageService(stateURL: url)
    }

    func loadState() -> ACState {
        if let data = try? Data(contentsOf: stateURL),
           let state = try? decoder.decode(ACState.self, from: data) {
            return state
        }

        Self.log.error("Failed to load state from primary file. Trying backup.")

        if let backupData = try? Data(contentsOf: backupURL),
           let state = try? decoder.decode(ACState.self, from: backupData) {
            Self.log.info("Restored state from backup.")
            try? writeStateData(state)
            return state
        }

        Self.log.error("No valid state file or backup found. Starting with fresh state.")
        return ACState()
    }

    func saveState(_ state: ACState) {
        do {
            if FileManager.default.fileExists(atPath: stateURL.path) {
                try? FileManager.default.removeItem(at: backupURL)
                try FileManager.default.copyItem(at: stateURL, to: backupURL)
            }

            try writeStateData(state)
        } catch {
            Self.log.error("failed to save state: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func writeStateData(_ state: ACState) throws {
        try FileManager.default.createDirectory(
            at: stateURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try encoder.encode(state)
        try data.write(to: stateURL, options: .atomic)
    }
}

//
//  StorageService.swift
//  AC
//
//  Created by Codex on 12.04.26.
//

import Foundation
import os.log

final class StorageService {
    private static let log = Logger(subsystem: "dev.accountycat", category: "storage")

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let stateURL: URL

    init(fileManager: FileManager = .default) {
        let supportURL = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent("AC", isDirectory: true)
        self.stateURL = supportURL.appendingPathComponent("state.json")
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    func loadState() -> ACState {
        guard let data = try? Data(contentsOf: stateURL) else {
            return ACState()
        }

        return (try? decoder.decode(ACState.self, from: data)) ?? ACState()
    }

    func saveState(_ state: ACState) {
        do {
            try FileManager.default.createDirectory(
                at: stateURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try encoder.encode(state)
            try data.write(to: stateURL, options: .atomic)
        } catch {
            Self.log.error("failed to save state: \(error.localizedDescription, privacy: .public)")
        }
    }
}

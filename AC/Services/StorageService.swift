//
//  StorageService.swift
//  AC
//
//  Created by Codex on 12.04.26.
//

import Foundation

final class StorageService {
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let stateURL: URL

    init(fileManager: FileManager = .default) {
        let supportURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
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
            NSLog("AC failed to save state: %@", error.localizedDescription)
        }
    }
}

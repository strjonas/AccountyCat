//
//  StorageServiceTests.swift
//  ACTests
//
//  Created by AccountyCat contributors on 02.05.26.
//

import Foundation
import Testing
@testable import AC

@MainActor
struct StorageServiceTests {

    @Test
    func saveLoadRoundtripPreservesAllFields() {
        let storage = StorageService.temporary()
        var state = ACState()
        state.goalsText = "Write a novel"
        state.debugMode = false
        state.rescueApp = RescueAppTarget(displayName: "Xcode", bundleIdentifier: "com.apple.dt.Xcode")

        storage.saveState(state)
        let loaded = storage.loadState()

        #expect(loaded.goalsText == "Write a novel")
        #expect(loaded.debugMode == false)
        #expect(loaded.rescueApp.bundleIdentifier == "com.apple.dt.Xcode")
    }

    @Test
    func savesChatHistoryRoundtrips() {
        let storage = StorageService.temporary()
        var state = ACState()
        state.chatHistory = [
            ChatMessage(role: .user, text: "Hello", timestamp: Date(timeIntervalSince1970: 100)),
            ChatMessage(role: .assistant, text: "Hi there", timestamp: Date(timeIntervalSince1970: 110))
        ]

        storage.saveState(state)
        let loaded = storage.loadState()

        #expect(loaded.chatHistory.count == 2)
        #expect(loaded.chatHistory[0].text == "Hello")
        #expect(loaded.chatHistory[1].text == "Hi there")
    }

    @Test
    func missingFileReturnsDefaultState() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ac-test-nonexistent-\(UUID().uuidString)")
            .appendingPathComponent("state.json")
        let storage = StorageService(stateURL: url)

        let state = storage.loadState()

        #expect(state.debugMode == true)
        #expect(!state.goalsText.isEmpty)
        #expect(state.chatHistory.isEmpty)
    }

    @Test
    func corruptedJSONFallsBackToBackup() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ac-test-corrupt-\(UUID().uuidString)")
            .appendingPathComponent("state.json")
        let backupURL = url.appendingPathExtension("backup")

        // Write a valid backup
        let parentURL = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parentURL, withIntermediateDirectories: true)
        var validState = ACState()
        validState.goalsText = "Backup goals"
        let backupData = try JSONEncoder().encode(validState)
        try backupData.write(to: backupURL, options: .atomic)

        // Write corrupted primary
        try Data("not-valid-json".utf8).write(to: url, options: .atomic)

        let storage = StorageService(stateURL: url)
        let loaded = storage.loadState()

        #expect(loaded.goalsText == "Backup goals")
        // Should have restored the backup to primary
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test
    func corruptedPrimaryAndBackupReturnsDefault() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ac-test-double-corrupt-\(UUID().uuidString)")
            .appendingPathComponent("state.json")
        let backupURL = url.appendingPathExtension("backup")

        let parentURL = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parentURL, withIntermediateDirectories: true)

        try Data("garbage".utf8).write(to: url, options: .atomic)
        try Data("also-garbage".utf8).write(to: backupURL, options: .atomic)

        let storage = StorageService(stateURL: url)
        let loaded = storage.loadState()

        #expect(!loaded.goalsText.isEmpty)
        #expect(loaded.chatHistory.isEmpty)
    }

    @Test
    func backupIsCreatedOnSecondSave() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ac-test-backup-created-\(UUID().uuidString)")
            .appendingPathComponent("state.json")
        let backupURL = url.appendingPathExtension("backup")

        let storage = StorageService(stateURL: url)

        // First save: no backup yet (no existing file to copy)
        var state1 = ACState()
        state1.goalsText = "First version"
        storage.saveState(state1)
        #expect(!FileManager.default.fileExists(atPath: backupURL.path))

        // Second save: backup should exist (copy of first version)
        var state2 = ACState()
        state2.goalsText = "Second version"
        storage.saveState(state2)
        #expect(FileManager.default.fileExists(atPath: backupURL.path))

        // Backup should contain first version's data
        let backupData = try Data(contentsOf: backupURL)
        let backupState = try JSONDecoder().decode(ACState.self, from: backupData)
        #expect(backupState.goalsText == "First version")
    }

    @Test
    func temporaryCreatesUniquePaths() {
        let storage1 = StorageService.temporary()
        let storage2 = StorageService.temporary()

        // Save and load different states to verify they target different files
        var state1 = ACState()
        state1.goalsText = "unique-1"
        storage1.saveState(state1)

        var state2 = ACState()
        state2.goalsText = "unique-2"
        storage2.saveState(state2)

        #expect(storage1.loadState().goalsText == "unique-1")
        #expect(storage2.loadState().goalsText == "unique-2")
    }
}

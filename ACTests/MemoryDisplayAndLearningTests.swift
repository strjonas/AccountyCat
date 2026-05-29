import Foundation
import Testing
@testable import AC

struct MemoryDisplayTests {

    @Test
    func displayContentMakesToneInferenceReadable() {
        let entry = MemoryEntry(
            createdAt: Date(timeIntervalSince1970: 1_780_000_000),
            text: "User greets with high energy; maintain upbeat but focused tone."
        )

        let display = MemoryRendering.displayContent(for: entry)

        #expect(display.category == "Reply style")
        #expect(display.headline == "Reply tone: upbeat but focused.")
        #expect(display.detail == "Greets with high energy")
    }

    @Test
    func displayContentFlagsOneOffGreetingAsSavedPhrase() {
        let entry = MemoryEntry(text: "wsup")

        let display = MemoryRendering.displayContent(for: entry)

        #expect(display.category == "Saved phrase")
        #expect(display.headline == "One-off wording from an older chat")
        #expect(display.detail == "\"wsup\"")
    }
}

struct MemoryLearningGuardTests {

    @Test
    func rejectsLowSignalChatArtifacts() {
        #expect(!AppController.shouldPersistModelLearnedMemory("hey there..."))
        #expect(!AppController.shouldPersistModelLearnedMemory("User greets with high energy; maintain upbeat but focused tone."))
    }

    @Test
    func keepsDurablePreferenceMemories() {
        #expect(AppController.shouldPersistModelLearnedMemory("Prefers direct nudges during coding."))
        #expect(AppController.shouldPersistModelLearnedMemory("Night owl; does best work after 10pm."))
    }
}

import Foundation
import Testing
@testable import AC

@MainActor
struct MemoryServiceTests {

    @Test
    func extractMemoryUpdateParsesStructuredBullet() async throws {
        let runtimeFixture = try FakeRuntimeFixture()
        let service = MemoryService(runtime: LocalModelRuntime())

        let update = await service.extractMemoryUpdate(
            userMessage: "Don't let me open social media during work blocks.",
            reply: "I'll keep that in mind.",
            currentMemory: "",
            runtimeOverride: runtimeFixture.runtimePath
        )

        guard let update else {
            Issue.record("Expected a memory update but got nil.")
            return
        }

        let tokens = semanticTokens(in: update)
        #expect(tokens.isSuperset(of: ["social", "media", "focus", "sessions"]))
        #expect(tokens.contains("blocked") || tokens.contains("block") || tokens.contains("avoid"))
        #expect(update == update.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    @Test
    func compressMemoryParsesCompressedSummary() async throws {
        let runtimeFixture = try FakeRuntimeFixture()
        let service = MemoryService(runtime: LocalModelRuntime())

        let compressed = await service.compressMemory(
            memory: """
            - Focus on coding
            - Keep social breaks short
            - Focus on coding
            """,
            runtimeOverride: runtimeFixture.runtimePath
        )

        guard let compressed else {
            Issue.record("Expected compressed memory but got nil.")
            return
        }

        let lines = compressed
            .split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let tokens = semanticTokens(in: compressed)

        #expect(lines.count == 2)
        #expect(tokens.isSuperset(of: ["focus", "coding", "social", "breaks"]))
        #expect(tokens.contains("short") || tokens.contains("brief"))
        #expect(compressed == compressed.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func semanticTokens(in text: String) -> Set<String> {
        Set(
            text
                .lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty }
        )
    }
}

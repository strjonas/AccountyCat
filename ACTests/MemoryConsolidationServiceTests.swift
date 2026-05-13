import Foundation
import Testing
@testable import AC

@MainActor
struct MemoryConsolidationServiceTests {

    @Test
    func consolidationPreservesLockedEntriesEvenWhenModelOmitsThem() async throws {
        var outputs = FakeRuntimeOutputSet()
        outputs.memoryCompression = """
        {"entries":[{"created":"2026-05-01T10:00:00Z","text":"User likes a coffee buffer before deep work."}]}
        """
        let runtimeFixture = try FakeRuntimeFixture(outputs: outputs)
        let runtime = LocalModelRuntime()
        let service = MemoryConsolidationService(
            runtime: runtime,
            onlineModelService: OnlineModelService()
        )
        let lockedID = try #require(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"))
        let entries = [
            MemoryEntry(
                id: lockedID,
                createdAt: Date(timeIntervalSince1970: 1_746_097_200),
                text: "User wants Sunday rest protected.",
                isLocked: true
            ),
            MemoryEntry(
                createdAt: Date(timeIntervalSince1970: 1_746_100_800),
                text: "User likes a coffee buffer before deep work."
            ),
        ]

        let consolidated = try #require(await service.consolidate(
            entries: entries,
            goals: "Stay focused.",
            recentUserMessages: [],
            now: Date(timeIntervalSince1970: 1_746_104_400),
            runtimeOverride: runtimeFixture.runtimePath,
            inferenceBackend: .local,
            localTextModelIdentifier: "fake-text-model"
        ))

        #expect(consolidated.contains {
            $0.id == lockedID && $0.text == "User wants Sunday rest protected." && $0.isLocked
        })
        #expect(consolidated.contains {
            $0.text == "User likes a coffee buffer before deep work."
        })
    }
}

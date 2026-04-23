//
//  ACTests.swift
//  ACTests
//
//  Created by AccountyCat contributors on 12.04.26.
//

import Testing
import Foundation
@testable import AC

@MainActor
struct ACTests {

    @Test
    func decodesMissingDebugModeAsEnabled() throws {
        let data = Data("{}".utf8)
        let state = try JSONDecoder().decode(ACState.self, from: data)

        #expect(state.debugMode == true)
        #expect(state.rescueApp.displayName == "Xcode")
    }

    @Test
    func preservesChatHistoryWhenStateIsEncoded() throws {
        var state = ACState()
        state.chatHistory = [
            ChatMessage(
                id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
                role: .user,
                text: "hello",
                timestamp: Date(timeIntervalSince1970: 10)
            ),
            ChatMessage(
                id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
                role: .assistant,
                text: "hi there",
                timestamp: Date(timeIntervalSince1970: 11)
            )
        ]

        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(ACState.self, from: data)

        #expect(decoded.chatHistory == state.chatHistory)
    }

    @Test
    func migratesLegacyChatHistoryWithoutTimestamps() throws {
        let data = Data(
            """
            {
              "chatHistory": [
                {
                  "id": "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
                  "role": "user",
                  "text": "hello"
                },
                {
                  "id": "11111111-2222-3333-4444-555555555555",
                  "role": "assistant",
                  "text": "hi there"
                }
              ]
            }
            """.utf8
        )

        let decoded = try JSONDecoder().decode(ACState.self, from: data)

        #expect(decoded.chatHistory.count == 2)
        #expect(decoded.chatHistory[0].text == "hello")
        #expect(decoded.chatHistory[1].text == "hi there")
        #expect(decoded.chatHistory[0].timestamp < decoded.chatHistory[1].timestamp)
    }

    @Test
    func memoryRenderingUsesAbsoluteTimestamps() {
        let createdAt = Date(timeIntervalSince1970: 1_745_423_400)
        let entries = [
            MemoryEntry(
                createdAt: createdAt,
                text: "X.com is allowed until 2026-04-23 17:15"
            )
        ]

        let prompt = MemoryRendering.renderForPrompt(
            entries: entries,
            now: Date(timeIntervalSince1970: 1_745_423_700),
            maxLines: 5,
            maxCharacters: 400
        )
        let display = MemoryRendering.renderForDisplay(
            entries: entries,
            now: Date(timeIntervalSince1970: 1_745_423_700)
        )
        let expectedLabel = "[\(PromptTimestampFormatting.absoluteLabel(for: createdAt))]"

        #expect(prompt.contains(expectedLabel))
        #expect(prompt.contains("today") == false)
        #expect(display.contains(expectedLabel))
    }

    @Test
    func recentUserMessagesKeepTimestamps() {
        let firstUserTime = Date(timeIntervalSince1970: 20)
        let secondUserTime = Date(timeIntervalSince1970: 30)
        let history = [
            ChatMessage(role: .assistant, text: "Earlier reply", timestamp: Date(timeIntervalSince1970: 10)),
            ChatMessage(role: .user, text: "Instagram is blocked", timestamp: firstUserTime),
            ChatMessage(role: .user, text: "Actually X.com is allowed until 2026-04-23 17:15", timestamp: secondUserTime),
        ]

        let recent = BrainService.recentUserMessages(chatHistory: history, limit: 2)

        #expect(recent == [
            "[\(PromptTimestampFormatting.absoluteLabel(for: firstUserTime))] Instagram is blocked",
            "[\(PromptTimestampFormatting.absoluteLabel(for: secondUserTime))] Actually X.com is allowed until 2026-04-23 17:15",
        ])
    }

}

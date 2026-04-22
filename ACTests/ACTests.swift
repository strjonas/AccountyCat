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

}

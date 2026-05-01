//
//  ProfileManagementTests.swift
//  ACTests
//
//  Created by Codex on 01.05.26.
//

import Foundation
import Testing
@testable import AC

@MainActor
struct ProfileManagementTests {

    @Test
    func deleteProfileBlocksWhenLockedScopedRulesExist() {
        let controller = AppController.shared
        let originalState = controller.state
        defer {
            controller.state = originalState
            controller.storageService.saveState(originalState)
        }

        var state = ACState()
        let profile = FocusProfile(
            id: "writing",
            name: "Writing",
            description: "Drafting product docs"
        )
        state.profiles.append(profile)
        state.policyMemory.rules = [
            PolicyRule(
                id: "locked-writing-rule",
                kind: .discourage,
                summary: "Do not drift into chat during writing blocks.",
                source: .explicitFeedback,
                isLocked: true,
                profileID: profile.id
            )
        ]
        controller.state = state

        #expect(controller.canDeleteProfile(id: profile.id) == false)

        controller.deleteProfile(id: profile.id)

        #expect(controller.state.profiles.contains(where: { $0.id == profile.id }))
        #expect(controller.state.policyMemory.rules.contains(where: { $0.id == "locked-writing-rule" }))
    }

    @Test
    func deleteProfileRemovesUnlockedScopedRules() {
        let controller = AppController.shared
        let originalState = controller.state
        defer {
            controller.state = originalState
            controller.storageService.saveState(originalState)
        }

        var state = ACState()
        let profile = FocusProfile(
            id: "coding",
            name: "Coding",
            description: "Deep repo work"
        )
        state.profiles.append(profile)
        state.policyMemory.rules = [
            PolicyRule(
                id: "coding-rule",
                kind: .allow,
                summary: "Xcode and terminal are in-bounds here.",
                source: .explicitFeedback,
                profileID: profile.id
            )
        ]
        controller.state = state

        #expect(controller.canDeleteProfile(id: profile.id))

        controller.deleteProfile(id: profile.id)

        #expect(!controller.state.profiles.contains(where: { $0.id == profile.id }))
        #expect(!controller.state.policyMemory.rules.contains(where: { $0.id == "coding-rule" }))
    }
}

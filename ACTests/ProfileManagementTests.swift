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
        let originalChatMessages = controller.chatMessages
        let originalUnreadState = controller.hasUnreadChatMessages
        defer {
            controller.state = originalState
            controller.chatMessages = originalChatMessages
            controller.hasUnreadChatMessages = originalUnreadState
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

    @Test
    func activatingNamedProfileWithAnnouncementCreatesSingleUnreadDeferredMessage() throws {
        let controller = AppController.shared
        let originalState = controller.state
        let originalChatMessages = controller.chatMessages
        let originalUnreadState = controller.hasUnreadChatMessages
        defer {
            controller.state = originalState
            controller.chatMessages = originalChatMessages
            controller.hasUnreadChatMessages = originalUnreadState
            controller.storageService.saveState(originalState)
        }

        var state = ACState()
        state.chatHistory = []
        let profile = FocusProfile(
            id: "coding",
            name: "Coding",
            description: "Deep repo work"
        )
        state.profiles.append(profile)
        controller.state = state
        controller.chatMessages = []
        controller.hasUnreadChatMessages = false

        let expiresAt = Date(timeIntervalSince1970: 3_600)
        let activated = controller.activateProfile(
            id: profile.id,
            expiresAt: expiresAt,
            reason: "Deep repo work",
            announce: true
        )

        #expect(activated)
        #expect(controller.state.activeProfileID == profile.id)
        #expect(controller.state.chatHistory.count == 1)
        #expect(controller.chatMessages.count == 1)
        let message = try #require(controller.state.chatHistory.last)
        #expect(message.interruptionPolicy == .deferred)
        #expect(message.isUnread)
        #expect(message.text.contains("Switching to your Coding profile"))
        #expect(message.text.contains("Deep repo work"))
        #expect(controller.chatMessages.last == message)
        #expect(controller.hasUnreadChatMessages)
    }

    @Test
    func endingActiveProfileWithAnnouncementReturnsToGeneralAndMarksMessageUnread() throws {
        let controller = AppController.shared
        let originalState = controller.state
        let originalChatMessages = controller.chatMessages
        let originalUnreadState = controller.hasUnreadChatMessages
        defer {
            controller.state = originalState
            controller.chatMessages = originalChatMessages
            controller.hasUnreadChatMessages = originalUnreadState
            controller.storageService.saveState(originalState)
        }

        var state = ACState()
        state.chatHistory = []
        let profile = FocusProfile(
            id: "presentation",
            name: "Presentation Prep",
            description: "Deck work"
        )
        state.profiles.append(profile)
        state.activeProfileID = profile.id
        controller.state = state
        controller.chatMessages = []
        controller.hasUnreadChatMessages = false

        controller.endActiveProfile(announce: true)

        #expect(controller.state.activeProfileID == PolicyRule.defaultProfileID)
        #expect(controller.state.chatHistory.count == 1)
        let message = try #require(controller.state.chatHistory.last)
        #expect(message.interruptionPolicy == .deferred)
        #expect(message.isUnread)
        #expect(message.text.contains("Switched back"))
        #expect(message.text.contains(FocusProfile.defaultDisplayName))
        #expect(controller.hasUnreadChatMessages)
    }

    @Test
    func policyMemoryActivateProfileOperationSwitchesAndAnnouncesOnce() throws {
        let controller = AppController.shared
        let originalState = controller.state
        let originalChatMessages = controller.chatMessages
        let originalUnreadState = controller.hasUnreadChatMessages
        defer {
            controller.state = originalState
            controller.chatMessages = originalChatMessages
            controller.hasUnreadChatMessages = originalUnreadState
            controller.storageService.saveState(originalState)
        }

        var state = ACState()
        state.chatHistory = []
        let profile = FocusProfile(id: "deep-work", name: "Deep Work", description: "No interruptions")
        state.profiles.append(profile)
        controller.state = state
        controller.chatMessages = []
        controller.hasUnreadChatMessages = false

        controller.applyProfileOperations([
            PolicyMemoryOperation(
                type: .activateProfile,
                reason: "User said 'deep work mode'",
                profileID: profile.id,
                profileDurationMinutes: 90
            )
        ])

        #expect(controller.state.activeProfileID == profile.id)
        #expect(controller.state.chatHistory.count == 1)
        let message = try #require(controller.state.chatHistory.last)
        #expect(message.interruptionPolicy == .deferred)
        #expect(message.isUnread)
        #expect(message.text.contains("Deep Work"))
        #expect(message.text.contains("deep work mode"))
        #expect(controller.hasUnreadChatMessages)
    }

    @Test
    func policyMemoryCreateAndActivateProfileOperationCreatesProfileAndAnnouncesOnce() throws {
        let controller = AppController.shared
        let originalState = controller.state
        let originalChatMessages = controller.chatMessages
        let originalUnreadState = controller.hasUnreadChatMessages
        defer {
            controller.state = originalState
            controller.chatMessages = originalChatMessages
            controller.hasUnreadChatMessages = originalUnreadState
            controller.storageService.saveState(originalState)
        }

        var state = ACState()
        state.chatHistory = []
        controller.state = state
        controller.chatMessages = []
        controller.hasUnreadChatMessages = false

        let profilesBefore = controller.state.profiles.count

        controller.applyProfileOperations([
            PolicyMemoryOperation(
                type: .createAndActivateProfile,
                reason: "User said 'presentation prep'",
                profileName: "Presentation Prep",
                profileDescription: "Slides and speaker notes",
                profileDurationMinutes: 120
            )
        ])

        #expect(controller.state.profiles.count == profilesBefore + 1)
        let created = try #require(controller.state.profiles.first(where: { $0.name == "Presentation Prep" }))
        #expect(controller.state.activeProfileID == created.id)
        #expect(controller.state.chatHistory.count == 1)
        let message = try #require(controller.state.chatHistory.last)
        #expect(message.interruptionPolicy == .deferred)
        #expect(message.isUnread)
        #expect(message.text.contains("Presentation Prep"))
        #expect(controller.hasUnreadChatMessages)
    }

    @Test
    func policyMemoryEndActiveProfileOperationReturnsToGeneralAndAnnouncesOnce() throws {
        let controller = AppController.shared
        let originalState = controller.state
        let originalChatMessages = controller.chatMessages
        let originalUnreadState = controller.hasUnreadChatMessages
        defer {
            controller.state = originalState
            controller.chatMessages = originalChatMessages
            controller.hasUnreadChatMessages = originalUnreadState
            controller.storageService.saveState(originalState)
        }

        var state = ACState()
        state.chatHistory = []
        let profile = FocusProfile(id: "writing", name: "Writing", description: "Blog posts")
        state.profiles.append(profile)
        state.activeProfileID = profile.id
        controller.state = state
        controller.chatMessages = []
        controller.hasUnreadChatMessages = false

        controller.applyProfileOperations([
            PolicyMemoryOperation(type: .endActiveProfile, reason: "session done")
        ])

        #expect(controller.state.activeProfileID == PolicyRule.defaultProfileID)
        #expect(controller.state.chatHistory.count == 1)
        let message = try #require(controller.state.chatHistory.last)
        #expect(message.interruptionPolicy == .deferred)
        #expect(message.isUnread)
        #expect(message.text.lowercased().contains("general") || message.text.lowercased().contains("switched back"))
        #expect(controller.hasUnreadChatMessages)
    }

    @Test
    func policyMemoryEndActiveProfileWhenAlreadyDefaultDoesNothing() {
        let controller = AppController.shared
        let originalState = controller.state
        let originalChatMessages = controller.chatMessages
        let originalUnreadState = controller.hasUnreadChatMessages
        defer {
            controller.state = originalState
            controller.chatMessages = originalChatMessages
            controller.hasUnreadChatMessages = originalUnreadState
            controller.storageService.saveState(originalState)
        }

        var state = ACState()
        state.chatHistory = []
        state.activeProfileID = PolicyRule.defaultProfileID
        controller.state = state
        controller.chatMessages = []
        controller.hasUnreadChatMessages = false

        controller.applyProfileOperations([
            PolicyMemoryOperation(type: .endActiveProfile, reason: "already general")
        ])

        #expect(controller.state.activeProfileID == PolicyRule.defaultProfileID)
        #expect(controller.state.chatHistory.isEmpty)
        #expect(!controller.hasUnreadChatMessages)
    }

    @Test
    func policyMemoryProfileOperationsAnnounceFinalStateOnlyOnce() throws {
        let controller = AppController.shared
        let originalState = controller.state
        let originalChatMessages = controller.chatMessages
        let originalUnreadState = controller.hasUnreadChatMessages
        defer {
            controller.state = originalState
            controller.chatMessages = originalChatMessages
            controller.hasUnreadChatMessages = originalUnreadState
            controller.storageService.saveState(originalState)
        }

        var state = ACState()
        state.chatHistory = []
        let coding = FocusProfile(
            id: "coding",
            name: "Coding",
            description: "Deep repo work"
        )
        let writing = FocusProfile(
            id: "writing",
            name: "Writing",
            description: "Drafting docs"
        )
        state.profiles.append(contentsOf: [coding, writing])
        controller.state = state
        controller.chatMessages = []
        controller.hasUnreadChatMessages = false

        controller.applyProfileOperations([
            PolicyMemoryOperation(
                type: .activateProfile,
                reason: "First pass",
                profileID: coding.id,
                profileDurationMinutes: 60
            ),
            PolicyMemoryOperation(
                type: .activateProfile,
                reason: "Final pass",
                profileID: writing.id,
                profileDurationMinutes: 30
            )
        ])

        #expect(controller.state.activeProfileID == writing.id)
        #expect(controller.state.chatHistory.count == 1)
        #expect(controller.chatMessages.count == 1)
        let message = try #require(controller.state.chatHistory.last)
        #expect(message.interruptionPolicy == .deferred)
        #expect(message.isUnread)
        #expect(message.text.contains("Writing"))
        #expect(message.text.contains("Final pass"))
        #expect(!message.text.contains("Coding"))
        #expect(controller.hasUnreadChatMessages)
    }

    @Test
    func policyMemoryUnknownProfileActivationDoesNotAnnounceOrSwitch() {
        let controller = AppController.shared
        let originalState = controller.state
        let originalChatMessages = controller.chatMessages
        let originalUnreadState = controller.hasUnreadChatMessages
        defer {
            controller.state = originalState
            controller.chatMessages = originalChatMessages
            controller.hasUnreadChatMessages = originalUnreadState
            controller.storageService.saveState(originalState)
        }

        var state = ACState()
        state.chatHistory = []
        controller.state = state
        controller.chatMessages = []
        controller.hasUnreadChatMessages = false

        controller.applyProfileOperations([
            PolicyMemoryOperation(
                type: .activateProfile,
                reason: "Should be ignored",
                profileID: "missing-profile",
                profileDurationMinutes: 45
            )
        ])

        #expect(controller.state.activeProfileID == PolicyRule.defaultProfileID)
        #expect(controller.state.chatHistory.isEmpty)
        #expect(controller.chatMessages.isEmpty)
        #expect(controller.hasUnreadChatMessages == false)
    }

    @Test
    func markAllChatMessagesReadClearsDeferredUnreadState() {
        let controller = AppController.shared
        let originalState = controller.state
        let originalChatMessages = controller.chatMessages
        let originalUnreadState = controller.hasUnreadChatMessages
        defer {
            controller.state = originalState
            controller.chatMessages = originalChatMessages
            controller.hasUnreadChatMessages = originalUnreadState
            controller.storageService.saveState(originalState)
        }

        let deferred = ChatMessage(
            role: .assistant,
            text: "Queued profile switch",
            interruptionPolicy: .deferred
        )
        var state = ACState()
        state.chatHistory = [deferred]
        controller.state = state
        controller.chatMessages = [deferred]
        controller.hasUnreadChatMessages = true

        controller.markAllChatMessagesRead()

        #expect(controller.hasUnreadChatMessages == false)
        #expect(controller.state.chatHistory.allSatisfy { !$0.isUnread })
        #expect(controller.chatMessages.allSatisfy { !$0.isUnread })
    }

    @Test
    func activateProfileWithDurationMinutesSetsRelativeExpiry() throws {
        let controller = AppController.shared
        let originalState = controller.state
        defer {
            controller.state = originalState
            controller.storageService.saveState(originalState)
        }

        var state = ACState()
        let profile = FocusProfile(id: "coding", name: "Coding", description: "Deep repo work")
        state.profiles.append(profile)
        controller.state = state

        let before = Date()
        let activated = controller.activateProfile(
            id: profile.id,
            durationMinutes: 120,
            reason: "manual_timer"
        )
        let after = Date()

        #expect(activated)
        let active = controller.state.activeProfile
        let expiresAt = try #require(active.expiresAt)
        #expect(expiresAt >= before.addingTimeInterval(119 * 60))
        #expect(expiresAt <= after.addingTimeInterval(121 * 60))
    }

    @Test
    func extendActiveProfileAddsMinutesFromExistingExpiry() throws {
        let controller = AppController.shared
        let originalState = controller.state
        defer {
            controller.state = originalState
            controller.storageService.saveState(originalState)
        }

        let existingExpiry = Date().addingTimeInterval(45 * 60)
        var state = ACState()
        let profile = FocusProfile(
            id: "writing",
            name: "Writing",
            description: "Docs",
            expiresAt: existingExpiry
        )
        state.profiles.append(profile)
        state.activeProfileID = profile.id
        controller.state = state

        let extended = controller.extendActiveProfile(byMinutes: 120)

        #expect(extended)
        let expiresAt = try #require(controller.state.activeProfile.expiresAt)
        #expect(abs(expiresAt.timeIntervalSince(existingExpiry.addingTimeInterval(120 * 60))) < 2)
    }

    @Test
    func mergeBrainStatePreservesConcurrentProfileActivationAndChatHistory() {
        let controller = AppController.shared
        let originalState = controller.state
        let originalChatMessages = controller.chatMessages
        let originalUnreadState = controller.hasUnreadChatMessages
        defer {
            controller.state = originalState
            controller.chatMessages = originalChatMessages
            controller.hasUnreadChatMessages = originalUnreadState
            controller.storageService.saveState(originalState)
        }

        var base = ACState()
        base.chatHistory = []

        var current = base
        let writing = FocusProfile(id: "writing", name: "Writing", description: "Essay work")
        current.profiles.append(writing)
        current.activeProfileID = writing.id
        current.chatHistory = [
            ChatMessage(role: .user, text: "Help me focus on writing."),
            ChatMessage(role: .assistant, text: "Switching to your Writing profile.", interruptionPolicy: .deferred)
        ]

        var updated = base
        updated.algorithmState.llmPolicy.distraction.lastAssessment = .focused

        controller.state = current
        controller.chatMessages = []
        controller.hasUnreadChatMessages = false

        controller.mergeBrainState(base: base, updated: updated)

        #expect(controller.state.activeProfileID == writing.id)
        #expect(controller.state.profiles.contains(where: { $0.id == writing.id }))
        #expect(controller.state.chatHistory == current.chatHistory)
        #expect(controller.state.algorithmState == updated.algorithmState)
    }

    @Test
    func mergeBrainStateAppendsBrainExpiryNoteWithoutDroppingNewerChat() {
        let controller = AppController.shared
        let originalState = controller.state
        let originalChatMessages = controller.chatMessages
        let originalUnreadState = controller.hasUnreadChatMessages
        defer {
            controller.state = originalState
            controller.chatMessages = originalChatMessages
            controller.hasUnreadChatMessages = originalUnreadState
            controller.storageService.saveState(originalState)
        }

        let originalNote = ChatMessage(role: .assistant, text: "Original state")
        let newerUserMessage = ChatMessage(role: .user, text: "Wait, keep the note too.")
        let expiryNote = ChatMessage(
            role: .assistant,
            text: "Writing ended. Switched back to General.",
            interruptionPolicy: .deferred
        )

        var base = ACState()
        let writing = FocusProfile(
            id: "writing",
            name: "Writing",
            description: "Essay work",
            expiresAt: Date().addingTimeInterval(60)
        )
        base.profiles.append(writing)
        base.activeProfileID = writing.id
        base.chatHistory = [originalNote]

        var current = base
        current.chatHistory.append(newerUserMessage)

        var updated = base
        if let index = updated.profiles.firstIndex(where: { $0.id == writing.id }) {
            updated.profiles[index].expiresAt = nil
            updated.profiles[index].activatedAt = nil
        }
        updated.activeProfileID = PolicyRule.defaultProfileID
        updated.chatHistory.append(expiryNote)

        controller.state = current
        controller.chatMessages = []
        controller.hasUnreadChatMessages = false

        controller.mergeBrainState(base: base, updated: updated)

        #expect(controller.state.activeProfileID == PolicyRule.defaultProfileID)
        #expect(controller.state.chatHistory.count == 3)
        #expect(controller.state.chatHistory.contains(where: { $0.id == newerUserMessage.id }))
        #expect(controller.state.chatHistory.contains(where: { $0.id == expiryNote.id }))
    }
}

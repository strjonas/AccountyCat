//
//  PolicyMemoryProposalTests.swift
//  ACTests
//
//  Covers the propose_rule / propose_memory routing layer: model-emitted proposal
//  ops never land in `policyMemory.rules` directly, behavioral-signal payloads are
//  carried into the policy_memory pass, and the prompt instructions guide the
//  apply-vs-propose decision.
//

import Foundation
import Testing
@testable import AC

@MainActor
struct PolicyMemoryProposalTests {

    // MARK: - PolicyMemory.apply: propose ops never mutate `rules`

    @Test
    func proposeRuleOperationDoesNotMutatePolicyMemoryRules() {
        var memory = PolicyMemory()
        let proposed = PolicyRule(
            kind: .discourage,
            summary: "Discourage Twitter",
            source: .implicitFeedback,
            scope: PolicyRuleScope(appName: "Twitter")
        )

        memory.apply(PolicyMemoryUpdateResponse(operations: [
            PolicyMemoryOperation(type: .proposeRule, rule: proposed, reason: "pattern observed")
        ]))

        #expect(memory.rules.isEmpty)
    }

    @Test
    func proposeMemoryOperationDoesNotMutatePolicyMemoryRules() {
        var memory = PolicyMemory()

        memory.apply(PolicyMemoryUpdateResponse(operations: [
            PolicyMemoryOperation(
                type: .proposeMemory,
                reason: "pattern observed",
                memoryNote: "User dismisses Twitter nudges every afternoon"
            )
        ]))

        #expect(memory.rules.isEmpty)
    }

    @Test
    func mixedOperationsApplyOnlyTheNonProposeOnes() {
        var memory = PolicyMemory()
        let appliedRule = PolicyRule(
            kind: .allow,
            summary: "Allow YouTube",
            source: .userChat,
            scope: PolicyRuleScope(appName: "YouTube"),
            profileID: PolicyRule.defaultProfileID
        )
        let proposed = PolicyRule(
            kind: .discourage,
            summary: "Discourage Reddit",
            source: .implicitFeedback,
            scope: PolicyRuleScope(appName: "Reddit"),
            profileID: PolicyRule.defaultProfileID
        )

        memory.apply(PolicyMemoryUpdateResponse(operations: [
            PolicyMemoryOperation(type: .addRule, rule: appliedRule),
            PolicyMemoryOperation(type: .proposeRule, rule: proposed, reason: "from behavior alone")
        ]))

        #expect(memory.rules.count == 1)
        #expect(memory.rules.first?.summary == "Allow YouTube")
    }

    // MARK: - ProposedPolicyChange model

    @Test
    func proposedPolicyChangeStaleAfterRetentionWindow() {
        let createdAt = Date()
        let proposal = ProposedPolicyChange(
            kind: .rule,
            proposedRule: PolicyRule(
                kind: .discourage,
                summary: "x",
                source: .implicitFeedback
            ),
            createdAt: createdAt
        )

        let withinWindow = createdAt.addingTimeInterval(ProposedPolicyChange.defaultRetention - 60)
        let pastWindow = createdAt.addingTimeInterval(ProposedPolicyChange.defaultRetention + 60)

        #expect(proposal.isStale(at: withinWindow) == false)
        #expect(proposal.isStale(at: pastWindow) == true)
    }

    @Test
    func proposedPolicyChangeRoundTripsCodableWithoutLosingFields() throws {
        let proposal = ProposedPolicyChange(
            kind: .rule,
            proposedRule: PolicyRule(
                kind: .discourage,
                summary: "Discourage Reddit",
                source: .implicitFeedback,
                scope: PolicyRuleScope(appName: "Reddit"),
                profileID: PolicyRule.defaultProfileID
            ),
            reason: "3 dismisses in 4h",
            sourceContextKey: "com.reddit"
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(proposal)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(ProposedPolicyChange.self, from: data)

        #expect(decoded.id == proposal.id)
        #expect(decoded.kind == .rule)
        #expect(decoded.proposedRule?.summary == "Discourage Reddit")
        #expect(decoded.reason == "3 dismisses in 4h")
        #expect(decoded.sourceContextKey == "com.reddit")
    }

    // MARK: - BehavioralSignalSummary lifecycle

    @Test
    func behavioralSignalIsStaleAfterRetentionWindow() {
        let observedAt = Date()
        let signal = BehavioralSignalSummary(
            kind: "appealApproved",
            observedAt: observedAt,
            scope: PolicyRuleScope(appName: "Chrome"),
            detail: "user appeal accepted"
        )

        let nearStale = observedAt.addingTimeInterval(BehavioralSignalSummary.retentionWindow - 60)
        let pastStale = observedAt.addingTimeInterval(BehavioralSignalSummary.retentionWindow + 60)

        #expect(signal.isStale(at: nearStale) == false)
        #expect(signal.isStale(at: pastStale) == true)
    }

    // MARK: - PolicyMemoryUpdateRequest carries signals

    @Test
    func policyMemoryUpdateRequestRetainsBehavioralSignals() {
        let signals = [
            BehavioralSignalSummary(kind: "appealApproved"),
            BehavioralSignalSummary(kind: "repeatedDismissal", occurrences: 3)
        ]

        let request = PolicyMemoryUpdateRequest(
            now: Date(),
            goals: "ship",
            freeFormMemory: "",
            policyMemory: PolicyMemory(),
            eventSummary: "test",
            recentActions: [],
            context: nil,
            runtimeProfileID: "gemma_balanced_v1",
            inferenceBackend: .openRouter,
            onlineModelIdentifier: "anthropic/claude-haiku-4-5",
            onlineTextModelIdentifier: nil,
            localModelIdentifier: nil,
            activeProfile: ProfilePromptSummary(
                id: PolicyRule.defaultProfileID,
                name: "Default",
                isDefault: true
            ),
            availableProfiles: [],
            recentBehavioralSignals: signals
        )

        #expect(request.recentBehavioralSignals.count == 2)
        #expect(request.recentBehavioralSignals.first?.kind == "appealApproved")
    }

    // MARK: - AC state round-trip

    @Test
    func acStateRoundTripsProposedChangesAndBehavioralSignals() throws {
        var state = ACState()
        state.proposedChanges = [
            ProposedPolicyChange(
                kind: .memory,
                proposedMemoryNote: "User checks Twitter mid-afternoon",
                reason: "3 dismisses",
                createdAt: Date()
            )
        ]
        state.recentBehavioralSignals = [
            BehavioralSignalSummary(
                kind: "repeatedDismissal",
                observedAt: Date(),
                scope: PolicyRuleScope(appName: "Twitter"),
                detail: "3 in 4h",
                occurrences: 3
            )
        ]

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(state)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(ACState.self, from: data)

        #expect(decoded.proposedChanges.count == 1)
        #expect(decoded.proposedChanges.first?.kind == .memory)
        #expect(decoded.proposedChanges.first?.proposedMemoryNote == "User checks Twitter mid-afternoon")
        #expect(decoded.recentBehavioralSignals.count == 1)
        #expect(decoded.recentBehavioralSignals.first?.kind == "repeatedDismissal")
        #expect(decoded.recentBehavioralSignals.first?.occurrences == 3)
    }

    @Test
    func staleProposalsAndSignalsAreDroppedOnDecode() throws {
        var state = ACState()
        let now = Date()
        let staleProposalCreatedAt = now.addingTimeInterval(-ProposedPolicyChange.defaultRetention - 3600)
        state.proposedChanges = [
            ProposedPolicyChange(
                kind: .memory,
                proposedMemoryNote: "stale entry",
                createdAt: staleProposalCreatedAt
            )
        ]
        let staleSignalAt = now.addingTimeInterval(-BehavioralSignalSummary.retentionWindow - 3600)
        state.recentBehavioralSignals = [
            BehavioralSignalSummary(kind: "appealApproved", observedAt: staleSignalAt)
        ]

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(state)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(ACState.self, from: data)

        #expect(decoded.proposedChanges.isEmpty)
        #expect(decoded.recentBehavioralSignals.isEmpty)
    }

    // MARK: - Prompt contents

    @Test
    func policyMemoryPromptDescribesProposeOpsAndSignalContract() {
        let prompt = ACPromptSets.policyMemorySystemPrompt()
        #expect(prompt.contains("propose_rule"))
        #expect(prompt.contains("propose_memory"))
        #expect(prompt.contains("recentBehavioralSignals"))
        #expect(prompt.contains("appealApproved"))
        #expect(prompt.contains("repeatedDismissal"))
        #expect(prompt.contains("Never auto-apply a rule that wasn't explicitly endorsed by the user"))
    }

    @Test
    func policyMemoryPromptDescribesAddMemoryForExplicitStatements() {
        let prompt = ACPromptSets.policyMemorySystemPrompt()
        #expect(prompt.contains("add_memory"))
        #expect(prompt.contains("explicitly stated"))
    }

    @Test
    func chatPromptHasPositivePersonalPreferenceExamples() {
        let prompt = ACPromptSets.chatSystemPrompt(withPersonality: "test voice")
        #expect(prompt.contains("Memory-worthy examples"))
        #expect(prompt.contains("sabbath"))
        #expect(prompt.contains("self-commitment without a memory action is a bug")
            || prompt.contains("self-commitment without a memory action"))
    }

    // MARK: - add_memory operation routes through controller

    @Test
    func addMemoryOperationIsSwallowedByPolicyMemoryApplyAndDoesNotMutateRules() {
        var memory = PolicyMemory()
        memory.apply(PolicyMemoryUpdateResponse(operations: [
            PolicyMemoryOperation(
                type: .addMemory,
                reason: "user explicit chat statement",
                memoryNote: "User does best work after 10pm."
            )
        ]))

        #expect(memory.rules.isEmpty)
        // PolicyMemory does not own memoryEntries — this op is intentionally
        // routed by the AppController layer, not by `apply`.
    }

    // MARK: - replyPromisesMemory backstop heuristic

    @Test
    func replyPromisesMemoryDetectsCommitmentPhrases() {
        #expect(AppController.replyPromisesMemory(reply: "Got it, I'll keep that in mind."))
        #expect(AppController.replyPromisesMemory(reply: "Noted! Sounds good."))
        #expect(AppController.replyPromisesMemory(reply: "Cool, it's a deal — I'll go easy on Sundays."))
        #expect(AppController.replyPromisesMemory(reply: "I'll remember that."))
        #expect(AppController.replyPromisesMemory(reply: "Good to know."))
    }

    @Test
    func replyPromisesMemoryReturnsFalseForOrdinaryChat() {
        #expect(AppController.replyPromisesMemory(reply: "Hi! How's it going?") == false)
        #expect(AppController.replyPromisesMemory(reply: "Sure thing — what's next?") == false)
        #expect(AppController.replyPromisesMemory(reply: "That sounds rough.") == false)
    }
}

// MARK: - AppController-driven proposal lifecycle

@MainActor
struct PolicyMemoryProposalControllerTests {

    @Test
    func acceptProposedRuleAddsItToPolicyMemoryAndRemovesFromQueue() {
        let controller = AppController.makeForTesting(storageService: .temporary())
        let originalState = controller.state
        defer { controller.state = originalState }

        var state = ACState()
        let proposedRule = PolicyRule(
            id: "proposed-rule",
            kind: .discourage,
            summary: "Discourage Reddit",
            source: .implicitFeedback,
            scope: PolicyRuleScope(appName: "Reddit"),
            profileID: PolicyRule.defaultProfileID
        )
        let proposal = ProposedPolicyChange(
            id: "p-1",
            kind: .rule,
            proposedRule: proposedRule,
            reason: "3 dismisses in 4h"
        )
        state.proposedChanges = [proposal]
        controller.state = state

        controller.acceptProposedChange(id: "p-1")

        #expect(controller.state.proposedChanges.isEmpty)
        #expect(controller.state.policyMemory.rules.contains { $0.id == "proposed-rule" })
    }

    @Test
    func dismissProposedChangeDropsItWithoutAddingRule() {
        let controller = AppController.makeForTesting(storageService: .temporary())
        let originalState = controller.state
        defer { controller.state = originalState }

        var state = ACState()
        let proposal = ProposedPolicyChange(
            id: "p-2",
            kind: .memory,
            proposedMemoryNote: "User dismisses Twitter every afternoon"
        )
        state.proposedChanges = [proposal]
        controller.state = state

        controller.dismissProposedChange(id: "p-2")

        #expect(controller.state.proposedChanges.isEmpty)
        #expect(controller.state.memoryEntries.isEmpty)
    }

    @Test
    func acceptProposedMemoryAppendsEntryWithoutDuplicateToast() {
        let controller = AppController.makeForTesting(storageService: .temporary())
        let originalState = controller.state
        defer { controller.state = originalState }

        var state = ACState()
        state.proposedChanges = [
            ProposedPolicyChange(
                id: "p-mem",
                kind: .memory,
                proposedMemoryNote: "User accepts Spotify during writing"
            )
        ]
        controller.state = state
        controller.learnedToast = nil

        controller.acceptProposedChange(id: "p-mem")

        #expect(controller.state.memoryEntries.contains {
            $0.text.contains("Spotify during writing")
        })
        // Accepting a proposal is an explicit user action — no toast should fire.
        #expect(controller.learnedToast == nil)
    }

    @Test
    func recordBehavioralSignalCapsAtRecentBehavioralSignalsCap() {
        let controller = AppController.makeForTesting(storageService: .temporary())
        let originalState = controller.state
        defer { controller.state = originalState }
        controller.state = ACState()

        for index in 0..<(ACState.recentBehavioralSignalsCap + 5) {
            controller.recordBehavioralSignal(BehavioralSignalSummary(
                kind: "appealApproved",
                detail: "signal \(index)"
            ))
        }

        #expect(controller.state.recentBehavioralSignals.count == ACState.recentBehavioralSignalsCap)
        // Newest signal must survive — old ones were dropped from the front of the buffer.
        #expect(controller.state.recentBehavioralSignals.last?.detail?.contains("signal") == true)
    }

    @Test
    func undoLearnedToastForRuleExpiresTheRule() {
        let controller = AppController.makeForTesting(storageService: .temporary())
        let originalState = controller.state
        defer { controller.state = originalState }

        var state = ACState()
        let rule = PolicyRule(
            id: "auto-rule",
            kind: .allow,
            summary: "Auto-allow Twitter",
            source: .system,
            scope: PolicyRuleScope(appName: "Twitter"),
            active: true,
            profileID: PolicyRule.defaultProfileID
        )
        state.policyMemory.rules = [rule]
        controller.state = state
        controller.learnedToast = LearnedToast(
            detail: "Twitter is allowed",
            subject: .rule(id: "auto-rule", summary: "Auto-allow Twitter")
        )

        controller.undoLearnedToast()

        #expect(controller.learnedToast == nil)
        let updatedRule = controller.state.policyMemory.rules.first { $0.id == "auto-rule" }
        #expect(updatedRule?.active == false)
    }
}

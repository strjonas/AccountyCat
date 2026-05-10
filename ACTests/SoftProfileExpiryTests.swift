//
//  SoftProfileExpiryTests.swift
//  ACTests
//
//  Verifies the pure-state soft-expiry logic in `BrainService.applySoftProfileLifecycle`:
//  pre-expiry warning, auto-extend when on-task, end-with-mode-change when off-task,
//  and stale `recentlyEndedSession` cleanup. Side-effect orchestration (chat sink,
//  activity log, telemetry) is exercised separately via the production tick path.
//

import Foundation
import Testing
@testable import AC

@MainActor
struct SoftProfileExpiryTests {

    // MARK: - Pre-expiry warning

    @Test
    func preWarnFiresOnceWithin5MinAndStampsProfile() throws {
        let now = Date(timeIntervalSince1970: 10_000)
        var state = ACState()
        let profile = makeWritingProfile(expiresAt: now.addingTimeInterval(3 * 60))
        state.profiles.append(profile)
        state.activeProfileID = profile.id

        let outcome = BrainService.applySoftProfileLifecycle(
            state: &state,
            lastObservedContext: nil,
            now: now
        )
        #expect(outcome == .preWarned(profileName: profile.name, minutesLeft: 3))

        let stamped = try #require(state.profiles.first(where: { $0.id == profile.id }))
        #expect(stamped.prewarnSentAt != nil)
        #expect(state.chatHistory.last?.text.contains("session ends in 3 min") == true)

        // Second pass within the same activation must NOT re-warn (idempotent).
        let secondOutcome = BrainService.applySoftProfileLifecycle(
            state: &state,
            lastObservedContext: nil,
            now: now.addingTimeInterval(30)
        )
        #expect(secondOutcome == .idle)
        #expect(state.chatHistory.filter { $0.text.contains("session ends in") }.count == 1)
    }

    @Test
    func preWarnDoesNotFireOutsideFiveMinuteWindow() {
        let now = Date(timeIntervalSince1970: 10_000)
        var state = ACState()
        let profile = makeWritingProfile(expiresAt: now.addingTimeInterval(10 * 60)) // 10 min away
        state.profiles.append(profile)
        state.activeProfileID = profile.id

        let outcome = BrainService.applySoftProfileLifecycle(
            state: &state,
            lastObservedContext: nil,
            now: now
        )
        #expect(outcome == .idle)
        #expect(state.profiles.first(where: { $0.id == profile.id })?.prewarnSentAt == nil)
    }

    // MARK: - Expiry: end vs auto-extend

    @Test
    func expiryEndsProfileWhenNotOnTask() throws {
        let now = Date(timeIntervalSince1970: 20_000)
        var state = ACState()
        let profile = makeWritingProfile(expiresAt: now.addingTimeInterval(-1))
        state.profiles.append(profile)
        state.activeProfileID = profile.id
        // No focused signal in algorithmState → stillOnTask = false → end profile.

        let outcome = BrainService.applySoftProfileLifecycle(
            state: &state,
            lastObservedContext: nil,
            now: now
        )
        #expect(outcome == .ended(profileName: profile.name))
        #expect(state.activeProfileID == PolicyRule.defaultProfileID)

        let recentlyEnded = try #require(state.recentlyEndedSession)
        #expect(recentlyEnded.name == profile.name)
        #expect(recentlyEnded.goalSummary == "Essay sprint")
        #expect(state.chatHistory.last?.text.contains("everyday mode") == true)
    }

    @Test
    func expiryAutoExtendsWhenLastAssessmentFocusedAndTitleRelevant() throws {
        let now = Date(timeIntervalSince1970: 30_000)
        var state = ACState()
        var profile = makeWritingProfile(expiresAt: now.addingTimeInterval(-1))
        profile.description = "Drafting an essay on machine consciousness"
        state.profiles.append(profile)
        state.activeProfileID = profile.id

        // Pre-seed: last assessment focused.
        state.algorithmState.llmPolicy.distraction = DistractionMetadata(
            contextKey: nil,
            stableSince: now.addingTimeInterval(-300),
            lastAssessment: .focused,
            consecutiveDistractedCount: 0,
            nextEvaluationAt: nil
        )
        let onTaskContext = FrontmostContext(
            bundleIdentifier: "com.apple.TextEdit",
            appName: "TextEdit",
            windowTitle: "Notes — machine consciousness draft"
        )

        let outcome = BrainService.applySoftProfileLifecycle(
            state: &state,
            lastObservedContext: onTaskContext,
            now: now
        )

        guard case let .autoExtended(profileName, until) = outcome else {
            Issue.record("Expected .autoExtended, got \(outcome)")
            return
        }
        #expect(profileName == profile.name)
        #expect(abs(until.timeIntervalSince(now) - (30 * 60)) < 1)

        let extended = try #require(state.profiles.first(where: { $0.id == profile.id }))
        #expect(extended.autoExtendedAt != nil)
        #expect(extended.expiresAt == until)
        #expect(extended.prewarnSentAt == nil, "Pre-warn flag must reset so the user gets a fresh heads-up before the new expiry")
        #expect(state.activeProfileID == profile.id)
        #expect(state.recentlyEndedSession == nil)
    }

    @Test
    func expiryDoesNotAutoExtendTwiceInARow() throws {
        let now = Date(timeIntervalSince1970: 40_000)
        var state = ACState()
        var profile = makeWritingProfile(expiresAt: now.addingTimeInterval(-1))
        profile.description = "Drafting an essay on machine consciousness"
        // Profile already auto-extended once → second expiry must end it.
        profile.autoExtendedAt = now.addingTimeInterval(-1800)
        state.profiles.append(profile)
        state.activeProfileID = profile.id

        state.algorithmState.llmPolicy.distraction = DistractionMetadata(
            contextKey: nil,
            stableSince: now.addingTimeInterval(-300),
            lastAssessment: .focused,
            consecutiveDistractedCount: 0,
            nextEvaluationAt: nil
        )
        let onTaskContext = FrontmostContext(
            bundleIdentifier: "com.apple.TextEdit",
            appName: "TextEdit",
            windowTitle: "Notes — machine consciousness draft"
        )

        let outcome = BrainService.applySoftProfileLifecycle(
            state: &state,
            lastObservedContext: onTaskContext,
            now: now
        )
        #expect(outcome == .ended(profileName: profile.name))
        #expect(state.activeProfileID == PolicyRule.defaultProfileID)
    }

    @Test
    func expiryEndsWhenFocusedButTitleUnrelated() {
        let now = Date(timeIntervalSince1970: 50_000)
        var state = ACState()
        var profile = makeWritingProfile(expiresAt: now.addingTimeInterval(-1))
        profile.description = "Drafting an essay on machine consciousness"
        state.profiles.append(profile)
        state.activeProfileID = profile.id

        state.algorithmState.llmPolicy.distraction = DistractionMetadata(
            contextKey: nil,
            stableSince: now.addingTimeInterval(-300),
            lastAssessment: .focused,
            consecutiveDistractedCount: 0,
            nextEvaluationAt: nil
        )
        // Title carries no overlap with the goal.
        let unrelatedContext = FrontmostContext(
            bundleIdentifier: "com.example.shop",
            appName: "Shop",
            windowTitle: "Cart — birthday gift options"
        )

        let outcome = BrainService.applySoftProfileLifecycle(
            state: &state,
            lastObservedContext: unrelatedContext,
            now: now
        )
        #expect(outcome == .ended(profileName: profile.name))
    }

    // MARK: - Recently-ended session retention

    @Test
    func staleRecentlyEndedSessionIsClearedOnTick() {
        let now = Date(timeIntervalSince1970: 60_000)
        var state = ACState()
        state.recentlyEndedSession = RecentlyEndedSession(
            name: "Writing",
            endedAt: now.addingTimeInterval(-(RecentlyEndedSession.retentionWindow + 60))
        )

        let outcome = BrainService.applySoftProfileLifecycle(
            state: &state,
            lastObservedContext: nil,
            now: now
        )
        #expect(outcome == .idle)
        #expect(state.recentlyEndedSession == nil)
    }

    @Test
    func freshRecentlyEndedSessionIsRetained() {
        let now = Date(timeIntervalSince1970: 60_000)
        var state = ACState()
        state.recentlyEndedSession = RecentlyEndedSession(
            name: "Writing",
            endedAt: now.addingTimeInterval(-60)
        )

        _ = BrainService.applySoftProfileLifecycle(
            state: &state,
            lastObservedContext: nil,
            now: now
        )
        #expect(state.recentlyEndedSession != nil)
    }

    // MARK: - Helpers

    private func makeWritingProfile(expiresAt: Date) -> FocusProfile {
        FocusProfile(
            id: "writing-\(UUID().uuidString)",
            name: "Writing",
            description: "Essay drafting",
            activatedAt: expiresAt.addingTimeInterval(-(2 * 60 * 60)),
            expiresAt: expiresAt,
            createdReason: "Essay sprint"
        )
    }
}

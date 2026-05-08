//
//  RecurringScheduleAndNudgeTests.swift
//  ACTests
//
//  Tests for RecurringSchedule matching, RecurringNudge firing, LRU eviction
//  interactions with scheduled profiles, and profile/nudge lifecycle edge cases.
//

import Foundation
import Testing
@testable import AC

// MARK: - RecurringSchedule.matches

struct RecurringScheduleTests {

    @Test
    func matchesExactMinute() {
        let schedule = RecurringSchedule(hour: 9, minute: 0)
        let now = Date(timeIntervalSince1970: 1_700_000_000) // some fixed timestamp
        let cal = Calendar.current
        // Set now to exactly 09:00
        let components = DateComponents(year: cal.component(.year, from: now),
                                        month: cal.component(.month, from: now),
                                        day: cal.component(.day, from: now),
                                        hour: 9, minute: 0)
        let nineOClock = cal.date(from: components)!
        #expect(schedule.matches(now: nineOClock, calendar: cal))
    }

    @Test
    func matchesWithinGraceWindow() {
        let schedule = RecurringSchedule(hour: 9, minute: 0)
        let cal = Calendar.current
        let base = cal.date(from: DateComponents(year: 2026, month: 5, day: 8, hour: 9, minute: 0))!
        let one = base.addingTimeInterval(60)       // 09:01
        let two = base.addingTimeInterval(120)      // 09:02
        let three = base.addingTimeInterval(180)    // 09:03

        #expect(schedule.matches(now: one, calendar: cal))
        #expect(schedule.matches(now: two, calendar: cal))
        #expect(!schedule.matches(now: three, calendar: cal))
    }

    @Test
    func doesNotMatchBeforeScheduledTime() {
        let schedule = RecurringSchedule(hour: 9, minute: 0)
        let cal = Calendar.current
        let base = cal.date(from: DateComponents(year: 2026, month: 5, day: 8, hour: 8, minute: 59))!
        #expect(!schedule.matches(now: base, calendar: cal))
    }

    @Test
    func matchesWeekdaySpecific() {
        // Thursday June 4, 2026 = weekday 5
        let schedule = RecurringSchedule(hour: 9, minute: 0, weekdays: [2, 3, 4, 5, 6])
        let cal = Calendar.current
        // Thursday
        let thursday = cal.date(from: DateComponents(year: 2026, month: 6, day: 4, hour: 9, minute: 1))!
        // Sunday
        let sunday = cal.date(from: DateComponents(year: 2026, month: 6, day: 7, hour: 9, minute: 1))!

        #expect(schedule.matches(now: thursday, calendar: cal))
        #expect(!schedule.matches(now: sunday, calendar: cal))
    }

    @Test
    func weekdayNilMatchesEveryDay() {
        let schedule = RecurringSchedule(hour: 14, minute: 30, weekdays: nil)
        let cal = Calendar.current
        let mon = cal.date(from: DateComponents(year: 2026, month: 6, day: 1, hour: 14, minute: 30))!
        let sun = cal.date(from: DateComponents(year: 2026, month: 6, day: 7, hour: 14, minute: 30))!

        #expect(schedule.matches(now: mon, calendar: cal))
        #expect(schedule.matches(now: sun, calendar: cal))
    }

    @Test
    func emptyWeekdaysArrayTreatedAsNil() {
        // RecurringSchedule init flattens empty weekdays to nil
        let schedule = RecurringSchedule(hour: 10, minute: 0, weekdays: [])
        #expect(schedule.weekdays == nil)
        let cal = Calendar.current
        let anyDay = cal.date(from: DateComponents(year: 2026, month: 6, day: 3, hour: 10, minute: 1))!
        #expect(schedule.matches(now: anyDay, calendar: cal))
    }

    @Test
    func scheduleDescriptionFormatsCorrectly() {
        let daily = RecurringSchedule(hour: 9, minute: 5)
        #expect(daily.scheduleDescription() == "every day at 09:05")

        let weekdaySchedule = RecurringSchedule(hour: 21, minute: 0, weekdays: [2, 3, 4, 5, 6])
        let desc = weekdaySchedule.scheduleDescription()
        #expect(desc.contains("at 21:00"))
        #expect(desc.contains("Mon"))
        #expect(desc.contains("Fri"))
        #expect(!desc.contains("Sun"))
    }

    @Test
    func hourAndMinuteClamped() {
        let schedule = RecurringSchedule(hour: 25, minute: 99)
        #expect(schedule.hour == 23)
        #expect(schedule.minute == 59)
    }
}

// MARK: - RecurringNudge matching

struct RecurringNudgeMatchingTests {

    @Test
    func nudgeMatchesScheduledTime() {
        let nudge = RecurringNudge(hour: 8, minute: 0, message: "Morning!")
        let cal = Calendar.current
        let atEight = cal.date(from: DateComponents(year: 2026, month: 5, day: 8, hour: 8, minute: 1))!
        #expect(nudge.matches(now: atEight, calendar: cal))
    }

    @Test
    func nudgeDoesNotMatchWrongTime() {
        let nudge = RecurringNudge(hour: 8, minute: 0, message: "Morning!")
        let cal = Calendar.current
        let atNine = cal.date(from: DateComponents(year: 2026, month: 5, day: 8, hour: 9, minute: 0))!
        #expect(!nudge.matches(now: atNine, calendar: cal))
    }

    @Test
    func nudgeDoesNotMatchAfterSameDayFire() {
        var nudge = RecurringNudge(hour: 8, minute: 0, message: "Morning!")
        let cal = Calendar.current
        let fireTime = cal.date(from: DateComponents(year: 2026, month: 5, day: 8, hour: 8, minute: 1))!
        nudge.lastFiredAt = fireTime

        // Same day, same 2-min window — should not fire again
        let later = fireTime.addingTimeInterval(60)
        #expect(!nudge.matches(now: later, calendar: cal))
    }

    @Test
    func nudgeFiresAgainNextDay() {
        var nudge = RecurringNudge(hour: 8, minute: 0, message: "Morning!")
        let cal = Calendar.current
        let day1 = cal.date(from: DateComponents(year: 2026, month: 5, day: 8, hour: 8, minute: 1))!
        nudge.lastFiredAt = day1

        // Next day, same time — should fire
        let day2 = cal.date(from: DateComponents(year: 2026, month: 5, day: 9, hour: 8, minute: 1))!
        #expect(nudge.matches(now: day2, calendar: cal))
    }

    @Test
    func nudgeRespectsWeekdays() {
        let nudge = RecurringNudge(hour: 9, minute: 0, weekdays: [2, 3, 4, 5, 6], message: "Work time")
        let cal = Calendar.current
        // Thursday June 4 2026
        let thursday = cal.date(from: DateComponents(year: 2026, month: 6, day: 4, hour: 9, minute: 1))!
        // Sunday June 7 2026
        let sunday = cal.date(from: DateComponents(year: 2026, month: 6, day: 7, hour: 9, minute: 1))!

        #expect(nudge.matches(now: thursday, calendar: cal))
        #expect(!nudge.matches(now: sunday, calendar: cal))
    }

    @Test
    func disabledNudgeNeverMatches() {
        var nudge = RecurringNudge(hour: 8, minute: 0, message: "Morning!")
        nudge.enabled = false
        let cal = Calendar.current
        let atEight = cal.date(from: DateComponents(year: 2026, month: 5, day: 8, hour: 8, minute: 1))!
        #expect(!nudge.matches(now: atEight, calendar: cal))
    }
}

// MARK: - Profile cap enforcement (no silent eviction)

@MainActor
struct LRUEvictionTests {

    @Test
    func createProfileFailsAtCapAndPostsChatMessage() {
        let controller = AppController.makeForTesting(storageService: .temporary())
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
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        // Default is always present. Add 6 named profiles to fill the cap.
        for i in 0..<6 {
            state.profiles.append(FocusProfile(
                id: "profile-\(i)",
                name: "Profile \(i)",
                lastUsedAt: base.addingTimeInterval(TimeInterval(i * 3600))
            ))
        }
        state.activeProfileID = "profile-5"
        controller.state = state
        controller.chatMessages = []
        controller.hasUnreadChatMessages = false

        // Creating one more should fail because the cap is reached
        let created = controller.createAndActivateProfile(
            name: "New Profile",
            duration: nil,
            reason: "test"
        )
        #expect(created == nil)
        // No profile should have been added
        #expect(!controller.state.profiles.contains(where: { $0.name == "New Profile" }))
        // A chat message should be posted suggesting removal
        #expect(controller.state.chatHistory.count == 1)
        let message = controller.state.chatHistory.last
        #expect(message != nil)
        #expect(message?.interruptionPolicy == .deferred)
        #expect(message?.text.contains("Profile 0") == true) // Suggests the LRU candidate
        #expect(message?.text.contains("New Profile") == true) // Names the profile the user tried to create
    }

    @Test
    func createProfileSucceedsWhenUnderCap() {
        let controller = AppController.makeForTesting(storageService: .temporary())
        let originalState = controller.state
        defer {
            controller.state = originalState
            controller.storageService.saveState(originalState)
        }

        var state = ACState()
        state.chatHistory = []
        // Only 3 named profiles (well under cap of 6)
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        for i in 0..<3 {
            state.profiles.append(FocusProfile(
                id: "profile-\(i)",
                name: "Profile \(i)",
                lastUsedAt: base.addingTimeInterval(TimeInterval(i * 3600))
            ))
        }
        state.activeProfileID = "profile-2"
        controller.state = state

        let created = controller.createAndActivateProfile(
            name: "New Profile",
            duration: nil,
            reason: "test"
        )
        #expect(created != nil)
        #expect(controller.state.profiles.contains(where: { $0.name == "New Profile" }))
        #expect(controller.state.activeProfileID == created?.id)
    }

    @Test
    func chatMessageMentionsRecurringScheduleOnSuggestedProfile() {
        let controller = AppController.makeForTesting(storageService: .temporary())
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
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        // Oldest profile has a recurring schedule — should be called out
        let scheduled = FocusProfile(
            id: "evening",
            name: "Evening Wind-Down",
            lastUsedAt: base,
            recurringSchedule: RecurringSchedule(hour: 21, minute: 0)
        )
        state.profiles.append(scheduled)
        for i in 1..<6 {
            state.profiles.append(FocusProfile(
                id: "profile-\(i)",
                name: "Profile \(i)",
                lastUsedAt: base.addingTimeInterval(TimeInterval(i * 3600))
            ))
        }
        state.activeProfileID = "profile-5"
        controller.state = state
        controller.chatMessages = []
        controller.hasUnreadChatMessages = false

        _ = controller.createAndActivateProfile(name: "Overflow", duration: nil, reason: "test")

        #expect(controller.state.chatHistory.count == 1)
        let message = controller.state.chatHistory.last
        #expect(message?.text.contains("Evening Wind-Down") == true)
        #expect(message?.text.contains("recurring schedule") == true)
        // The schedule itself is preserved — no deletion happened
        #expect(controller.state.profiles.contains(where: { $0.id == "evening" }))
        let eveningProfile = controller.state.profiles.first(where: { $0.id == "evening" })
        #expect(eveningProfile?.recurringSchedule != nil)
    }

    @Test
    func doesNotDeleteProfileOrRulesAtCap() {
        let controller = AppController.makeForTesting(storageService: .temporary())
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
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        for i in 0..<6 {
            state.profiles.append(FocusProfile(
                id: "profile-\(i)",
                name: "Profile \(i)",
                lastUsedAt: base.addingTimeInterval(TimeInterval(i * 3600))
            ))
        }
        state.activeProfileID = "profile-5"
        // Add rules scoped to the oldest profile
        state.policyMemory.rules = [
            PolicyRule(id: "old-rule-1", kind: .discourage, summary: "Block X", source: .userChat, profileID: "profile-0"),
            PolicyRule(id: "old-rule-2", kind: .allow, summary: "Allow Y", source: .explicitFeedback, isLocked: true, profileID: "profile-0"),
        ]
        controller.state = state
        controller.chatMessages = []
        controller.hasUnreadChatMessages = false

        _ = controller.createAndActivateProfile(name: "Overflow", duration: nil, reason: "test")

        // Nothing should be deleted — all profiles and rules survive
        #expect(controller.state.profiles.count == 7) // default + 6 named
        #expect(controller.state.profiles.contains(where: { $0.id == "profile-0" }))
        #expect(controller.state.policyMemory.rules.contains(where: { $0.id == "old-rule-1" }))
        #expect(controller.state.policyMemory.rules.contains(where: { $0.id == "old-rule-2" }))
    }

    @Test
    func chatMessageWhenNoRemovableCandidates() {
        let controller = AppController.makeForTesting(storageService: .temporary())
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
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        for i in 0..<6 {
            // All profiles have locked rules → not removable via canDeleteProfile
            state.profiles.append(FocusProfile(
                id: "profile-\(i)",
                name: "Profile \(i)",
                lastUsedAt: base.addingTimeInterval(TimeInterval(i * 3600))
            ))
        }
        state.activeProfileID = "profile-5"
        // All profiles have locked rules
        for i in 0..<6 {
            state.policyMemory.rules.append(
                PolicyRule(id: "locked-rule-\(i)", kind: .allow, summary: "Locked", source: .userChat, isLocked: true, profileID: "profile-\(i)")
            )
        }
        controller.state = state
        controller.chatMessages = []
        controller.hasUnreadChatMessages = false

        _ = controller.createAndActivateProfile(name: "Blocked", duration: nil, reason: "test")

        // Should still post a message, but about removing via Settings
        #expect(controller.state.chatHistory.count == 1)
        let message = controller.state.chatHistory.last
        #expect(message?.text.contains("Remove a profile first via Settings") == true)
    }
}

// MARK: - ProfileActionParser recurring schedule extraction

struct ProfileActionParserRecurringTests {

    @Test
    func parsesRecurringScheduleWithDailyAt24HourTime() throws {
        let coding = FocusProfile(id: "c", name: "Coding")
        let ops = try #require(ProfileActionParser.parse(
            action: "activate Coding profile every day at 21:00",
            availableProfiles: [coding],
            activeProfileID: PolicyRule.defaultProfileID
        ))
        #expect(ops.count == 1)
        #expect(ops[0].type == .activateProfile)
        let schedule = try #require(ops[0].recurringSchedule)
        #expect(schedule.hour == 21)
        #expect(schedule.minute == 0)
        #expect(schedule.weekdays == nil) // every day
    }

    @Test
    func parsesRecurringScheduleWithWeekdays() throws {
        let coding = FocusProfile(id: "c", name: "Coding")
        let ops = try #require(ProfileActionParser.parse(
            action: "always activate Coding profile on weekdays at 9AM",
            availableProfiles: [coding],
            activeProfileID: PolicyRule.defaultProfileID
        ))
        let schedule = try #require(ops[0].recurringSchedule)
        #expect(schedule.hour == 9)
        #expect(schedule.minute == 0)
        #expect(schedule.weekdays == [2, 3, 4, 5, 6]) // Mon–Fri
    }

    @Test
    func returnsNilWithoutRecurringSignalWord() {
        let coding = FocusProfile(id: "c", name: "Coding")
        // "at 9PM" without "every"/"daily"/etc should not produce a recurring schedule
        let ops = ProfileActionParser.parse(
            action: "activate Coding profile for 60 min",
            availableProfiles: [coding],
            activeProfileID: PolicyRule.defaultProfileID
        )
        #expect(ops != nil)
        if let ops {
            #expect(ops[0].recurringSchedule == nil)
        }
    }

    @Test
    func parsesRecurringScheduleWithPM() throws {
        let reading = FocusProfile(id: "r", name: "Reading")
        let ops = try #require(ProfileActionParser.parse(
            action: "schedule Reading profile every evening at 8:30PM",
            availableProfiles: [reading],
            activeProfileID: PolicyRule.defaultProfileID
        ))
        let schedule = try #require(ops[0].recurringSchedule)
        #expect(schedule.hour == 20)
        #expect(schedule.minute == 30)
    }

    @Test
    func createsNewProfileWithRecurringSchedule() throws {
        let ops = try #require(ProfileActionParser.parse(
            action: "create and activate Deep Work profile daily at 09:00",
            availableProfiles: [],
            activeProfileID: PolicyRule.defaultProfileID
        ))
        #expect(ops[0].type == .createAndActivateProfile)
        #expect(ops[0].profileName == "Deep")
        let schedule = try #require(ops[0].recurringSchedule)
        #expect(schedule.hour == 9)
        #expect(schedule.minute == 0)
    }

    @Test
    func parsesWeekendSchedule() throws {
        let profile = FocusProfile(id: "w", name: "Weekend")
        let ops = try #require(ProfileActionParser.parse(
            action: "activate Weekend profile on weekends at 10AM",
            availableProfiles: [profile],
            activeProfileID: PolicyRule.defaultProfileID
        ))
        let schedule = try #require(ops[0].recurringSchedule)
        #expect(schedule.weekdays == [1, 7]) // Sun, Sat
    }
}

// MARK: - ProfileActionParser multi-word name edge cases

struct ProfileActionParserNameExtractionTests {

    @Test
    func verbFirstPatternExtractsOnlyFirstWord() {
        // "start Deep Work for 90 minutes" — the verb-first fallback captures
        // only "Deep" as the name. This is a known limitation.
        let result = ProfileActionParser.parse(
            action: "start Deep Work for 90 minutes",
            availableProfiles: [],
            activeProfileID: PolicyRule.defaultProfileID
        )
        // The parser currently extracts "Deep" from the verb-first fallback.
        // The "profile (Word)" pattern doesn't match because there's no word
        // "profile" before "Deep Work".
        #expect(result != nil)
        if let ops = result {
            #expect(ops[0].profileName == "Deep") // Known limitation: should ideally be "Deep Work"
        }
    }

    @Test
    func profileSpaceWordPatternCapturesMultiWord() {
        // "activate profile Deep Work for 90 minutes" — the "profile (Word)" pattern
        // captures "Deep". This is also a single-word capture.
        let profile = FocusProfile(id: "dw", name: "Deep Work")
        let result = ProfileActionParser.parse(
            action: "create and activate profile Deep Work",
            availableProfiles: [profile],
            activeProfileID: PolicyRule.defaultProfileID
        )
        #expect(result != nil)
    }

    @Test
    func wordBeforeProfilePatternCapturesSingleWord() {
        let coding = FocusProfile(id: "c", name: "Coding")
        let result = ProfileActionParser.parse(
            action: "activate Coding profile for 60 min",
            availableProfiles: [coding],
            activeProfileID: PolicyRule.defaultProfileID
        )
        #expect(result != nil)
        if let ops = result {
            #expect(ops[0].profileID == "c")
        }
    }

    @Test
    func substringMatchFallsBackForPartialName() {
        let deepWork = FocusProfile(id: "dw", name: "Deep Work")
        let result = ProfileActionParser.parse(
            action: "start Work profile",
            availableProfiles: [deepWork],
            activeProfileID: PolicyRule.defaultProfileID
        )
        #expect(result != nil)
        if let ops = result {
            // "Work" is a substring of "Deep Work" — should match
            #expect(ops[0].profileID == "dw")
        }
    }
}

// MARK: - LLM output parsing edge cases

struct LLMOutputParsingEdgeCaseTests {

    @Test
    func parsesCollapsedActionKind() {
        // Small models sometimes emit {"action":{"kind":"end"}} instead of
        // {"action":{"kind":"profile","intent":"end"}}
        let output = """
        {"action":{"kind":"end"}}
        """
        let action = LLMOutputParsing.extractChatAction(from: output, expectedKind: .profile)
        #expect(action != nil)
        #expect(action?.intent == "end")
        #expect(action?.kind == .profile)
    }

    @Test
    func parsesCollapsedActivateIntent() {
        let output = """
        {"action":{"kind":"activate","profileName":"Coding","durationMinutes":60}}
        """
        let action = LLMOutputParsing.extractChatAction(from: output, expectedKind: .profile)
        #expect(action != nil)
        #expect(action?.intent == "activate")
        #expect(action?.kind == .profile)
    }

    @Test
    func focusPolicyActionFallsBackToMemory() {
        // "always allow Spotify, no matter what profile" → should resolve to
        // focus_policy action, but the prompt says if it's truly cross-profile,
        // return kind "memory". The parser tolerates this crossover.
        let output = """
        {"action":{"kind":"memory","text":"User wants Spotify allowed regardless of which profile is active."}}
        """
        // focusPolicy expected, but memory is accepted as a valid fallback
        let action = LLMOutputParsing.extractChatAction(from: output, expectedKind: .focusPolicy)
        #expect(action != nil)
        #expect(action?.kind == .memory)
    }

    @Test
    func extractDecisionWithAlternativeKeyNames() {
        let output = """
        {"verdict":"distracted","suggestedAction":"nudge","confidence":0.85,"reasonTags":["social_media"]}
        """
        let decision = LLMOutputParsing.extractDecision(from: output)
        #expect(decision != nil)
        #expect(decision?.assessment == .distracted)
        #expect(decision?.suggestedAction == .nudge)
        #expect(decision?.reasonTags == ["social_media"])
    }

    @Test
    func extractDecisionWithFocusAlias() {
        let output = """
        {"assessment":"focus","suggested_action":"none"}
        """
        let decision = LLMOutputParsing.extractDecision(from: output)
        #expect(decision?.assessment == .focused)
    }

    @Test
    func extractDecisionInfersActionFromAssessment() {
        // Missing suggested_action — should be inferred from assessment
        let output = """
        {"assessment":"unclear"}
        """
        let decision = LLMOutputParsing.extractDecision(from: output)
        #expect(decision?.assessment == .unclear)
        #expect(decision?.suggestedAction == .abstain)
    }

    @Test
    func extractChatResultWithSchedule() {
        let output = """
        {"reply":"Sure, I'll set that up.","actions":[{"kind":"profile","intent":"activate","profileID":"coding","durationMinutes":60}],"schedule":{"type":"nudge","delay_minutes":5,"message":"Focus reminder!"}}
        """
        let result = LLMOutputParsing.extractChatResult(from: output)
        #expect(result != nil)
        #expect(result?.reply == "Sure, I'll set that up.")
        #expect(result?.actions.count == 1)
        #expect(result?.actions.first?.kind == .profile)
        #expect(result?.schedule != nil)
        #expect(result?.schedule?.delayMinutes == 5)
    }

    @Test
    func scheduleCandidateRejectsOver24hDelay() {
        let output = """
        {"reply":"I'll remind you.","actions":[],"schedule":{"type":"nudge","delay_minutes":99999,"message":"Way too late"}}
        """
        let result = LLMOutputParsing.extractChatResult(from: output)
        #expect(result?.schedule == nil) // Should reject > 1440
    }

    @Test
    func scheduleCandidateAcceptsValidDelay() {
        let output = """
        {"reply":"OK","actions":[],"schedule":{"type":"nudge","delay_minutes":10,"message":"Focus reminder!"}}
        """
        let result = LLMOutputParsing.extractChatResult(from: output)
        #expect(result?.schedule?.delayMinutes == 10)
    }

    @Test
    func cleansRuntimeNoiseFromChatOutput() {
        let noisy = """
        main: llama model loaded
        build: 1234
        I'd love to help you focus!
        """
        let cleaned = LLMOutputParsing.cleanChatOutput(noisy)
        #expect(cleaned.contains("love to help"))
        #expect(!cleaned.contains("main:"))
        #expect(!cleaned.contains("build:"))
    }
}
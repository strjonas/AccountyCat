import Foundation
import Testing
@testable import AC

@MainActor
struct SafelistPromotionTests {

    // MARK: - State round-trip

    @Test
    func algorithmStateRoundTripsObservationsAndDecisionCache() throws {
        var state = LLMPolicyAlgorithmState()
        let now = Date(timeIntervalSince1970: 100_000)
        state.focusedObservations["com.activitymonitor"] = FocusedObservationStat(
            contextFingerprint: "com.activitymonitor",
            appName: "Activity Monitor",
            bundleIdentifier: "com.activitymonitor",
            sampleWindowTitles: ["Activity Monitor"],
            focusedCount: 5,
            distractedCount: 0,
            firstSeenAt: now,
            lastSeenAt: now,
            distinctDayKeys: [now.acDayKey]
        )
        state.decisionCacheByContext["com.activitymonitor|Activity Monitor"] = CachedDecision(
            assessment: .focused,
            decidedAt: now,
            contextKey: "com.activitymonitor|Activity Monitor"
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(state)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(LLMPolicyAlgorithmState.self, from: data)

        #expect(decoded.focusedObservations.count == 1)
        #expect(decoded.focusedObservations["com.activitymonitor"]?.focusedCount == 5)
        #expect(decoded.decisionCacheByContext["com.activitymonitor|Activity Monitor"]?.assessment == .focused)
    }

    @Test
    func legacyStatePayloadDecodesWithoutNewFields() throws {
        let legacyJSON = """
        {
            "distraction": {"consecutiveDistractedCount": 0},
            "recentNudgeMessages": []
        }
        """
        let data = legacyJSON.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(LLMPolicyAlgorithmState.self, from: data)
        #expect(decoded.focusedObservations.isEmpty)
        #expect(decoded.decisionCacheByContext.isEmpty)
    }

    // MARK: - Eligibility tiers

    @Test
    func belowThresholdIsIneligible() {
        var stat = makeStat(focused: 1)
        stat.distractedCount = 0
        let result = SafelistPromotionPolicy.eligibility(
            for: stat,
            policyMemory: PolicyMemory(),
            context: makeContext(),
            now: Date()
        )
        #expect(result == .ineligible(reason: "below_threshold"))
    }

    @Test
    func twoFocusedZeroDistractedIsProbationary() {
        let stat = makeStat(focused: 2)
        let result = SafelistPromotionPolicy.eligibility(
            for: stat,
            policyMemory: PolicyMemory(),
            context: makeContext(),
            now: Date()
        )
        #expect(result == .eligible(tier: .probationary))
    }

    @Test
    func sixFocusedTwoDaysAfterCleanExpiryIsTrusted() {
        var stat = makeStat(focused: 6)
        stat.distinctDayKeys = ["2026-04-25", "2026-04-26"]
        stat.previousAutoAllowOutcome = .expiredClean
        let result = SafelistPromotionPolicy.eligibility(
            for: stat,
            policyMemory: PolicyMemory(),
            context: makeContext(),
            now: Date()
        )
        #expect(result == .eligible(tier: .trusted))
    }

    @Test
    func anyDistractedHistoryBlocksPromotion() {
        var stat = makeStat(focused: 10)
        stat.distractedCount = 1
        let result = SafelistPromotionPolicy.eligibility(
            for: stat,
            policyMemory: PolicyMemory(),
            context: makeContext(),
            now: Date()
        )
        #expect(result == .ineligible(reason: "distracted_history"))
    }

    @Test
    func recentPromotionAttemptIsThrottled() {
        var stat = makeStat(focused: 4)
        let now = Date(timeIntervalSince1970: 10_000)
        stat.promotionAttemptedAt = now.addingTimeInterval(-60 * 60)
        let result = SafelistPromotionPolicy.eligibility(
            for: stat,
            policyMemory: PolicyMemory(),
            context: makeContext(),
            now: now
        )
        #expect(result == .ineligible(reason: "throttled"))
    }

    @Test
    func userRestrictionBlocksPromotion() {
        let stat = makeStat(focused: 4)
        var policyMemory = PolicyMemory()
        policyMemory.rules.append(
            PolicyRule(
                kind: .disallow,
                summary: "no time on this app",
                source: .userChat,
                scope: PolicyRuleScope(bundleIdentifier: "com.app")
            )
        )
        let result = SafelistPromotionPolicy.eligibility(
            for: stat,
            policyMemory: policyMemory,
            context: makeContext(),
            now: Date()
        )
        #expect(result == .ineligible(reason: "user_restriction_active"))
    }

    @Test
    func existingAllowRuleBlocksPromotion() {
        let stat = makeStat(focused: 4)
        var policyMemory = PolicyMemory()
        policyMemory.rules.append(
            PolicyRule(
                kind: .allow,
                summary: "already allowed",
                source: .userChat,
                scope: PolicyRuleScope(bundleIdentifier: "com.app")
            )
        )
        let result = SafelistPromotionPolicy.eligibility(
            for: stat,
            policyMemory: policyMemory,
            context: makeContext(),
            now: Date()
        )
        #expect(result == .ineligible(reason: "already_allowed"))
    }

    // MARK: - Context fingerprinting

    @Test
    func nativeAppFingerprintsByBundle() {
        let context = FrontmostContext(
            bundleIdentifier: "com.activitymonitor",
            appName: "Activity Monitor",
            windowTitle: "CPU"
        )
        let observation = SafelistPromotionPolicy.makeContext(
            from: context,
            isBrowser: false,
            now: Date()
        )
        #expect(observation?.fingerprint == "com.activitymonitor")
        #expect(observation?.titleSignature == nil)
        #expect(observation?.requiresTitleScope == false)
    }

    @Test
    func browserContextUsesExactTitleSignature() {
        let unknown = FrontmostContext(
            bundleIdentifier: "com.google.Chrome",
            appName: "Google Chrome",
            windowTitle: "Random page that we have no signal for"
        )
        let unknownObservation = SafelistPromotionPolicy.makeContext(from: unknown, isBrowser: true, now: Date())
        #expect(unknownObservation?.fingerprint == "com.google.Chrome::Random page that we have no signal for")
        #expect(unknownObservation?.titleSignature == "Random page that we have no signal for")
        #expect(unknownObservation?.requiresTitleScope == true)

        let known = FrontmostContext(
            bundleIdentifier: "com.google.Chrome",
            appName: "Google Chrome",
            windowTitle: "AC idea log - Google Docs"
        )
        let observation = SafelistPromotionPolicy.makeContext(from: known, isBrowser: true, now: Date())
        #expect(observation?.fingerprint == "com.google.Chrome::AC idea log - Google Docs")
        #expect(observation?.titleSignature == "AC idea log - Google Docs")

    }

    @Test
    func ambiguousNativeAppsRequireTitleScope() {
        let context = FrontmostContext(
            bundleIdentifier: "com.apple.mail",
            appName: "Mail",
            windowTitle: "Max Weigand - draft reply"
        )
        let observation = SafelistPromotionPolicy.makeContext(
            from: context,
            isBrowser: false,
            now: Date()
        )
        #expect(observation?.fingerprint == "com.apple.mail::Max Weigand - draft reply")
        #expect(observation?.titleSignature == "Max Weigand - draft reply")
        #expect(observation?.requiresTitleScope == true)
    }

    // MARK: - Title signature derivation

    @Test
    func browserTitleSignatureMatchesKnownSites() {
        #expect(BrowserTitleSignature.derive(from: "Inbox - GitHub") == "Inbox - GitHub")
        #expect(BrowserTitleSignature.derive(from: "AC plan - Notion") == "AC plan - Notion")
        #expect(BrowserTitleSignature.derive(from: "Google Calendar - Today") == "Google Calendar - Today")
        #expect(BrowserTitleSignature.derive(from: "Crafting a Post-Scarcity Future - Google Gemini") == "Crafting a Post-Scarcity Future - Google Gemini")
        #expect(BrowserTitleSignature.derive(from: "Drafting outreach email - internal hiring loop") == "Drafting outreach email - internal hiring loop")
        #expect(BrowserTitleSignature.derive(from: "Random Twitter ramble") == "Random Twitter ramble")
        #expect(BrowserTitleSignature.derive(from: "Funny clip - YouTube") == "Funny clip - YouTube")
        #expect(BrowserTitleSignature.derive(from: nil) == nil)
        #expect(BrowserTitleSignature.derive(from: "") == nil)
    }

    // MARK: - Adaptive screenshot heuristic

    @Test
    func canRelyOnTitleAloneRejectsBrowsers() {
        #expect(MonitoringHeuristics.canRelyOnTitleAlone(
            bundleIdentifier: "com.google.Chrome",
            appName: "Google Chrome",
            windowTitle: "AppController.swift — AC",
            isBrowser: true
        ) == false)
    }

    @Test
    func canRelyOnTitleAloneRejectsAmbiguousContentApps() {
        #expect(MonitoringHeuristics.canRelyOnTitleAlone(
            bundleIdentifier: "com.spotify.client",
            appName: "Spotify",
            windowTitle: "Lex Fridman Podcast - Episode 372",
            isBrowser: false
        ) == false)
        #expect(MonitoringHeuristics.canRelyOnTitleAlone(
            bundleIdentifier: "tv.twitch.desktop.app",
            appName: "Twitch",
            windowTitle: "Coding stream - Building AC",
            isBrowser: false
        ) == false)
    }

    @Test
    func canRelyOnTitleAloneAcceptsIDETitles() {
        #expect(MonitoringHeuristics.canRelyOnTitleAlone(
            bundleIdentifier: "com.apple.dt.Xcode",
            appName: "Xcode",
            windowTitle: "AppController.swift",
            isBrowser: false
        ) == true)
    }

    @Test
    func canRelyOnTitleAloneRequiresStructuralMarkerForUnknownApps() {
        // Plain "Documents" — no marker — keep the screenshot.
        #expect(MonitoringHeuristics.canRelyOnTitleAlone(
            bundleIdentifier: "com.unknown.tool",
            appName: "Unknown Tool",
            windowTitle: "Documents",
            isBrowser: false
        ) == false)
        // With a clear hyphen separator and a content-y name on both sides — drop the screenshot.
        #expect(MonitoringHeuristics.canRelyOnTitleAlone(
            bundleIdentifier: "com.unknown.tool",
            appName: "Unknown Tool",
            windowTitle: "AppController.swift — AC project",
            isBrowser: false
        ) == true)
    }

    // MARK: - Rule construction

    @Test
    func buildRuleScopesNativeAppByBundle() {
        let observation = SafelistObservationContext(
            fingerprint: "com.activitymonitor",
            appName: "Activity Monitor",
            bundleIdentifier: "com.activitymonitor",
            titleSignature: nil,
            isBrowser: false,
            requiresTitleScope: false,
            dayKey: Date().acDayKey
        )
        let envelope = MonitoringSafelistAppealEnvelope(
            approve: true,
            scopeKind: .bundle,
            titlePattern: nil,
            summary: "always productive",
            reason: "system app"
        )
        let now = Date(timeIntervalSince1970: 1_000)
        let rule = SafelistPromotionPolicy.buildRule(
            from: envelope,
            observation: observation,
            tier: .probationary,
            now: now
        )
        #expect(rule?.kind == .allow)
        #expect(rule?.scope.bundleIdentifier == "com.activitymonitor")
        #expect(rule?.schedule.expiresAt == now.addingTimeInterval(SafelistPromotionTier.probationary.ttl))
        #expect(rule?.source == .system)
    }

    @Test
    func buildRuleRejectsBundleScopeForBrowser() {
        let observation = SafelistObservationContext(
            fingerprint: "com.google.Chrome::Google Docs",
            appName: "Google Chrome",
            bundleIdentifier: "com.google.Chrome",
            titleSignature: "Google Docs",
            isBrowser: true,
            requiresTitleScope: true,
            dayKey: Date().acDayKey
        )
        let envelope = MonitoringSafelistAppealEnvelope(
            approve: true,
            scopeKind: .bundle,
            titlePattern: nil,
            summary: nil,
            reason: nil
        )
        let rule = SafelistPromotionPolicy.buildRule(
            from: envelope,
            observation: observation,
            tier: .probationary,
            now: Date()
        )
        #expect(rule == nil)
    }

    @Test
    func buildRuleScopesBrowserByTitlePattern() {
        let observation = SafelistObservationContext(
            fingerprint: "com.google.Chrome::AC idea log - Google Docs",
            appName: "Google Chrome",
            bundleIdentifier: "com.google.Chrome",
            titleSignature: "AC idea log - Google Docs",
            isBrowser: true,
            requiresTitleScope: true,
            dayKey: Date().acDayKey
        )
        let envelope = MonitoringSafelistAppealEnvelope(
            approve: true,
            scopeKind: .titlePattern,
            titlePattern: "Google Docs",
            summary: "user uses docs for project notes",
            reason: "matches goals"
        )
        let now = Date(timeIntervalSince1970: 2_000)
        let rule = SafelistPromotionPolicy.buildRule(
            from: envelope,
            observation: observation,
            tier: .trusted,
            now: now
        )
        #expect(rule?.scope.bundleIdentifier == "com.google.Chrome")
        #expect(rule?.scope.titleContains == ["AC idea log - Google Docs"])
        #expect(rule?.schedule.expiresAt == now.addingTimeInterval(SafelistPromotionTier.trusted.ttl))
    }

    @Test
    func buildRuleScopesTitlePatternToNativeBundleToo() {
        let observation = SafelistObservationContext(
            fingerprint: "com.apple.mail::Max Weigand - draft reply",
            appName: "Mail",
            bundleIdentifier: "com.apple.mail",
            titleSignature: "Max Weigand - draft reply",
            isBrowser: false,
            requiresTitleScope: true,
            dayKey: Date().acDayKey
        )
        let envelope = MonitoringSafelistAppealEnvelope(
            approve: true,
            scopeKind: .titlePattern,
            titlePattern: "Max Weigand - draft reply",
            summary: "drafting outreach mail",
            reason: "goal aligned"
        )
        let rule = SafelistPromotionPolicy.buildRule(
            from: envelope,
            observation: observation,
            tier: .probationary,
            now: Date()
        )
        #expect(rule?.scope.bundleIdentifier == "com.apple.mail")
        #expect(rule?.scope.titleContains == ["Max Weigand - draft reply"])
    }

    // MARK: - Helpers

    private func makeStat(focused: Int) -> FocusedObservationStat {
        let now = Date(timeIntervalSince1970: 10_000)
        return FocusedObservationStat(
            contextFingerprint: "com.app",
            appName: "App",
            bundleIdentifier: "com.app",
            sampleWindowTitles: ["title"],
            focusedCount: focused,
            distractedCount: 0,
            firstSeenAt: now.addingTimeInterval(-3600),
            lastSeenAt: now,
            distinctDayKeys: [now.acDayKey]
        )
    }

    private func makeContext() -> FrontmostContext {
        FrontmostContext(
            bundleIdentifier: "com.app",
            appName: "App",
            windowTitle: "title"
        )
    }
}

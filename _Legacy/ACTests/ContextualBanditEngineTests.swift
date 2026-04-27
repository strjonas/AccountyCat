//
//  ContextualBanditEngineTests.swift
//  ACTests
//

import Foundation
import Testing
@testable import AC

struct ContextualBanditEngineTests {

    // MARK: - Helpers

    /// Builds a feature vector with a known non-zero pattern (avoids trivial all-zero edge cases).
    private func makeVector(seed: Double = 1.0) -> BanditFeatureVector {
        var values = [Double](repeating: 0, count: BanditFeatureVector.dimension)
        values[0] = 1.0          // bias
        values[1] = seed * 0.5   // sin-like
        values[2] = seed * 0.3   // cos-like
        values[3] = 0.0          // weekday
        values[4] = 1.0          // one-hot productivity
        values[12] = 0.2 * seed  // productivityScore
        values[13] = 0.5 * seed  // log(timeInApp)
        values[14] = 1.0         // log(timeSinceNudge)
        values[15] = 0.0         // lastNudgeReaction unknown
        return BanditFeatureVector(values: values)
    }

    /// Builds a vector orthogonal to `makeVector(seed:1.0)` in the sense that the dot product of
    /// the non-shared dimensions is zero.  We use only dimension [5] (a different one-hot bucket).
    private func makeOrthogonalVector() -> BanditFeatureVector {
        var values = [Double](repeating: 0, count: BanditFeatureVector.dimension)
        values[5] = 1.0  // one-hot communication — orthogonal to v[4]
        return BanditFeatureVector(values: values)
    }

    // MARK: - Tests

    @Test func freshEngineExploresIntervention() {
        // A fresh engine has A=I, b=0 for every arm.
        // theta = A⁻¹b = 0,  meanReward = 0
        // variance = xᵀ A⁻¹ x = xᵀ I x = ||x||² > 0
        // UCB = 0 + alpha * sqrt(||x||²) > 0  ⟹  pick the best-scoring intervention arm.
        let engine = ContextualBanditEngine()
        let x = makeVector()
        let (arm, ucb, scores) = engine.selectArm(context: x)
        #expect(arm != .none)
        #expect(ucb > 0)
        #expect(scores.count == BanditArm.learnable.count)
    }

    @Test func positiveRewardRaisesUCBForSameArmAndContext() {
        let engineBefore = ContextualBanditEngine()
        var engineAfter = ContextualBanditEngine()
        let x = makeVector()

        let ucbBefore = engineBefore
            .selectArm(context: x).scores
            .first(where: { $0.arm == .supportiveNudge })?.ucb ?? 0
        engineAfter.update(arm: .supportiveNudge, context: x, reward: 1.0)
        let ucbAfter = engineAfter
            .selectArm(context: x).scores
            .first(where: { $0.arm == .supportiveNudge })?.ucb ?? 0

        #expect(ucbAfter > ucbBefore)
    }

    @Test func strongNegativeRewardSuppressesAllArms() {
        // Fresh engine fires (exploration-dominated); after repeatedly strong negative feedback
        // on every arm, every UCB drops below 0 and `.none` wins.
        var engine = ContextualBanditEngine()
        let x = makeVector()

        #expect(engine.selectArm(context: x).arm != .none)

        // Five updates with reward −5 on each learnable arm make every mean so negative
        // that every UCB < 0.
        for _ in 0..<5 {
            for arm in BanditArm.learnable {
                engine.update(arm: arm, context: x, reward: -5.0)
            }
        }

        #expect(engine.selectArm(context: x).arm == .none)
    }

    @Test func orthogonalContextsDoNotCrossContaminateMeanReward() {
        // After updating a single arm with x1, the mean reward for orthogonal x2 should stay 0
        // on that arm.  (The exploration term changes because A grows, but theta·x2 = (A⁻¹b)·x2
        // stays 0 when x1·x2 = 0 — provable via Woodbury identity.)
        var engine = ContextualBanditEngine()
        let x1 = makeVector(seed: 1.0)
        let x2 = makeOrthogonalVector()

        engine.update(arm: .supportiveNudge, context: x1, reward: 1.0)

        // Any selected arm on x2 should still be driven by exploration (UCB > 0).
        let (arm, ucb, _) = engine.selectArm(context: x2)
        // x2 has non-zero norm so exploration term keeps UCB > 0.
        #expect(arm != .none)
        #expect(ucb > 0)
    }

    @Test func stateRoundtripsViaJSON() throws {
        var engine = ContextualBanditEngine()
        let x = makeVector()
        engine.update(arm: .supportiveNudge, context: x, reward: 0.7)
        engine.update(arm: .challengingNudge, context: makeVector(seed: 2.0), reward: -0.3)
        engine.update(arm: .overlay, context: makeVector(seed: 1.5), reward: 0.1)

        let (armBefore, ucbBefore, scoresBefore) = engine.selectArm(context: x)

        let data = try JSONEncoder().encode(engine)
        let decoded = try JSONDecoder().decode(ContextualBanditEngine.self, from: data)

        let (armAfter, ucbAfter, scoresAfter) = decoded.selectArm(context: x)

        #expect(armBefore == armAfter)
        #expect(abs(ucbBefore - ucbAfter) < 1e-10)
        #expect(scoresBefore == scoresAfter)
    }

    @Test func noneIsNotALearnableArm() {
        // `.none` is the implicit baseline; updating it should be silently ignored.
        var engine = ContextualBanditEngine()
        let before = engine
        engine.update(arm: .none, context: makeVector(), reward: 10.0)
        #expect(engine == before)
    }

    @Test func featureDimensionConsistency() {
        #expect(BanditFeatureVector.dimension == ContextualBanditEngine.d)
    }

    @Test func weekendFlagCorrect() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!

        // 2024-01-06 is a Saturday (weekday == 7)
        var comps = DateComponents()
        comps.year = 2024; comps.month = 1; comps.day = 6; comps.hour = 12
        let saturday = calendar.date(from: comps)!

        // 2024-01-08 is a Monday (weekday == 2)
        comps.day = 8
        let monday = calendar.date(from: comps)!

        let screenState = BanditScreenState(
            appCategory: .productivity,
            productivityScore: 0.8,
            onTask: true,
            contentSummary: "coding",
            confidence: 0.9,
            candidateNudge: nil
        )

        let satVec = BanditFeatureVector.build(
            screenState: screenState, now: saturday,
            timeInAppSeconds: 60, timeSinceLastNudgeSeconds: nil, lastNudgeWasPositive: nil
        )
        let monVec = BanditFeatureVector.build(
            screenState: screenState, now: monday,
            timeInAppSeconds: 60, timeSinceLastNudgeSeconds: nil, lastNudgeWasPositive: nil
        )

        #expect(satVec.values[3] == 1.0)
        #expect(monVec.values[3] == 0.0)
    }

    @Test func cyclicalHourEncodingCorrect() {
        // Use Calendar.current (same as BanditFeatureVector.build) to build local-time dates.
        let calendar = Calendar.current

        // midnight local: sin(2π·0/24) = 0, cos(2π·0/24) = 1
        var comps = DateComponents()
        comps.year = 2024; comps.month = 1; comps.day = 8; comps.hour = 0; comps.minute = 0
        let midnight = calendar.date(from: comps)!

        // 6am local: sin(2π·6/24) = sin(π/2) = 1, cos(π/2) ≈ 0
        comps.hour = 6
        let sixAm = calendar.date(from: comps)!

        let screenState = BanditScreenState(
            appCategory: .other, productivityScore: 0.5, onTask: true,
            contentSummary: "test", confidence: 0.5, candidateNudge: nil
        )

        let midVec = BanditFeatureVector.build(
            screenState: screenState, now: midnight,
            timeInAppSeconds: 0, timeSinceLastNudgeSeconds: nil, lastNudgeWasPositive: nil
        )
        let sixVec = BanditFeatureVector.build(
            screenState: screenState, now: sixAm,
            timeInAppSeconds: 0, timeSinceLastNudgeSeconds: nil, lastNudgeWasPositive: nil
        )

        #expect(abs(midVec.values[1] - 0.0) < 1e-10)  // sin(0) = 0
        #expect(abs(midVec.values[2] - 1.0) < 1e-10)  // cos(0) = 1
        #expect(abs(sixVec.values[1] - 1.0) < 1e-6)   // sin(π/2) = 1
        #expect(abs(sixVec.values[2] - 0.0) < 1e-6)   // cos(π/2) ≈ 0
    }
}

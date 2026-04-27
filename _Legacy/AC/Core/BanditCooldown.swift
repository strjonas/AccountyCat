//
//  BanditCooldown.swift
//  AC
//

import Foundation

// MARK: - BanditCooldown

/// Minimal anti-spam for `BanditMonitoringAlgorithm`.
///
/// The bandit's policy should do the heavy lifting — filter too aggressively and the
/// algorithm can't learn. This cooldown only prevents pathological nudge-loops:
///
/// - A per-context `stabilityWindow` gives the user time to land in an app before the
///   bandit even looks.
/// - Once an intervention has fired in a context, a `minInterInterventionInterval` keeps
///   the bandit from firing again immediately.
///
/// Both values are conservative by design: they let the bandit explore.
struct BanditCooldown: Sendable {

    /// Seconds the user must dwell in a new context before the bandit evaluates.
    let stabilityWindow: TimeInterval
    /// Minimum seconds between two interventions in the same context.
    let minInterInterventionInterval: TimeInterval

    init(
        stabilityWindow: TimeInterval = 20,
        minInterInterventionInterval: TimeInterval = 60
    ) {
        self.stabilityWindow = stabilityWindow
        self.minInterInterventionInterval = minInterInterventionInterval
    }

    // MARK: - Queries

    /// Returns whether the bandit should evaluate the current context.
    func shouldEvaluate(
        contextKey: String,
        enteredContextAt: Date?,
        lastInterventionInContextAt: Date?,
        now: Date
    ) -> Bool {
        guard let enteredContextAt else { return false }
        guard now.timeIntervalSince(enteredContextAt) >= stabilityWindow else { return false }
        if let last = lastInterventionInContextAt,
           now.timeIntervalSince(last) < minInterInterventionInterval {
            return false
        }
        _ = contextKey
        return true
    }

    /// Returns whether an intervention may fire right now (cooldown not active).
    func mayIntervene(
        contextKey: String,
        lastInterventionInContextAt: Date?,
        now: Date
    ) -> Bool {
        guard let last = lastInterventionInContextAt else { return true }
        _ = contextKey
        return now.timeIntervalSince(last) >= minInterInterventionInterval
    }
}

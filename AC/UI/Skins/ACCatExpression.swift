//
//  ACCatExpression.swift
//  AC
//
//  Expression states for the cat portrait. One per shipped pose:
//  neutral (default), blink (idle wink), happy (celebrate / session win),
//  sleep (paused / idle), concerned (overlay / hard escalation).
//
//  Decoupled from CompanionMood so the UI can swap to expressions the
//  monitoring loop does not explicitly emit (e.g. one-shot celebrate).
//

import Foundation

enum ACCatExpression: String, Codable, CaseIterable, Sendable {
    case neutral
    case blink
    case happy
    case sleep
    case concerned
}

extension ACCatExpression {
    var displayName: String {
        switch self {
        case .neutral:   return "neutral"
        case .blink:     return "blink"
        case .happy:     return "happy"
        case .sleep:     return "sleep"
        case .concerned: return "concerned"
        }
    }
}

// MARK: - CompanionMood mapping

extension CompanionMood {
    var catExpression: ACCatExpression {
        switch self {
        case .setup:         return .neutral
        case .idle:          return .sleep
        case .watching:      return .neutral
        case .nudging:       return .neutral
        case .escalated:     return .concerned
        case .escalatedHard: return .concerned
        case .paused:        return .sleep
        }
    }
}

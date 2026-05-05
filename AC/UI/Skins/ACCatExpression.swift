//
//  ACCatExpression.swift
//  AC
//
//  Expression states for the cat skin renderer. Decoupled from CompanionMood
//  so the UI can show intermediate expressions (e.g. "celebrate") that the
//  monitoring loop does not explicitly emit.
//

import Foundation

enum ACCatExpression: String, Codable, CaseIterable, Sendable {
    case neutral
    case happy
    case sleep
    case alert
    case drift
    case celebrate
    case concern
}

extension ACCatExpression {
    var displayName: String {
        switch self {
        case .neutral:   return "neutral"
        case .happy:     return "happy"
        case .sleep:     return "sleep"
        case .alert:     return "alert"
        case .drift:     return "drift"
        case .celebrate: return "celebrate"
        case .concern:   return "concern"
        }
    }
}

// MARK: - CompanionMood mapping

extension CompanionMood {
    var catExpression: ACCatExpression {
        switch self {
        case .setup:         return .neutral
        case .idle:          return .sleep
        case .watching:      return .alert
        case .nudging:       return .drift
        case .escalated:     return .concern
        case .escalatedHard: return .concern
        case .paused:        return .sleep
        }
    }
}

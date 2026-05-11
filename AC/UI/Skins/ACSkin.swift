//
//  ACSkin.swift
//  AC
//
//  Visual skin system for the companion cat. Character controls personality
//  and accent palette; skin controls how the cat is drawn. Skin is fully
//  decoupled from character: any character × any skin is supported.
//

import Foundation

enum ACSkin: String, Codable, CaseIterable, Sendable {
    case mono
    case bubble
    case plush
}

extension ACSkin {
    var displayName: String {
        switch self {
        case .mono:   return "Mono"
        case .bubble: return "Bubble"
        case .plush:  return "Plush"
        }
    }

    var blurb: String {
        switch self {
        case .mono:   return "Calm & minimal"
        case .bubble: return "Warm & refined"
        case .plush:  return "Expressive & cute"
        }
    }
}

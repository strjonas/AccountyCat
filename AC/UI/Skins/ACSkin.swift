//
//  ACSkin.swift
//  AC
//
//  Visual skin system for the companion cat. Character controls personality
//  and accent palette; skin controls how the cat is drawn.
//

import Foundation

enum ACSkin: String, Codable, CaseIterable, Sendable {
    case pixel
    case bubble
    case liquid
}

extension ACSkin {
    var displayName: String {
        switch self {
        case .pixel:  return "Pixel"
        case .bubble: return "Bubble"
        case .liquid: return "Liquid"
        }
    }

    var blurb: String {
        switch self {
        case .pixel:  return "Chunky retro grid"
        case .bubble: return "Solid sticker, rounded"
        case .liquid: return "Glass blob"
        }
    }
}

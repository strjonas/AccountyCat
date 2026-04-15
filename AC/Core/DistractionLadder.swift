//
//  DistractionLadder.swift
//  AC
//
//  Created by Codex on 12.04.26.
//

import Foundation

enum DistractionSignal: Equatable, Sendable {
    case none
    case nudgeEligible(sequence: Int)
    case overlayEligible(sequence: Int)
}

// MARK: - DistractionLadder

struct DistractionLadder: Sendable {
    private(set) var metadata = DistractionMetadata()

    let stabilityWindow: TimeInterval = 20
    let firstFollowUp: TimeInterval = 5 * 60
    let secondFollowUp: TimeInterval = 10 * 60
    let thirdFollowUp: TimeInterval = 20 * 60

    init(metadata: DistractionMetadata = DistractionMetadata()) {
        self.metadata = metadata
    }

    mutating func noteContext(_ key: String?, at now: Date) -> Bool {
        guard metadata.contextKey != key else {
            return false
        }

        metadata = DistractionMetadata(
            contextKey: key,
            stableSince: key == nil ? nil : now,
            lastAssessment: nil,
            consecutiveDistractedCount: 0,
            nextEvaluationAt: nil
        )
        return true
    }

    mutating func reset() {
        metadata = DistractionMetadata()
    }

    func shouldEvaluate(at now: Date) -> Bool {
        guard metadata.contextKey != nil else {
            return false
        }

        if metadata.lastAssessment == .distracted {
            guard let nextEvaluationAt = metadata.nextEvaluationAt else {
                return false
            }
            return now >= nextEvaluationAt
        }

        guard metadata.lastAssessment == nil, let stableSince = metadata.stableSince else {
            return false
        }

        return now.timeIntervalSince(stableSince) >= stabilityWindow
    }

    /// Records a model assessment and returns the appropriate signal.
    /// The model is the brain: the ladder only enforces spam-prevention timing.
    /// - First distracted → nudgeEligible immediately (model decides if it nudges)
    /// - Repeated → escalating follow-up delays, eventual overlayEligible
    mutating func record(assessment: ModelAssessment, at now: Date) -> DistractionSignal {
        switch assessment {
        case .focused, .unclear:
            metadata.lastAssessment = assessment
            metadata.consecutiveDistractedCount = 0
            metadata.nextEvaluationAt = nil
            return .none

        case .distracted:
            metadata.lastAssessment = .distracted
            metadata.consecutiveDistractedCount += 1

            switch metadata.consecutiveDistractedCount {
            case 1:
                // First hit: give the model power to nudge right away
                metadata.nextEvaluationAt = now.addingTimeInterval(firstFollowUp)
                return .nudgeEligible(sequence: 1)
            case 2:
                metadata.nextEvaluationAt = now.addingTimeInterval(secondFollowUp)
                return .nudgeEligible(sequence: 2)
            case 3:
                metadata.nextEvaluationAt = now.addingTimeInterval(thirdFollowUp)
                return .nudgeEligible(sequence: 3)
            default:
                metadata.nextEvaluationAt = now.addingTimeInterval(thirdFollowUp)
                return .overlayEligible(sequence: metadata.consecutiveDistractedCount)
            }
        }
    }
}

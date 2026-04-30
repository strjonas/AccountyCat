//
//  MonitoringModels.swift
//  AC
//
//  Created by Codex on 15.04.26.
//

import Foundation

enum MonitoringSelectionMode: String, Codable, CaseIterable, Sendable {
    case fixed
}

enum MonitoringCadenceMode: String, Codable, CaseIterable, Hashable, Sendable {
    case sharp
    case balanced
    case gentle

    var displayName: String {
        switch self {
        case .sharp: return "Sharp"
        case .balanced: return "Balanced"
        case .gentle: return "Gentle"
        }
    }

    var description: String {
        switch self {
        case .sharp:
            return "Checks sooner after context changes. Best when fast drift prevention matters."
        case .balanced:
            return "Default timing with conservative call gates. Good all-day companion behavior."
        case .gentle:
            return "Checks less often and gives you more room before AC steps in."
        }
    }

    var byokCostHint: String {
        switch self {
        case .sharp: return "Higher usage"
        case .balanced: return "Moderate usage"
        case .gentle: return "Lower usage"
        }
    }

    var stableContextDelay: TimeInterval {
        switch self {
        case .sharp: return 6
        case .balanced: return 30
        case .gentle: return 60
        }
    }

    var focusedFollowUp: TimeInterval {
        switch self {
        case .sharp: return 2 * 60
        case .balanced: return 5 * 60
        case .gentle: return 10 * 60
        }
    }

    var unclearFollowUp: TimeInterval {
        switch self {
        case .sharp: return 90
        case .balanced: return 2 * 60
        case .gentle: return 4 * 60
        }
    }

    var distractedFollowUp: TimeInterval {
        switch self {
        case .sharp: return 30
        case .balanced: return 45
        case .gentle: return 90
        }
    }

    var focusedDecisionCacheTTL: TimeInterval {
        focusedFollowUp * 3
    }
}

struct MonitoringConfiguration: Codable, Hashable, Sendable {
    // Historical ids retained only so old state files migrate onto the active algorithm.
    nonisolated static let deprecatedLegacyLLMAlgorithmID = "legacy_focus_v1"
    nonisolated static let deprecatedLLMFocusAlgorithmID = "llm_focus_v1"
    nonisolated static let deprecatedLLMMonitorAlgorithmID = "llm_policy_v1"
    nonisolated static let legacyLLMFocusAlgorithmID = "llm_focus_legacy_v1"
    nonisolated static let currentLLMMonitorAlgorithmID = "llm_monitor_v1"
    nonisolated static let defaultAlgorithmID = currentLLMMonitorAlgorithmID
    nonisolated static let defaultPromptProfileID = "focus_default_v2"
    nonisolated static let defaultPipelineProfileID = "vision_split_default"
    nonisolated static let defaultOnlineVisionPipelineProfileID = "online_single_round_vision"
    nonisolated static let defaultOnlineTextPipelineProfileID = "online_single_round_text"
    nonisolated static let defaultRuntimeProfileID = "gemma_balanced_v1"
    nonisolated static let defaultInferenceBackend: MonitoringInferenceBackend = .local
    nonisolated static let defaultOnlineModelIdentifier = "google/gemma-4-31b-it"
    nonisolated static let banditAlgorithmID = "bandit_focus_v1"

    var algorithmID: String
    var promptProfileID: String
    var pipelineProfileID: String
    var runtimeProfileID: String
    var inferenceBackend: MonitoringInferenceBackend
    var selectionMode: MonitoringSelectionMode
    var cadenceMode: MonitoringCadenceMode
    var experimentArmOverride: String?
    var modelOverride: String?
    var onlineModelIdentifier: String
    var thinkingEnabled: Bool

    enum CodingKeys: String, CodingKey {
        case algorithmID
        case promptProfileID
        case pipelineProfileID
        case runtimeProfileID
        case inferenceBackend
        case selectionMode
        case cadenceMode
        case experimentArmOverride
        case modelOverride
        case onlineModelIdentifier
        case thinkingEnabled
    }

    init(
        algorithmID: String = Self.defaultAlgorithmID,
        promptProfileID: String = Self.defaultPromptProfileID,
        pipelineProfileID: String = Self.defaultPipelineProfileID,
        runtimeProfileID: String = Self.defaultRuntimeProfileID,
        inferenceBackend: MonitoringInferenceBackend = Self.defaultInferenceBackend,
        selectionMode: MonitoringSelectionMode = .fixed,
        cadenceMode: MonitoringCadenceMode = .balanced,
        experimentArmOverride: String? = nil,
        modelOverride: String? = nil,
        onlineModelIdentifier: String = Self.defaultOnlineModelIdentifier,
        thinkingEnabled: Bool = false
    ) {
        self.algorithmID = Self.normalizedAlgorithmID(algorithmID)
        self.promptProfileID = promptProfileID
        self.pipelineProfileID = pipelineProfileID
        self.runtimeProfileID = runtimeProfileID
        self.inferenceBackend = inferenceBackend
        self.selectionMode = selectionMode
        self.cadenceMode = cadenceMode
        self.experimentArmOverride = experimentArmOverride
        self.modelOverride = modelOverride
        self.onlineModelIdentifier = Self.normalizedOnlineModelIdentifier(onlineModelIdentifier)
        self.thinkingEnabled = thinkingEnabled
    }

    nonisolated static func normalizedAlgorithmID(_ id: String) -> String {
        switch id {
        case deprecatedLegacyLLMAlgorithmID,
             deprecatedLLMFocusAlgorithmID,
             deprecatedLLMMonitorAlgorithmID,
             legacyLLMFocusAlgorithmID,
             banditAlgorithmID:
            return currentLLMMonitorAlgorithmID
        default:
            return id
        }
    }

    nonisolated static func shouldAutoMigrateDeprecatedDefaultAlgorithm(_ id: String) -> Bool {
        normalizedAlgorithmID(id) == currentLLMMonitorAlgorithmID && id != currentLLMMonitorAlgorithmID
    }

    var experimentArm: String {
        experimentArmOverride ?? [
            selectionMode.rawValue,
            Self.normalizedAlgorithmID(algorithmID),
            inferenceBackend.rawValue,
            cadenceMode.rawValue,
            pipelineProfileID,
            runtimeProfileID,
            promptProfileID,
        ].joined(separator: ":")
    }

    nonisolated var usesOnlineInference: Bool {
        inferenceBackend == .openRouter
    }

    nonisolated static func normalizedOnlineModelIdentifier(_ rawValue: String) -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return defaultOnlineModelIdentifier
        }

        if let url = URL(string: trimmed),
           let host = url.host?.lowercased(),
           host.contains("openrouter.ai") {
            let parts = url.pathComponents.filter { $0 != "/" }
            if parts.count >= 2, parts[0] != "api", parts[0] != "docs" {
                return normalizedOnlineModelIdentifier("\(parts[0])/\(parts[1])")
            }
        }

        if trimmed.hasSuffix(":free") {
            return String(trimmed.dropLast(5))
        }

        return trimmed
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        algorithmID = Self.normalizedAlgorithmID(
            try c.decodeIfPresent(String.self, forKey: .algorithmID) ?? Self.defaultAlgorithmID
        )
        promptProfileID = try c.decodeIfPresent(String.self, forKey: .promptProfileID) ?? Self.defaultPromptProfileID
        pipelineProfileID = try c.decodeIfPresent(String.self, forKey: .pipelineProfileID) ?? Self.defaultPipelineProfileID
        runtimeProfileID = try c.decodeIfPresent(String.self, forKey: .runtimeProfileID) ?? Self.defaultRuntimeProfileID
        inferenceBackend = try c.decodeIfPresent(MonitoringInferenceBackend.self, forKey: .inferenceBackend) ?? Self.defaultInferenceBackend
        selectionMode = try c.decodeIfPresent(MonitoringSelectionMode.self, forKey: .selectionMode) ?? .fixed
        cadenceMode = try c.decodeIfPresent(MonitoringCadenceMode.self, forKey: .cadenceMode) ?? .balanced
        experimentArmOverride = try c.decodeIfPresent(String.self, forKey: .experimentArmOverride)
        modelOverride = try c.decodeIfPresent(String.self, forKey: .modelOverride)
        onlineModelIdentifier = Self.normalizedOnlineModelIdentifier(
            try c.decodeIfPresent(String.self, forKey: .onlineModelIdentifier) ?? Self.defaultOnlineModelIdentifier
        )
        thinkingEnabled = try c.decodeIfPresent(Bool.self, forKey: .thinkingEnabled) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Self.normalizedAlgorithmID(algorithmID), forKey: .algorithmID)
        try c.encode(promptProfileID, forKey: .promptProfileID)
        try c.encode(pipelineProfileID, forKey: .pipelineProfileID)
        try c.encode(runtimeProfileID, forKey: .runtimeProfileID)
        try c.encode(inferenceBackend, forKey: .inferenceBackend)
        try c.encode(selectionMode, forKey: .selectionMode)
        try c.encode(cadenceMode, forKey: .cadenceMode)
        try c.encodeIfPresent(experimentArmOverride, forKey: .experimentArmOverride)
        try c.encodeIfPresent(modelOverride, forKey: .modelOverride)
        try c.encode(onlineModelIdentifier, forKey: .onlineModelIdentifier)
        try c.encode(thinkingEnabled, forKey: .thinkingEnabled)
    }
}

struct MonitoringAlgorithmDescriptor: Hashable, Sendable {
    var id: String
    var version: String
    var displayName: String
    var summary: String
}

struct MonitoringPromptProfileDescriptor: Hashable, Sendable {
    var id: String
    var version: String
    var displayName: String
    var summary: String
}

struct MonitoringPipelineProfileDescriptor: Hashable, Sendable {
    var id: String
    var displayName: String
    var summary: String
    var requiresScreenshot: Bool
}

struct MonitoringRuntimeProfileDescriptor: Hashable, Sendable {
    var id: String
    var displayName: String
    var summary: String
    var modelIdentifier: String
}

struct MonitoringExecutionMetadata: Hashable, Sendable {
    var algorithmID: String
    var algorithmVersion: String
    var promptProfileID: String
    var pipelineProfileID: String?
    var runtimeProfileID: String?
    var experimentArm: String?
}

struct LLMFocusAlgorithmState: Codable, Sendable, Equatable {
    var distraction = DistractionMetadata()
    var lastVisualCheckByContext: [String: Date] = [:]
}

enum AutoAllowOutcome: String, Codable, Sendable, Equatable {
    case expiredClean = "expired_clean"
    case revokedByDistracted = "revoked_by_distracted"
    case revokedByUser = "revoked_by_user"
}

enum SafelistPromotionAttemptOutcome: String, Codable, Sendable, Equatable {
    case approved
    case denied
    case invalid
    case error
    case ineligible
}

struct FocusedObservationStat: Codable, Sendable, Equatable {
    var contextFingerprint: String
    var appName: String
    var bundleIdentifier: String?
    var titleSignature: String?
    var sampleWindowTitles: [String] = []
    var focusedCount: Int = 0
    var distractedCount: Int = 0
    var firstSeenAt: Date
    var lastSeenAt: Date
    var distinctDayKeys: [String] = []
    var promotionAttemptedAt: Date?
    var lastAutoAllowRuleID: String?
    var previousAutoAllowOutcome: AutoAllowOutcome?
    var lastPromotionOutcome: SafelistPromotionAttemptOutcome?
    var lastPromotionReason: String?
    var lastPromotionCheckedAt: Date?

    var distinctDayCount: Int { distinctDayKeys.count }

    init(
        contextFingerprint: String,
        appName: String,
        bundleIdentifier: String? = nil,
        titleSignature: String? = nil,
        sampleWindowTitles: [String] = [],
        focusedCount: Int = 0,
        distractedCount: Int = 0,
        firstSeenAt: Date,
        lastSeenAt: Date,
        distinctDayKeys: [String] = [],
        promotionAttemptedAt: Date? = nil,
        lastAutoAllowRuleID: String? = nil,
        previousAutoAllowOutcome: AutoAllowOutcome? = nil,
        lastPromotionOutcome: SafelistPromotionAttemptOutcome? = nil,
        lastPromotionReason: String? = nil,
        lastPromotionCheckedAt: Date? = nil
    ) {
        self.contextFingerprint = contextFingerprint
        self.appName = appName
        self.bundleIdentifier = bundleIdentifier
        self.titleSignature = titleSignature
        self.sampleWindowTitles = sampleWindowTitles
        self.focusedCount = focusedCount
        self.distractedCount = distractedCount
        self.firstSeenAt = firstSeenAt
        self.lastSeenAt = lastSeenAt
        self.distinctDayKeys = distinctDayKeys
        self.promotionAttemptedAt = promotionAttemptedAt
        self.lastAutoAllowRuleID = lastAutoAllowRuleID
        self.previousAutoAllowOutcome = previousAutoAllowOutcome
        self.lastPromotionOutcome = lastPromotionOutcome
        self.lastPromotionReason = lastPromotionReason
        self.lastPromotionCheckedAt = lastPromotionCheckedAt
    }
}

struct CachedDecision: Codable, Sendable, Equatable {
    var assessment: MonitoringVerdict
    var decidedAt: Date
    var contextKey: String
}

struct FocusSignalState: Codable, Sendable, Equatable {
    var driftEMA: Double = 0
    var lastUpdatedAt: Date?
    var lastFocusedBlockStartedAt: Date?
    var lastCelebrationAt: Date?

    var clampedDrift: Double {
        min(max(driftEMA, 0), 1)
    }

    mutating func record(
        assessment: ModelAssessment,
        confidence: Double?,
        at now: Date
    ) {
        let clampedConfidence = min(max(confidence ?? 0.5, 0), 1)
        let evidence: Double
        switch assessment {
        case .focused:
            evidence = 1 - clampedConfidence
            if lastFocusedBlockStartedAt == nil {
                lastFocusedBlockStartedAt = now
            }
        case .unclear:
            evidence = 0.45
        case .distracted:
            evidence = clampedConfidence
            lastFocusedBlockStartedAt = nil
        }

        let alpha = 0.35
        driftEMA = lastUpdatedAt == nil
            ? evidence
            : ((alpha * evidence) + ((1 - alpha) * driftEMA))
        driftEMA = min(max(driftEMA, 0), 1)
        lastUpdatedAt = now
    }

    mutating func resetFlow(at now: Date? = nil) {
        driftEMA = 0
        lastUpdatedAt = now
        lastFocusedBlockStartedAt = now
    }
}

struct LLMPolicyAlgorithmState: Codable, Sendable, Equatable {
    var distraction = DistractionMetadata()
    var currentContextKey: String?
    var currentContextEnteredAt: Date?
    var lastInterventionAt: Date?
    var lastNudgeAt: Date?
    var lastOverlayAt: Date?
    var recentNudgeMessages: [String] = []
    var activeAppeal: MonitoringAppealSession?
    var focusedObservations: [String: FocusedObservationStat] = [:]
    var decisionCacheByContext: [String: CachedDecision] = [:]
    var focusSignal = FocusSignalState()

    enum CodingKeys: String, CodingKey {
        case distraction
        case currentContextKey
        case currentContextEnteredAt
        case lastInterventionAt
        case lastNudgeAt
        case lastOverlayAt
        case recentNudgeMessages
        case activeAppeal
        case focusedObservations
        case decisionCacheByContext
        case focusSignal
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        distraction = try c.decodeIfPresent(DistractionMetadata.self, forKey: .distraction) ?? DistractionMetadata()
        currentContextKey = try c.decodeIfPresent(String.self, forKey: .currentContextKey)
        currentContextEnteredAt = try c.decodeIfPresent(Date.self, forKey: .currentContextEnteredAt)
        lastInterventionAt = try c.decodeIfPresent(Date.self, forKey: .lastInterventionAt)
        lastNudgeAt = try c.decodeIfPresent(Date.self, forKey: .lastNudgeAt)
        lastOverlayAt = try c.decodeIfPresent(Date.self, forKey: .lastOverlayAt)
        recentNudgeMessages = try c.decodeIfPresent([String].self, forKey: .recentNudgeMessages) ?? []
        activeAppeal = try c.decodeIfPresent(MonitoringAppealSession.self, forKey: .activeAppeal)
        focusedObservations = try c.decodeIfPresent([String: FocusedObservationStat].self, forKey: .focusedObservations) ?? [:]
        decisionCacheByContext = try c.decodeIfPresent([String: CachedDecision].self, forKey: .decisionCacheByContext) ?? [:]
        focusSignal = try c.decodeIfPresent(FocusSignalState.self, forKey: .focusSignal) ?? FocusSignalState()
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(distraction, forKey: .distraction)
        try c.encodeIfPresent(currentContextKey, forKey: .currentContextKey)
        try c.encodeIfPresent(currentContextEnteredAt, forKey: .currentContextEnteredAt)
        try c.encodeIfPresent(lastInterventionAt, forKey: .lastInterventionAt)
        try c.encodeIfPresent(lastNudgeAt, forKey: .lastNudgeAt)
        try c.encodeIfPresent(lastOverlayAt, forKey: .lastOverlayAt)
        try c.encode(recentNudgeMessages, forKey: .recentNudgeMessages)
        try c.encodeIfPresent(activeAppeal, forKey: .activeAppeal)
        try c.encode(focusedObservations, forKey: .focusedObservations)
        try c.encode(decisionCacheByContext, forKey: .decisionCacheByContext)
        try c.encode(focusSignal, forKey: .focusSignal)
    }
}

struct AlgorithmStateEnvelope: Codable, Sendable, Equatable {
    // The current build persists only the active LLM monitor state.
    // Decoder shims below still read older legacy/bandit keys.
    var llmPolicy = LLMPolicyAlgorithmState()

    // MARK: - Codable (with migration from older algorithm slices)

    enum CodingKeys: String, CodingKey {
        case llmFocus
        case legacyFocus // read-only migration key for state.json files written before the rename
        case llmPolicy
        case banditFocus
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        llmPolicy = try c.decodeIfPresent(LLMPolicyAlgorithmState.self, forKey: .llmPolicy)
               ?? LLMPolicyAlgorithmState()
        let legacyFocus = try c.decodeIfPresent(LLMFocusAlgorithmState.self, forKey: .llmFocus)
               ?? c.decodeIfPresent(LLMFocusAlgorithmState.self, forKey: .legacyFocus)
               ?? LLMFocusAlgorithmState()
        if llmPolicy.distraction == DistractionMetadata(),
           legacyFocus.distraction != DistractionMetadata() {
            llmPolicy.distraction = legacyFocus.distraction
        }
        _ = try? c.decodeIfPresent(EmptyCodableState.self, forKey: .banditFocus)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(llmPolicy, forKey: .llmPolicy)
    }
}

private struct EmptyCodableState: Codable {}

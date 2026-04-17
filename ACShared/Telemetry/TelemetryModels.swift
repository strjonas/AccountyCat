//
//  TelemetryModels.swift
//  AC
//
//  Created by Codex on 13.04.26.
//

import Foundation

nonisolated enum TelemetryEventKind: String, Codable, CaseIterable, Sendable {
    case sessionStarted = "session_started"
    case observation = "observation"
    case evaluationRequested = "evaluation_requested"
    case modelInputSaved = "model_input_saved"
    case modelOutputReceived = "model_output_received"
    case modelOutputParsed = "model_output_parsed"
    case policyDecided = "policy_decided"
    case actionExecuted = "action_executed"
    case userReaction = "user_reaction"
    case annotationSaved = "annotation_saved"
    case sessionEnded = "session_ended"
    case failure
}

nonisolated enum ArtifactKind: String, Codable, Sendable {
    case screenshotOriginal = "screenshot_original"
    case screenshotThumbnail = "screenshot_thumbnail"
    case promptTemplate = "prompt_template"
    case promptPayload = "prompt_payload"
    case renderedPrompt = "rendered_prompt"
    case rawStdout = "raw_stdout"
    case rawStderr = "raw_stderr"
    case exportManifest = "export_manifest"
}

nonisolated struct ArtifactRef: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var kind: ArtifactKind
    var relativePath: String
    var sha256: String?
    var byteCount: Int
    var width: Int?
    var height: Int?
    var createdAt: Date
}

nonisolated struct TelemetrySessionDescriptor: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var startedAt: Date
    var endedAt: Date?
    var reason: String
    var retentionDays: Int
    var eventsRelativePath: String
    var artifactsRelativePath: String
}

nonisolated struct TelemetryEvent: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var kind: TelemetryEventKind
    var timestamp: Date
    var sessionID: String
    var episodeID: String?
    var episode: EpisodeRecord?
    var session: SessionLifecycleRecord?
    var observation: ObservationRecord?
    var evaluation: EvaluationRequestRecord?
    var modelInput: ModelInputRecord?
    var modelOutput: ModelOutputRecord?
    var parsedOutput: ModelOutputParsedRecord?
    var policy: PolicyDecisionRecord?
    var action: ActionExecutionRecord?
    var reaction: UserReactionRecord?
    var annotation: EpisodeAnnotation?
    var failure: FailureRecord?
}

nonisolated enum EpisodeStatus: String, Codable, Sendable {
    case active
    case ended
}

nonisolated enum EpisodeEndReason: String, Codable, Sendable {
    case contextChange = "context_change"
    case idleReset = "idle_reset"
    case paused
    case sessionInactive = "session_inactive"
    case rescueReturn = "rescue_return"
    case sessionEnded = "session_ended"
}

nonisolated struct EpisodeRecord: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var sessionID: String
    var contextKey: String
    var appName: String
    var windowTitle: String?
    var startedAt: Date
    var endedAt: Date?
    var status: EpisodeStatus
    var endReason: EpisodeEndReason?
    var pinned: Bool
}

nonisolated enum EpisodeAnnotationLabel: String, Codable, CaseIterable, Sendable {
    case goodSilence = "good_silence"
    case goodNudge = "good_nudge"
    case badNudge = "bad_nudge"
    case shouldHaveNudged = "should_have_nudged"
    case tooEarly = "too_early"
    case tooLate = "too_late"
    case interruptedFlow = "interrupted_flow"
    case wrongTone = "wrong_tone"
    case escalationCorrect = "escalation_correct"
    case escalationWrong = "escalation_wrong"
}

nonisolated enum AnnotationSource: String, Codable, Sendable {
    case human
    case weak
    case synthetic
}

nonisolated struct EpisodeAnnotation: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var sessionID: String
    var episodeID: String
    var labels: [EpisodeAnnotationLabel]
    var note: String
    var pinned: Bool
    var source: AnnotationSource
    var createdAt: Date
}

nonisolated enum ObservationTransition: String, Codable, Sendable {
    case started
    case continuedObserving = "continued_observing"
    case ended
}

nonisolated struct ObservationRecord: Codable, Hashable, Sendable {
    var context: TelemetryContextRecord
    var heuristics: TelemetryHeuristicSnapshot
    var distraction: TelemetryDistractionState
    var visualCheckReason: String?
    var shouldEvaluateNow: Bool
    var transition: ObservationTransition
    var endReason: EpisodeEndReason?
}

nonisolated struct TelemetryContextRecord: Codable, Hashable, Sendable {
    var bundleIdentifier: String?
    var appName: String
    var windowTitle: String?
    var contextKey: String
    var idleSeconds: TimeInterval
    var recentSwitches: [TelemetryAppSwitchRecord]
    var perAppDurations: [TelemetryUsageRecord]
    var recentActions: [TelemetryActionSummary]
    var timestamp: Date
}

nonisolated struct TelemetryAppSwitchRecord: Codable, Hashable, Sendable {
    var fromAppName: String?
    var toAppName: String
    var toWindowTitle: String?
    var timestamp: Date
}

nonisolated struct TelemetryUsageRecord: Codable, Hashable, Sendable {
    var appName: String
    var seconds: TimeInterval
}

nonisolated struct TelemetryActionSummary: Codable, Hashable, Sendable {
    var kind: String
    var message: String?
    var timestamp: Date
}

nonisolated struct TelemetryHeuristicSnapshot: Codable, Hashable, Sendable {
    var clearlyProductive: Bool
    var browser: Bool
    var helpfulWindowTitle: Bool
    var periodicVisualReason: String?
}

nonisolated struct TelemetryDistractionState: Codable, Hashable, Sendable {
    var stableSince: Date?
    var lastAssessment: ModelAssessment?
    var consecutiveDistractedCount: Int
    var nextEvaluationAt: Date?
}

nonisolated struct EvaluationRequestRecord: Codable, Hashable, Sendable {
    var evaluationID: String
    var reason: String
    var promptMode: String
    var promptVersion: String
    var strategy: MonitoringExecutionMetadataRecord?
}

nonisolated struct PromptTemplateRecord: Codable, Hashable, Sendable {
    var id: String
    var version: String
    var sha256: String
}

nonisolated struct MonitoringExecutionMetadataRecord: Codable, Hashable, Sendable {
    var algorithmID: String
    var algorithmVersion: String
    var promptProfileID: String
    var pipelineProfileID: String? = nil
    var runtimeProfileID: String? = nil
    var experimentArm: String?
}

nonisolated struct ModelInputRecord: Codable, Hashable, Sendable {
    var evaluationID: String
    var goalsSummary: String
    var screenshot: ArtifactRef?
    var screenshotThumbnail: ArtifactRef?
    var promptMode: String
    var promptTemplate: PromptTemplateRecord
    var promptTemplateArtifact: ArtifactRef?
    var promptPayloadArtifact: ArtifactRef?
    var renderedPromptArtifact: ArtifactRef?
    var context: TelemetryContextRecord
    var heuristics: TelemetryHeuristicSnapshot
    var distraction: TelemetryDistractionState
}

nonisolated enum ModelAssessment: String, Codable, Sendable {
    case focused
    case distracted
    case unclear
}

nonisolated enum ModelSuggestedAction: String, Codable, Sendable {
    case none
    case nudge
    case overlay
    case abstain
}

nonisolated struct ModelOutputParsedRecord: Codable, Hashable, Sendable {
    var assessment: ModelAssessment
    var suggestedAction: ModelSuggestedAction
    var confidence: Double?
    var reasonTags: [String]
    var nudge: String?
    var abstainReason: String?
}

nonisolated struct ModelOutputRecord: Codable, Hashable, Sendable {
    var evaluationID: String
    var runtimePath: String
    var modelIdentifier: String
    var promptMode: String
    var stdoutArtifact: ArtifactRef?
    var stderrArtifact: ArtifactRef?
    var stdoutPreview: String
    var stderrPreview: String
}

nonisolated enum TelemetryCompanionActionKind: String, Codable, Sendable {
    case none
    case nudge
    case overlay
}

nonisolated struct TelemetryCompanionActionRecord: Codable, Hashable, Sendable {
    var kind: TelemetryCompanionActionKind
    var message: String?
}

nonisolated struct PolicyDecisionRecord: Codable, Hashable, Sendable {
    var evaluationID: String
    var model: ModelOutputParsedRecord
    var strategy: MonitoringExecutionMetadataRecord?
    var ladderSignal: String
    var interventionSignal: String?
    var allowIntervention: Bool
    var allowEscalation: Bool
    var blockReason: String?
    var finalAction: TelemetryCompanionActionRecord
    var distractionBefore: TelemetryDistractionState
    var distractionAfter: TelemetryDistractionState

    enum CodingKeys: String, CodingKey {
        case evaluationID
        case model
        case strategy
        case ladderSignal
        case interventionSignal
        case allowIntervention
        case allowEscalation
        case blockReason
        case finalAction
        case distractionBefore
        case distractionAfter
    }

    init(
        evaluationID: String,
        model: ModelOutputParsedRecord,
        strategy: MonitoringExecutionMetadataRecord?,
        ladderSignal: String,
        interventionSignal: String? = nil,
        allowIntervention: Bool,
        allowEscalation: Bool,
        blockReason: String?,
        finalAction: TelemetryCompanionActionRecord,
        distractionBefore: TelemetryDistractionState,
        distractionAfter: TelemetryDistractionState
    ) {
        self.evaluationID = evaluationID
        self.model = model
        self.strategy = strategy
        self.ladderSignal = ladderSignal
        self.interventionSignal = interventionSignal
        self.allowIntervention = allowIntervention
        self.allowEscalation = allowEscalation
        self.blockReason = blockReason
        self.finalAction = finalAction
        self.distractionBefore = distractionBefore
        self.distractionAfter = distractionAfter
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        evaluationID = try c.decode(String.self, forKey: .evaluationID)
        model = try c.decode(ModelOutputParsedRecord.self, forKey: .model)
        strategy = try c.decodeIfPresent(MonitoringExecutionMetadataRecord.self, forKey: .strategy)
        let decodedLadderSignal = try c.decode(String.self, forKey: .ladderSignal)
        let decodedInterventionSignal = try c.decodeIfPresent(String.self, forKey: .interventionSignal)
        if let decodedInterventionSignal {
            ladderSignal = decodedLadderSignal
            interventionSignal = decodedInterventionSignal
        } else if decodedLadderSignal.hasPrefix("bandit:") {
            ladderSignal = "none"
            interventionSignal = decodedLadderSignal
        } else {
            ladderSignal = decodedLadderSignal
            interventionSignal = nil
        }
        allowIntervention = try c.decode(Bool.self, forKey: .allowIntervention)
        allowEscalation = try c.decode(Bool.self, forKey: .allowEscalation)
        blockReason = try c.decodeIfPresent(String.self, forKey: .blockReason)
        finalAction = try c.decode(TelemetryCompanionActionRecord.self, forKey: .finalAction)
        distractionBefore = try c.decode(TelemetryDistractionState.self, forKey: .distractionBefore)
        distractionAfter = try c.decode(TelemetryDistractionState.self, forKey: .distractionAfter)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(evaluationID, forKey: .evaluationID)
        try c.encode(model, forKey: .model)
        try c.encodeIfPresent(strategy, forKey: .strategy)
        try c.encode(ladderSignal, forKey: .ladderSignal)
        try c.encodeIfPresent(interventionSignal, forKey: .interventionSignal)
        try c.encode(allowIntervention, forKey: .allowIntervention)
        try c.encode(allowEscalation, forKey: .allowEscalation)
        try c.encodeIfPresent(blockReason, forKey: .blockReason)
        try c.encode(finalAction, forKey: .finalAction)
        try c.encode(distractionBefore, forKey: .distractionBefore)
        try c.encode(distractionAfter, forKey: .distractionAfter)
    }
}

nonisolated struct ActionExecutionRecord: Codable, Hashable, Sendable {
    var evaluationID: String?
    var strategy: MonitoringExecutionMetadataRecord?
    var action: TelemetryCompanionActionRecord
    var source: String
    var succeeded: Bool
}

nonisolated enum UserReactionKind: String, Codable, Sendable {
    case overlayDismissed = "overlay_dismissed"
    case backToWorkSelected = "back_to_work_selected"
    case postNudgeAppSwitch = "post_nudge_app_switch"
    case postNudgeRescueReturn = "post_nudge_rescue_return"
    case nudgeIgnored = "nudge_ignored"
    case negativeChatFeedback = "negative_chat_feedback"
    case nudgeRatedPositive = "nudge_rated_positive"
    case nudgeRatedNegative = "nudge_rated_negative"
}

nonisolated struct UserReactionRecord: Codable, Hashable, Sendable {
    var kind: UserReactionKind
    var relatedAction: TelemetryCompanionActionRecord?
    var positive: Bool?
    var details: String?
}

nonisolated struct SessionLifecycleRecord: Codable, Hashable, Sendable {
    var reason: String
}

nonisolated struct FailureRecord: Codable, Hashable, Sendable {
    var domain: String
    var message: String
    var evaluationID: String?
}

nonisolated struct TrainingExportManifest: Codable, Hashable, Sendable {
    var version: Int
    var generatedAt: Date
    var sessionIDs: [String]
    var episodeCount: Int
    var episodes: [TrainingEpisodeExportRecord]
}

nonisolated struct TrainingEpisodeExportRecord: Codable, Hashable, Sendable {
    var sessionID: String
    var episodeID: String
    var strategy: MonitoringExecutionMetadataRecord?
    var labels: [EpisodeAnnotationLabel]
    var note: String
    var source: AnnotationSource
    var screenshot: ArtifactRef?
    var promptPayload: ArtifactRef?
    var renderedPrompt: ArtifactRef?
    var modelOutput: ModelOutputParsedRecord?
    var shortTermOutcomeLabels: [String]
    var longTermOutcomeLabels: [String]
}

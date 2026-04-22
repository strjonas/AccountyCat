//
//  LLMPolicyProfileModels.swift
//  AC
//

import Foundation

enum LLMPolicyStage: String, Codable, CaseIterable, Sendable {
    case perceptionTitle = "perception_title"
    case perceptionVision = "perception_vision"
    case decision
    case nudgeCopy = "nudge_copy"
    case appealReview = "appeal_review"
    case policyMemory = "policy_memory"
}

struct RuntimeInferenceOptions: Codable, Hashable, Sendable {
    var modelIdentifier: String
    var maxTokens: Int
    var temperature: Double
    var topP: Double
    var topK: Int
    var ctxSize: Int
    var batchSize: Int
    var ubatchSize: Int
    var timeoutSeconds: UInt64
}

struct LLMPolicyPipelineProfile: Hashable, Sendable {
    var descriptor: MonitoringPipelineProfileDescriptor
    var usesTitlePerception: Bool
    var usesVisionPerception: Bool
    var splitCopyGeneration: Bool
}

struct MonitoringRuntimeProfile: Hashable, Sendable {
    var descriptor: MonitoringRuntimeProfileDescriptor
    var optionsByStage: [LLMPolicyStage: RuntimeInferenceOptions]

    nonisolated func options(for stage: LLMPolicyStage) -> RuntimeInferenceOptions {
        optionsByStage[stage] ?? RuntimeInferenceOptions(
            modelIdentifier: descriptor.modelIdentifier,
            maxTokens: 160,
            temperature: 0.2,
            topP: 0.95,
            topK: 64,
            ctxSize: 4096,
            batchSize: 1024,
            ubatchSize: 512,
            timeoutSeconds: 45
        )
    }
}

struct MonitoringPermissionRequirements: Hashable, Sendable {
    var requiresAccessibility: Bool
    var requiresScreenRecording: Bool
}

enum LLMPolicyCatalog {
    nonisolated static let availablePipelineProfiles: [LLMPolicyPipelineProfile] =
        MonitoringPromptTuning.pipelineDefinitions.map(makePipelineProfile)

    nonisolated static let defaultPipelineProfile: LLMPolicyPipelineProfile =
        availablePipelineProfiles.first(where: { $0.descriptor.id == MonitoringConfiguration.defaultPipelineProfileID })
        ?? makePipelineProfile(from: MonitoringPromptTuning.pipelineDefinitions[0])

    nonisolated static let availableRuntimeProfiles: [MonitoringRuntimeProfile] =
        MonitoringPromptTuning.runtimeDefinitions.map(makeRuntimeProfile)

    nonisolated static let defaultRuntimeProfile: MonitoringRuntimeProfile =
        availableRuntimeProfiles.first(where: { $0.descriptor.id == MonitoringConfiguration.defaultRuntimeProfileID })
        ?? makeRuntimeProfile(from: MonitoringPromptTuning.runtimeDefinitions[0])

    nonisolated static func pipelineProfile(id: String) -> LLMPolicyPipelineProfile {
        availablePipelineProfiles.first(where: { $0.descriptor.id == id }) ?? defaultPipelineProfile
    }

    nonisolated static func runtimeProfile(id: String) -> MonitoringRuntimeProfile {
        availableRuntimeProfiles.first(where: { $0.descriptor.id == id }) ?? defaultRuntimeProfile
    }

    nonisolated static func permissionRequirements(for configuration: MonitoringConfiguration) -> MonitoringPermissionRequirements {
        switch MonitoringConfiguration.normalizedAlgorithmID(configuration.algorithmID) {
        case MonitoringConfiguration.banditAlgorithmID,
             MonitoringConfiguration.legacyLLMFocusAlgorithmID:
            return MonitoringPermissionRequirements(
                requiresAccessibility: true,
                requiresScreenRecording: true
            )
        case MonitoringConfiguration.currentLLMMonitorAlgorithmID:
            let profile = pipelineProfile(id: configuration.pipelineProfileID)
            return MonitoringPermissionRequirements(
                requiresAccessibility: true,
                requiresScreenRecording: profile.descriptor.requiresScreenshot
            )
        default:
            return MonitoringPermissionRequirements(
                requiresAccessibility: true,
                requiresScreenRecording: true
            )
        }
    }

    nonisolated private static func makePipelineProfile(
        from definition: MonitoringPipelineDefinition
    ) -> LLMPolicyPipelineProfile {
        LLMPolicyPipelineProfile(
            descriptor: MonitoringPipelineProfileDescriptor(
                id: definition.id,
                displayName: definition.displayName,
                summary: definition.summary,
                requiresScreenshot: definition.requiresScreenshot
            ),
            usesTitlePerception: definition.usesTitlePerception,
            usesVisionPerception: definition.usesVisionPerception,
            splitCopyGeneration: definition.splitCopyGeneration
        )
    }

    nonisolated private static func makeRuntimeProfile(
        from definition: MonitoringRuntimeDefinition
    ) -> MonitoringRuntimeProfile {
        var optionsByStage: [LLMPolicyStage: RuntimeInferenceOptions] = [:]
        for stageDefinition in definition.optionsByStage {
            guard let stage = llmPolicyStage(for: stageDefinition.stage) else {
                continue
            }

            optionsByStage[stage] = RuntimeInferenceOptions(
                modelIdentifier: stageDefinition.options.modelIdentifier,
                maxTokens: stageDefinition.options.maxTokens,
                temperature: stageDefinition.options.temperature,
                topP: stageDefinition.options.topP,
                topK: stageDefinition.options.topK,
                ctxSize: stageDefinition.options.ctxSize,
                batchSize: stageDefinition.options.batchSize,
                ubatchSize: stageDefinition.options.ubatchSize,
                timeoutSeconds: stageDefinition.options.timeoutSeconds
            )
        }

        return MonitoringRuntimeProfile(
            descriptor: MonitoringRuntimeProfileDescriptor(
                id: definition.id,
                displayName: definition.displayName,
                summary: definition.summary,
                modelIdentifier: definition.options(for: .decision)?.modelIdentifier ?? LocalModelRuntime.defaultModelIdentifier
            ),
            optionsByStage: optionsByStage
        )
    }

    nonisolated private static func llmPolicyStage(
        for sharedStage: MonitoringPromptTuningStage
    ) -> LLMPolicyStage? {
        switch sharedStage {
        case .perceptionTitle:
            return .perceptionTitle
        case .perceptionVision:
            return .perceptionVision
        case .decision:
            return .decision
        case .nudgeCopy:
            return .nudgeCopy
        case .appealReview:
            return .appealReview
        case .policyMemory:
            return .policyMemory
        case .legacyDecision, .legacyDecisionFallback:
            return nil
        }
    }
}

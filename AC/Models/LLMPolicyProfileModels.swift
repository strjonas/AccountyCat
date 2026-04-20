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
    nonisolated static let defaultPipelineProfile = LLMPolicyPipelineProfile(
        descriptor: MonitoringPipelineProfileDescriptor(
            id: MonitoringConfiguration.defaultPipelineProfileID,
            displayName: "Vision Split Default",
            summary: "Vision-backed perception, low-temperature decision, separate nudge copy.",
            requiresScreenshot: true
        ),
        usesTitlePerception: true,
        usesVisionPerception: true,
        splitCopyGeneration: true
    )

    nonisolated static let availablePipelineProfiles: [LLMPolicyPipelineProfile] = [
        defaultPipelineProfile,
        LLMPolicyPipelineProfile(
            descriptor: MonitoringPipelineProfileDescriptor(
                id: "title_only_default",
                displayName: "Title Only",
                summary: "Uses app name, tab/window title, history, and policy memory without screenshots.",
                requiresScreenshot: false
            ),
            usesTitlePerception: true,
            usesVisionPerception: false,
            splitCopyGeneration: true
        ),
        LLMPolicyPipelineProfile(
            descriptor: MonitoringPipelineProfileDescriptor(
                id: "vision_single_call",
                displayName: "Vision Single Call",
                summary: "Vision-backed decision with inline nudge writing in one policy call.",
                requiresScreenshot: true
            ),
            usesTitlePerception: true,
            usesVisionPerception: true,
            splitCopyGeneration: false
        ),
        LLMPolicyPipelineProfile(
            descriptor: MonitoringPipelineProfileDescriptor(
                id: "title_split_copy",
                displayName: "Title Split Copy",
                summary: "Title-only perception with split low-temp decision and higher-temp nudge copy.",
                requiresScreenshot: false
            ),
            usesTitlePerception: true,
            usesVisionPerception: false,
            splitCopyGeneration: true
        ),
    ]

    nonisolated static let defaultRuntimeProfile = MonitoringRuntimeProfile(
        descriptor: MonitoringRuntimeProfileDescriptor(
            id: MonitoringConfiguration.defaultRuntimeProfileID,
            displayName: "Gemma Balanced",
            summary: "Gemma E2B tuned for steady on-device policy work.",
            modelIdentifier: LocalModelRuntime.defaultModelIdentifier
        ),
        optionsByStage: [
            .perceptionTitle: RuntimeInferenceOptions(
                modelIdentifier: LocalModelRuntime.defaultModelIdentifier,
                maxTokens: 180,
                temperature: 0.15,
                topP: 0.9,
                topK: 48,
                ctxSize: 3072,
                batchSize: 1024,
                ubatchSize: 512,
                timeoutSeconds: 30
            ),
            .perceptionVision: RuntimeInferenceOptions(
                modelIdentifier: LocalModelRuntime.defaultModelIdentifier,
                maxTokens: 180,
                temperature: 0.15,
                topP: 0.95,
                topK: 64,
                ctxSize: 2048,
                batchSize: 2048,
                ubatchSize: 2048,
                timeoutSeconds: 45
            ),
            .decision: RuntimeInferenceOptions(
                modelIdentifier: LocalModelRuntime.defaultModelIdentifier,
                maxTokens: 220,
                temperature: 0.1,
                topP: 0.9,
                topK: 40,
                ctxSize: 4096,
                batchSize: 1024,
                ubatchSize: 512,
                timeoutSeconds: 40
            ),
            .nudgeCopy: RuntimeInferenceOptions(
                modelIdentifier: LocalModelRuntime.defaultModelIdentifier,
                maxTokens: 120,
                temperature: 0.55,
                topP: 0.95,
                topK: 64,
                ctxSize: 3072,
                batchSize: 1024,
                ubatchSize: 512,
                timeoutSeconds: 30
            ),
            .appealReview: RuntimeInferenceOptions(
                modelIdentifier: LocalModelRuntime.defaultModelIdentifier,
                maxTokens: 180,
                temperature: 0.15,
                topP: 0.92,
                topK: 48,
                ctxSize: 4096,
                batchSize: 1024,
                ubatchSize: 512,
                timeoutSeconds: 35
            ),
            .policyMemory: RuntimeInferenceOptions(
                modelIdentifier: LocalModelRuntime.defaultModelIdentifier,
                maxTokens: 260,
                temperature: 0.15,
                topP: 0.9,
                topK: 48,
                ctxSize: 4096,
                batchSize: 1024,
                ubatchSize: 512,
                timeoutSeconds: 35
            ),
        ]
    )

    nonisolated static let availableRuntimeProfiles: [MonitoringRuntimeProfile] = [
        defaultRuntimeProfile,
        MonitoringRuntimeProfile(
            descriptor: MonitoringRuntimeProfileDescriptor(
                id: "gemma_low_ram_v1",
                displayName: "Gemma Low RAM",
                summary: "More conservative context and token limits for smaller-memory systems.",
                modelIdentifier: LocalModelRuntime.defaultModelIdentifier
            ),
            optionsByStage: [
                .perceptionTitle: RuntimeInferenceOptions(
                    modelIdentifier: LocalModelRuntime.defaultModelIdentifier,
                    maxTokens: 140,
                    temperature: 0.12,
                    topP: 0.9,
                    topK: 40,
                    ctxSize: 2048,
                    batchSize: 768,
                    ubatchSize: 384,
                    timeoutSeconds: 25
                ),
                .perceptionVision: RuntimeInferenceOptions(
                    modelIdentifier: LocalModelRuntime.defaultModelIdentifier,
                    maxTokens: 140,
                    temperature: 0.12,
                    topP: 0.92,
                    topK: 48,
                    ctxSize: 1536,
                    batchSize: 1024,
                    ubatchSize: 1024,
                    timeoutSeconds: 35
                ),
                .decision: RuntimeInferenceOptions(
                    modelIdentifier: LocalModelRuntime.defaultModelIdentifier,
                    maxTokens: 180,
                    temperature: 0.08,
                    topP: 0.9,
                    topK: 32,
                    ctxSize: 3072,
                    batchSize: 768,
                    ubatchSize: 384,
                    timeoutSeconds: 30
                ),
                .nudgeCopy: RuntimeInferenceOptions(
                    modelIdentifier: LocalModelRuntime.defaultModelIdentifier,
                    maxTokens: 90,
                    temperature: 0.45,
                    topP: 0.95,
                    topK: 48,
                    ctxSize: 2048,
                    batchSize: 768,
                    ubatchSize: 384,
                    timeoutSeconds: 20
                ),
                .appealReview: RuntimeInferenceOptions(
                    modelIdentifier: LocalModelRuntime.defaultModelIdentifier,
                    maxTokens: 140,
                    temperature: 0.12,
                    topP: 0.92,
                    topK: 40,
                    ctxSize: 3072,
                    batchSize: 768,
                    ubatchSize: 384,
                    timeoutSeconds: 25
                ),
                .policyMemory: RuntimeInferenceOptions(
                    modelIdentifier: LocalModelRuntime.defaultModelIdentifier,
                    maxTokens: 220,
                    temperature: 0.12,
                    topP: 0.9,
                    topK: 40,
                    ctxSize: 3072,
                    batchSize: 768,
                    ubatchSize: 384,
                    timeoutSeconds: 25
                ),
            ]
        ),
        MonitoringRuntimeProfile(
            descriptor: MonitoringRuntimeProfileDescriptor(
                id: "llama_experiment_v1",
                displayName: "Llama Experiment",
                summary: "Llama-family preset for comparison runs and Prompt Lab sweeps.",
                modelIdentifier: "bartowski/Llama-3.2-3B-Instruct-GGUF:Q4_K_M"
            ),
            optionsByStage: [
                .perceptionTitle: RuntimeInferenceOptions(
                    modelIdentifier: "bartowski/Llama-3.2-3B-Instruct-GGUF:Q4_K_M",
                    maxTokens: 180,
                    temperature: 0.15,
                    topP: 0.9,
                    topK: 48,
                    ctxSize: 4096,
                    batchSize: 1024,
                    ubatchSize: 512,
                    timeoutSeconds: 35
                ),
                .perceptionVision: RuntimeInferenceOptions(
                    modelIdentifier: "bartowski/Llama-3.2-3B-Instruct-GGUF:Q4_K_M",
                    maxTokens: 180,
                    temperature: 0.15,
                    topP: 0.95,
                    topK: 64,
                    ctxSize: 2048,
                    batchSize: 2048,
                    ubatchSize: 2048,
                    timeoutSeconds: 45
                ),
                .decision: RuntimeInferenceOptions(
                    modelIdentifier: "bartowski/Llama-3.2-3B-Instruct-GGUF:Q4_K_M",
                    maxTokens: 240,
                    temperature: 0.1,
                    topP: 0.9,
                    topK: 40,
                    ctxSize: 4096,
                    batchSize: 1024,
                    ubatchSize: 512,
                    timeoutSeconds: 40
                ),
                .nudgeCopy: RuntimeInferenceOptions(
                    modelIdentifier: "bartowski/Llama-3.2-3B-Instruct-GGUF:Q4_K_M",
                    maxTokens: 120,
                    temperature: 0.6,
                    topP: 0.95,
                    topK: 64,
                    ctxSize: 3072,
                    batchSize: 1024,
                    ubatchSize: 512,
                    timeoutSeconds: 30
                ),
                .appealReview: RuntimeInferenceOptions(
                    modelIdentifier: "bartowski/Llama-3.2-3B-Instruct-GGUF:Q4_K_M",
                    maxTokens: 180,
                    temperature: 0.15,
                    topP: 0.92,
                    topK: 48,
                    ctxSize: 4096,
                    batchSize: 1024,
                    ubatchSize: 512,
                    timeoutSeconds: 35
                ),
                .policyMemory: RuntimeInferenceOptions(
                    modelIdentifier: "bartowski/Llama-3.2-3B-Instruct-GGUF:Q4_K_M",
                    maxTokens: 260,
                    temperature: 0.15,
                    topP: 0.9,
                    topK: 48,
                    ctxSize: 4096,
                    batchSize: 1024,
                    ubatchSize: 512,
                    timeoutSeconds: 35
                ),
            ]
        ),
    ]

    nonisolated static func pipelineProfile(id: String) -> LLMPolicyPipelineProfile {
        availablePipelineProfiles.first(where: { $0.descriptor.id == id }) ?? defaultPipelineProfile
    }

    nonisolated static func runtimeProfile(id: String) -> MonitoringRuntimeProfile {
        availableRuntimeProfiles.first(where: { $0.descriptor.id == id }) ?? defaultRuntimeProfile
    }

    nonisolated static func permissionRequirements(for configuration: MonitoringConfiguration) -> MonitoringPermissionRequirements {
        switch MonitoringConfiguration.normalizedAlgorithmID(configuration.algorithmID) {
        case MonitoringConfiguration.banditAlgorithmID,
             MonitoringConfiguration.llmAlgorithmID:
            return MonitoringPermissionRequirements(
                requiresAccessibility: true,
                requiresScreenRecording: true
            )
        case MonitoringConfiguration.llmPolicyAlgorithmID:
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
}

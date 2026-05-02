//
//  PolicyMemoryService.swift
//  AC
//

import Foundation

struct PolicyMemoryUpdateRequest: Sendable {
    var now: Date
    var goals: String
    var freeFormMemory: String
    var policyMemory: PolicyMemory
    var eventSummary: String
    var recentActions: [ActionRecord]
    var context: FrontmostContext?
    var runtimeProfileID: String
    var inferenceBackend: MonitoringInferenceBackend
    var onlineModelIdentifier: String
    var onlineTextModelIdentifier: String?
    var localModelIdentifier: String?
    /// Active focus profile (for the model to know what's currently in scope).
    var activeProfile: ProfilePromptSummary
    /// Other available profiles for matching against an `activate_profile` op.
    var availableProfiles: [ProfilePromptSummary]
}

/// Compact, prompt-safe summary of a focus profile for the policy_memory pipeline.
struct ProfilePromptSummary: Sendable, Codable, Hashable {
    var id: String
    var name: String
    var isDefault: Bool
    var description: String?
    /// One-line summary of the rules currently scoped to this profile (allow/disallow names).
    var rulesSummary: String?
    var lastUsedAt: Date?
    var expiresAt: Date?

    nonisolated init(
        id: String,
        name: String,
        isDefault: Bool,
        description: String? = nil,
        rulesSummary: String? = nil,
        lastUsedAt: Date? = nil,
        expiresAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.isDefault = isDefault
        self.description = description
        self.rulesSummary = rulesSummary
        self.lastUsedAt = lastUsedAt
        self.expiresAt = expiresAt
    }
}

protocol PolicyMemoryServicing: Sendable {
    func deriveUpdate(
        request: PolicyMemoryUpdateRequest,
        runtimeOverride: String?
    ) async -> PolicyMemoryUpdateResponse?
}

actor PolicyMemoryService: PolicyMemoryServicing {
    private let runtime: LocalModelRuntime
    private let onlineModelService: any OnlineModelServing

    init(
        runtime: LocalModelRuntime,
        onlineModelService: any OnlineModelServing
    ) {
        self.runtime = runtime
        self.onlineModelService = onlineModelService
    }

    func deriveUpdate(
        request: PolicyMemoryUpdateRequest,
        runtimeOverride: String?
    ) async -> PolicyMemoryUpdateResponse? {
        let runtimeProfile = LLMPolicyCatalog.runtimeProfile(id: request.runtimeProfileID)
        let options = runtimeProfile.options(for: .policyMemory)
        let systemPrompt = ACPromptSets.policyMemorySystemPrompt()
        let userPrompt = ACPromptSets.renderPolicyMemoryUserPrompt(
            payloadJSON: Self.makePayloadJSON(request: request)
        )

        let output: RuntimeProcessOutput
        do {
            if request.inferenceBackend == .openRouter {
                output = try await onlineModelService.runInference(
                    OnlineModelRequest(
                        source: .policyMemory,
                        modelIdentifier: request.onlineTextModelIdentifier ?? request.onlineModelIdentifier,
                        systemPrompt: systemPrompt,
                        userPrompt: userPrompt,
                        imagePath: nil,
                        options: options
                    )
                )
            } else {
                let runtimePath = RuntimeSetupService.normalizedRuntimePath(from: runtimeOverride)
                guard FileManager.default.isExecutableFile(atPath: runtimePath) else { return nil }
                guard let localModelIdentifier = request.localModelIdentifier, !localModelIdentifier.isEmpty else {
                    await ActivityLogService.shared.append(category: "policy-memory-error", message: "No local text model configured.")
                    return nil
                }
                output = try await runtime.runTextInference(
                    runtimePath: runtimePath,
                    modelIdentifier: localModelIdentifier,
                    systemPrompt: systemPrompt,
                    userPrompt: userPrompt,
                    options: options
                )
            }
        } catch {
            await ActivityLogService.shared.append(
                category: "policy-memory-error",
                message: error.localizedDescription
            )
            return nil
        }

        return Self.parseUpdate(from: output.stdout + "\n" + output.stderr)
    }

    nonisolated private static func makePayloadJSON(request: PolicyMemoryUpdateRequest) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        struct Payload: Encodable {
            var now: Date
            var goals: String
            var freeFormMemory: String
            var policyMemory: PolicyMemory
            var eventSummary: String
            var recentActions: [ActionRecord]
            var context: FrontmostContext?
            var activeProfile: ProfilePromptSummary
            var availableProfiles: [ProfilePromptSummary]
        }

        let payload = Payload(
            now: request.now,
            goals: request.goals.cleanedSingleLine,
            freeFormMemory: request.freeFormMemory,
            policyMemory: request.policyMemory,
            eventSummary: request.eventSummary.cleanedSingleLine,
            recentActions: Array(request.recentActions.prefix(4)),
            context: request.context,
            activeProfile: request.activeProfile,
            availableProfiles: request.availableProfiles
        )

        guard let data = try? encoder.encode(payload),
              let json = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return json
    }

    nonisolated private static func parseUpdate(from output: String) -> PolicyMemoryUpdateResponse? {
        for json in LLMOutputParsing.jsonObjects(in: output).reversed() {
            guard let data = json.data(using: .utf8),
                  let response = try? JSONDecoder.iso8601.decode(PolicyMemoryUpdateResponse.self, from: data) else {
                continue
            }
            return response
        }
        return nil
    }
}

private extension JSONDecoder {
    nonisolated static var iso8601: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

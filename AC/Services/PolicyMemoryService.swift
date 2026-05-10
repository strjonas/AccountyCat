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
    /// Recent behavioral observations (appeal approvals, repeated dismissals, returns to focus
    /// after a nudge). The model uses these to decide whether to apply a rule directly or to
    /// emit `propose_rule` for the user to approve.
    var recentBehavioralSignals: [BehavioralSignalSummary] = []
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
                let pmStartedAt = Date()
                do {
                    var localOutput = try await runtime.runTextInference(
                        runtimePath: runtimePath,
                        modelIdentifier: localModelIdentifier,
                        systemPrompt: systemPrompt,
                        userPrompt: userPrompt,
                        options: options
                    )
                    let id = await LLMTelemetryRecorder.shared.record(
                        LLMTelemetryCall(
                            kind: .policyMemory,
                            runtime: .llamaCpp,
                            modelIdentifier: localOutput.usedModelIdentifier ?? localModelIdentifier,
                            promptMode: "policy-memory",
                            systemPrompt: systemPrompt,
                            userPrompt: userPrompt,
                            startedAt: pmStartedAt,
                            endedAt: Date(),
                            rawStdout: localOutput.stdout,
                            rawStderr: localOutput.stderr,
                            tokenUsage: localOutput.tokenUsage
                        )
                    )
                    localOutput.interactionID = id
                    output = localOutput
                } catch {
                    await LLMTelemetryRecorder.shared.record(
                        LLMTelemetryCall(
                            kind: .policyMemory,
                            runtime: .llamaCpp,
                            modelIdentifier: localModelIdentifier,
                            promptMode: "policy-memory",
                            systemPrompt: systemPrompt,
                            userPrompt: userPrompt,
                            startedAt: pmStartedAt,
                            endedAt: Date(),
                            rawStdout: nil,
                            rawStderr: nil,
                            failure: LLMInteractionFailure(
                                domain: String(describing: type(of: error)),
                                message: error.localizedDescription
                            )
                        )
                    )
                    throw error
                }
            }
        } catch {
            await ActivityLogService.shared.append(
                category: "policy-memory-error",
                message: error.localizedDescription
            )
            return nil
        }

        let combined = output.stdout + "\n" + output.stderr
        let parsed = Self.parseUpdate(from: combined)
        if parsed == nil {
            await ActivityLogService.shared.append(
                category: "policy-memory-parse-error",
                message: "Could not parse policy-memory JSON from \(request.inferenceBackend == .openRouter ? "online" : "local") model. Raw output: \(combined.cleanedSingleLine.truncatedForPrompt(maxLength: 900))"
            )
        }
        if let interactionID = output.interactionID {
            await Self.annotatePolicyMemory(
                interactionID: interactionID,
                request: request,
                parsed: parsed
            )
        }
        return parsed
    }

    private static func annotatePolicyMemory(
        interactionID: String,
        request: PolicyMemoryUpdateRequest,
        parsed: PolicyMemoryUpdateResponse?
    ) async {
        var fields: [String: String] = [
            "triggerSummary": request.eventSummary.cleanedSingleLine.truncatedForPrompt(maxLength: 300),
        ]
        if let parsed {
            fields["operationsCount"] = String(parsed.operations.count)
            let kinds = parsed.operations.map { String(describing: $0) }.joined(separator: ", ")
            if !kinds.isEmpty {
                fields["operationKinds"] = kinds.truncatedForPrompt(maxLength: 400)
            }
        } else {
            fields["parseFailed"] = "true"
        }
        var parsedJSON: String? = nil
        if let parsed {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            if let data = try? encoder.encode(parsed),
               let str = String(data: data, encoding: .utf8) {
                parsedJSON = str
            }
        }
        await LLMTelemetryRecorder.shared.annotate(
            LLMTelemetryAnnotation(
                interactionID: interactionID,
                kind: .policyMemory,
                parsedOutputJSON: parsedJSON,
                summary: parsed.map { "\($0.operations.count) op(s)" } ?? "no parse",
                extractedFields: fields
            )
        )
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
            var recentBehavioralSignals: [BehavioralSignalSummary]?
        }

        let recentSignals = request.recentBehavioralSignals
            .filter { !$0.isStale(at: request.now) }
            .suffix(8)
            .map { $0 }

        let payload = Payload(
            now: request.now,
            goals: request.goals.cleanedSingleLine,
            freeFormMemory: request.freeFormMemory,
            policyMemory: request.policyMemory,
            eventSummary: request.eventSummary.cleanedSingleLine,
            recentActions: Array(request.recentActions.prefix(4)),
            context: request.context,
            activeProfile: request.activeProfile,
            availableProfiles: request.availableProfiles,
            recentBehavioralSignals: recentSignals.isEmpty ? nil : recentSignals
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

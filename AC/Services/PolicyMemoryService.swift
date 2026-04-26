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
        let systemPrompt = PromptCatalog.loadPolicyMemorySystemPrompt()
        let userPrompt = PromptCatalog.renderPolicyMemoryUserPrompt(
            payloadJSON: Self.makePayloadJSON(request: request)
        )

        let output: RuntimeProcessOutput
        do {
            if request.inferenceBackend == .openRouter {
                output = try await onlineModelService.runInference(
                    OnlineModelRequest(
                        modelIdentifier: request.onlineModelIdentifier,
                        systemPrompt: systemPrompt,
                        userPrompt: userPrompt,
                        imagePath: nil,
                        options: options
                    )
                )
            } else {
                let runtimePath = RuntimeSetupService.normalizedRuntimePath(from: runtimeOverride)
                guard FileManager.default.isExecutableFile(atPath: runtimePath) else { return nil }
                output = try await runtime.runTextInference(
                    runtimePath: runtimePath,
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
        }

        let payload = Payload(
            now: request.now,
            goals: request.goals.cleanedSingleLine,
            freeFormMemory: request.freeFormMemory,
            policyMemory: request.policyMemory,
            eventSummary: request.eventSummary.cleanedSingleLine,
            recentActions: Array(request.recentActions.prefix(4)),
            context: request.context
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

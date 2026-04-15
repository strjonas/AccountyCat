//
//  MemoryService.swift
//  AC
//
//  Created by Codex on 15.04.26.
//

import Foundation

actor MemoryService {
    private let runtime: LocalModelRuntime
    private let modelIdentifier: String

    init(
        runtime: LocalModelRuntime,
        modelIdentifier: String = LocalModelRuntime.defaultModelIdentifier
    ) {
        self.runtime = runtime
        self.modelIdentifier = modelIdentifier
    }

    func extractMemoryUpdate(
        userMessage: String,
        reply: String,
        currentMemory: String,
        runtimeOverride: String?
    ) async -> String? {
        let runtimePath = RuntimeSetupService.normalizedRuntimePath(from: runtimeOverride)
        guard FileManager.default.isExecutableFile(atPath: runtimePath) else { return nil }

        let systemPrompt = PromptCatalog.loadMemoryExtractionSystemPrompt()
        let userPrompt = """
        User message: \(userMessage.cleanedSingleLine)
        Assistant reply: \(reply.cleanedSingleLine)
        Existing memory (for dedup):
        \(currentMemory.isEmpty ? "(empty)" : currentMemory)
        """

        do {
            let output = try await runtime.runTextInference(
                runtimePath: runtimePath,
                modelIdentifier: modelIdentifier,
                systemPrompt: systemPrompt,
                userPrompt: userPrompt
            )
            let combined = output.stdout + "\n" + output.stderr
            for json in LLMOutputParsing.jsonObjects(in: combined) {
                guard let data = json.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let bullet = obj["memory"] as? String,
                      !bullet.isEmpty,
                      bullet.lowercased() != "none" else { continue }
                return bullet.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        } catch { }
        return nil
    }

    func compressMemory(
        memory: String,
        runtimeOverride: String?
    ) async -> String? {
        let runtimePath = RuntimeSetupService.normalizedRuntimePath(from: runtimeOverride)
        guard FileManager.default.isExecutableFile(atPath: runtimePath) else { return nil }

        let systemPrompt = PromptCatalog.loadMemoryCompressionSystemPrompt()
        let userPrompt = "Memory to compress:\n\(memory)"

        do {
            let output = try await runtime.runTextInference(
                runtimePath: runtimePath,
                modelIdentifier: modelIdentifier,
                systemPrompt: systemPrompt,
                userPrompt: userPrompt
            )
            let combined = output.stdout + "\n" + output.stderr
            for json in LLMOutputParsing.jsonObjects(in: combined) {
                guard let data = json.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let compressed = obj["memory"] as? String,
                      !compressed.isEmpty else { continue }
                return compressed.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        } catch { }
        return nil
    }
}

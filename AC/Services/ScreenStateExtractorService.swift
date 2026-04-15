//
//  ScreenStateExtractorService.swift
//  AC
//

import Foundation

// MARK: - Protocol

/// Brain 1: extracts structured screen state from a screenshot via the local VLM.
protocol ScreenStateExtracting: Sendable {
    func extract(
        snapshot: AppSnapshot,
        goals: String,
        recentNudgeMessages: [String],
        runtimePath: String
    ) async -> BanditScreenState?
}

// MARK: - Implementation

actor ScreenStateExtractorService: ScreenStateExtracting {
    private let runtime: LocalModelRuntime
    private let modelIdentifier: String

    init(
        runtime: LocalModelRuntime,
        modelIdentifier: String = LocalModelRuntime.defaultModelIdentifier
    ) {
        self.runtime = runtime
        self.modelIdentifier = modelIdentifier
    }

    func extract(
        snapshot: AppSnapshot,
        goals: String,
        recentNudgeMessages: [String],
        runtimePath: String
    ) async -> BanditScreenState? {
        let systemPrompt = PromptCatalog.loadExtractionSystemPrompt()
        let payloadJSON = makePayloadJSON(
            snapshot: snapshot,
            goals: goals,
            recentNudgeMessages: recentNudgeMessages
        )
        let userPrompt = PromptCatalog.loadExtractionUserPrompt(replacingPayloadWith: payloadJSON)

        let output: RuntimeProcessOutput
        do {
            output = try await runtime.runVisionInference(
                runtimePath: runtimePath,
                modelIdentifier: modelIdentifier,
                snapshotPath: snapshot.screenshotPath,
                systemPrompt: systemPrompt,
                userPrompt: userPrompt
            )
        } catch {
            await ActivityLogService.shared.append(
                category: "extractor-error",
                message: error.localizedDescription
            )
            return nil
        }

        return parseScreenState(from: output.stdout + "\n" + output.stderr)
    }

    // MARK: - Private

    private func makePayloadJSON(
        snapshot: AppSnapshot,
        goals: String,
        recentNudgeMessages: [String]
    ) -> String {
        let payload: [String: Any] = [
            "goals": goals,
            "frontmost_app": snapshot.appName,
            "window_title": snapshot.windowTitle ?? "",
            "recent_nudge_messages": recentNudgeMessages,
            "timestamp": ISO8601DateFormatter().string(from: snapshot.timestamp),
        ]
        guard
            let data = try? JSONSerialization.data(withJSONObject: payload, options: .sortedKeys),
            let json = String(data: data, encoding: .utf8)
        else { return "{}" }
        return json
    }

    private func parseScreenState(from output: String) -> BanditScreenState? {
        for json in LLMOutputParsing.jsonObjects(in: output).reversed() {
            guard
                let data = json.data(using: .utf8),
                let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                obj["app_category"] != nil,
                let decoded = try? JSONDecoder().decode(BanditScreenStateRaw.self, from: data)
            else { continue }
            return decoded.toBanditScreenState()
        }
        return nil
    }
}

// MARK: - Raw decoding helper

/// Bridges the snake_case VLM JSON output to `BanditScreenState`.
private struct BanditScreenStateRaw: Decodable {
    var app_category: String
    var productivity_score: Double
    var on_task: Bool
    var content_summary: String
    var confidence: Double
    var candidate_nudge: String?

    func toBanditScreenState() -> BanditScreenState {
        BanditScreenState(
            appCategory: BanditScreenState.AppCategory(rawValue: app_category) ?? .other,
            productivityScore: max(0, min(1, productivity_score)),
            onTask: on_task,
            contentSummary: content_summary,
            confidence: max(0, min(1, confidence)),
            candidateNudge: candidate_nudge.flatMap { $0.isEmpty ? nil : $0 }
        )
    }
}

//
//  MemoryConsolidationService.swift
//  AC
//
//  Periodically trims, merges, and prunes AC's persistent memory. The LLM does the
//  curating — this service just shuttles the state in and the result out. Triggered
//  from AppController when the soft cap is exceeded or at most once per day.
//

import Foundation

actor MemoryConsolidationService {
    private let runtime: LocalModelRuntime
    private let onlineModelService: any OnlineModelServing

    init(
        runtime: LocalModelRuntime,
        onlineModelService: any OnlineModelServing
    ) {
        self.runtime = runtime
        self.onlineModelService = onlineModelService
    }

    /// Ask AC to produce a consolidated memory list.
    ///
    /// Returns the new entry list on success, or nil if the model couldn't produce a
    /// valid response. On nil, callers keep the existing memory — we never delete on
    /// failure.
    func consolidate(
        entries: [MemoryEntry],
        goals: String,
        recentUserMessages: [String],
        now: Date,
        runtimeOverride: String?,
        inferenceBackend: MonitoringInferenceBackend = .local,
        onlineModelIdentifier: String = AITier.balanced.byokModelIdentifierImage,
        onlineTextModelIdentifier: String? = nil,
        localTextModelIdentifier: String? = nil
    ) async -> [MemoryEntry]? {
        guard !entries.isEmpty else { return nil }

        let systemPrompt = ACPromptSets.memoryConsolidationSystemPrompt
        let userPrompt = Self.makeUserPrompt(
            entries: entries,
            goals: goals,
            recentUserMessages: recentUserMessages,
            now: now
        )

        let output: RuntimeProcessOutput
        do {
            if inferenceBackend == .openRouter {
                let resolvedOnlineModelIdentifier = onlineTextModelIdentifier ?? onlineModelIdentifier
                await ActivityLogService.shared.append(level: .verbose,
                    category: "llm:memory",
                    message: "─── Request → openrouter/\(resolvedOnlineModelIdentifier) · consolidating \(entries.count) entries ───"
                )
                output = try await onlineModelService.runInference(
                    OnlineModelRequest(
                        source: .memoryConsolidation,
                        modelIdentifier: resolvedOnlineModelIdentifier,
                        systemPrompt: systemPrompt,
                        userPrompt: userPrompt,
                        imagePath: nil,
                        options: Self.inferenceOptions()
                    )
                )
            } else {
                let runtimePath = RuntimeSetupService.normalizedRuntimePath(from: runtimeOverride)
                guard FileManager.default.isExecutableFile(atPath: runtimePath) else { return nil }
                guard let localTextModelIdentifier, !localTextModelIdentifier.isEmpty else {
                    await ActivityLogService.shared.append(
                        category: "memory-consolidation-error",
                        message: "No local text model configured."
                    )
                    return nil
                }
                output = try await runtime.runTextInference(
                    runtimePath: runtimePath,
                    modelIdentifier: localTextModelIdentifier,
                    systemPrompt: systemPrompt,
                    userPrompt: userPrompt,
                    options: Self.inferenceOptions()
                )
            }
        } catch {
            await ActivityLogService.shared.append(
                category: "memory-consolidation-error",
                message: error.localizedDescription
            )
            return nil
        }

        let combined = output.stdout + "\n" + output.stderr
        return Self.parseEntries(from: combined, fallback: entries, now: now)
    }

    nonisolated private static func makeUserPrompt(
        entries: [MemoryEntry],
        goals: String,
        recentUserMessages: [String],
        now: Date
    ) -> String {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        let entriesText = entries
            .sorted { $0.createdAt < $1.createdAt }
            .map { entry in
                "- id=\(entry.id.uuidString) created=\(iso.string(from: entry.createdAt)) text=\(entry.text.cleanedSingleLine)"
            }
            .joined(separator: "\n")

        let recentMessages = recentUserMessages
            .map { $0.cleanedSingleLine }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")

        return ACPromptSets.renderMemoryConsolidationUserPrompt(
            nowISO: iso.string(from: now),
            nowLabel: PromptTimestampFormatting.absoluteLabel(for: now),
            goals: goals.cleanedSingleLine,
            recentMessages: recentMessages,
            entries: entriesText
        )
    }

    nonisolated private static func inferenceOptions() -> RuntimeInferenceOptions {
        RuntimeInferenceOptions(
            maxTokens: 320,
            temperature: 0.15,
            topP: 0.9,
            topK: 48,
            ctxSize: 4096,
            batchSize: 1024,
            ubatchSize: 512,
            timeoutSeconds: 45
        )
    }

    nonisolated private static func parseEntries(
        from output: String,
        fallback: [MemoryEntry],
        now: Date
    ) -> [MemoryEntry]? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        struct WireEntry: Decodable {
            var created: String?
            var createdAt: String?
            var text: String
        }
        struct Wire: Decodable {
            var entries: [WireEntry]
        }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]

        for json in LLMOutputParsing.jsonObjects(in: output).reversed() {
            guard let data = json.data(using: .utf8),
                  let wire = try? decoder.decode(Wire.self, from: data) else {
                continue
            }
            let fallbackByID: [UUID: MemoryEntry] = Dictionary(
                fallback.map { ($0.id, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            let fallbackByText: [String: MemoryEntry] = Dictionary(
                fallback.map { ($0.text.lowercased(), $0) },
                uniquingKeysWith: { a, _ in a }
            )
            var usedIDs = Set<UUID>()
            let consolidated: [MemoryEntry] = wire.entries.compactMap { raw in
                let text = raw.text.cleanedSingleLine
                guard !text.isEmpty else { return nil }
                let createdString = raw.created ?? raw.createdAt
                let created = createdString.flatMap { iso.date(from: $0) } ?? now

                // Reuse the original id when we recognise the text — stable ids are nicer
                // for any future UI or eval harness.
                let existing = fallbackByText[text.lowercased()]
                let id = existing?.id ?? UUID()
                guard usedIDs.insert(id).inserted else { return nil }
                return MemoryEntry(
                    id: id,
                    createdAt: existing?.createdAt ?? created,
                    text: text,
                    profileID: existing?.profileID,
                    profileName: existing?.profileName
                )
            }

            if !consolidated.isEmpty {
                return consolidated
            }
        }
        return nil
    }
}

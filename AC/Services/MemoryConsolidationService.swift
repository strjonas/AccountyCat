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
    private let modelIdentifier: String

    init(
        runtime: LocalModelRuntime,
        onlineModelService: any OnlineModelServing,
        modelIdentifier: String = LocalModelRuntime.defaultModelIdentifier
    ) {
        self.runtime = runtime
        self.onlineModelService = onlineModelService
        self.modelIdentifier = modelIdentifier
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
        onlineModelIdentifier: String = MonitoringConfiguration.defaultOnlineModelIdentifier
    ) async -> [MemoryEntry]? {
        guard !entries.isEmpty else { return nil }

        let systemPrompt = PromptCatalog.loadMemoryConsolidationSystemPrompt()
        let userPrompt = Self.makeUserPrompt(
            entries: entries,
            goals: goals,
            recentUserMessages: recentUserMessages,
            now: now
        )

        let output: RuntimeProcessOutput
        do {
            if inferenceBackend == .openRouter {
                output = try await onlineModelService.runInference(
                    OnlineModelRequest(
                        modelIdentifier: onlineModelIdentifier,
                        systemPrompt: systemPrompt,
                        userPrompt: userPrompt,
                        imagePath: nil,
                        options: Self.inferenceOptions(modelIdentifier: onlineModelIdentifier)
                    )
                )
            } else {
                let runtimePath = RuntimeSetupService.normalizedRuntimePath(from: runtimeOverride)
                guard FileManager.default.isExecutableFile(atPath: runtimePath) else { return nil }
                output = try await runtime.runTextInference(
                    runtimePath: runtimePath,
                    systemPrompt: systemPrompt,
                    userPrompt: userPrompt,
                    options: Self.inferenceOptions(modelIdentifier: modelIdentifier)
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
        let payload = entries
            .sorted { $0.createdAt < $1.createdAt }
            .map { entry in
                // Keep each line parseable: id marker, ISO timestamp, text. Model may keep
                // the id it wants to keep, or omit it to emit a brand-new bullet.
                "- id=\(entry.id.uuidString) created=\(iso.string(from: entry.createdAt)) text=\(entry.text.cleanedSingleLine)"
            }
            .joined(separator: "\n")

        let recentMessages = recentUserMessages
            .map { $0.cleanedSingleLine }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")

        return """
        Current local time: \(PromptTimestampFormatting.absoluteLabel(for: now))
        Current ISO time: \(iso.string(from: now))

        User goals:
        \(goals.cleanedSingleLine)

        Recent user chat messages (oldest first):
        \(recentMessages.isEmpty ? "(none)" : recentMessages)

        Current memory (oldest first):
        \(payload.isEmpty ? "(empty)" : payload)

        Produce a consolidated memory list. Rules:
        - Drop entries whose time scope has clearly passed (e.g. "today" but created yesterday or earlier, "this evening" once it's the next morning, "for the next hour" more than an hour ago).
        - Merge duplicates and near-duplicates into a single line.
        - Keep both restrictions ("don't let me use X") and allowances ("X is okay" / "taking a break") — neither is more important than the other. The newest version wins if they conflict.
        - Treat explicit directives in recent user chat messages as fresh ground truth even if they are not yet present in memory.
        - When a memory line uses relative time language, resolve it against the current time and prefer rewriting the surviving line with an explicit end time when that makes it clearer.
        - Prefer recent entries over older ones when both can't fit.
        - Preserve load-bearing detail (app names, durations, time scopes). Don't paraphrase things away.
        - Aim for 10 or fewer final entries. It is fine to return fewer.

        Return exactly one JSON object:
        {"entries":[{"created":"ISO-8601 timestamp","text":"single concise bullet"}, ...]}
        - Use the original created timestamp when keeping/merging an entry (pick the most recent contributor).
        - Use the current time for any genuinely new summary line.
        - In `text`, prefer explicit times over vague relative phrases when the expiry matters.
        - No markdown, no other keys, no commentary.
        """
    }

    nonisolated private static func inferenceOptions(modelIdentifier: String) -> RuntimeInferenceOptions {
        RuntimeInferenceOptions(
            modelIdentifier: modelIdentifier,
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
                uniqueKeysWithValues: fallback.map { ($0.id, $0) }
            )
            let fallbackByText: [String: MemoryEntry] = Dictionary(
                fallback.map { ($0.text.lowercased(), $0) },
                uniquingKeysWith: { a, _ in a }
            )
            let consolidated: [MemoryEntry] = wire.entries.compactMap { raw in
                let text = raw.text.cleanedSingleLine
                guard !text.isEmpty else { return nil }
                let createdString = raw.created ?? raw.createdAt
                let created = createdString.flatMap { iso.date(from: $0) } ?? now

                // Reuse the original id when we recognise the text — stable ids are nicer
                // for any future UI or eval harness.
                let existing = fallbackByText[text.lowercased()]
                return MemoryEntry(
                    id: existing?.id ?? fallbackByID[existing?.id ?? UUID()]?.id ?? UUID(),
                    createdAt: existing?.createdAt ?? created,
                    text: text
                )
            }

            if !consolidated.isEmpty {
                return consolidated
            }
        }
        return nil
    }
}

//
//  InspectorController.swift
//  ACInspector
//
//  Created by Codex on 13.04.26.
//

import AppKit
import Combine
import Foundation

@MainActor
final class InspectorController: ObservableObject {
    @Published var selectedTab: InspectorTab = .episodes
    @Published var episodes: [IndexedEpisode] = []
    @Published var selectedEpisodeID: String?
    @Published var selectedEpisodeEvents: [IndexedEvent] = []
    @Published var selectedEpisodeAttempts: [IndexedModelAttempt] = []
    @Published var selectedEvaluationRuns: [IndexedEvaluationRun] = []
    @Published var annotationNote = ""
    @Published var selectedLabels: Set<EpisodeAnnotationLabel> = []
    @Published var pinEpisode = false
    @Published var statusText = "Loading telemetry."
    @Published var promptLabScenarios: [PromptLabScenario] = [.syntheticDefault] { didSet { schedulePersistPromptLabState() } }
    @Published var selectedPromptLabScenarioID: UUID? = PromptLabScenario.syntheticDefault.id { didSet { schedulePersistPromptLabState() } }
    @Published var promptLabPromptSets: [PromptLabPromptSet] = PromptLabPromptSet.defaults { didSet { schedulePersistPromptLabState() } }
    @Published var selectedPromptSetID: String = PromptLabPromptSet.defaults.first?.id ?? "" { didSet { schedulePersistPromptLabState() } }
    @Published var selectedPromptStage: PromptLabStage = .decision { didSet { schedulePersistPromptLabState() } }
    @Published var selectedPipelineIDs: Set<String> = [PromptLabPipelineProfile.defaults.first?.id ?? ""] { didSet { schedulePersistPromptLabState() } }
    @Published var selectedRuntimeProfileIDs: Set<String> = [PromptLabRuntimeProfile.defaults.first?.id ?? ""] { didSet { schedulePersistPromptLabState() } }
    @Published var promptLabRuntimePath = PromptLabRunner.defaultRuntimePath { didSet { schedulePersistPromptLabState() } }
    @Published var promptLabResults: [PromptLabRunResult] = [] { didSet { schedulePersistPromptLabState() } }
    @Published var promptLabStatusText = "Prompt Lab ready."
    @Published var promptLabIsRunning = false

    private let indexStore = TelemetryIndexStore()
    private let telemetryStore = TelemetryStore.shared
    private let promptLabRunner = PromptLabRunner()
    private let promptLabPersistenceURL: URL
    private var refreshTask: Task<Void, Never>?
    private var promptLabSaveTask: Task<Void, Never>?
    private var lastLoadedDraft: AnnotationDraft?
    private var lastLoadedEpisodeID: String?
    private var isHydratingPromptLabState = false

    private struct AnnotationDraft: Equatable {
        var note: String
        var labels: Set<EpisodeAnnotationLabel>
        var pinned: Bool
    }

    private struct PromptLabPersistenceState: Codable {
        var scenarios: [PromptLabScenario]
        var selectedScenarioID: UUID?
        var promptSets: [PromptLabPromptSet]
        var selectedPromptSetID: String
        var selectedPromptStage: PromptLabStage
        var selectedPipelineIDs: [String]
        var selectedRuntimeProfileIDs: [String]
        var runtimePath: String
        var results: [PromptLabRunResult]
    }

    init(fileManager: FileManager = .default) {
        promptLabPersistenceURL = TelemetryPaths.inspectorSupportURL(fileManager: fileManager)
            .appendingPathComponent("prompt_lab_state.json")
        loadPersistedPromptLabState(fileManager: fileManager)
    }

    deinit {
        refreshTask?.cancel()
        promptLabSaveTask?.cancel()
    }

    func start() {
        guard refreshTask == nil else { return }

        refreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.refresh()
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }

    func refresh(forceRebuild: Bool = false) async {
        do {
            let didChange = try await indexStore.refresh(forceRebuild: forceRebuild)
            guard didChange || forceRebuild || episodes.isEmpty else {
                return
            }

            let episodes = try await indexStore.loadEpisodes()
            self.episodes = episodes

            if let selectedEpisodeID,
               episodes.contains(where: { $0.id == selectedEpisodeID }) == false {
                self.selectedEpisodeID = episodes.first?.id
            } else if selectedEpisodeID == nil {
                selectedEpisodeID = episodes.first?.id
            }

            if let selectedEpisodeID {
                try await loadEpisodeDetails(episodeID: selectedEpisodeID, preserveDraftIfDirty: true)
            } else {
                clearSelectionState()
            }

            statusText = episodes.isEmpty ? "No telemetry episodes yet." : "Loaded \(episodes.count) episodes."
        } catch {
            statusText = error.localizedDescription
        }
    }

    func selectionDidChange() async {
        guard let selectedEpisodeID else {
            clearSelectionState()
            return
        }

        do {
            try await loadEpisodeDetails(episodeID: selectedEpisodeID, preserveDraftIfDirty: false)
        } catch {
            statusText = error.localizedDescription
        }
    }

    func saveAnnotation() {
        guard let selectedEpisode else { return }
        let annotation = EpisodeAnnotation(
            id: UUID().uuidString,
            sessionID: selectedEpisode.sessionID,
            episodeID: selectedEpisode.id,
            labels: Array(selectedLabels).sorted { $0.rawValue < $1.rawValue },
            note: annotationNote.cleanedSingleLine,
            pinned: pinEpisode,
            source: .human,
            createdAt: Date()
        )
        let savedDraft = AnnotationDraft(
            note: annotation.note,
            labels: Set(annotation.labels),
            pinned: annotation.pinned
        )
        applyAnnotationDraft(savedDraft)
        lastLoadedDraft = savedDraft
        lastLoadedEpisodeID = selectedEpisode.id
        statusText = "Saving annotation."

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.telemetryStore.appendAnnotation(annotation, episode: selectedEpisode.episodeRecord)
                await self.refresh()
                self.statusText = "Annotation saved."
            } catch {
                self.statusText = error.localizedDescription
            }
        }
    }

    func openFile(_ path: String?) {
        guard let path else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    func addSyntheticPromptLabScenario() {
        let scenario = PromptLabScenario.syntheticDefault
        promptLabScenarios.insert(
            PromptLabScenario(
                id: UUID(),
                name: "Synthetic Scenario \(promptLabScenarios.count + 1)",
                source: .synthetic,
                sourceEpisodeID: nil,
                appName: scenario.appName,
                bundleIdentifier: scenario.bundleIdentifier,
                windowTitle: scenario.windowTitle,
                timestamp: Date(),
                goals: scenario.goals,
                freeFormMemorySummary: scenario.freeFormMemorySummary,
                policyMemorySummary: scenario.policyMemorySummary,
                policyMemoryJSON: scenario.policyMemoryJSON,
                recentSwitches: scenario.recentSwitches,
                recentActions: scenario.recentActions,
                usage: scenario.usage,
                screenshotPath: scenario.screenshotPath,
                appealText: scenario.appealText,
                heuristics: scenario.heuristics,
                distraction: scenario.distraction,
                expectedAssessment: scenario.expectedAssessment,
                expectedAction: scenario.expectedAction
            ),
            at: 0
        )
        selectedPromptLabScenarioID = promptLabScenarios.first?.id
        selectedTab = .promptLab
        promptLabStatusText = "Added synthetic scenario."
    }

    func deletePromptLabScenarios(at offsets: IndexSet) {
        let removedIDs = offsets.map { promptLabScenarios[$0].id }
        promptLabScenarios = promptLabScenarios.enumerated()
            .filter { offsets.contains($0.offset) == false }
            .map(\.element)
        promptLabResults.removeAll { removedIDs.contains($0.scenarioID) }
        if let selectedPromptLabScenarioID, removedIDs.contains(selectedPromptLabScenarioID) {
            self.selectedPromptLabScenarioID = promptLabScenarios.first?.id
        }
        if promptLabScenarios.isEmpty {
            promptLabScenarios = [.syntheticDefault]
            selectedPromptLabScenarioID = promptLabScenarios.first?.id
        }
    }

    func importSelectedEpisodeIntoPromptLab() {
        guard let episode = selectedEpisode else {
            promptLabStatusText = "Select an episode first."
            return
        }

        do {
            let scenario = try makePromptLabScenario(from: episode, events: selectedEpisodeEvents)
            promptLabScenarios.insert(scenario, at: 0)
            selectedPromptLabScenarioID = scenario.id
            selectedTab = .promptLab
            promptLabStatusText = "Imported telemetry episode into Prompt Lab."
        } catch {
            promptLabStatusText = error.localizedDescription
        }
    }

    func runPromptLab() {
        guard let scenario = selectedPromptLabScenario else {
            promptLabStatusText = "Select a scenario first."
            return
        }

        let promptSet = selectedPromptSet ?? PromptLabPromptSet.defaults[0]
        let pipelines = PromptLabPipelineProfile.defaults.filter { selectedPipelineIDs.contains($0.id) }
        let runtimeProfiles = PromptLabRuntimeProfile.defaults.filter { selectedRuntimeProfileIDs.contains($0.id) }

        guard !pipelines.isEmpty else {
            promptLabStatusText = "Select at least one pipeline profile."
            return
        }
        guard !runtimeProfiles.isEmpty else {
            promptLabStatusText = "Select at least one runtime profile."
            return
        }

        promptLabIsRunning = true
        promptLabStatusText = "Running \(pipelines.count * runtimeProfiles.count) Prompt Lab combinations."

        Task { @MainActor [weak self] in
            guard let self else { return }
            let results = await self.promptLabRunner.runMatrix(
                scenario: scenario,
                promptSet: promptSet,
                pipelines: pipelines,
                runtimeProfiles: runtimeProfiles,
                runtimePath: self.promptLabRuntimePath
            )
            self.promptLabResults.removeAll { $0.scenarioID == scenario.id }
            self.promptLabResults.append(contentsOf: results)
            self.promptLabResults.sort { $0.startedAt > $1.startedAt }
            self.promptLabIsRunning = false
            let summary = self.matrixSummary(for: scenario.id)
            self.promptLabStatusText = "Completed \(summary.totalRuns) runs."
        }
    }

    func updatePromptLabResultAnnotation(resultID: UUID, labels: Set<EpisodeAnnotationLabel>, note: String) {
        guard let index = promptLabResults.firstIndex(where: { $0.id == resultID }) else { return }
        promptLabResults[index].annotationLabels = labels
        promptLabResults[index].annotationNote = note
    }

    var selectedEpisode: IndexedEpisode? {
        episodes.first { $0.id == selectedEpisodeID }
    }

    var selectedPromptLabScenario: PromptLabScenario? {
        promptLabScenarios.first { $0.id == selectedPromptLabScenarioID }
    }

    var selectedPromptSet: PromptLabPromptSet? {
        promptLabPromptSets.first { $0.id == selectedPromptSetID }
    }

    var selectedScenarioResults: [PromptLabRunResult] {
        guard let selectedPromptLabScenarioID else { return [] }
        return promptLabResults.filter { $0.scenarioID == selectedPromptLabScenarioID }
    }

    func matrixSummary(for scenarioID: UUID?) -> PromptLabMatrixSummary {
        let results: [PromptLabRunResult]
        if let scenarioID {
            results = promptLabResults.filter { $0.scenarioID == scenarioID }
        } else {
            results = promptLabResults
        }

        let passed = results.filter { $0.pass == true }.count
        let failed = results.filter { $0.pass == false }.count
        let unmatched = results.filter { $0.pass == nil }.count
        return PromptLabMatrixSummary(
            totalRuns: results.count,
            passedRuns: passed,
            failedRuns: failed,
            unmatchedRuns: unmatched
        )
    }

    private func loadEpisodeDetails(episodeID: String, preserveDraftIfDirty: Bool) async throws {
        selectedEpisodeEvents = try await indexStore.loadEvents(for: episodeID)
        selectedEpisodeAttempts = await makeAttemptDetails(from: selectedEpisodeEvents)
        selectedEvaluationRuns = makeEvaluationRuns(
            from: selectedEpisodeEvents,
            attempts: selectedEpisodeAttempts
        )
        if let selectedEpisode = episodes.first(where: { $0.id == episodeID }) {
            let loadedDraft = AnnotationDraft(
                note: selectedEpisode.note,
                labels: Set(selectedEpisode.labels),
                pinned: selectedEpisode.pinned
            )
            let sameEpisode = lastLoadedEpisodeID == episodeID
            let hasUnsavedLocalChanges = sameEpisode && currentDraft != lastLoadedDraft

            if preserveDraftIfDirty == false || hasUnsavedLocalChanges == false {
                applyAnnotationDraft(loadedDraft)
            }

            lastLoadedDraft = loadedDraft
            lastLoadedEpisodeID = episodeID
        }
    }

    private var currentDraft: AnnotationDraft {
        AnnotationDraft(
            note: annotationNote,
            labels: selectedLabels,
            pinned: pinEpisode
        )
    }

    private func applyAnnotationDraft(_ draft: AnnotationDraft) {
        annotationNote = draft.note
        selectedLabels = draft.labels
        pinEpisode = draft.pinned
    }

    private func clearSelectionState() {
        selectedEpisodeEvents = []
        selectedEpisodeAttempts = []
        selectedEvaluationRuns = []
        applyAnnotationDraft(AnnotationDraft(note: "", labels: Set<EpisodeAnnotationLabel>(), pinned: false))
        lastLoadedDraft = nil
        lastLoadedEpisodeID = nil
    }

    private func makePromptLabScenario(
        from episode: IndexedEpisode,
        events: [IndexedEvent]
    ) throws -> PromptLabScenario {
        let telemetryEvents = events.compactMap(Self.decodeTelemetryEvent)
        let modelInput = telemetryEvents.compactMap(\.modelInput).last
        let parsedOutput = telemetryEvents.compactMap(\.parsedOutput).last
        let context = modelInput?.context

        let payloadHints = Self.extractPromptPayloadHints(path: episode.promptPayloadPath)

        return PromptLabScenario(
            name: "Imported: \(episode.title)",
            source: .telemetry,
            sourceEpisodeID: episode.id,
            appName: context?.appName ?? episode.appName,
            bundleIdentifier: context?.bundleIdentifier ?? "",
            windowTitle: context?.windowTitle ?? episode.windowTitle ?? "",
            timestamp: context?.timestamp ?? episode.startedAt,
            goals: modelInput?.goalsSummary ?? payloadHints.goals ?? "Imported telemetry scenario.",
            freeFormMemorySummary: payloadHints.freeFormMemory ?? "",
            policyMemorySummary: payloadHints.policySummary ?? "",
            policyMemoryJSON: payloadHints.policyMemoryJSON ?? "",
            recentSwitches: (context?.recentSwitches ?? []).map {
                PromptLabSwitchRecord(
                    fromAppName: $0.fromAppName ?? "",
                    toAppName: $0.toAppName,
                    toWindowTitle: $0.toWindowTitle ?? "",
                    timestamp: $0.timestamp
                )
            },
            recentActions: (context?.recentActions ?? []).map {
                PromptLabActionRecord(
                    kind: $0.kind,
                    message: $0.message ?? "",
                    timestamp: $0.timestamp
                )
            },
            usage: (context?.perAppDurations ?? []).map {
                PromptLabUsageRecord(appName: $0.appName, seconds: $0.seconds)
            },
            screenshotPath: episode.screenshotPath ?? "",
            appealText: "",
            heuristics: PromptLabHeuristics(
                clearlyProductive: modelInput?.heuristics.clearlyProductive ?? false,
                browser: modelInput?.heuristics.browser ?? Self.looksLikeBrowser(appName: episode.appName),
                helpfulWindowTitle: modelInput?.heuristics.helpfulWindowTitle ?? !(episode.windowTitle ?? "").isEmpty,
                periodicVisualReason: modelInput?.heuristics.periodicVisualReason ?? ""
            ),
            distraction: PromptLabDistractionState(
                stableSince: modelInput?.distraction.stableSince,
                lastAssessment: modelInput?.distraction.lastAssessment ?? parsedOutput?.assessment,
                consecutiveDistractedCount: modelInput?.distraction.consecutiveDistractedCount ?? 0,
                nextEvaluationAt: modelInput?.distraction.nextEvaluationAt
            ),
            expectedAssessment: nil,
            expectedAction: nil
        )
    }

    private static func decodeTelemetryEvent(from indexedEvent: IndexedEvent) -> TelemetryEvent? {
        guard let data = indexedEvent.rawJSON.data(using: .utf8) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(TelemetryEvent.self, from: data)
    }

    private static func looksLikeBrowser(appName: String) -> Bool {
        let lowered = appName.lowercased()
        return lowered.contains("chrome")
            || lowered.contains("safari")
            || lowered.contains("arc")
            || lowered.contains("firefox")
            || lowered.contains("browser")
    }

    private static func extractPromptPayloadHints(path: String?) -> (
        goals: String?,
        freeFormMemory: String?,
        policySummary: String?,
        policyMemoryJSON: String?
    ) {
        guard let path,
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let jsonObject = try? JSONSerialization.jsonObject(with: data) else {
            return (nil, nil, nil, nil)
        }

        return (
            findString(in: jsonObject, matching: ["goals", "goalsSummary"]),
            findString(in: jsonObject, matching: ["memory", "freeFormMemory", "free_form_memory"]),
            findString(in: jsonObject, matching: ["policySummary", "policy_summary"]),
            findJSON(in: jsonObject, matching: ["policyMemory", "policy_memory"])
        )
    }

    private static func findString(in object: Any, matching keys: Set<String>) -> String? {
        if let dictionary = object as? [String: Any] {
            for (key, value) in dictionary {
                if keys.contains(key), let string = value as? String, !string.cleanedSingleLine.isEmpty {
                    return string
                }
                if let nested = findString(in: value, matching: keys) {
                    return nested
                }
            }
        } else if let array = object as? [Any] {
            for value in array {
                if let nested = findString(in: value, matching: keys) {
                    return nested
                }
            }
        }
        return nil
    }

    private static func findJSON(in object: Any, matching keys: Set<String>) -> String? {
        if let dictionary = object as? [String: Any] {
            for (key, value) in dictionary {
                if keys.contains(key),
                   JSONSerialization.isValidJSONObject(value),
                   let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]),
                   let string = String(data: data, encoding: .utf8) {
                    return string
                }
                if let nested = findJSON(in: value, matching: keys) {
                    return nested
                }
            }
        } else if let array = object as? [Any] {
            for value in array {
                if let nested = findJSON(in: value, matching: keys) {
                    return nested
                }
            }
        }
        return nil
    }

    private static func findStringArray(in object: Any, matching keys: Set<String>) -> [String] {
        if let dictionary = object as? [String: Any] {
            for (key, value) in dictionary {
                if keys.contains(key), let values = value as? [String] {
                    return values.map(\.cleanedSingleLine).filter { !$0.isEmpty }
                }
                let nested = findStringArray(in: value, matching: keys)
                if !nested.isEmpty {
                    return nested
                }
            }
        } else if let array = object as? [Any] {
            for value in array {
                let nested = findStringArray(in: value, matching: keys)
                if !nested.isEmpty {
                    return nested
                }
            }
        }
        return []
    }

    private func makeAttemptDetails(from indexedEvents: [IndexedEvent]) async -> [IndexedModelAttempt] {
        var attemptsByID: [String: IndexedModelAttempt] = [:]

        for indexedEvent in indexedEvents {
            guard let event = Self.decodeTelemetryEvent(from: indexedEvent) else { continue }

            if let modelInput = event.modelInput {
                let key = Self.attemptKey(
                    evaluationID: modelInput.evaluationID,
                    promptMode: modelInput.promptMode
                )
                var attempt = attemptsByID[key] ?? IndexedModelAttempt(
                    evaluationID: modelInput.evaluationID,
                    promptMode: modelInput.promptMode,
                    timestamp: indexedEvent.timestamp,
                    promptTemplatePath: nil,
                    promptPayloadPath: nil,
                    renderedPromptPath: nil,
                    runtimePath: nil,
                    modelIdentifier: nil,
                    runtimeOptions: nil,
                    stdoutPath: nil,
                    stderrPath: nil,
                    stdoutPreview: nil,
                    stderrPreview: nil,
                    parsedOutputJSON: nil
                )
                if let template = modelInput.promptTemplateArtifact {
                    attempt.promptTemplatePath = await telemetryStore.absoluteArtifactURL(
                        for: template,
                        sessionID: indexedEvent.sessionID
                    ).path
                }
                if let payload = modelInput.promptPayloadArtifact {
                    attempt.promptPayloadPath = await telemetryStore.absoluteArtifactURL(
                        for: payload,
                        sessionID: indexedEvent.sessionID
                    ).path
                }
                if let renderedPrompt = modelInput.renderedPromptArtifact {
                    attempt.renderedPromptPath = await telemetryStore.absoluteArtifactURL(
                        for: renderedPrompt,
                        sessionID: indexedEvent.sessionID
                    ).path
                }
                attemptsByID[key] = attempt
            }

            if let modelOutput = event.modelOutput {
                let key = Self.attemptKey(
                    evaluationID: modelOutput.evaluationID,
                    promptMode: modelOutput.promptMode
                )
                var attempt = attemptsByID[key] ?? IndexedModelAttempt(
                    evaluationID: modelOutput.evaluationID,
                    promptMode: modelOutput.promptMode,
                    timestamp: indexedEvent.timestamp,
                    promptTemplatePath: nil,
                    promptPayloadPath: nil,
                    renderedPromptPath: nil,
                    runtimePath: nil,
                    modelIdentifier: nil,
                    runtimeOptions: nil,
                    stdoutPath: nil,
                    stderrPath: nil,
                    stdoutPreview: nil,
                    stderrPreview: nil,
                    parsedOutputJSON: nil
                )
                attempt.runtimePath = modelOutput.runtimePath
                attempt.modelIdentifier = modelOutput.modelIdentifier
                attempt.runtimeOptions = modelOutput.runtimeOptions
                if let stdoutArtifact = modelOutput.stdoutArtifact {
                    attempt.stdoutPath = await telemetryStore.absoluteArtifactURL(
                        for: stdoutArtifact,
                        sessionID: indexedEvent.sessionID
                    ).path
                }
                if let stderrArtifact = modelOutput.stderrArtifact {
                    attempt.stderrPath = await telemetryStore.absoluteArtifactURL(
                        for: stderrArtifact,
                        sessionID: indexedEvent.sessionID
                    ).path
                }
                attempt.stdoutPreview = modelOutput.stdoutPreview.cleanedSingleLine.isEmpty
                    ? nil
                    : modelOutput.stdoutPreview
                attempt.stderrPreview = modelOutput.stderrPreview.cleanedSingleLine.isEmpty
                    ? nil
                    : modelOutput.stderrPreview
                attemptsByID[key] = attempt
            }

            if let policy = event.policy,
               let parsedJSON = Self.prettyJSONString(for: policy.model) {
                let promptMode = Self.decisionPromptMode(
                    for: policy.evaluationID,
                    attempts: attemptsByID
                )
                let key = Self.attemptKey(
                    evaluationID: policy.evaluationID,
                    promptMode: promptMode
                )
                var attempt = attemptsByID[key] ?? IndexedModelAttempt(
                    evaluationID: policy.evaluationID,
                    promptMode: promptMode,
                    timestamp: indexedEvent.timestamp,
                    promptTemplatePath: nil,
                    promptPayloadPath: nil,
                    renderedPromptPath: nil,
                    runtimePath: nil,
                    modelIdentifier: nil,
                    runtimeOptions: nil,
                    stdoutPath: nil,
                    stderrPath: nil,
                    stdoutPreview: nil,
                    stderrPreview: nil,
                    parsedOutputJSON: nil
                )
                attempt.parsedOutputJSON = parsedJSON
                attemptsByID[key] = attempt
            }
        }

        return attemptsByID.values.sorted { lhs, rhs in
            if lhs.timestamp == rhs.timestamp {
                return lhs.promptMode < rhs.promptMode
            }
            return lhs.timestamp < rhs.timestamp
        }
    }

    private static func attemptKey(evaluationID: String, promptMode: String) -> String {
        "\(evaluationID):\(promptMode)"
    }

    private static func decisionPromptMode(
        for evaluationID: String,
        attempts: [String: IndexedModelAttempt]
    ) -> String {
        let promptModes = attempts.values
            .filter { $0.evaluationID == evaluationID }
            .map(\.promptMode)

        if let legacyDecision = promptModes.first(where: { $0 == "legacy_decision" || $0 == "legacy_decision_fallback" }) {
            return legacyDecision
        }
        if let decision = promptModes.first(where: { $0 == "decision" }) {
            return decision
        }
        return promptModes.first ?? "decision"
    }

    private static func prettyJSONString<T: Encodable>(for value: T) -> String? {
        guard let data = try? makeJSONEncoder().encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func makeEvaluationRuns(
        from indexedEvents: [IndexedEvent],
        attempts: [IndexedModelAttempt]
    ) -> [IndexedEvaluationRun] {
        var requestedAtByEvaluationID: [String: Date] = [:]
        var policyByEvaluationID: [String: PolicyDecisionRecord] = [:]

        for indexedEvent in indexedEvents {
            guard let event = Self.decodeTelemetryEvent(from: indexedEvent) else { continue }
            if let evaluation = event.evaluation {
                requestedAtByEvaluationID[evaluation.evaluationID] = indexedEvent.timestamp
            }
            if let policy = event.policy {
                policyByEvaluationID[policy.evaluationID] = policy
            }
        }

        return Dictionary(grouping: attempts, by: \.evaluationID)
            .map { evaluationID, groupedAttempts in
                let stages = groupedAttempts
                    .map(Self.makeEvaluationStage)
                    .sorted { lhs, rhs in
                        let left = Self.primarySortOrder(for: lhs)
                        let right = Self.primarySortOrder(for: rhs)
                        if left == right {
                            return lhs.timestamp < rhs.timestamp
                        }
                        return left < right
                    }

                let (primaryStages, secondaryStages) = Self.partitionStages(stages)
                let requestedAt = requestedAtByEvaluationID[evaluationID]
                    ?? groupedAttempts.map(\.timestamp).min()
                    ?? .distantPast

                return IndexedEvaluationRun(
                    evaluationID: evaluationID,
                    requestedAt: requestedAt,
                    outcomeSummary: Self.outcomeSummary(for: policyByEvaluationID[evaluationID]),
                    primaryStages: primaryStages,
                    secondaryStages: secondaryStages
                )
            }
            .sorted { $0.requestedAt > $1.requestedAt }
    }

    private static func makeEvaluationStage(from attempt: IndexedModelAttempt) -> IndexedEvaluationStage {
        let promptMode = attempt.promptMode
        let kind = stageKind(for: promptMode)
        let payloadObject = jsonObject(at: attempt.promptPayloadPath)

        var summary = "No parsed output."
        var details: [InspectorDetailRow] = []

        switch promptMode {
        case "perception_vision", "perception_title", "legacy_perception_vision":
            let output = decodeJSONFile(MonitoringPerceptionEnvelope.self, path: attempt.stdoutPath)
            let activitySummary = output.map { $0.activitySummary.cleanedSingleLine } ?? ""
            summary = activitySummary.isEmpty ? "No parsed perception output." : activitySummary
            if let focusGuess = output?.focusGuess {
                details.append(InspectorDetailRow(label: "Focus guess", value: focusGuess.rawValue))
            }
            let tags = output?.reasonTags ?? []
            if !tags.isEmpty {
                details.append(InspectorDetailRow(label: "Reason tags", value: tags.joined(separator: ", ")))
            }
            let notes = (output?.notes ?? []).map(\.cleanedSingleLine).filter { !$0.isEmpty }
            if !notes.isEmpty {
                details.append(InspectorDetailRow(label: "Notes", value: notes.joined(separator: "\n")))
            }
            let contextParts = [
                findString(in: payloadObject as Any, matching: ["appName", "frontmostApp"]),
                findString(in: payloadObject as Any, matching: ["windowTitle"])
            ].compactMap { value -> String? in
                guard let value, !value.cleanedSingleLine.isEmpty else { return nil }
                return value.cleanedSingleLine
            }
            if !contextParts.isEmpty {
                details.append(InspectorDetailRow(label: "Context", value: contextParts.joined(separator: " • ")))
            }

        case "decision", "legacy_decision", "decision_fallback", "legacy_decision_fallback":
            let decision = decodeDecisionRecord(from: attempt)
            summary = formattedDecisionSummary(from: decision) ?? "No parsed decision output."
            if let nudge = decision?.nudge?.cleanedSingleLine, !nudge.isEmpty {
                details.append(InspectorDetailRow(label: "Inline nudge", value: nudge))
            }
            if let abstainReason = decision?.abstainReason?.cleanedSingleLine, !abstainReason.isEmpty {
                details.append(InspectorDetailRow(label: "Abstain reason", value: abstainReason))
            }
            if let goals = findString(in: payloadObject as Any, matching: ["goals", "goalsSummary"]),
               !goals.cleanedSingleLine.isEmpty {
                details.append(InspectorDetailRow(label: "Goals", value: goals.cleanedSingleLine))
            }
            if let memory = findString(in: payloadObject as Any, matching: ["freeFormMemory", "memory", "free_form_memory"]),
               !memory.cleanedSingleLine.isEmpty {
                // Memory is multiline (timestamps + bullets) — preserve newlines for readability.
                details.append(InspectorDetailRow(label: "Memory", value: memory))
            }
            let recentChat = findStringArray(in: payloadObject as Any, matching: ["recentUserMessages", "recent_user_messages"])
            if !recentChat.isEmpty {
                details.append(InspectorDetailRow(
                    label: "Recent chat",
                    value: recentChat.map { "• \($0.cleanedSingleLine)" }.joined(separator: "\n")
                ))
            }
            if let policySummary = findString(in: payloadObject as Any, matching: ["policySummary", "policy_summary"]),
               !policySummary.cleanedSingleLine.isEmpty {
                details.append(InspectorDetailRow(label: "Policy context", value: policySummary))
            }
            let contextParts = [
                findString(in: payloadObject as Any, matching: ["appName", "frontmostApp"]),
                findString(in: payloadObject as Any, matching: ["windowTitle"])
            ].compactMap { value -> String? in
                guard let value, !value.cleanedSingleLine.isEmpty else { return nil }
                return value.cleanedSingleLine
            }
            if !contextParts.isEmpty {
                details.append(InspectorDetailRow(label: "Context", value: contextParts.joined(separator: " • ")))
            }
            if let perception = findString(in: payloadObject as Any, matching: ["activitySummary", "activity_summary", "sceneSummary", "scene_summary"]),
               !perception.cleanedSingleLine.isEmpty {
                details.append(InspectorDetailRow(label: "Perception passed in", value: perception.cleanedSingleLine))
            }

        case "nudge_copy":
            let nudge = decodeJSONFile(MonitoringNudgeEnvelope.self, path: attempt.stdoutPath)?.nudge?.cleanedSingleLine
            summary = (nudge?.isEmpty == false) ? nudge! : "No nudge copy returned."
            if let goals = findString(in: payloadObject as Any, matching: ["goals"]),
               !goals.cleanedSingleLine.isEmpty {
                details.append(InspectorDetailRow(label: "Goals", value: goals.cleanedSingleLine))
            }
            if let memory = findString(in: payloadObject as Any, matching: ["freeFormMemory", "free_form_memory", "memory"]),
               !memory.cleanedSingleLine.isEmpty {
                details.append(InspectorDetailRow(label: "Memory", value: memory))
            }
            let recentChatNudge = findStringArray(in: payloadObject as Any, matching: ["recentUserMessages", "recent_user_messages"])
            if !recentChatNudge.isEmpty {
                details.append(InspectorDetailRow(
                    label: "Recent chat",
                    value: recentChatNudge.map { "• \($0.cleanedSingleLine)" }.joined(separator: "\n")
                ))
            }
            if let policySummary = findString(in: payloadObject as Any, matching: ["policySummary", "policy_summary"]),
               !policySummary.cleanedSingleLine.isEmpty {
                details.append(InspectorDetailRow(label: "Policy context", value: policySummary))
            }
            let contextParts = [
                findString(in: payloadObject as Any, matching: ["appName"]),
                findString(in: payloadObject as Any, matching: ["windowTitle"])
            ].compactMap { value -> String? in
                guard let value, !value.cleanedSingleLine.isEmpty else { return nil }
                return value.cleanedSingleLine
            }
            if !contextParts.isEmpty {
                details.append(InspectorDetailRow(label: "Context", value: contextParts.joined(separator: " • ")))
            }
            if let perception = findString(in: payloadObject as Any, matching: ["visionPerception", "titlePerception"]),
               !perception.cleanedSingleLine.isEmpty {
                details.append(InspectorDetailRow(label: "Perception passed in", value: perception.cleanedSingleLine))
            }
            let recentNudges = findStringArray(in: payloadObject as Any, matching: ["recentNudges"])
            if !recentNudges.isEmpty {
                details.append(InspectorDetailRow(label: "Recent nudges", value: recentNudges.joined(separator: "\n")))
            }

        case "appeal_review":
            let appeal = decodeJSONFile(MonitoringAppealEnvelope.self, path: attempt.stdoutPath)
            let appealMessage = appeal.map { $0.message.cleanedSingleLine } ?? ""
            summary = [
                appeal?.decision.rawValue,
                appealMessage
            ]
            .compactMap { value -> String? in
                guard let value, !value.isEmpty else { return nil }
                return value
            }
            .joined(separator: " • ")
            if let appealText = findString(in: payloadObject as Any, matching: ["appealText"]),
               !appealText.cleanedSingleLine.isEmpty {
                details.append(InspectorDetailRow(label: "Appeal", value: appealText))
            }

        default:
            summary = attempt.stdoutPreview ?? "No parsed output."
        }

        return IndexedEvaluationStage(
            evaluationID: attempt.evaluationID,
            promptMode: promptMode,
            timestamp: attempt.timestamp,
            kind: kind,
            title: stageTitle(for: promptMode),
            summary: summary,
            details: details,
            promptTemplatePath: attempt.promptTemplatePath,
            promptPayloadPath: attempt.promptPayloadPath,
            renderedPromptPath: attempt.renderedPromptPath,
            runtimePath: attempt.runtimePath,
            modelIdentifier: attempt.modelIdentifier,
            runtimeOptions: attempt.runtimeOptions,
            stdoutPath: attempt.stdoutPath,
            stderrPath: attempt.stderrPath,
            stdoutPreview: attempt.stdoutPreview,
            stderrPreview: attempt.stderrPreview
        )
    }

    private static func partitionStages(
        _ stages: [IndexedEvaluationStage]
    ) -> ([IndexedEvaluationStage], [IndexedEvaluationStage]) {
        var primary: [IndexedEvaluationStage] = []
        var secondary: [IndexedEvaluationStage] = []
        var hasPerception = false
        var hasDecision = false
        var hasNudge = false

        for stage in stages {
            switch stage.kind {
            case .perception where !hasPerception:
                primary.append(stage)
                hasPerception = true
            case .decision where !hasDecision:
                primary.append(stage)
                hasDecision = true
            case .nudge where !hasNudge:
                primary.append(stage)
                hasNudge = true
            default:
                secondary.append(stage)
            }
        }

        return (primary, secondary)
    }

    private static func primarySortOrder(for stage: IndexedEvaluationStage) -> Int {
        switch stage.kind {
        case .perception:
            return stage.promptMode == "perception_vision" ? 0 : 1
        case .decision:
            return stage.promptMode == "decision" ? 10 : 11
        case .nudge:
            return 20
        case .additional:
            return 30
        }
    }

    private static func stageKind(for promptMode: String) -> IndexedEvaluationStageKind {
        switch promptMode {
        case "perception_vision", "perception_title", "legacy_perception_vision":
            return .perception
        case "decision", "legacy_decision", "decision_fallback", "legacy_decision_fallback":
            return .decision
        case "nudge_copy":
            return .nudge
        default:
            return .additional
        }
    }

    private static func stageTitle(for promptMode: String) -> String {
        switch promptMode {
        case "perception_vision":
            return "Perception"
        case "perception_title":
            return "Title Perception"
        case "legacy_perception_vision":
            return "Legacy Perception"
        case "decision":
            return "Decision"
        case "legacy_decision":
            return "Legacy Decision"
        case "decision_fallback", "legacy_decision_fallback":
            return "Fallback Decision"
        case "nudge_copy":
            return "Nudge"
        case "appeal_review":
            return "Appeal Review"
        default:
            return promptMode.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    private static func decodeDecisionRecord(from attempt: IndexedModelAttempt) -> ModelOutputParsedRecord? {
        if let parsedOutputJSON = attempt.parsedOutputJSON {
            return decodeJSONString(ModelOutputParsedRecord.self, string: parsedOutputJSON)
        }
        if let envelope = decodeJSONFile(MonitoringDecisionEnvelope.self, path: attempt.stdoutPath) {
            return ModelOutputParsedRecord(
                assessment: envelope.assessment,
                suggestedAction: envelope.suggestedAction,
                confidence: envelope.confidence,
                reasonTags: envelope.reasonTags,
                nudge: envelope.nudge,
                abstainReason: envelope.abstainReason
            )
        }
        return nil
    }

    private static func formattedDecisionSummary(from decision: ModelOutputParsedRecord?) -> String? {
        guard let decision else { return nil }
        var parts = [decision.assessment.rawValue, decision.suggestedAction.rawValue]
        if let confidence = decision.confidence {
            parts.append("\(Int((confidence * 100).rounded()))%")
        }
        return parts.joined(separator: " • ")
    }

    private static func outcomeSummary(for policy: PolicyDecisionRecord?) -> String {
        guard let policy else { return "Pending" }
        var parts = [
            policy.model.assessment.rawValue,
            policy.finalAction.kind.rawValue
        ]
        if let blockReason = policy.blockReason?.cleanedSingleLine, !blockReason.isEmpty {
            parts.append(blockReason)
        }
        return parts.joined(separator: " • ")
    }

    private static func decodeJSONFile<T: Decodable>(_ type: T.Type, path: String?) -> T? {
        guard let path,
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            return nil
        }
        let decoder = makeJSONDecoder()
        return try? decoder.decode(type, from: data)
    }

    private static func decodeJSONString<T: Decodable>(_ type: T.Type, string: String?) -> T? {
        guard let string,
              let data = string.data(using: .utf8) else {
            return nil
        }
        let decoder = makeJSONDecoder()
        return try? decoder.decode(type, from: data)
    }

    private static func jsonObject(at path: String?) -> Any? {
        guard let path,
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            return nil
        }
        return try? JSONSerialization.jsonObject(with: data)
    }

    private func schedulePersistPromptLabState() {
        guard !isHydratingPromptLabState else { return }

        promptLabSaveTask?.cancel()
        promptLabSaveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard let self, !Task.isCancelled else { return }
            self.persistPromptLabState()
        }
    }

    private func loadPersistedPromptLabState(fileManager: FileManager) {
        guard let data = try? Data(contentsOf: promptLabPersistenceURL),
              let persisted = try? Self.makeJSONDecoder().decode(PromptLabPersistenceState.self, from: data) else {
            normalizePromptLabSelections()
            return
        }

        isHydratingPromptLabState = true
        defer { isHydratingPromptLabState = false }

        let normalizedPromptSets = normalizePromptSets(persisted.promptSets)
        let normalizedScenarios = persisted.scenarios.isEmpty ? [.syntheticDefault] : persisted.scenarios
        let validScenarioIDs = Set(normalizedScenarios.map(\.id))
        let validPipelineIDs = Set(PromptLabPipelineProfile.defaults.map(\.id))
        let validRuntimeIDs = Set(PromptLabRuntimeProfile.defaults.map(\.id))

        promptLabScenarios = normalizedScenarios
        selectedPromptLabScenarioID = validScenarioIDs.contains(persisted.selectedScenarioID ?? UUID())
            ? persisted.selectedScenarioID
            : normalizedScenarios.first?.id
        promptLabPromptSets = normalizedPromptSets
        selectedPromptSetID = normalizedPromptSets.contains(where: { $0.id == persisted.selectedPromptSetID })
            ? persisted.selectedPromptSetID
            : normalizedPromptSets.first?.id ?? ""
        selectedPromptStage = PromptLabStage.allCases.contains(persisted.selectedPromptStage)
            ? persisted.selectedPromptStage
            : .decision
        selectedPipelineIDs = Set(persisted.selectedPipelineIDs.filter { validPipelineIDs.contains($0) })
        if selectedPipelineIDs.isEmpty, let first = PromptLabPipelineProfile.defaults.first?.id {
            selectedPipelineIDs = [first]
        }
        selectedRuntimeProfileIDs = Set(persisted.selectedRuntimeProfileIDs.filter { validRuntimeIDs.contains($0) })
        if selectedRuntimeProfileIDs.isEmpty, let first = PromptLabRuntimeProfile.defaults.first?.id {
            selectedRuntimeProfileIDs = [first]
        }
        promptLabRuntimePath = persisted.runtimePath.cleanedSingleLine.isEmpty
            ? PromptLabRunner.defaultRuntimePath
            : persisted.runtimePath.cleanedSingleLine
        promptLabResults = persisted.results.filter { validScenarioIDs.contains($0.scenarioID) }
        normalizePromptLabSelections()
    }

    private func persistPromptLabState() {
        let state = PromptLabPersistenceState(
            scenarios: promptLabScenarios,
            selectedScenarioID: selectedPromptLabScenarioID,
            promptSets: promptLabPromptSets,
            selectedPromptSetID: selectedPromptSetID,
            selectedPromptStage: selectedPromptStage,
            selectedPipelineIDs: Array(selectedPipelineIDs).sorted(),
            selectedRuntimeProfileIDs: Array(selectedRuntimeProfileIDs).sorted(),
            runtimePath: promptLabRuntimePath.cleanedSingleLine,
            results: promptLabResults
        )

        do {
            try FileManager.default.createDirectory(
                at: promptLabPersistenceURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try Self.makeJSONEncoder().encode(state)
            try data.write(to: promptLabPersistenceURL, options: .atomic)
        } catch {
            promptLabStatusText = "Prompt Lab save failed: \(error.localizedDescription)"
        }
    }

    private func normalizePromptLabSelections() {
        if promptLabScenarios.isEmpty {
            promptLabScenarios = [.syntheticDefault]
        }
        if promptLabScenarios.contains(where: { $0.id == selectedPromptLabScenarioID }) == false {
            selectedPromptLabScenarioID = promptLabScenarios.first?.id
        }

        promptLabPromptSets = normalizePromptSets(promptLabPromptSets)
        if promptLabPromptSets.contains(where: { $0.id == selectedPromptSetID }) == false {
            selectedPromptSetID = promptLabPromptSets.first?.id ?? ""
        }

        let validPipelineIDs = Set(PromptLabPipelineProfile.defaults.map(\.id))
        selectedPipelineIDs = selectedPipelineIDs.filter { validPipelineIDs.contains($0) }
        if selectedPipelineIDs.isEmpty, let first = PromptLabPipelineProfile.defaults.first?.id {
            selectedPipelineIDs = [first]
        }

        let validRuntimeIDs = Set(PromptLabRuntimeProfile.defaults.map(\.id))
        selectedRuntimeProfileIDs = selectedRuntimeProfileIDs.filter { validRuntimeIDs.contains($0) }
        if selectedRuntimeProfileIDs.isEmpty, let first = PromptLabRuntimeProfile.defaults.first?.id {
            selectedRuntimeProfileIDs = [first]
        }
    }

    private func normalizePromptSets(_ promptSets: [PromptLabPromptSet]) -> [PromptLabPromptSet] {
        var normalized: [PromptLabPromptSet] = []
        let defaultSets = PromptLabPromptSet.defaults

        for defaultSet in defaultSets {
            if let persisted = promptSets.first(where: { $0.id == defaultSet.id }) {
                normalized.append(normalizePromptSet(persisted, fallback: defaultSet))
            } else {
                normalized.append(defaultSet)
            }
        }

        for promptSet in promptSets where defaultSets.contains(where: { $0.id == promptSet.id }) == false {
            normalized.append(normalizePromptSet(promptSet, fallback: nil))
        }

        return normalized
    }

    private func normalizePromptSet(
        _ promptSet: PromptLabPromptSet,
        fallback: PromptLabPromptSet?
    ) -> PromptLabPromptSet {
        var normalized = fallback ?? PromptLabPromptSet(
            id: promptSet.id,
            name: promptSet.name,
            summary: promptSet.summary,
            prompts: PromptLabStage.allCases.map {
                PromptLabStagePrompt(stage: $0, systemPrompt: "", userTemplate: "{{PAYLOAD_JSON}}")
            }
        )

        normalized.name = promptSet.name
        normalized.summary = promptSet.summary

        for stage in PromptLabStage.allCases {
            let persistedPrompt = promptSet.prompts.first(where: { $0.stage == stage })
            let stagePrompt = persistedPrompt ?? fallback?.prompt(for: stage) ?? normalized.prompt(for: stage)
            normalized.update(
                stage: stage,
                systemPrompt: stagePrompt.systemPrompt,
                userTemplate: stagePrompt.userTemplate
            )
        }

        return normalized
    }

    private static func makeJSONEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func makeJSONDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

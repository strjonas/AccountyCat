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
    @Published var annotationNote = ""
    @Published var selectedLabels: Set<EpisodeAnnotationLabel> = []
    @Published var pinEpisode = false
    @Published var statusText = "Loading telemetry."
    @Published var promptLabScenarios: [PromptLabScenario] = [.syntheticDefault]
    @Published var selectedPromptLabScenarioID: UUID? = PromptLabScenario.syntheticDefault.id
    @Published var promptLabPromptSets: [PromptLabPromptSet] = PromptLabPromptSet.defaults
    @Published var selectedPromptSetID: String = PromptLabPromptSet.defaults.first?.id ?? ""
    @Published var selectedPromptStage: PromptLabStage = .decision
    @Published var selectedPipelineIDs: Set<String> = [PromptLabPipelineProfile.defaults.first?.id ?? ""]
    @Published var selectedRuntimeProfileIDs: Set<String> = [PromptLabRuntimeProfile.defaults.first?.id ?? ""]
    @Published var promptLabRuntimePath = PromptLabRunner.defaultRuntimePath
    @Published var promptLabResults: [PromptLabRunResult] = []
    @Published var promptLabStatusText = "Prompt Lab ready."
    @Published var promptLabIsRunning = false

    private let indexStore = TelemetryIndexStore()
    private let telemetryStore = TelemetryStore.shared
    private let promptLabRunner = PromptLabRunner()
    private var refreshTask: Task<Void, Never>?
    private var lastLoadedDraft: AnnotationDraft?
    private var lastLoadedEpisodeID: String?

    private struct AnnotationDraft: Equatable {
        var note: String
        var labels: Set<EpisodeAnnotationLabel>
        var pinned: Bool
    }

    deinit {
        refreshTask?.cancel()
    }

    func start() {
        guard refreshTask == nil else { return }

        refreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.refresh()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    func refresh() async {
        do {
            try await indexStore.refresh()
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
}

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
    @Published var episodes: [IndexedEpisode] = []
    @Published var selectedEpisodeID: String?
    @Published var selectedEpisodeEvents: [IndexedEvent] = []
    @Published var annotationNote = ""
    @Published var selectedLabels: Set<EpisodeAnnotationLabel> = []
    @Published var pinEpisode = false
    @Published var statusText = "Loading telemetry."

    private let indexStore = TelemetryIndexStore()
    private let telemetryStore = TelemetryStore.shared
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

    var selectedEpisode: IndexedEpisode? {
        episodes.first { $0.id == selectedEpisodeID }
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
}

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
                try await loadEpisodeDetails(episodeID: selectedEpisodeID)
            } else {
                selectedEpisodeEvents = []
                annotationNote = ""
                selectedLabels = []
                pinEpisode = false
            }

            statusText = episodes.isEmpty ? "No telemetry episodes yet." : "Loaded \(episodes.count) episodes."
        } catch {
            statusText = error.localizedDescription
        }
    }

    func selectionDidChange() async {
        guard let selectedEpisodeID else {
            selectedEpisodeEvents = []
            annotationNote = ""
            selectedLabels = []
            pinEpisode = false
            return
        }

        do {
            try await loadEpisodeDetails(episodeID: selectedEpisodeID)
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

        Task { @MainActor [weak self] in
            guard let self else { return }
            try? await self.telemetryStore.appendAnnotation(annotation, episode: selectedEpisode.episodeRecord)
            await self.refresh()
        }
    }

    func openFile(_ path: String?) {
        guard let path else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    var selectedEpisode: IndexedEpisode? {
        episodes.first { $0.id == selectedEpisodeID }
    }

    private func loadEpisodeDetails(episodeID: String) async throws {
        selectedEpisodeEvents = try await indexStore.loadEvents(for: episodeID)
        if let selectedEpisode = episodes.first(where: { $0.id == episodeID }) {
            annotationNote = selectedEpisode.note
            selectedLabels = Set(selectedEpisode.labels)
            pinEpisode = selectedEpisode.pinned
        }
    }
}

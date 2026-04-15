//
//  ACInspectorApp.swift
//  ACInspector
//
//  Created by Codex on 13.04.26.
//

import AppKit
import SwiftUI

@main
struct ACInspectorApp: App {
    @StateObject private var controller = InspectorController()

    var body: some Scene {
        WindowGroup("AC Inspector") {
            InspectorRootView()
                .environmentObject(controller)
                .onAppear { controller.start() }
        }
        .windowResizability(.contentSize)
    }
}

private struct InspectorRootView: View {
    @EnvironmentObject private var controller: InspectorController

    var body: some View {
        NavigationSplitView {
            List(selection: Binding(
                get: { controller.selectedEpisodeID },
                set: { id in
                    controller.selectedEpisodeID = id
                }
            )) {
                ForEach(controller.episodes) { episode in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(episode.appName)
                            .font(.headline)
                        Text(episode.title)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                        Text(episode.startedAt.formatted(date: .abbreviated, time: .standard))
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                        if let strategySummary = episode.strategySummary, !strategySummary.isEmpty {
                            Text(strategySummary)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .tag(episode.id)
                }
            }
            .navigationTitle("Episodes")
        } detail: {
            if let episode = controller.selectedEpisode {
                InspectorDetailView(episode: episode)
            } else {
                ContentUnavailableView("No Episode Selected", systemImage: "square.stack.3d.up.slash")
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Refresh") {
                    Task { @MainActor in
                        await controller.refresh()
                    }
                }
            }
            ToolbarItem(placement: .automatic) {
                Text(controller.statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .task(id: controller.selectedEpisodeID) {
            await controller.selectionDidChange()
        }
        .frame(minWidth: 1200, minHeight: 760)
    }
}

private struct InspectorDetailView: View {
    @EnvironmentObject private var controller: InspectorController
    let episode: IndexedEpisode

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                screenshotSection
                promptSection
                modelSection
                annotationSection
                timelineSection
            }
            .padding(24)
        }
        .navigationTitle(episode.appName)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(episode.title)
                .font(.title2.weight(.semibold))
            Text("Session: \(episode.sessionID)")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            Text("Started: \(episode.startedAt.formatted(date: .abbreviated, time: .standard))")
                .font(.callout)
            if let endedAt = episode.endedAt {
                Text("Ended: \(endedAt.formatted(date: .abbreviated, time: .standard))")
                    .font(.callout)
            }
            if !episode.labels.isEmpty {
                Text(episode.labels.map(\.rawValue).joined(separator: ", "))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            if let reactionSummary = episode.reactionSummary, !reactionSummary.isEmpty {
                Text("Reactions: \(reactionSummary)")
                    .font(.callout)
            }
            if let strategySummary = episode.strategySummary, !strategySummary.isEmpty {
                Text("Strategy: \(strategySummary)")
                    .font(.callout)
            }
            if let algorithmVersion = episode.algorithmVersion, !algorithmVersion.isEmpty {
                Text("Algorithm version: \(algorithmVersion)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            if let experimentArm = episode.experimentArm, !experimentArm.isEmpty {
                Text("Experiment arm: \(experimentArm)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var screenshotSection: some View {
        GroupBox("Screenshot") {
            VStack(alignment: .leading, spacing: 12) {
                if let screenshotPath = episode.screenshotPath,
                   let image = NSImage(contentsOfFile: screenshotPath) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: 420)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
                        )
                    Button("Open Screenshot") {
                        controller.openFile(screenshotPath)
                    }
                } else {
                    Text("No persisted screenshot for this episode.")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var promptSection: some View {
        GroupBox("Prompt Inputs") {
            VStack(alignment: .leading, spacing: 12) {
                filePreview(title: "Prompt payload", path: episode.promptPayloadPath)
                filePreview(title: "Rendered prompt", path: episode.renderedPromptPath)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var modelSection: some View {
        GroupBox("Model Output") {
            if let modelOutputJSON = episode.modelOutputJSON, !modelOutputJSON.isEmpty {
                ScrollView {
                    Text(modelOutputJSON)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(minHeight: 140)
            } else {
                Text("No parsed output stored for this episode.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var annotationSection: some View {
        GroupBox("Annotation") {
            VStack(alignment: .leading, spacing: 12) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 10)], spacing: 10) {
                    ForEach(EpisodeAnnotationLabel.allCases, id: \.self) { label in
                        Toggle(
                            isOn: Binding(
                                get: { controller.selectedLabels.contains(label) },
                                set: { isOn in
                                    if isOn {
                                        controller.selectedLabels.insert(label)
                                    } else {
                                        controller.selectedLabels.remove(label)
                                    }
                                }
                            )
                        ) {
                            Text(label.rawValue)
                                .font(.caption.monospaced())
                        }
                        .toggleStyle(.checkbox)
                    }
                }

                Toggle("Pin episode", isOn: $controller.pinEpisode)
                    .toggleStyle(.switch)

                TextEditor(text: $controller.annotationNote)
                    .font(.system(size: 13, design: .monospaced))
                    .frame(minHeight: 110)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
                    )

                Button("Save annotation") {
                    controller.saveAnnotation()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var timelineSection: some View {
        GroupBox("Timeline") {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(controller.selectedEpisodeEvents) { event in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(event.kind)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                        Text(event.summary)
                            .font(.body)
                        Text(event.timestamp.formatted(date: .abbreviated, time: .standard))
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                        Divider()
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func filePreview(title: String, path: String?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.headline)
                Spacer()
                Button("Open") {
                    controller.openFile(path)
                }
                .disabled(path == nil)
            }

            if let path,
               let contents = try? String(contentsOfFile: path, encoding: .utf8) {
                ScrollView {
                    Text(contents)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(minHeight: 140)
            } else {
                Text("No file stored.")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

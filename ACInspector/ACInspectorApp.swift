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
        TabView(selection: $controller.selectedTab) {
            EpisodesRootView()
                .tag(InspectorTab.episodes)
                .tabItem {
                    Label("Episodes", systemImage: "square.stack.3d.up")
                }

            PromptLabRootView()
                .tag(InspectorTab.promptLab)
                .tabItem {
                    Label("Prompt Lab", systemImage: "flask")
                }
        }
        .frame(minWidth: 1360, minHeight: 860)
    }
}

private struct EpisodesRootView: View {
    @EnvironmentObject private var controller: InspectorController

    var body: some View {
        NavigationSplitView {
            List(selection: Binding(
                get: { controller.selectedEpisodeID },
                set: { id in controller.selectedEpisodeID = id }
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
            ToolbarItemGroup(placement: .primaryAction) {
                Button("Refresh") {
                    Task { @MainActor in
                        await controller.refresh()
                    }
                }
                Button("Import To Prompt Lab") {
                    controller.importSelectedEpisodeIntoPromptLab()
                }
                .disabled(controller.selectedEpisode == nil)
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
    }
}

private struct PromptLabRootView: View {
    @EnvironmentObject private var controller: InspectorController

    var body: some View {
        NavigationSplitView {
            List(selection: Binding(
                get: { controller.selectedPromptLabScenarioID },
                set: { id in controller.selectedPromptLabScenarioID = id }
            )) {
                ForEach(controller.promptLabScenarios) { scenario in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(scenario.name)
                                .font(.headline)
                            Spacer()
                            Text(scenario.source.rawValue)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        Text(scenario.appName)
                            .font(.subheadline)
                        Text(scenario.windowTitle.isEmpty ? "No title" : scenario.windowTitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    .tag(scenario.id)
                }
                .onDelete(perform: controller.deletePromptLabScenarios)
            }
            .navigationTitle("Prompt Lab")
        } detail: {
            if let scenarioBinding = selectedScenarioBinding,
               let promptSetBinding = selectedPromptSetBinding {
                PromptLabDetailView(
                    scenario: scenarioBinding,
                    promptSet: promptSetBinding
                )
            } else {
                ContentUnavailableView("No Scenario Selected", systemImage: "flask")
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button("Add Synthetic") {
                    controller.addSyntheticPromptLabScenario()
                }
                Button("Import Selected Episode") {
                    controller.importSelectedEpisodeIntoPromptLab()
                }
                .disabled(controller.selectedEpisode == nil)
                Button(controller.promptLabIsRunning ? "Running…" : "Run Matrix") {
                    controller.runPromptLab()
                }
                .disabled(controller.promptLabIsRunning || controller.selectedPromptLabScenario == nil)
            }
            ToolbarItem(placement: .automatic) {
                Text(controller.promptLabStatusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var selectedScenarioBinding: Binding<PromptLabScenario>? {
        guard let scenarioID = controller.selectedPromptLabScenarioID,
              let index = controller.promptLabScenarios.firstIndex(where: { $0.id == scenarioID }) else {
            return nil
        }
        return Binding(
            get: { controller.promptLabScenarios[index] },
            set: { controller.promptLabScenarios[index] = $0 }
        )
    }

    private var selectedPromptSetBinding: Binding<PromptLabPromptSet>? {
        guard let index = controller.promptLabPromptSets.firstIndex(where: { $0.id == controller.selectedPromptSetID }) else {
            return nil
        }
        return Binding(
            get: { controller.promptLabPromptSets[index] },
            set: { controller.promptLabPromptSets[index] = $0 }
        )
    }
}

private struct PromptLabDetailView: View {
    @EnvironmentObject private var controller: InspectorController
    @Binding var scenario: PromptLabScenario
    @Binding var promptSet: PromptLabPromptSet

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                promptLabHeader
                runControlsSection
                scenarioSection
                promptEditorSection
                resultsSection
            }
            .padding(24)
        }
        .navigationTitle(scenario.name)
    }

    private var promptLabHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(scenario.name)
                .font(.title2.weight(.semibold))
            Text("Source: \(scenario.source.rawValue)")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            if let sourceEpisodeID = scenario.sourceEpisodeID {
                Text("Episode: \(sourceEpisodeID)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var runControlsSection: some View {
        GroupBox("Run Matrix") {
            VStack(alignment: .leading, spacing: 16) {
                TextField("Runtime path", text: $controller.promptLabRuntimePath)
                    .textFieldStyle(.roundedBorder)

                Picker("Prompt set", selection: $controller.selectedPromptSetID) {
                    ForEach(controller.promptLabPromptSets) { set in
                        Text(set.name).tag(set.id)
                    }
                }
                .pickerStyle(.segmented)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Pipelines")
                        .font(.headline)
                    ForEach(PromptLabPipelineProfile.defaults) { pipeline in
                        Toggle(
                            pipeline.displayName,
                            isOn: bindingForSetMembership(
                                pipeline.id,
                                selection: $controller.selectedPipelineIDs
                            )
                        )
                        .toggleStyle(.checkbox)
                        Text(pipeline.summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Runtime Profiles")
                        .font(.headline)
                    ForEach(PromptLabRuntimeProfile.defaults) { runtimeProfile in
                        Toggle(
                            runtimeProfile.displayName,
                            isOn: bindingForSetMembership(
                                runtimeProfile.id,
                                selection: $controller.selectedRuntimeProfileIDs
                            )
                        )
                        .toggleStyle(.checkbox)
                        Text(runtimeProfile.summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                let summary = controller.matrixSummary(for: scenario.id)
                HStack(spacing: 18) {
                    Label("\(summary.totalRuns) total", systemImage: "number")
                    Label("\(summary.passedRuns) passed", systemImage: "checkmark.circle")
                    Label("\(summary.failedRuns) failed", systemImage: "xmark.circle")
                    Label("\(summary.unmatchedRuns) unmatched", systemImage: "questionmark.circle")
                }
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)

                Button(controller.promptLabIsRunning ? "Running…" : "Run Selected Matrix") {
                    controller.runPromptLab()
                }
                .disabled(controller.promptLabIsRunning)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var scenarioSection: some View {
        GroupBox("Scenario") {
            VStack(alignment: .leading, spacing: 16) {
                TextField("Scenario name", text: $scenario.name)
                TextField("Goals", text: $scenario.goals, axis: .vertical)
                    .lineLimit(2...4)

                HStack {
                    TextField("App name", text: $scenario.appName)
                    TextField("Bundle id", text: $scenario.bundleIdentifier)
                    TextField("Window title", text: $scenario.windowTitle)
                }

                HStack {
                    TextField("Screenshot path", text: $scenario.screenshotPath)
                    Button("Open") {
                        controller.openFile(scenario.screenshotPath.nilIfBlank)
                    }
                    .disabled(scenario.screenshotPath.cleanedSingleLine.isEmpty)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Free-form Memory Summary")
                        .font(.headline)
                    TextEditor(text: $scenario.freeFormMemorySummary)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(minHeight: 80)
                        .overlay(roundedBorder)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Policy Memory Summary")
                        .font(.headline)
                    TextEditor(text: $scenario.policyMemorySummary)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(minHeight: 80)
                        .overlay(roundedBorder)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Structured Policy Memory JSON")
                        .font(.headline)
                    TextEditor(text: $scenario.policyMemoryJSON)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(minHeight: 160)
                        .overlay(roundedBorder)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Appeal Text")
                        .font(.headline)
                    TextField("Optional typed appeal for appeal-review runs", text: $scenario.appealText, axis: .vertical)
                        .lineLimit(2...4)
                }

                PromptLabDynamicRowsSection(
                    title: "Recent Switches",
                    addActionTitle: "Add Switch"
                ) {
                    scenario.recentSwitches.append(PromptLabSwitchRecord())
                } content: {
                    ForEach($scenario.recentSwitches) { $record in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                TextField("From app", text: $record.fromAppName)
                                TextField("To app", text: $record.toAppName)
                                TextField("To title", text: $record.toWindowTitle)
                            }
                            DatePicker("Timestamp", selection: $record.timestamp)
                            Button("Remove", role: .destructive) {
                                scenario.recentSwitches.removeAll { $0.id == record.id }
                            }
                        }
                        .padding(12)
                        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                }

                PromptLabDynamicRowsSection(
                    title: "Recent Actions",
                    addActionTitle: "Add Action"
                ) {
                    scenario.recentActions.append(PromptLabActionRecord())
                } content: {
                    ForEach($scenario.recentActions) { $record in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                TextField("Kind", text: $record.kind)
                                TextField("Message", text: $record.message)
                            }
                            DatePicker("Timestamp", selection: $record.timestamp)
                            Button("Remove", role: .destructive) {
                                scenario.recentActions.removeAll { $0.id == record.id }
                            }
                        }
                        .padding(12)
                        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                }

                PromptLabDynamicRowsSection(
                    title: "Usage Stats",
                    addActionTitle: "Add Usage"
                ) {
                    scenario.usage.append(PromptLabUsageRecord())
                } content: {
                    ForEach($scenario.usage) { $record in
                        HStack {
                            TextField("App", text: $record.appName)
                            TextField("Seconds", value: $record.seconds, format: .number.precision(.fractionLength(0)))
                            Button("Remove", role: .destructive) {
                                scenario.usage.removeAll { $0.id == record.id }
                            }
                        }
                        .padding(12)
                        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                }

                GroupBox("Advanced") {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("Clearly productive", isOn: $scenario.heuristics.clearlyProductive)
                        Toggle("Browser context", isOn: $scenario.heuristics.browser)
                        Toggle("Helpful window title", isOn: $scenario.heuristics.helpfulWindowTitle)
                        TextField("Periodic visual reason", text: $scenario.heuristics.periodicVisualReason)

                        Stepper("Distracted streak: \(scenario.distraction.consecutiveDistractedCount)", value: $scenario.distraction.consecutiveDistractedCount, in: 0...12)
                        optionalAssessmentPicker("Last assessment", selection: $scenario.distraction.lastAssessment)
                        optionalDatePicker("Stable since", selection: $scenario.distraction.stableSince)
                        optionalDatePicker("Next evaluation", selection: $scenario.distraction.nextEvaluationAt)

                        optionalAssessmentPicker("Expected assessment", selection: $scenario.expectedAssessment)
                        optionalActionPicker("Expected action", selection: $scenario.expectedAction)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var promptEditorSection: some View {
        GroupBox("Prompt Set Editor") {
            VStack(alignment: .leading, spacing: 12) {
                Text(promptSet.summary)
                    .foregroundStyle(.secondary)

                Picker("Stage", selection: $controller.selectedPromptStage) {
                    ForEach(PromptLabStage.allCases) { stage in
                        Text(stage.displayName).tag(stage)
                    }
                }
                .pickerStyle(.segmented)

                VStack(alignment: .leading, spacing: 8) {
                    Text("System Prompt")
                        .font(.headline)
                    TextEditor(text: systemPromptBinding(for: controller.selectedPromptStage))
                        .font(.system(size: 12, design: .monospaced))
                        .frame(minHeight: 180)
                        .overlay(roundedBorder)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("User Template")
                        .font(.headline)
                    TextEditor(text: userTemplateBinding(for: controller.selectedPromptStage))
                        .font(.system(size: 12, design: .monospaced))
                        .frame(minHeight: 150)
                        .overlay(roundedBorder)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var resultsSection: some View {
        GroupBox("Replay Results") {
            VStack(alignment: .leading, spacing: 16) {
                if controller.selectedScenarioResults.isEmpty {
                    Text("No replay results yet for this scenario.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(controller.selectedScenarioResults) { result in
                        if let binding = bindingForResult(id: result.id) {
                            PromptLabResultCard(result: binding)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func bindingForResult(id: UUID) -> Binding<PromptLabRunResult>? {
        guard let index = controller.promptLabResults.firstIndex(where: { $0.id == id }) else { return nil }
        return Binding(
            get: { controller.promptLabResults[index] },
            set: { controller.promptLabResults[index] = $0 }
        )
    }

    private func systemPromptBinding(for stage: PromptLabStage) -> Binding<String> {
        Binding(
            get: { promptSet.prompt(for: stage).systemPrompt },
            set: { value in
                let template = promptSet.prompt(for: stage)
                promptSet.update(stage: stage, systemPrompt: value, userTemplate: template.userTemplate)
            }
        )
    }

    private func userTemplateBinding(for stage: PromptLabStage) -> Binding<String> {
        Binding(
            get: { promptSet.prompt(for: stage).userTemplate },
            set: { value in
                let template = promptSet.prompt(for: stage)
                promptSet.update(stage: stage, systemPrompt: template.systemPrompt, userTemplate: value)
            }
        )
    }

    private func bindingForSetMembership(
        _ value: String,
        selection: Binding<Set<String>>
    ) -> Binding<Bool> {
        Binding(
            get: { selection.wrappedValue.contains(value) },
            set: { isOn in
                if isOn {
                    selection.wrappedValue.insert(value)
                } else {
                    selection.wrappedValue.remove(value)
                }
            }
        )
    }

    @ViewBuilder
    private func optionalDatePicker(_ title: String, selection: Binding<Date?>) -> some View {
        Toggle(
            title,
            isOn: Binding(
                get: { selection.wrappedValue != nil },
                set: { isOn in
                    if isOn {
                        selection.wrappedValue = selection.wrappedValue ?? Date()
                    } else {
                        selection.wrappedValue = nil
                    }
                }
            )
        )
        .toggleStyle(.switch)

        if selection.wrappedValue != nil {
            DatePicker(
                title,
                selection: Binding(
                    get: { selection.wrappedValue ?? Date() },
                    set: { selection.wrappedValue = $0 }
                )
            )
        }
    }

    @ViewBuilder
    private func optionalAssessmentPicker(_ title: String, selection: Binding<ModelAssessment?>) -> some View {
        Picker(title, selection: Binding(
            get: { selection.wrappedValue?.rawValue ?? "" },
            set: { rawValue in
                selection.wrappedValue = rawValue.isEmpty ? nil : ModelAssessment(rawValue: rawValue)
            }
        )) {
            Text("Any").tag("")
            ForEach([ModelAssessment.focused, .distracted, .unclear], id: \.rawValue) { value in
                Text(value.rawValue).tag(value.rawValue)
            }
        }
    }

    @ViewBuilder
    private func optionalActionPicker(_ title: String, selection: Binding<ModelSuggestedAction?>) -> some View {
        Picker(title, selection: Binding(
            get: { selection.wrappedValue?.rawValue ?? "" },
            set: { rawValue in
                selection.wrappedValue = rawValue.isEmpty ? nil : ModelSuggestedAction(rawValue: rawValue)
            }
        )) {
            Text("Any").tag("")
            ForEach([ModelSuggestedAction.none, .nudge, .overlay, .abstain], id: \.rawValue) { value in
                Text(value.rawValue).tag(value.rawValue)
            }
        }
    }

    private var roundedBorder: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
    }
}

private struct PromptLabDynamicRowsSection<Content: View>: View {
    let title: String
    let addActionTitle: String
    let addAction: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title)
                    .font(.headline)
                Spacer()
                Button(addActionTitle, action: addAction)
            }
            content()
        }
    }
}

private struct PromptLabResultCard: View {
    @Binding var result: PromptLabRunResult

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(result.comboLabel)
                        .font(.headline)
                    Text("\(Int(result.durationMS)) ms")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let pass = result.pass {
                    Text(pass ? "PASS" : "FAIL")
                        .font(.caption.monospaced().weight(.semibold))
                        .foregroundStyle(pass ? Color.green : Color.red)
                } else {
                    Text("UNMATCHED")
                        .font(.caption.monospaced().weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 14) {
                Text("Assessment: \(result.assessment?.rawValue ?? "n/a")")
                Text("Action: \(result.suggestedAction?.rawValue ?? "n/a")")
                if let confidence = result.confidence {
                    Text("Confidence: \(confidence.formatted(.number.precision(.fractionLength(2))))")
                }
            }
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)

            if let nudge = result.nudge, !nudge.isEmpty {
                Text("Nudge: \(nudge)")
            }

            if let appealDecision = result.appealDecision,
               let appealMessage = result.appealMessage {
                Text("Appeal: \(appealDecision) — \(appealMessage)")
            }

            if let errorSummary = result.errorSummary, !errorSummary.isEmpty {
                Text(errorSummary)
                    .foregroundStyle(.red)
            }

            ForEach(result.stageResults) { stageResult in
                DisclosureGroup(stageResult.stage.displayName) {
                    VStack(alignment: .leading, spacing: 10) {
                        if let errorMessage = stageResult.errorMessage, !errorMessage.isEmpty {
                            Text("Error: \(errorMessage)")
                                .foregroundStyle(.red)
                        }
                        Text(stageResult.parsedSummary)
                            .font(.callout)
                        Text("Latency: \(Int(stageResult.latencyMS)) ms")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                        PromptLabCodeBlock(title: "Payload", text: stageResult.payloadJSON)
                        PromptLabCodeBlock(title: "Rendered Prompt", text: stageResult.renderedPrompt)
                        PromptLabCodeBlock(title: "Raw Output", text: stageResult.rawOutput)
                    }
                    .padding(.top, 8)
                }
            }

            GroupBox("Human Labels") {
                VStack(alignment: .leading, spacing: 10) {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 10)], spacing: 10) {
                        ForEach(EpisodeAnnotationLabel.allCases, id: \.self) { label in
                            Toggle(
                                isOn: Binding(
                                    get: { result.annotationLabels.contains(label) },
                                    set: { isOn in
                                        if isOn {
                                            result.annotationLabels.insert(label)
                                        } else {
                                            result.annotationLabels.remove(label)
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

                    TextEditor(text: $result.annotationNote)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(minHeight: 70)
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
                        )
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(16)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct PromptLabCodeBlock: View {
    let title: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.headline)
            ScrollView {
                Text(text.isEmpty ? "No output." : text)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(minHeight: 90, maxHeight: 180)
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
            )
        }
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
                if controller.selectedEvaluationRuns.isEmpty, controller.selectedEpisodeAttempts.isEmpty {
                    promptSection
                    modelSection
                } else if controller.selectedEvaluationRuns.isEmpty {
                    modelAttemptsSection
                } else {
                    evaluationRunsSection
                }
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

    private var modelAttemptsSection: some View {
        GroupBox("Model Attempts") {
            VStack(alignment: .leading, spacing: 16) {
                ForEach(controller.selectedEpisodeAttempts) { attempt in
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text(attempt.title)
                                .font(.headline)
                            Spacer()
                            Text(attempt.timestamp.formatted(date: .omitted, time: .standard))
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }

                        if let parsedOutputJSON = attempt.parsedOutputJSON, !parsedOutputJSON.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Parsed output")
                                    .font(.subheadline.weight(.semibold))
                                ScrollView {
                                    Text(parsedOutputJSON)
                                        .font(.system(size: 12, design: .monospaced))
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .textSelection(.enabled)
                                }
                                .frame(minHeight: 110)
                            }
                        }

                        filePreview(title: "Prompt payload", path: attempt.promptPayloadPath)
                        filePreview(title: "Rendered prompt", path: attempt.renderedPromptPath)
                        filePreview(title: "Raw stdout", path: attempt.stdoutPath, fallbackText: attempt.stdoutPreview)
                        filePreview(title: "Raw stderr", path: attempt.stderrPath, fallbackText: attempt.stderrPreview)
                    }
                    .padding(16)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color.secondary.opacity(0.06))
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var evaluationRunsSection: some View {
        GroupBox("Evaluation Runs") {
            VStack(alignment: .leading, spacing: 18) {
                ForEach(controller.selectedEvaluationRuns) { run in
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(run.outcomeSummary)
                                    .font(.headline)
                                Text("Evaluation \(run.evaluationID.prefix(8))")
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(run.requestedAt.formatted(date: .omitted, time: .standard))
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }

                        ForEach(run.primaryStages) { stage in
                            evaluationStageCard(stage)
                        }

                        if !run.secondaryStages.isEmpty {
                            DisclosureGroup("Additional stages") {
                                VStack(alignment: .leading, spacing: 12) {
                                    ForEach(run.secondaryStages) { stage in
                                        evaluationStageCard(stage)
                                    }
                                }
                                .padding(.top, 8)
                            }
                        }
                    }
                    .padding(16)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color.secondary.opacity(0.06))
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
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
        GroupBox {
            DisclosureGroup("Raw Timeline") {
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
    }

    @ViewBuilder
    private func evaluationStageCard(_ stage: IndexedEvaluationStage) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(stage.title)
                        .font(.subheadline.weight(.semibold))
                    Text(stage.summary)
                        .font(.body)
                }
                Spacer()
                Text(stage.timestamp.formatted(date: .omitted, time: .standard))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }

            if !stage.details.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(stage.details) { row in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(row.label)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                            Text(row.value)
                                .font(.callout)
                                .textSelection(.enabled)
                        }
                    }
                }
            }

            DisclosureGroup("Debug") {
                VStack(alignment: .leading, spacing: 12) {
                    filePreview(title: "Prompt payload", path: stage.promptPayloadPath)
                    filePreview(title: "Rendered prompt", path: stage.renderedPromptPath)
                    filePreview(title: "Raw stdout", path: stage.stdoutPath, fallbackText: stage.stdoutPreview)
                    filePreview(title: "Raw stderr", path: stage.stderrPath, fallbackText: stage.stderrPreview)
                }
                .padding(.top, 8)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.001))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.secondary.opacity(0.12), lineWidth: 1)
        )
    }

    private func filePreview(title: String, path: String?, fallbackText: String? = nil) -> some View {
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
            } else if let fallbackText, !fallbackText.isEmpty {
                ScrollView {
                    Text(fallbackText)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(minHeight: 110)
            } else {
                Text("No file stored.")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private extension String {
    var nilIfBlank: String? {
        cleanedSingleLine.isEmpty ? nil : self
    }
}

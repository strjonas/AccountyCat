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

            EvalCasesRootView()
                .tag(InspectorTab.evalCases)
                .tabItem {
                    Label("Eval Cases", systemImage: "checklist")
                }
        }
        .frame(minWidth: 1360, minHeight: 860)
        .sheet(isPresented: Binding(
            get: { controller.evalCreationDraft != nil },
            set: { isPresented in
                if !isPresented {
                    controller.evalCreationDraft = nil
                }
            }
        )) {
            EvalCaseEditorView(
                evalCase: evalDraftBinding,
                onSave: { controller.saveEvalCreationDraft() },
                onCancel: { controller.evalCreationDraft = nil }
            )
            .frame(minWidth: 720, minHeight: 680)
        }
    }

    private var evalDraftBinding: Binding<ACEvalCase> {
        Binding(
            get: {
                controller.evalCreationDraft ?? ACEvalCase(
                    name: "Eval Case",
                    kind: .focus,
                    source: ACEvalSource(),
                    expectation: ACEvalExpectation()
                )
            },
            set: { controller.evalCreationDraft = $0 }
        )
    }
}

private struct EpisodesRootView: View {
    @EnvironmentObject private var controller: InspectorController

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                KindFilterBar()
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                Divider()
                List(selection: Binding(
                    get: { controller.selectedEpisodeID },
                    set: { id in
                        guard controller.selectedEpisodeID != id else { return }
                        controller.selectedEpisodeID = id
                    }
                )) {
                    ForEach(controller.filteredEpisodes) { episode in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                KindBadge(kind: episode.kind)
                                Text(episode.appName)
                                    .font(.headline)
                                    .lineLimit(1)
                            }
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
                            if let parent = episode.parentEpisodeID, !parent.isEmpty {
                                Text("↳ child of \(parent.prefix(8))…")
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                            }
                        }
                        .tag(episode.id)
                    }
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
                        await controller.refresh(forceRebuild: true)
                    }
                }
                Button("Import To Prompt Lab") {
                    controller.importSelectedEpisodeIntoPromptLab()
                }
                .disabled(controller.selectedEpisode == nil)
                Button("Create Eval Case") {
                    controller.beginEvalCaseCreationFromSelectedEpisode()
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

private struct EvalCasesRootView: View {
    @EnvironmentObject private var controller: InspectorController

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                evalFilters
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                Divider()
                List(selection: Binding(
                    get: { controller.selectedEvalCaseID },
                    set: { controller.selectedEvalCaseID = $0 }
                )) {
                    ForEach(ACEvalKind.allCases) { kind in
                        let cases = controller.filteredEvalCases.filter { $0.kind == kind }
                        if !cases.isEmpty {
                            Section(kind.displayName) {
                                ForEach(cases) { evalCase in
                                    EvalCaseListRow(evalCase: evalCase)
                                        .tag(evalCase.id)
                                }
                                .onDelete { offsets in
                                    for offset in offsets where cases.indices.contains(offset) {
                                        controller.deleteEvalCase(id: cases[offset].id)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Eval Cases")
        } detail: {
            if let evalCase = controller.selectedEvalCase {
                EvalCaseDetailView(evalCase: evalCase)
            } else {
                ContentUnavailableView("No Eval Case Selected", systemImage: "checklist")
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button("Refresh") {
                    controller.refreshEvalCases()
                }
                Button("Create From Selected Episode") {
                    controller.beginEvalCaseCreationFromSelectedEpisode()
                }
                .disabled(controller.selectedEpisode == nil)
            }
            ToolbarItem(placement: .automatic) {
                Text(controller.evalStatusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var evalFilters: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker("Kind", selection: Binding(
                    get: { controller.evalKindFilter?.rawValue ?? "" },
                    set: { controller.evalKindFilter = $0.isEmpty ? nil : ACEvalKind(rawValue: $0) }
                )) {
                    Text("All kinds").tag("")
                    ForEach(ACEvalKind.allCases) { kind in
                        Text(kind.displayName).tag(kind.rawValue)
                    }
                }

                Picker("Importance", selection: Binding(
                    get: { controller.evalImportanceFilter?.rawValue ?? "" },
                    set: { controller.evalImportanceFilter = $0.isEmpty ? nil : ACEvalImportance(rawValue: $0) }
                )) {
                    Text("All importance").tag("")
                    ForEach(ACEvalImportance.allCases) { importance in
                        Text(importance.rawValue).tag(importance.rawValue)
                    }
                }

                TextField("category", text: $controller.evalCategoryFilter)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 160)
            }
            .labelsHidden()
        }
    }
}

private struct EvalCaseListRow: View {
    let evalCase: ACEvalCase

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                EvalKindBadge(kind: evalCase.kind)
                Text(evalCase.name)
                    .font(.headline)
                    .lineLimit(1)
            }
            Text(evalCase.expectedOutcomeSummary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            HStack(spacing: 8) {
                Text(evalCase.importance.rawValue)
                if evalCase.hasScreenshot {
                    Label("screenshot", systemImage: "photo")
                }
                Text(evalCase.source.appName.isEmpty ? "No app" : evalCase.source.appName)
            }
            .font(.caption2.monospaced())
            .foregroundStyle(.secondary)
        }
    }
}

private struct EvalCaseDetailView: View {
    @EnvironmentObject private var controller: InspectorController
    let evalCase: ACEvalCase

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                metadataSection
                inputSection
                expectationSection
                if let observed = evalCase.observedOutput {
                    observedSection(observed)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(evalCase.name)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                EvalKindBadge(kind: evalCase.kind)
                Text(evalCase.importance.rawValue)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            Text(evalCase.name)
                .font(.title2.weight(.semibold))
            Text(evalCase.expectedOutcomeSummary)
                .font(.callout)
            if !evalCase.rationale.cleanedSingleLine.isEmpty {
                Text(evalCase.rationale)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            FlowWrap(items: evalCase.categories) { category in
                Text(category)
                    .font(.caption.monospaced())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.secondary.opacity(0.12), in: Capsule())
            }
        }
    }

    private var metadataSection: some View {
        GroupBox("Source") {
            VStack(alignment: .leading, spacing: 8) {
                detailRow("Episode", evalCase.source.episodeID ?? "n/a")
                detailRow("Session", evalCase.source.sessionID ?? "n/a")
                detailRow("App", evalCase.source.appName.isEmpty ? "n/a" : evalCase.source.appName)
                detailRow("Bundle", evalCase.source.bundleIdentifier ?? "n/a")
                detailRow("Title", evalCase.source.windowTitle ?? "n/a")
                detailRow("Backend", evalCase.recommendedBackend.rawValue)
                if let screenshotPath = evalCase.source.screenshotPath ?? evalCase.focusInput?.screenshotPath {
                    HStack {
                        detailRow("Screenshot", (screenshotPath as NSString).lastPathComponent)
                        Spacer()
                        Button("Open") { controller.openFile(screenshotPath) }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
        }
    }

    private var inputSection: some View {
        GroupBox("Input") {
            VStack(alignment: .leading, spacing: 8) {
                switch evalCase.kind {
                case .focus:
                    if let input = evalCase.focusInput {
                        detailRow("Context", [input.appName, input.windowTitle ?? ""].filter { !$0.isEmpty }.joined(separator: " / "))
                        detailRow("Recent chat", input.recentUserMessages.joined(separator: "\n"))
                    }
                case .chat:
                    if let input = evalCase.chatInput {
                        detailRow("Message", input.userMessage)
                        detailRow("Context", [input.context.frontmostAppName, input.context.frontmostWindowTitle ?? ""].filter { !$0.isEmpty }.joined(separator: " / "))
                        detailRow("Workflow", input.workflow.rawValue)
                    }
                case .chatAction:
                    if let input = evalCase.chatActionInput {
                        detailRow("Action", input.action.kind.rawValue)
                        detailRow("Instruction", input.action.instruction ?? "")
                        detailRow("Latest message", input.latestUserMessage)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
        }
    }

    private var expectationSection: some View {
        GroupBox("Expectation") {
            Text(evalCase.expectedOutcomeSummary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
        }
    }

    private func observedSection(_ observed: ACEvalObservedOutput) -> some View {
        GroupBox("Observed Output") {
            VStack(alignment: .leading, spacing: 8) {
                detailRow("Summary", observed.summary)
                detailRow("Model", observed.modelIdentifier ?? "n/a")
                if let json = observed.json, !json.isEmpty {
                    PromptLabCodeBlock(title: "JSON", text: json)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
        }
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(label)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .frame(width: 110, alignment: .leading)
            Text(value.isEmpty ? "n/a" : value)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct EvalCaseEditorView: View {
    @Binding var evalCase: ACEvalCase
    let onSave: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Create Eval Case")
                    .font(.title2.weight(.semibold))
                Spacer()
                Button("Cancel", action: onCancel)
                Button("Save Eval", action: onSave)
                    .keyboardShortcut(.defaultAction)
                    .disabled(evalCase.name.cleanedSingleLine.isEmpty)
            }
            .padding(20)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    metadataEditor
                    expectationEditor
                    sourceSummary
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var metadataEditor: some View {
        GroupBox("Case") {
            VStack(alignment: .leading, spacing: 12) {
                TextField("Name", text: $evalCase.name)
                Picker("Importance", selection: $evalCase.importance) {
                    ForEach(ACEvalImportance.allCases) { importance in
                        Text(importance.rawValue).tag(importance)
                    }
                }
                .pickerStyle(.segmented)
                TextField("Categories", text: Binding(
                    get: { evalCase.categories.joined(separator: ", ") },
                    set: { evalCase.categories = Self.parseCategories($0) }
                ))
                TextField("Rationale", text: $evalCase.rationale, axis: .vertical)
                    .lineLimit(2...5)
            }
            .padding(8)
        }
    }

    @ViewBuilder
    private var expectationEditor: some View {
        if let observed = evalCase.observedOutput {
            GroupBox("What the model did") {
                VStack(alignment: .leading, spacing: 6) {
                    Text(observed.summary)
                        .font(.callout)
                    if let model = observed.modelIdentifier, !model.isEmpty {
                        Text(model)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
            }
        }
        switch evalCase.kind {
        case .focus:
            focusExpectationEditor
        case .chat:
            chatExpectationEditor
        case .chatAction:
            chatActionExpectationEditor
        }
    }

    private var focusExpectationEditor: some View {
        GroupBox("What should have happened") {
            VStack(alignment: .leading, spacing: 14) {
                EvalToggleGrid(title: "Accepted assessments") {
                    ForEach(Self.assessments, id: \.rawValue) { value in
                        Toggle(value.rawValue, isOn: focusAssessmentBinding(value, accepted: true))
                            .toggleStyle(.checkbox)
                    }
                }
                EvalToggleGrid(title: "Forbidden assessments") {
                    ForEach(Self.assessments, id: \.rawValue) { value in
                        Toggle(value.rawValue, isOn: focusAssessmentBinding(value, accepted: false))
                            .toggleStyle(.checkbox)
                    }
                }
                EvalToggleGrid(title: "Accepted actions") {
                    ForEach(Self.actions, id: \.rawValue) { value in
                        Toggle(value.rawValue, isOn: focusActionBinding(value, accepted: true))
                            .toggleStyle(.checkbox)
                    }
                }
                EvalToggleGrid(title: "Forbidden actions") {
                    ForEach(Self.actions, id: \.rawValue) { value in
                        Toggle(value.rawValue, isOn: focusActionBinding(value, accepted: false))
                            .toggleStyle(.checkbox)
                    }
                }
            }
            .padding(8)
        }
    }

    private var chatExpectationEditor: some View {
        GroupBox("What should have happened") {
            VStack(alignment: .leading, spacing: 14) {
                Toggle("Reply must be non-empty", isOn: Binding(
                    get: { evalCase.expectation.chat?.replyMustBeNonEmpty ?? true },
                    set: { value in
                        var expectation = evalCase.expectation.chat ?? ACEvalChatExpectation()
                        expectation.replyMustBeNonEmpty = value
                        evalCase.expectation.chat = expectation
                    }
                ))
                .toggleStyle(.checkbox)

                EvalToggleGrid(title: "Required action kinds") {
                    ForEach(Self.chatActionKinds, id: \.rawValue) { value in
                        Toggle(value.rawValue, isOn: chatActionKindBinding(value, required: true))
                            .toggleStyle(.checkbox)
                    }
                }
                EvalToggleGrid(title: "Forbidden action kinds") {
                    ForEach(Self.chatActionKinds, id: \.rawValue) { value in
                        Toggle(value.rawValue, isOn: chatActionKindBinding(value, required: false))
                            .toggleStyle(.checkbox)
                    }
                }

                TextField("Required schedule kind", text: Binding(
                    get: { evalCase.expectation.chat?.requiredScheduleKind ?? "" },
                    set: { value in
                        var expectation = evalCase.expectation.chat ?? ACEvalChatExpectation()
                        expectation.requiredScheduleKind = value.nilIfBlank
                        evalCase.expectation.chat = expectation
                    }
                ))
            }
            .padding(8)
        }
    }

    private var chatActionExpectationEditor: some View {
        GroupBox("What should have happened") {
            VStack(alignment: .leading, spacing: 12) {
                Picker("Kind", selection: Binding(
                    get: { evalCase.expectation.chatAction?.kind?.rawValue ?? "" },
                    set: { rawValue in
                        updateChatActionExpectation { expectation in
                            expectation.kind = rawValue.isEmpty ? nil : CompanionChatActionKind(rawValue: rawValue)
                        }
                    }
                )) {
                    Text("Any").tag("")
                    ForEach(Self.chatActionKinds, id: \.rawValue) { value in
                        Text(value.rawValue).tag(value.rawValue)
                    }
                }

                TextField("Intent", text: chatActionStringBinding(\.intent))
                TextField("Target type", text: chatActionStringBinding(\.targetType))
                TextField("Target value", text: chatActionStringBinding(\.targetValue))
                TextField("Scope", text: chatActionStringBinding(\.scope))
                TextField("Duration", text: chatActionStringBinding(\.duration))
                TextField("Duration minutes", text: chatActionIntBinding(\.durationMinutes))
                TextField("Profile id", text: chatActionStringBinding(\.profileID))
                TextField("Profile name", text: chatActionStringBinding(\.profileName))
                TextField("Profile description", text: chatActionStringBinding(\.profileDescription))
                TextField("Memory text contains", text: chatActionStringBinding(\.textContains))
                Picker("Locked", selection: chatActionBoolTagBinding(\.locked)) {
                    Text("Any").tag("")
                    Text("true").tag("true")
                    Text("false").tag("false")
                }
            }
            .padding(8)
        }
    }

    private var sourceSummary: some View {
        GroupBox("Captured Context") {
            VStack(alignment: .leading, spacing: 8) {
                Text("\(evalCase.source.appName) / \(evalCase.source.windowTitle ?? "No title")")
                Text("Kind: \(evalCase.kind.displayName)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Text("Expected: \(evalCase.expectedOutcomeSummary)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func focusAssessmentBinding(_ value: ModelAssessment, accepted: Bool) -> Binding<Bool> {
        Binding(
            get: {
                let expectation = evalCase.expectation.focus ?? ACEvalFocusExpectation()
                return accepted
                    ? expectation.acceptedAssessments.contains(value)
                    : expectation.forbiddenAssessments.contains(value)
            },
            set: { isOn in
                var expectation = evalCase.expectation.focus ?? ACEvalFocusExpectation()
                if accepted {
                    Self.setMembership(value, in: &expectation.acceptedAssessments, isOn: isOn)
                } else {
                    Self.setMembership(value, in: &expectation.forbiddenAssessments, isOn: isOn)
                }
                evalCase.expectation.focus = expectation
            }
        )
    }

    private func focusActionBinding(_ value: ModelSuggestedAction, accepted: Bool) -> Binding<Bool> {
        Binding(
            get: {
                let expectation = evalCase.expectation.focus ?? ACEvalFocusExpectation()
                return accepted
                    ? expectation.acceptedActions.contains(value)
                    : expectation.forbiddenActions.contains(value)
            },
            set: { isOn in
                var expectation = evalCase.expectation.focus ?? ACEvalFocusExpectation()
                if accepted {
                    Self.setMembership(value, in: &expectation.acceptedActions, isOn: isOn)
                } else {
                    Self.setMembership(value, in: &expectation.forbiddenActions, isOn: isOn)
                }
                evalCase.expectation.focus = expectation
            }
        )
    }

    private func chatActionKindBinding(_ value: CompanionChatActionKind, required: Bool) -> Binding<Bool> {
        Binding(
            get: {
                let expectation = evalCase.expectation.chat ?? ACEvalChatExpectation()
                return required
                    ? expectation.requiredActionKinds.contains(value)
                    : expectation.forbiddenActionKinds.contains(value)
            },
            set: { isOn in
                var expectation = evalCase.expectation.chat ?? ACEvalChatExpectation()
                if required {
                    Self.setMembership(value, in: &expectation.requiredActionKinds, isOn: isOn)
                } else {
                    Self.setMembership(value, in: &expectation.forbiddenActionKinds, isOn: isOn)
                }
                evalCase.expectation.chat = expectation
            }
        )
    }

    private func chatActionStringBinding(_ keyPath: WritableKeyPath<ACEvalChatActionExpectation, String?>) -> Binding<String> {
        Binding(
            get: { (evalCase.expectation.chatAction ?? ACEvalChatActionExpectation())[keyPath: keyPath] ?? "" },
            set: { value in
                updateChatActionExpectation { expectation in
                    expectation[keyPath: keyPath] = value.nilIfBlank
                }
            }
        )
    }

    private func chatActionIntBinding(_ keyPath: WritableKeyPath<ACEvalChatActionExpectation, Int?>) -> Binding<String> {
        Binding(
            get: {
                guard let value = (evalCase.expectation.chatAction ?? ACEvalChatActionExpectation())[keyPath: keyPath] else {
                    return ""
                }
                return String(value)
            },
            set: { value in
                updateChatActionExpectation { expectation in
                    expectation[keyPath: keyPath] = Int(value.trimmingCharacters(in: .whitespacesAndNewlines))
                }
            }
        )
    }

    private func chatActionBoolTagBinding(_ keyPath: WritableKeyPath<ACEvalChatActionExpectation, Bool?>) -> Binding<String> {
        Binding(
            get: {
                guard let value = (evalCase.expectation.chatAction ?? ACEvalChatActionExpectation())[keyPath: keyPath] else {
                    return ""
                }
                return value ? "true" : "false"
            },
            set: { value in
                updateChatActionExpectation { expectation in
                    switch value {
                    case "true": expectation[keyPath: keyPath] = true
                    case "false": expectation[keyPath: keyPath] = false
                    default: expectation[keyPath: keyPath] = nil
                    }
                }
            }
        )
    }

    private func updateChatActionExpectation(_ mutate: (inout ACEvalChatActionExpectation) -> Void) {
        var expectation = evalCase.expectation.chatAction ?? ACEvalChatActionExpectation()
        mutate(&expectation)
        evalCase.expectation.chatAction = expectation
    }

    private static func parseCategories(_ value: String) -> [String] {
        value
            .split(separator: ",")
            .map { ACEvalStore.normalizeCategory(String($0)) }
            .filter { !$0.isEmpty }
    }

    private static func setMembership<T: Equatable>(_ value: T, in values: inout [T], isOn: Bool) {
        if isOn {
            if !values.contains(value) {
                values.append(value)
            }
        } else {
            values.removeAll { $0 == value }
        }
    }

    private static let assessments: [ModelAssessment] = [.focused, .tolerated, .distracted, .unclear]
    private static let actions: [ModelSuggestedAction] = [.none, .nudge, .overlay, .abstain]
    private static let chatActionKinds: [CompanionChatActionKind] = [.profile, .memory, .focusPolicy, .recurringNudge]
}

private struct EvalToggleGrid<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 8) {
                content()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct EvalKindBadge: View {
    let kind: ACEvalKind

    var body: some View {
        Text(kind.displayName)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
            .overlay(Capsule().stroke(color.opacity(0.35), lineWidth: 0.5))
    }

    private var color: Color {
        switch kind {
        case .focus: return .blue
        case .chat: return .green
        case .chatAction: return .orange
        }
    }
}

private struct FlowWrap<Item: Hashable, Content: View>: View {
    let items: [Item]
    @ViewBuilder let content: (Item) -> Content

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 6)], alignment: .leading, spacing: 6) {
            ForEach(items, id: \.self) { item in
                content(item)
            }
        }
    }
}

private struct PromptLabRootView: View {
    @EnvironmentObject private var controller: InspectorController

    var body: some View {
        NavigationSplitView {
            List(selection: Binding(
                get: { controller.selectedPromptLabScenarioID },
                set: { id in
                    guard controller.selectedPromptLabScenarioID != id else { return }
                    controller.selectedPromptLabScenarioID = id
                }
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
                Button(controller.promptLabIsRunning ? "Running…" : "Run Golden") {
                    controller.runPromptLabGolden()
                }
                .disabled(controller.promptLabIsRunning)
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
            ForEach([ModelAssessment.focused, .tolerated, .distracted, .unclear], id: \.rawValue) { value in
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

private struct KindBadge: View {
    let kind: IndexedEpisodeKind

    var body: some View {
        Text(kind.displayName)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
            .overlay(Capsule().stroke(color.opacity(0.35), lineWidth: 0.5))
    }

    private var color: Color {
        switch kind {
        case .focusDecision: return .blue
        case .chat, .localChat: return .green
        case .chatAction: return .orange
        case .policyMemory: return .purple
        case .memoryConsolidation: return .pink
        case .monitoringText, .monitoringVision: return .cyan
        case .safelistAppeal: return .yellow
        }
    }
}

private struct KindFilterBar: View {
    @EnvironmentObject private var controller: InspectorController

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                FilterChip(
                    label: "All",
                    isSelected: controller.kindFilter.isEmpty,
                    action: { controller.kindFilter.removeAll() }
                )
                ForEach(IndexedEpisodeKind.allCases, id: \.self) { kind in
                    FilterChip(
                        label: kind.displayName,
                        isSelected: controller.kindFilter.contains(kind),
                        action: {
                            if controller.kindFilter.contains(kind) {
                                controller.kindFilter.remove(kind)
                            } else {
                                controller.kindFilter.insert(kind)
                            }
                        }
                    )
                }
            }
        }
    }

    private struct FilterChip: View {
        let label: String
        let isSelected: Bool
        let action: () -> Void

        var body: some View {
            Button(action: action) {
                Text(label)
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(isSelected ? Color.accentColor.opacity(0.25) : Color.secondary.opacity(0.12), in: Capsule())
                    .overlay(Capsule().stroke(isSelected ? Color.accentColor : Color.secondary.opacity(0.25), lineWidth: 0.5))
            }
            .buttonStyle(.plain)
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
                if episode.kind != .focusDecision {
                    extractedFieldsSection
                    llmRawIOSection
                    if let parent = episode.parentEpisodeID, !parent.isEmpty {
                        parentLinkSection(parent: parent)
                    }
                } else {
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
                }
                timelineSection
            }
            .padding(24)
        }
        .navigationTitle(episode.appName)
    }

    private var extractedFieldsSection: some View {
        GroupBox(label: HStack(spacing: 6) {
            KindBadge(kind: episode.kind)
            Text(episode.kind.displayName).font(.headline)
        }) {
            VStack(alignment: .leading, spacing: 8) {
                if !episode.summary.isEmpty {
                    Text(episode.summary)
                        .font(.callout)
                }
                if let model = episode.modelIdentifier, !model.isEmpty {
                    HStack(spacing: 6) {
                        Text("Model").font(.caption.monospaced()).foregroundStyle(.secondary)
                        Text(model).font(.caption.monospaced())
                    }
                }
                if let failure = episode.failureMessage, !failure.isEmpty {
                    Text("Failure: \(failure)")
                        .font(.callout)
                        .foregroundStyle(.red)
                }
                Divider().padding(.vertical, 4)
                if episode.extractedFields.isEmpty {
                    Text("(no extracted fields)").font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(episode.extractedFields.keys.sorted(), id: \.self) { key in
                        HStack(alignment: .top, spacing: 12) {
                            Text(key)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .frame(width: 160, alignment: .leading)
                            Text(episode.extractedFields[key] ?? "")
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
        }
    }

    private var llmRawIOSection: some View {
        GroupBox("Raw I/O") {
            VStack(alignment: .leading, spacing: 12) {
                rawFileRow(label: "System prompt", path: episode.systemPromptPath)
                rawFileRow(label: "User prompt", path: episode.renderedPromptPath)
                rawFileRow(label: "Request payload", path: episode.promptPayloadPath)
                rawFileRow(label: "Raw stdout", path: episode.rawStdoutPath)
                rawFileRow(label: "Raw stderr", path: episode.rawStderrPath)
                if let parsed = episode.modelOutputJSON, !parsed.isEmpty {
                    Divider()
                    Text("Parsed output JSON")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                    ScrollView {
                        Text(parsed)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 280)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
        }
    }

    @ViewBuilder
    private func rawFileRow(label: String, path: String?) -> some View {
        if let path, !path.isEmpty {
            HStack(spacing: 12) {
                Text(label).font(.caption.monospaced()).foregroundStyle(.secondary).frame(width: 140, alignment: .leading)
                Text((path as NSString).lastPathComponent)
                    .font(.caption.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("Open") { controller.openFile(path) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
    }

    private func parentLinkSection(parent: String) -> some View {
        GroupBox("Parent") {
            HStack {
                Text("Triggered by chat \(parent.prefix(8))…")
                    .font(.caption.monospaced())
                Spacer()
                Button("View parent chat") {
                    controller.selectEpisode(parent)
                }
            }
            .padding(8)
        }
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

                        InspectorDebugPanel(
                            promptText: exactPromptText(
                                promptTemplatePath: attempt.promptTemplatePath,
                                renderedPromptPath: attempt.renderedPromptPath
                            ),
                            responseText: exactResponseText(
                                stdoutPath: attempt.stdoutPath,
                                stdoutPreview: attempt.stdoutPreview,
                                stderrPath: attempt.stderrPath,
                                stderrPreview: attempt.stderrPreview
                            ),
                            parametersText: callParametersText(
                                promptMode: attempt.promptMode,
                                runtimePath: attempt.runtimePath,
                                modelIdentifier: attempt.modelIdentifier,
                                runtimeOptions: attempt.runtimeOptions
                            )
                        )
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

                HStack {
                    Button("Save annotation") {
                        controller.saveAnnotation()
                    }
                    Button("Create Eval Case") {
                        controller.beginEvalCaseCreationFromSelectedEpisode()
                    }
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
                InspectorDebugPanel(
                    promptText: exactPromptText(
                        promptTemplatePath: stage.promptTemplatePath,
                        renderedPromptPath: stage.renderedPromptPath
                    ),
                    responseText: exactResponseText(
                        stdoutPath: stage.stdoutPath,
                        stdoutPreview: stage.stdoutPreview,
                        stderrPath: stage.stderrPath,
                        stderrPreview: stage.stderrPreview
                    ),
                    parametersText: callParametersText(
                        promptMode: stage.promptMode,
                        runtimePath: stage.runtimePath,
                        modelIdentifier: stage.modelIdentifier,
                        runtimeOptions: stage.runtimeOptions
                    )
                )
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

    private func exactPromptText(
        promptTemplatePath: String?,
        renderedPromptPath: String?
    ) -> String {
        let systemPrompt = readTextFile(at: promptTemplatePath)
        let userPrompt = readTextFile(at: renderedPromptPath)

        switch (systemPrompt, userPrompt) {
        case let (system?, user?) where !system.isEmpty || !user.isEmpty:
            return """
            SYSTEM
            \(system)

            USER
            \(user)
            """
        case let (_, user?) where !user.isEmpty:
            return user
        case let (system?, _) where !system.isEmpty:
            return system
        default:
            return "No prompt stored."
        }
    }

    private func exactResponseText(
        stdoutPath: String?,
        stdoutPreview: String?,
        stderrPath: String?,
        stderrPreview: String?
    ) -> String {
        if let stdout = readTextFile(at: stdoutPath), !stdout.isEmpty {
            return stdout
        }
        if let stdoutPreview, !stdoutPreview.isEmpty {
            return stdoutPreview
        }
        if let stderr = readTextFile(at: stderrPath), !stderr.isEmpty {
            return stderr
        }
        if let stderrPreview, !stderrPreview.isEmpty {
            return stderrPreview
        }
        return "No response stored."
    }

    private func callParametersText(
        promptMode: String,
        runtimePath: String?,
        modelIdentifier: String?,
        runtimeOptions: TelemetryRuntimeOptions?
    ) -> String {
        struct InspectorCallParameters: Encodable {
            var promptMode: String
            var runtimePath: String?
            var modelIdentifier: String?
            var runtimeOptions: TelemetryRuntimeOptions?
        }

        let payload = InspectorCallParameters(
            promptMode: promptMode,
            runtimePath: runtimePath,
            modelIdentifier: modelIdentifier,
            runtimeOptions: runtimeOptions
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(payload),
           let text = String(data: data, encoding: .utf8) {
            return text
        }
        return "No call parameters stored."
    }

    private func readTextFile(at path: String?) -> String? {
        guard let path else { return nil }
        return try? String(contentsOfFile: path, encoding: .utf8)
    }
}

private struct InspectorDebugPanel: View {
    let promptText: String
    let responseText: String
    let parametersText: String

    @State private var promptExpanded = true
    @State private var responseExpanded = true
    @State private var parametersExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Spacer()
                Button("Copy all") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(formattedExport, forType: .string)
                }
            }

            DisclosureGroup("Exact Prompt", isExpanded: $promptExpanded) {
                debugTextBlock(promptText)
                    .padding(.top, 8)
            }

            DisclosureGroup("Exact Response", isExpanded: $responseExpanded) {
                debugTextBlock(responseText)
                    .padding(.top, 8)
            }

            DisclosureGroup("Call Parameters", isExpanded: $parametersExpanded) {
                debugTextBlock(parametersText)
                    .padding(.top, 8)
            }
        }
    }

    private var formattedExport: String {
        [
            "EXACT PROMPT",
            promptText,
            "",
            "EXACT RESPONSE",
            responseText,
            "",
            "CALL PARAMETERS",
            parametersText
        ].joined(separator: "\n")
    }

    @ViewBuilder
    private func debugTextBlock(_ text: String) -> some View {
        ScrollView {
            Text(text)
                .font(.system(size: 12, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .frame(minHeight: 110)
    }
}

private extension String {
    var nilIfBlank: String? {
        cleanedSingleLine.isEmpty ? nil : self
    }
}

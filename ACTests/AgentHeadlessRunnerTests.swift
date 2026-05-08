//
//  AgentHeadlessRunnerTests.swift
//  ACTests
//

import Foundation
import Testing
@testable import AC

@MainActor
struct AgentHeadlessRunnerTests {

    @Test
    func headlessRunnerCommand() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let command = env["AC_DEBUG_RUNNER_COMMAND"] else {
            return
        }

        switch command {
        case "chat":
            try await runChat(env: env)
        case "monitor":
            try await runMonitor(env: env)
        default:
            Issue.record("Unsupported AC_DEBUG_RUNNER_COMMAND: \(command)")
        }
    }

    private func runChat(env: [String: String]) async throws {
        let state = try loadState(path: env["AC_DEBUG_RUNNER_STATE"])
        let message = env["AC_DEBUG_RUNNER_MESSAGE"] ?? "Help me focus for the next 30 minutes."
        let fixture = try FakeRuntimeFixture()
        let runtime = LocalModelRuntime()
        let service = CompanionChatService(runtime: runtime, onlineModelService: OnlineModelService())

        let result = await service.chat(
            userMessage: message,
            goals: state.goalsText,
            recentActions: state.recentActions,
            context: ChatContext(
                frontmostAppName: "Xcode",
                frontmostWindowTitle: "AccountyCat",
                idleSeconds: 0,
                timestamp: Date(),
                recentSwitches: state.recentSwitches,
                perAppDurations: []
            ),
            history: state.chatHistory,
            memory: state.memoryForPrompt(now: Date()),
            policyRules: state.policyRulesForChatPrompt(now: Date()),
            character: state.character,
            activeProfileContext: makeProfileContextForChatPrompt(state: state),
            runtimeOverride: fixture.runtimePath,
            inferenceBackend: .local,
            onlineModelIdentifier: state.monitoringConfiguration.onlineModelIdentifier,
            onlineTextModelIdentifier: state.monitoringConfiguration.onlineModelIdentifierText,
            localTextModelIdentifier: state.monitoringConfiguration.localModelIdentifierText,
            workflow: .staged
        )

        let resolved = try #require(result)
        #expect(!resolved.reply.isEmpty)
        print("""
        AC_DEBUG_RUNNER_RESULT {"command":"chat","reply":\(Self.jsonString(resolved.reply)),"actionCount":\(resolved.actions.count),"hasSchedule":\(resolved.schedule != nil)}
        """)
    }

    private func runMonitor(env: [String: String]) async throws {
        var state = try loadState(path: env["AC_DEBUG_RUNNER_STATE"])
        let context = try loadContext(path: env["AC_DEBUG_RUNNER_CONTEXT"])
        let fixture = try FakeRuntimeFixture()
        let store = TelemetryStore(
            rootURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("ac-headless-monitor-\(UUID().uuidString)", isDirectory: true)
        )

        state.setupStatus = .ready
        state.permissions = PermissionsSnapshot(screenRecording: .granted, accessibility: .granted)
        state.runtimePathOverride = fixture.runtimePath
        state.algorithmState.llmPolicy.currentContextKey = context.contextKey
        state.algorithmState.llmPolicy.currentContextEnteredAt = Date.distantPast
        state.algorithmState.llmPolicy.distraction = DistractionMetadata(
            contextKey: context.contextKey,
            stableSince: Date.distantPast,
            lastAssessment: .focused,
            consecutiveDistractedCount: 0,
            nextEvaluationAt: nil
        )

        let runtime = LocalModelRuntime()
        let registry = MonitoringAlgorithmRegistry(
            runtime: runtime,
            onlineModelService: OnlineModelService(),
            policyMemoryService: PolicyMemoryService(runtime: runtime, onlineModelService: OnlineModelService())
        )
        let brain = BrainService(
            monitoringAlgorithmRegistry: registry,
            executiveArm: ExecutiveArm(
                showNudge: { _ in },
                showOverlay: { _ in },
                hideOverlay: { },
                minimizeApp: { _ in }
            ),
            storageService: .temporary(),
            telemetryStore: store
        )
        brain.stateProvider = { state }
        brain.contextProvider = { context }
        brain.idleSecondsProvider = { 0 }
        if let screenshotPath = env["AC_DEBUG_RUNNER_SCREENSHOT"], !screenshotPath.isEmpty {
            brain.screenshotCapture = { URL(fileURLWithPath: screenshotPath) }
        }

        await brain.tick()
        try await Task.sleep(for: .milliseconds(200))

        let sessions = await store.listSessions()
        let events = await sessions.asyncFlatMap { await store.loadEvents(sessionID: $0.id) }
        #expect(!events.isEmpty)
        let eventKinds = Dictionary(grouping: events, by: { $0.kind.rawValue })
            .mapValues(\.count)
        let json = String(data: try JSONEncoder().encode(eventKinds), encoding: .utf8) ?? "{}"
        print("""
        AC_DEBUG_RUNNER_RESULT {"command":"monitor","sessionCount":\(sessions.count),"eventCounts":\(json)}
        """)
    }

    private func loadState(path: String?) throws -> ACState {
        guard let path, !path.isEmpty else { return ACState() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ACState.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    }

    private func loadContext(path: String?) throws -> FrontmostContext {
        guard let path, !path.isEmpty else {
            return FrontmostContext(
                bundleIdentifier: "com.apple.dt.Xcode",
                appName: "Xcode",
                windowTitle: "AccountyCat - Agent debug runner"
            )
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(FrontmostContext.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    }

    private static func jsonString(_ value: String) -> String {
        let data = (try? JSONEncoder().encode(value)) ?? Data("null".utf8)
        return String(data: data, encoding: .utf8) ?? "null"
    }

    private func makeProfileContextForChatPrompt(state: ACState) -> String {
        let activeProfile = state.activeProfile
        let availableText = state.profiles
            .filter { $0.id != state.activeProfileID }
            .map { profile in
                let description = profile.description.map { " — \($0)" } ?? ""
                let schedule = profile.recurringSchedule.map { " [scheduled: \($0.scheduleDescription())]" } ?? ""
                return "- \(profile.name) (id: \(profile.id))\(description)\(schedule)"
            }
            .joined(separator: "\n")

        return ACPromptSets.chatProfileContextSection(
            activeProfileID: activeProfile.id,
            activeProfileName: activeProfile.name,
            activeProfileDescription: activeProfile.description,
            activeProfileIsDefault: activeProfile.isDefault,
            activeProfileExpiresAtLabel: nil,
            activeProfileScheduleLabel: activeProfile.recurringSchedule?.scheduleDescription(),
            availableProfiles: availableText
        )
    }
}

private extension Sequence {
    func asyncFlatMap<T>(_ transform: (Element) async -> [T]) async -> [T] {
        var result: [T] = []
        for element in self {
            result.append(contentsOf: await transform(element))
        }
        return result
    }
}

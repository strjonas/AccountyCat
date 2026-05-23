import Foundation
import Testing
@testable import AC

@MainActor
struct AgentEvalCommandRunnerTests {

    @Test
    func run() async throws {
        let env = ProcessInfo.processInfo.environment
        let request = Self.loadFileRequest(environment: env)
        // This test can load every eval case under Application Support and run
        // full local/online inference — hours of work if triggered accidentally.
        // Normal `xcodebuild test` must never inherit runner settings from a shell
        // profile and silently run the suite. The Swift eval script provides either
        // `AC_EVAL_ALLOW_TEST_HOST_RUN=1` or a short-lived signed handoff file.
        guard env["AC_EVAL_ALLOW_TEST_HOST_RUN"] == "1" || request?.allowTestHostRun == true else {
            return
        }

        guard env["AC_EVAL_RUNNER_COMMAND"] == "run" || request != nil else {
            return
        }

        let options = request.map(ACEvalRunnerOptions.init(request:)) ?? ACEvalRunnerOptions(environment: env)
        let store = ACEvalStore(rootURL: options.rootURL ?? ACEvalStore().rootURL)
        let cases = try options.filteredCases(from: store)
        let executor = ACEvalExecutor(environment: Self.mergedEvalEnvironment(base: env, request: request))
        let results = await executor.run(
            cases: cases,
            backend: options.backend,
            onlineModel: options.onlineModel,
            runtimePath: options.runtimePath
        )
        let output = ACEvalRunnerOutput(results: results)
        let json = Self.jsonString(output)
        if let resultPath = request?.resultPath ?? env["AC_EVAL_RESULT_PATH"], !resultPath.isEmpty {
            try json.write(
                to: URL(fileURLWithPath: resultPath),
                atomically: true,
                encoding: String.Encoding.utf8
            )
        }
        print("AC_EVAL_RUNNER_RESULT \(json)")
        #expect(output.failedCount == 0)
    }

    private static func jsonString<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = (try? encoder.encode(value)) ?? Data("{}".utf8)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private static func loadFileRequest(environment: [String: String]) -> ACEvalRunnerFileRequest? {
        var urls: [URL] = []
        if let path = environment["AC_EVAL_REQUEST_PATH"], !path.isEmpty {
            urls.append(URL(fileURLWithPath: path))
        } else {
            urls.append(URL(fileURLWithPath: "/tmp/ac-eval-runner-request.json"))
        }

        for url in urls {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let modifiedAt = attributes[.modificationDate] as? Date,
                  abs(modifiedAt.timeIntervalSinceNow) < 180,
                  let data = try? Data(contentsOf: url),
                  let request = try? JSONDecoder().decode(ACEvalRunnerFileRequest.self, from: data) else {
                continue
            }
            guard request.allowTestHostRun == true,
                  request.resultPath.hasPrefix("/tmp/ac-eval-runner-"),
                  request.resultPath.hasSuffix("-result.json") else {
                continue
            }
            if let expiresAt = request.expiresAt,
               Date().timeIntervalSince1970 > expiresAt {
                try? FileManager.default.removeItem(at: url)
                continue
            }
            try? FileManager.default.removeItem(at: url)
            return request
        }
        return nil
    }

    private static func mergedEvalEnvironment(
        base: [String: String],
        request: ACEvalRunnerFileRequest?
    ) -> [String: String] {
        var merged = base
        if let key = request?.openRouterAPIKey, !key.isEmpty {
            merged["AC_EVAL_OPENROUTER_API_KEY"] = key
        }
        if let key = request?.openAIAPIKey, !key.isEmpty {
            merged["AC_EVAL_OPENAI_API_KEY"] = key
        }
        return merged
    }
}

@MainActor
struct AgentEvalRunnerTests {

    @Test
    func focusEvalPassesWithFakeRuntime() async throws {
        let fixture = try FakeRuntimeFixture()
        let evalCase = Self.makeFocusCase(
            expectation: ACEvalFocusExpectation(
                acceptedAssessments: [.distracted],
                acceptedActions: [.nudge]
            )
        )
        let results = await ACEvalExecutor(environment: [:]).run(
            cases: [evalCase],
            backend: .local,
            onlineModel: nil,
            runtimePath: fixture.runtimePath
        )
        #expect(results.first?.pass == true)
    }

    @Test
    func focusEvalFailsForbiddenNudgeWithFakeRuntime() async throws {
        let fixture = try FakeRuntimeFixture()
        let evalCase = Self.makeFocusCase(
            expectation: ACEvalFocusExpectation(
                acceptedAssessments: [.distracted],
                forbiddenActions: [.nudge]
            )
        )
        let results = await ACEvalExecutor(environment: [:]).run(
            cases: [evalCase],
            backend: .local,
            onlineModel: nil,
            runtimePath: fixture.runtimePath
        )
        #expect(results.first?.pass == false)
        #expect(results.first?.reason == "forbidden_action:nudge")
    }

    @Test
    func chatEvalDetectsRequiredProfileAction() async throws {
        var outputs = FakeRuntimeOutputSet()
        outputs.chatReply = """
        {"reply":"Starting a coding focus session.","actions":[{"kind":"profile","instruction":"start coding for one hour"}],"schedule":null}
        """
        let fixture = try FakeRuntimeFixture(outputs: outputs)
        let evalCase = Self.makeChatCase(
            expectation: ACEvalChatExpectation(requiredActionKinds: [.profile])
        )

        let results = await ACEvalExecutor(environment: [:]).run(
            cases: [evalCase],
            backend: .local,
            onlineModel: nil,
            runtimePath: fixture.runtimePath
        )

        #expect(results.first?.pass == true)
        #expect(results.first?.parsedOutput["actions"] == "profile")
    }

    @Test
    func chatActionEvalDetectsMemoryAction() async throws {
        let fixture = try FakeRuntimeFixture()
        let evalCase = Self.makeChatActionCase(
            action: CompanionChatAction(kind: .memory, instruction: "remember short breaks"),
            expectation: ACEvalChatActionExpectation(
                kind: .memory,
                textContains: "short breaks"
            )
        )

        let results = await ACEvalExecutor(environment: [:]).run(
            cases: [evalCase],
            backend: .local,
            onlineModel: nil,
            runtimePath: fixture.runtimePath
        )

        #expect(results.first?.pass == true)
        #expect(results.first?.parsedOutput["kind"] == "memory")
    }

    @Test
    func onlineModeRefusesWithoutExplicitEvalAPIKey() async throws {
        let evalCase = Self.makeChatCase(
            expectation: ACEvalChatExpectation(requiredActionKinds: [.profile])
        )

        let results = await ACEvalExecutor(environment: [:]).run(
            cases: [evalCase],
            backend: .online,
            onlineModel: "openai/gpt-4.1-mini",
            runtimePath: nil
        )

        #expect(results.first?.pass == false)
        #expect(results.first?.reason == "missing_eval_api_key")
    }

    private static func makeFocusCase(expectation: ACEvalFocusExpectation) -> ACEvalCase {
        let now = Date(timeIntervalSince1970: 1_000)
        return ACEvalCase(
            id: "focus-runner",
            name: "Focus runner",
            kind: .focus,
            importance: .high,
            categories: ["false_positive"],
            source: ACEvalSource(
                appName: "Google Chrome",
                bundleIdentifier: "com.google.Chrome",
                windowTitle: "Docs",
                timestamp: now
            ),
            focusInput: ACEvalFocusInput(
                timestamp: now,
                appName: "Google Chrome",
                bundleIdentifier: "com.google.Chrome",
                windowTitle: "Docs",
                screenshotPath: nil,
                goals: "Ship AC and stay focused on engineering work.",
                freeFormMemory: "Keep social media short during focused work.",
                recentUserMessages: [],
                policyMemorySummary: "",
                policyMemoryJSON: "",
                recentSwitches: [
                    ACEvalSwitchRecord(
                        fromAppName: "Xcode",
                        toAppName: "Google Chrome",
                        toWindowTitle: "Docs",
                        timestamp: now.addingTimeInterval(-15)
                    ),
                ],
                recentActions: [],
                usage: [
                    ACEvalUsageRecord(appName: "Google Chrome", seconds: 900),
                    ACEvalUsageRecord(appName: "Xcode", seconds: 3_600),
                ],
                heuristics: ACEvalHeuristics(browser: true),
                distraction: ACEvalDistraction(
                    stableSince: now.addingTimeInterval(-120),
                    lastAssessment: nil,
                    consecutiveDistractedCount: 0,
                    nextEvaluationAt: nil
                ),
                activeProfile: ACEvalActiveProfile(
                    id: "general",
                    name: "Everyday",
                    isDefault: true,
                    description: nil,
                    activatedAt: nil,
                    expiresAt: nil
                )
            ),
            expectation: ACEvalExpectation(focus: expectation)
        )
    }

    private static func makeChatCase(expectation: ACEvalChatExpectation) -> ACEvalCase {
        ACEvalCase(
            id: "chat-runner",
            name: "Chat runner",
            kind: .chat,
            importance: .high,
            categories: ["profile"],
            source: ACEvalSource(appName: "Chat"),
            chatInput: ACEvalChatInput(
                userMessage: "I will code for an hour.",
                goals: "Ship AC and stay focused on engineering work.",
                memory: "",
                policyRules: "",
                context: ACEvalChatContext(
                    frontmostAppName: "Xcode",
                    frontmostWindowTitle: "AC",
                    idleSeconds: 0,
                    timestamp: Date(timeIntervalSince1970: 1_000),
                    recentSwitches: [],
                    usage: []
                ),
                history: [],
                character: "mochi",
                activeProfileContext: "",
                workflow: .staged
            ),
            expectation: ACEvalExpectation(chat: expectation)
        )
    }

    private static func makeChatActionCase(
        action: CompanionChatAction,
        expectation: ACEvalChatActionExpectation
    ) -> ACEvalCase {
        ACEvalCase(
            id: "chat-action-runner",
            name: "Chat action runner",
            kind: .chatAction,
            importance: .high,
            categories: [action.kind.rawValue],
            source: ACEvalSource(appName: "Chat Action"),
            chatActionInput: ACEvalChatActionInput(
                action: action,
                latestUserMessage: action.instruction ?? "",
                recentUserMessages: [action.instruction ?? ""].filter { !$0.isEmpty },
                goals: "Ship AC and stay focused on engineering work.",
                freeFormMemory: "",
                policyRules: "",
                context: ACEvalFrontmostContext(
                    bundleIdentifier: "com.apple.dt.Xcode",
                    appName: "Xcode",
                    windowTitle: "AC"
                ),
                activeProfile: ACEvalProfileSummary(id: "general", name: "Everyday", description: nil, isDefault: true),
                availableProfiles: []
            ),
            expectation: ACEvalExpectation(chatAction: expectation)
        )
    }

}

private enum ACEvalRunnerBackend: String, Codable {
    case local
    case online
}

private struct ACEvalRunnerOptions {
    var backend: ACEvalRunnerBackend
    var ids: Set<String>
    var kind: ACEvalKind?
    var importances: Set<ACEvalImportance>
    var categories: Set<String>
    var limit: Int?
    var onlineModel: String?
    var runtimePath: String?
    var rootURL: URL?

    init(environment: [String: String]) {
        backend = ACEvalRunnerBackend(rawValue: environment["AC_EVAL_BACKEND"] ?? "local") ?? .local
        ids = Self.csvSet(environment["AC_EVAL_IDS"])
        kind = environment["AC_EVAL_KIND"].flatMap(ACEvalKind.init(rawValue:))
        importances = Set(Self.csvSet(environment["AC_EVAL_IMPORTANCE"]).compactMap(ACEvalImportance.init(rawValue:)))
        categories = Self.csvSet(environment["AC_EVAL_CATEGORY"])
        limit = environment["AC_EVAL_LIMIT"].flatMap(Int.init)
        onlineModel = environment["AC_EVAL_ONLINE_MODEL"]
        runtimePath = environment["AC_EVAL_RUNTIME_PATH"]
        rootURL = environment["AC_EVAL_ROOT"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    init(request: ACEvalRunnerFileRequest) {
        backend = ACEvalRunnerBackend(rawValue: request.backend) ?? .local
        ids = Set(request.ids)
        kind = request.kind.flatMap(ACEvalKind.init(rawValue:))
        importances = Set(request.importances.compactMap(ACEvalImportance.init(rawValue:)))
        categories = Set(request.categories)
        limit = request.limit
        onlineModel = request.onlineModel
        runtimePath = request.runtimePath
        rootURL = URL(fileURLWithPath: request.root, isDirectory: true)
    }

    func filteredCases(from store: ACEvalStore) throws -> [ACEvalCase] {
        let initial = ids.isEmpty
            ? try store.query(kind: kind, importances: importances, categories: categories, limit: limit)
            : try ids.map { try store.load(id: $0) }
        if let limit, limit > 0 {
            return Array(initial.prefix(limit))
        }
        return initial
    }

    private static func csvSet(_ value: String?) -> Set<String> {
        guard let value else { return [] }
        return Set(value
            .split(separator: ",")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty })
    }
}

private struct ACEvalRunnerFileRequest: Codable {
    var root: String
    var backend: String
    var ids: [String]
    var kind: String?
    var importances: [String]
    var categories: [String]
    var limit: Int?
    var onlineModel: String?
    var runtimePath: String?
    var openRouterAPIKey: String?
    var openAIAPIKey: String?
    var resultPath: String
    var allowTestHostRun: Bool?
    var expiresAt: TimeInterval?
}

private struct ACEvalRunnerOutput: Codable {
    var generatedAt = Date()
    var totalCount: Int
    var passedCount: Int
    var failedCount: Int
    var results: [ACEvalRunResult]

    init(results: [ACEvalRunResult]) {
        self.results = results
        totalCount = results.count
        passedCount = results.filter(\.pass).count
        failedCount = results.filter { !$0.pass }.count
    }
}

private struct ACEvalRunResult: Codable {
    var id: String
    var name: String
    var kind: ACEvalKind
    var pass: Bool
    var reason: String
    var parsedOutput: [String: String]
    var modelUsed: String?
    var latencyMS: Double
    var artifactPaths: [String]
}

@MainActor
private struct ACEvalExecutor {
    let environment: [String: String]

    func run(
        cases: [ACEvalCase],
        backend: ACEvalRunnerBackend,
        onlineModel: String?,
        runtimePath: String?
    ) async -> [ACEvalRunResult] {
        var results: [ACEvalRunResult] = []
        for evalCase in cases {
            let started = Date()
            do {
                let output = try await evaluate(
                    evalCase,
                    backend: backend,
                    onlineModel: onlineModel,
                    runtimePath: runtimePath
                )
                let latency = Date().timeIntervalSince(started) * 1_000
                results.append(output.withLatency(latency))
            } catch {
                let latency = Date().timeIntervalSince(started) * 1_000
                results.append(ACEvalRunResult(
                    id: evalCase.id,
                    name: evalCase.name,
                    kind: evalCase.kind,
                    pass: false,
                    reason: (error as? ACEvalRunnerError)?.rawValue ?? error.localizedDescription,
                    parsedOutput: [:],
                    modelUsed: nil,
                    latencyMS: latency,
                    artifactPaths: Self.artifactPaths(for: evalCase)
                ))
            }
        }
        return results
    }

    private func evaluate(
        _ evalCase: ACEvalCase,
        backend: ACEvalRunnerBackend,
        onlineModel: String?,
        runtimePath: String?
    ) async throws -> ACEvalRunResult {
        if backend == .online, !Self.hasEvalOnlineAPIKey(environment) {
            throw ACEvalRunnerError.missingEvalAPIKey
        }

        switch evalCase.kind {
        case .focus:
            return try await evaluateFocus(evalCase, backend: backend, onlineModel: onlineModel, runtimePath: runtimePath)
        case .chat:
            return try await evaluateChat(evalCase, backend: backend, onlineModel: onlineModel, runtimePath: runtimePath)
        case .chatAction:
            return try await evaluateChatAction(evalCase, backend: backend, onlineModel: onlineModel, runtimePath: runtimePath)
        }
    }

    private func evaluateFocus(
        _ evalCase: ACEvalCase,
        backend: ACEvalRunnerBackend,
        onlineModel: String?,
        runtimePath: String?
    ) async throws -> ACEvalRunResult {
        guard let input = evalCase.focusInput,
              let expectation = evalCase.expectation.focus else {
            throw ACEvalRunnerError.missingEvalInput
        }

        let runtime = LocalModelRuntime()
        let onlineService = makeOnlineService()
        let algorithm = LLMMonitorAlgorithm(
            runtime: runtime,
            onlineModelService: onlineService,
            policyMemoryService: PolicyMemoryService(runtime: runtime, onlineModelService: onlineService)
        )
        let snapshot = AppSnapshot(
            bundleIdentifier: input.bundleIdentifier,
            appName: input.appName,
            windowTitle: input.windowTitle,
            recentSwitches: input.recentSwitches.map {
                AppSwitchRecord(fromAppName: $0.fromAppName, toAppName: $0.toAppName, toWindowTitle: $0.toWindowTitle, timestamp: $0.timestamp)
            },
            perAppDurations: input.usage.map { AppUsageRecord(appName: $0.appName, seconds: $0.seconds) },
            screenshotArtifact: nil,
            screenshotThumbnail: nil,
            screenshotPath: input.screenshotPath,
            idle: false,
            timestamp: input.timestamp
        )
        var configuration = MonitoringConfiguration(
            pipelineProfileID: input.screenshotPath == nil ? "title_only_default" : "vision_split_default",
            inferenceBackend: backend == .online ? .openRouter : .local,
            onlineModelIdentifier: onlineModel ?? AITier.balanced.byokModelIdentifierImage,
            onlineModelIdentifierText: onlineModel,
            onlineModelIdentifierImage: onlineModel,
            localModelIdentifierText: AITier.balanced.localModelIdentifierText,
            localModelIdentifierImage: AITier.balanced.localModelIdentifierImage
        )
        if backend == .online, input.screenshotPath == nil {
            configuration.pipelineProfileID = MonitoringConfiguration.defaultOnlineTextPipelineProfileID
        } else if backend == .online {
            configuration.pipelineProfileID = MonitoringConfiguration.defaultOnlineVisionPipelineProfileID
        }
        var state = AlgorithmStateEnvelope()
        state.llmPolicy.currentContextKey = snapshot.contextKey
        state.llmPolicy.currentContextEnteredAt = input.distraction.stableSince
        state.llmPolicy.distraction = DistractionMetadata(
            contextKey: snapshot.contextKey,
            stableSince: input.distraction.stableSince,
            lastAssessment: input.distraction.lastAssessment,
            consecutiveDistractedCount: input.distraction.consecutiveDistractedCount,
            nextEvaluationAt: input.distraction.nextEvaluationAt
        )
        let decisionInput = MonitoringDecisionInput(
            now: input.timestamp,
            evaluationID: "eval-\(evalCase.id)",
            snapshot: snapshot,
            goals: input.goals,
            recentActions: input.recentActions.map {
                ActionRecord(
                    kind: ActionKind(rawValue: $0.kind) ?? .nudge,
                    message: $0.message,
                    timestamp: $0.timestamp
                )
            },
            heuristics: TelemetryHeuristicSnapshot(
                clearlyProductive: input.heuristics.clearlyProductive,
                browser: input.heuristics.browser,
                helpfulWindowTitle: input.heuristics.helpfulWindowTitle,
                periodicVisualReason: input.heuristics.periodicVisualReason,
                titleRelatesToDeclaredFocus: input.heuristics.titleRelatesToDeclaredFocus
            ),
            memory: input.freeFormMemory,
            recentUserMessages: input.recentUserMessages,
            policyMemory: Self.decodePolicyMemory(input.policyMemoryJSON),
            runtimeOverride: runtimePath ?? RuntimeSetupService.normalizedRuntimePath(from: nil),
            configuration: configuration,
            algorithmState: state,
            activeProfileID: input.activeProfile.id,
            activeProfileName: input.activeProfile.name,
            activeProfileDescription: input.activeProfile.description,
            activeProfileActivatedAt: input.activeProfile.activatedAt,
            activeProfileExpiresAt: input.activeProfile.expiresAt
        )

        let result = await algorithm.evaluate(input: decisionInput)
        let match = expectation.evaluate(
            assessment: result.decision.assessment,
            action: result.decision.suggestedAction
        )
        return ACEvalRunResult(
            id: evalCase.id,
            name: evalCase.name,
            kind: evalCase.kind,
            pass: match.pass,
            reason: match.reason,
            parsedOutput: [
                "assessment": result.decision.assessment.rawValue,
                "action": result.decision.suggestedAction.rawValue,
            ],
            modelUsed: result.evaluation.lastUsedModelIdentifier,
            latencyMS: 0,
            artifactPaths: Self.artifactPaths(for: evalCase)
        )
    }

    private func evaluateChat(
        _ evalCase: ACEvalCase,
        backend: ACEvalRunnerBackend,
        onlineModel: String?,
        runtimePath: String?
    ) async throws -> ACEvalRunResult {
        guard let input = evalCase.chatInput,
              let expectation = evalCase.expectation.chat else {
            throw ACEvalRunnerError.missingEvalInput
        }

        let runtime = LocalModelRuntime()
        let service = CompanionChatService(runtime: runtime, onlineModelService: makeOnlineService())
        let result = await service.chat(
            userMessage: input.userMessage,
            goals: input.goals,
            recentActions: [],
            context: ChatContext(
                frontmostAppName: input.context.frontmostAppName,
                frontmostWindowTitle: input.context.frontmostWindowTitle,
                idleSeconds: input.context.idleSeconds,
                timestamp: input.context.timestamp,
                recentSwitches: input.context.recentSwitches.map {
                    AppSwitchRecord(fromAppName: $0.fromAppName, toAppName: $0.toAppName, toWindowTitle: $0.toWindowTitle, timestamp: $0.timestamp)
                },
                perAppDurations: input.context.usage.map { AppUsageRecord(appName: $0.appName, seconds: $0.seconds) }
            ),
            history: input.history.compactMap { message in
                guard let role = ChatRole(rawValue: message.role) else { return nil }
                return ChatMessage(role: role, text: message.text, timestamp: message.timestamp)
            },
            memory: input.memory,
            policyRules: input.policyRules,
            character: ACCharacter(rawValue: input.character) ?? .mochi,
            activeProfileContext: input.activeProfileContext,
            runtimeOverride: runtimePath ?? RuntimeSetupService.normalizedRuntimePath(from: nil),
            inferenceBackend: backend == .online ? .openRouter : .local,
            onlineModelIdentifier: onlineModel ?? AITier.balanced.byokModelIdentifierImage,
            onlineTextModelIdentifier: onlineModel,
            localTextModelIdentifier: AITier.balanced.localModelIdentifierText,
            workflow: input.workflow
        )
        guard let result else {
            throw ACEvalRunnerError.missingModelOutput
        }
        let scheduleKind = result.schedule?.kind.rawValue
        let match = expectation.evaluate(reply: result.reply, actions: result.actions, scheduleKind: scheduleKind)
        return ACEvalRunResult(
            id: evalCase.id,
            name: evalCase.name,
            kind: evalCase.kind,
            pass: match.pass,
            reason: match.reason,
            parsedOutput: [
                "reply": result.reply,
                "actions": result.actions.map(\.kind.rawValue).joined(separator: ","),
                "schedule": scheduleKind ?? "",
            ],
            modelUsed: result.usedModelIdentifier,
            latencyMS: 0,
            artifactPaths: Self.artifactPaths(for: evalCase)
        )
    }

    private func evaluateChatAction(
        _ evalCase: ACEvalCase,
        backend: ACEvalRunnerBackend,
        onlineModel: String?,
        runtimePath: String?
    ) async throws -> ACEvalRunResult {
        guard let input = evalCase.chatActionInput,
              let expectation = evalCase.expectation.chatAction else {
            throw ACEvalRunnerError.missingEvalInput
        }

        let runtime = LocalModelRuntime()
        let service = CompanionChatService(runtime: runtime, onlineModelService: makeOnlineService())
        let resolved = await service.resolveAction(
            ChatActionResolutionRequest(
                action: input.action,
                latestUserMessage: input.latestUserMessage,
                recentUserMessages: input.recentUserMessages,
                goals: input.goals,
                freeFormMemory: input.freeFormMemory,
                policyRules: input.policyRules,
                context: input.context.map {
                    FrontmostContext(
                        bundleIdentifier: $0.bundleIdentifier,
                        appName: $0.appName,
                        windowTitle: $0.windowTitle
                    )
                },
                activeProfile: Self.profileSummary(input.activeProfile),
                availableProfiles: input.availableProfiles.map(Self.profileSummary),
                runtimeOverride: runtimePath ?? RuntimeSetupService.normalizedRuntimePath(from: nil),
                inferenceBackend: backend == .online ? .openRouter : .local,
                onlineModelIdentifier: onlineModel ?? AITier.balanced.byokModelIdentifierImage,
                onlineTextModelIdentifier: onlineModel,
                localTextModelIdentifier: AITier.balanced.localModelIdentifierText
            )
        )

        let match = expectation.evaluate(action: resolved)
        return ACEvalRunResult(
            id: evalCase.id,
            name: evalCase.name,
            kind: evalCase.kind,
            pass: match.pass,
            reason: match.reason,
            parsedOutput: [
                "kind": resolved?.kind.rawValue ?? "",
                "intent": resolved?.intent ?? "",
                "target": resolved?.target.map { "\($0.type):\($0.value ?? "")" } ?? "",
                "scope": resolved?.scope ?? "",
                "duration": resolved?.duration ?? "",
                "text": resolved?.text ?? "",
            ],
            modelUsed: nil,
            latencyMS: 0,
            artifactPaths: Self.artifactPaths(for: evalCase)
        )
    }

    private func makeOnlineService() -> any OnlineModelServing {
        EnvKeyOnlineModelService(environment: environment)
    }

    private static func decodePolicyMemory(_ json: String) -> PolicyMemory {
        guard !json.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let data = json.data(using: .utf8),
              let memory = try? JSONDecoder().decode(PolicyMemory.self, from: data) else {
            return PolicyMemory()
        }
        return memory
    }

    private static func profileSummary(_ value: ACEvalProfileSummary) -> ProfilePromptSummary {
        ProfilePromptSummary(
            id: value.id,
            name: value.name,
            isDefault: value.isDefault,
            description: value.description
        )
    }

    private static func hasEvalOnlineAPIKey(_ environment: [String: String]) -> Bool {
        !(environment["AC_EVAL_OPENROUTER_API_KEY"] ?? "").isEmpty
            || !(environment["AC_EVAL_OPENAI_API_KEY"] ?? "").isEmpty
    }

    private static func artifactPaths(for evalCase: ACEvalCase) -> [String] {
        [evalCase.source.screenshotPath, evalCase.focusInput?.screenshotPath]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
    }
}

private extension ACEvalRunResult {
    func withLatency(_ latencyMS: Double) -> ACEvalRunResult {
        ACEvalRunResult(
            id: id,
            name: name,
            kind: kind,
            pass: pass,
            reason: reason,
            parsedOutput: parsedOutput,
            modelUsed: modelUsed,
            latencyMS: latencyMS,
            artifactPaths: artifactPaths
        )
    }
}

private enum ACEvalRunnerError: String, LocalizedError {
    case missingEvalAPIKey = "missing_eval_api_key"
    case missingEvalInput = "missing_eval_input"
    case missingModelOutput = "missing_model_output"

    var errorDescription: String? { rawValue }
}

private actor EnvKeyOnlineModelService: OnlineModelServing {
    private let environment: [String: String]

    init(environment: [String: String]) {
        self.environment = environment
    }

    func runInference(_ request: OnlineModelRequest) async throws -> RuntimeProcessOutput {
        let provider = providerConfiguration()
        let body = try await Self.makeChatCompletionBody(request: request, modelIdentifier: request.modelIdentifier)
        var urlRequest = URLRequest(url: provider.url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("Bearer \(provider.apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let raw = String(data: data, encoding: .utf8) ?? ""
            throw NSError(domain: "ACEvalOnlineModel", code: status, userInfo: [NSLocalizedDescriptionKey: raw])
        }
        let decoded = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
        guard let content = decoded.choices.first?.message.content, !content.isEmpty else {
            throw ACEvalRunnerError.missingModelOutput
        }
        return RuntimeProcessOutput(
            stdout: content,
            stderr: "",
            usedModelIdentifier: decoded.model ?? request.modelIdentifier,
            tokenUsage: decoded.usage.map {
                TokenUsage(
                    promptTokens: $0.promptTokens ?? 0,
                    completionTokens: $0.completionTokens ?? 0,
                    totalTokens: $0.totalTokens,
                    estimated: false
                )
            },
            imageWasProcessed: request.imagePath != nil
        )
    }

    func runInference(_ request: OnlineModelRequest, parentInteractionID: String?) async throws -> RuntimeProcessOutput {
        try await runInference(request)
    }

    func runFirstSuccessfulInference(from requests: [OnlineModelRequest]) async throws -> RuntimeProcessOutput {
        var errors: [Error] = []
        for request in requests {
            do {
                return try await runInference(request)
            } catch {
                errors.append(error)
            }
        }
        throw errors.last ?? ACEvalRunnerError.missingModelOutput
    }

    func hasHadSuccessfulChat() async -> Bool {
        true
    }

    private func providerConfiguration() -> (url: URL, apiKey: String) {
        if let key = environment["AC_EVAL_OPENROUTER_API_KEY"], !key.isEmpty {
            return (URL(string: "https://openrouter.ai/api/v1/chat/completions")!, key)
        }
        return (URL(string: "https://api.openai.com/v1/chat/completions")!, environment["AC_EVAL_OPENAI_API_KEY"] ?? "")
    }

    @MainActor
    private static func makeChatCompletionBody(
        request: OnlineModelRequest,
        modelIdentifier: String
    ) throws -> [String: Any] {
        let userContent: Any
        if let imagePath = request.imagePath,
           let data = try? Data(contentsOf: URL(fileURLWithPath: imagePath)) {
            let ext = (imagePath as NSString).pathExtension.lowercased()
            let mime = ext == "jpg" || ext == "jpeg" ? "image/jpeg" : "image/png"
            userContent = [
                ["type": "text", "text": request.userPrompt],
                [
                    "type": "image_url",
                    "image_url": ["url": "data:\(mime);base64,\(data.base64EncodedString())"],
                ],
            ]
        } else {
            userContent = request.userPrompt
        }

        return [
            "model": modelIdentifier,
            "messages": [
                ["role": "system", "content": request.systemPrompt],
                ["role": "user", "content": userContent],
            ],
            "max_tokens": request.options.maxTokens,
            "temperature": request.options.temperature,
            "top_p": request.options.topP,
        ]
    }

    private struct ChatCompletionResponse: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable {
                var content: String
            }

            var message: Message
        }

        struct Usage: Decodable {
            var promptTokens: Int?
            var completionTokens: Int?
            var totalTokens: Int?

            enum CodingKeys: String, CodingKey {
                case promptTokens = "prompt_tokens"
                case completionTokens = "completion_tokens"
                case totalTokens = "total_tokens"
            }
        }

        var model: String?
        var choices: [Choice]
        var usage: Usage?
    }
}

import Foundation
import Testing
@testable import AC

@MainActor
struct ACEvalStoreTests {

    @Test
    func evalCaseSaveLoadRoundTripAndCopiesScreenshot() throws {
        let root = temporaryRoot()
        let store = ACEvalStore(rootURL: root)
        let screenshot = root.deletingLastPathComponent()
            .appendingPathComponent("source-screenshot.png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: screenshot)

        let evalCase = makeFocusCase(
            id: "focus-copy",
            categories: ["false_positive", "browser"],
            screenshotPath: screenshot.path
        )

        let saved = try store.save(evalCase)
        let loaded = try store.load(id: "focus-copy")

        #expect(loaded.id == evalCase.id)
        #expect(loaded.name == evalCase.name)
        #expect(loaded.source.screenshotPath != screenshot.path)
        #expect(saved.source.screenshotPath == loaded.source.screenshotPath)
        #expect(FileManager.default.fileExists(atPath: try #require(loaded.source.screenshotPath)))
    }

    @Test
    func manifestRegenerationAndFiltering() throws {
        let store = ACEvalStore(rootURL: temporaryRoot())
        _ = try store.save(makeFocusCase(id: "focus-critical", importance: .critical, categories: ["false_positive"]))
        _ = try store.save(makeChatCase(id: "chat-high", importance: .high, categories: ["memory", "chat"]))
        _ = try store.save(makeChatActionCase(id: "action-low", importance: .low, categories: ["focus_policy"]))

        let manifest = try store.loadManifest()
        #expect(manifest.caseCount == 3)
        #expect(manifest.cases.map(\.id).contains("focus-critical"))

        let filtered = try store.query(
            kind: .chat,
            importances: [.high],
            categories: ["memory"]
        )
        #expect(filtered.map(\.id) == ["chat-high"])
    }

    @Test
    func expectationMatchersReportPassAndFailureReasons() throws {
        let focus = ACEvalFocusExpectation(
            acceptedAssessments: [.focused],
            forbiddenActions: [.nudge]
        )
        #expect(focus.evaluate(assessment: .focused, action: ModelSuggestedAction.none).pass)
        #expect(focus.evaluate(assessment: .focused, action: .nudge).reason == "forbidden_action:nudge")
        #expect(focus.evaluate(assessment: .distracted, action: ModelSuggestedAction.none).reason == "assessment_not_accepted:distracted")

        let chat = ACEvalChatExpectation(
            requiredActionKinds: [.memory],
            forbiddenActionKinds: [.profile]
        )
        #expect(chat.evaluate(
            reply: "Saved.",
            actions: [CompanionChatAction(kind: .memory)],
            scheduleKind: nil
        ).pass)
        #expect(chat.evaluate(
            reply: "Saved.",
            actions: [CompanionChatAction(kind: .profile)],
            scheduleKind: nil
        ).reason == "forbidden_action_kind:profile")

        let chatAction = ACEvalChatActionExpectation(
            kind: .focusPolicy,
            intent: "allow",
            scope: "active_profile",
            targetType: "current_context",
            duration: "profile_session",
            textContains: nil,
            locked: false
        )
        let action = CompanionChatAction(
            kind: .focusPolicy,
            intent: "allow",
            scope: "active_profile",
            target: CompanionChatActionTarget(type: "current_context"),
            duration: "profile_session",
            locked: false
        )
        #expect(chatAction.evaluate(action: action).pass)
        #expect(chatAction.evaluate(action: CompanionChatAction(kind: .memory)).reason == "kind_not_matched:memory")
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ac-eval-store-tests-\(UUID().uuidString)", isDirectory: true)
    }

    private func makeFocusCase(
        id: String,
        importance: ACEvalImportance = .medium,
        categories: [String] = [],
        screenshotPath: String? = nil
    ) -> ACEvalCase {
        ACEvalCase(
            id: id,
            name: "Focus \(id)",
            kind: .focus,
            importance: importance,
            categories: categories,
            source: ACEvalSource(
                episodeID: "episode-\(id)",
                appName: "Google Chrome",
                bundleIdentifier: "com.google.Chrome",
                windowTitle: "Docs",
                screenshotPath: screenshotPath
            ),
            focusInput: ACEvalFocusInput(
                timestamp: Date(timeIntervalSince1970: 1_000),
                appName: "Google Chrome",
                bundleIdentifier: "com.google.Chrome",
                windowTitle: "Docs",
                screenshotPath: screenshotPath,
                goals: "Ship AC.",
                freeFormMemory: "",
                recentUserMessages: [],
                policyMemorySummary: "",
                policyMemoryJSON: "",
                recentSwitches: [],
                recentActions: [],
                usage: [],
                heuristics: ACEvalHeuristics(browser: true),
                distraction: ACEvalDistraction(stableSince: Date(timeIntervalSince1970: 900), lastAssessment: nil, consecutiveDistractedCount: 0, nextEvaluationAt: nil),
                activeProfile: ACEvalActiveProfile(id: "general", name: "Everyday", isDefault: true)
            ),
            expectation: ACEvalExpectation(
                focus: ACEvalFocusExpectation(acceptedAssessments: [.distracted], acceptedActions: [.nudge])
            )
        )
    }

    private func makeChatCase(
        id: String,
        importance: ACEvalImportance,
        categories: [String]
    ) -> ACEvalCase {
        ACEvalCase(
            id: id,
            name: "Chat \(id)",
            kind: .chat,
            importance: importance,
            categories: categories,
            source: ACEvalSource(appName: "Chat"),
            chatInput: ACEvalChatInput(
                userMessage: "remember short breaks",
                goals: "Ship AC.",
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
            expectation: ACEvalExpectation(
                chat: ACEvalChatExpectation(requiredActionKinds: [.memory])
            )
        )
    }

    private func makeChatActionCase(
        id: String,
        importance: ACEvalImportance,
        categories: [String]
    ) -> ACEvalCase {
        ACEvalCase(
            id: id,
            name: "Action \(id)",
            kind: .chatAction,
            importance: importance,
            categories: categories,
            source: ACEvalSource(appName: "Chat Action"),
            chatActionInput: ACEvalChatActionInput(
                action: CompanionChatAction(kind: .focusPolicy, instruction: "allow current context"),
                latestUserMessage: "this is fine",
                recentUserMessages: ["this is fine"],
                goals: "Ship AC.",
                freeFormMemory: "",
                policyRules: "",
                context: nil,
                activeProfile: ACEvalProfileSummary(id: "general", name: "Everyday", description: nil, isDefault: true),
                availableProfiles: []
            ),
            expectation: ACEvalExpectation(
                chatAction: ACEvalChatActionExpectation(kind: .focusPolicy, intent: "allow")
            )
        )
    }
}

import Foundation

@testable import AC

/// Curated synthetic eval suite for AccountyCat's monitoring + chat judgment.
///
/// These cases are authored by hand (not captured from Inspector) to cover the
/// ~95% of real usage the team wants pinned down before v1.0. Each case is fed
/// straight into the live algorithm + prompts by `AgentEvalRunnerTests`; the
/// expectation compares the model's `assessment` + `suggestedAction`.
///
/// Expectation style (per product decision):
/// - Most cases are *guards*: they forbid the harmful outcome (nudging legit
///   work / staying silent on real drift) and accept any defensible verdict.
/// - A tagged subset uses *discrimination*: it asserts the exact verdict
///   (e.g. tolerated-not-focused) where that distinction is behaviorally load
///   bearing.
///
/// The pass bar is the balanced online tier (DeepSeek V4 Flash text /
/// Qwen 3.6 35B vision). Local runs are informational.
enum SyntheticEvalCases {

    static var all: [ACEvalCase] {
        everydayFocusCases + sessionFocusCases + visionFocusCases + chatCases + chatActionCases
    }

    // MARK: - Shared fixtures

    /// Fixed reference time so `currentContextSeconds` (= now − stableSince) and
    /// every timestamp are deterministic across runs.
    static let now: Date = {
        let formatter = ISO8601DateFormatter()
        return formatter.date(from: "2026-05-23T15:00:00Z")!
    }()

    /// Real screenshots mined from telemetry, copied into a local (non-git) fixtures dir
    /// so we never commit personal screen captures. These exercise the vision pipeline
    /// where the title alone is insufficient or misleading. Run with
    /// `--online-model qwen/qwen3.6-35b-a3b` (the balanced vision model). If a fixture is
    /// missing, the seeder skips the case rather than silently downgrading it to title-only.
    private static let visionFixtureDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/AC/evals/fixtures/vision", isDirectory: true)

    private static func visionShot(_ name: String) -> String {
        visionFixtureDir.appendingPathComponent(name).path
    }

    private static var visionFocusCases: [ACEvalCase] {
        [
            focus(
                id: "syn-vision-everyday-dev-youtube",
                name: "Vision: dev-tool YouTube video in Everyday",
                categories: ["everyday_mode", "browser", "false_positive"],
                rationale:
                    "A YouTube video whose title looks like leisure, but the screen shows a developer-tool walkthrough (a Python type-checker release). Watching dev/learning content is productive — must NOT be nudged. Counterpart to the cat-compilation case: vision distinguishes legit YouTube from entertainment.",
                app: "Google Chrome", bundleID: chrome, title: "Pyrefly v1.0.0 is here! - YouTube",
                screenshotPath: visionShot("everyday-dev-youtube.png"),
                goals: "Build my product and keep learning the tools I use.",
                profile: everyday, contextSeconds: 300,
                browser: true,
                accepted: [.focused, .tolerated, .unclear], acceptedActions: [.none, .abstain],
                forbidden: [.distracted], forbiddenActions: [.nudge, .overlay],
                backend: .online
            ),
            focus(
                id: "syn-vision-session-x-feed",
                name: "Vision: X home feed during an App-Release session",
                categories: ["focus_session", "browser", "false_negative"],
                rationale:
                    "The screen shows the X 'For you' home feed during an active 'App Release' session. This is a deliberate GUARD, not a forced nudge: an X feed during an app launch is genuinely ambiguous (could be checking launch buzz), so a cautious `unclear`/abstain is acceptable. The meaningful assertion is that vision must NOT mistake idle social scrolling for genuine `focused` work, nor treat a sustained feed as a brief `tolerated` detour.",
                app: "Google Chrome", bundleID: chrome, title: "(1) Home / X",
                screenshotPath: visionShot("session-x-feed.png"),
                goals: "Ship the AccountyCat release.",
                profile: named("apprelease-1", "App Release", description: "Final tasks to ship the app: build, release notes, store assets."),
                contextSeconds: 450,
                switches: [
                    switchTo("Google Chrome", "(1) Home / X", agoSeconds: 450, from: "ACInspector"),
                    switchTo("Google Chrome", "Home / X", agoSeconds: 180),
                ],
                browser: true,
                accepted: [.distracted, .unclear], acceptedActions: [.nudge, .overlay, .abstain],
                forbidden: [.focused, .tolerated], forbiddenActions: [.none],
                backend: .online
            ),
            focus(
                id: "syn-vision-everyday-arxiv-paper",
                name: "Vision: reading an arXiv paper in Everyday",
                categories: ["everyday_mode", "browser", "false_positive"],
                rationale:
                    "The window title is an opaque PDF URL (arxiv.org/pdf/1706.03762) — title-only this is ambiguous, but the screen clearly shows an academic paper being read. Deep technical reading is productive → focused.",
                app: "Google Chrome", bundleID: chrome, title: "arxiv.org/pdf/1706.03762 - Google Chrome",
                screenshotPath: visionShot("everyday-arxiv-paper.png"),
                goals: "Build my product; learn the ML foundations behind it.",
                profile: everyday, contextSeconds: 400,
                browser: true,
                accepted: [.focused, .unclear], acceptedActions: [.none, .abstain],
                forbidden: [.distracted], forbiddenActions: [.nudge, .overlay],
                backend: .online
            ),
        ]
    }

    private static let everyday = ACEvalActiveProfile(
        id: PolicyRule.defaultProfileID,
        name: "Everyday",
        isDefault: true,
        description: "Everyday baseline. Active when no named focus session is running."
    )

    private static func named(
        _ id: String,
        _ name: String,
        description: String?,
        activatedAgo: TimeInterval = 3_600
    ) -> ACEvalActiveProfile {
        ACEvalActiveProfile(
            id: id,
            name: name,
            isDefault: false,
            description: description,
            activatedAt: now.addingTimeInterval(-activatedAgo),
            expiresAt: now.addingTimeInterval(3_600)
        )
    }

    private static func switchTo(
        _ app: String,
        _ title: String?,
        agoSeconds: TimeInterval,
        from: String? = nil
    ) -> ACEvalSwitchRecord {
        ACEvalSwitchRecord(
            fromAppName: from,
            toAppName: app,
            toWindowTitle: title,
            timestamp: now.addingTimeInterval(-agoSeconds)
        )
    }

    private static func usage(_ pairs: [(String, Double)]) -> [ACEvalUsageRecord] {
        pairs.map { ACEvalUsageRecord(appName: $0.0, seconds: $0.1) }
    }

    /// Encoded with a plain `JSONEncoder` so it round-trips through the runner's
    /// plain `JSONDecoder` (both use `deferredToDate`, not iso8601).
    private static func policyJSON(_ memory: PolicyMemory?) -> String {
        guard let memory else { return "" }
        guard let data = try? JSONEncoder().encode(memory),
            let string = String(data: data, encoding: .utf8)
        else {
            return ""
        }
        return string
    }

    private static func disallowMemory(
        summary: String,
        titleContains: [String] = [],
        appName: String? = nil
    ) -> PolicyMemory {
        var memory = PolicyMemory()
        memory.rules = [
            PolicyRule(
                kind: .disallow,
                summary: summary,
                source: .userChat,
                createdAt: now.addingTimeInterval(-86_400),
                updatedAt: now.addingTimeInterval(-86_400),
                scope: PolicyRuleScope(appName: appName, titleContains: titleContains),
                profileID: nil
            )
        ]
        return memory
    }

    // MARK: - Focus case builder

    // swiftlint:disable:next function_body_length
    private static func focus(
        id: String,
        name: String,
        importance: ACEvalImportance = .high,
        categories: [String],
        rationale: String,
        app: String,
        bundleID: String?,
        title: String?,
        screenshotPath: String? = nil,
        goals: String,
        memory: String = "",
        userMessages: [String] = [],
        policyMemory: PolicyMemory? = nil,
        profile: ACEvalActiveProfile,
        contextSeconds: TimeInterval,
        distractedCount: Int = 0,
        lastAssessment: ModelAssessment? = nil,
        switches: [ACEvalSwitchRecord] = [],
        usageRecords: [ACEvalUsageRecord] = [],
        browser: Bool = false,
        clearlyProductive: Bool = false,
        helpfulTitle: Bool = true,
        titleRelatesToFocus: Bool? = nil,
        accepted: [ModelAssessment],
        acceptedActions: [ModelSuggestedAction],
        forbidden: [ModelAssessment] = [],
        forbiddenActions: [ModelSuggestedAction] = [],
        backend: ACEvalRecommendedBackend = .local
    ) -> ACEvalCase {
        ACEvalCase(
            id: id,
            name: name,
            kind: .focus,
            importance: importance,
            categories: categories,
            rationale: rationale,
            createdAt: now,
            updatedAt: now,
            source: ACEvalSource(
                appName: app,
                bundleIdentifier: bundleID,
                windowTitle: title,
                timestamp: now,
                screenshotPath: screenshotPath
            ),
            recommendedBackend: backend,
            focusInput: ACEvalFocusInput(
                timestamp: now,
                appName: app,
                bundleIdentifier: bundleID,
                windowTitle: title,
                screenshotPath: screenshotPath,
                goals: goals,
                freeFormMemory: memory,
                recentUserMessages: userMessages,
                policyMemorySummary: "",
                policyMemoryJSON: policyJSON(policyMemory),
                recentSwitches: switches,
                recentActions: [],
                usage: usageRecords,
                heuristics: ACEvalHeuristics(
                    clearlyProductive: clearlyProductive,
                    browser: browser,
                    helpfulWindowTitle: helpfulTitle,
                    periodicVisualReason: browser ? "browser" : nil,
                    titleRelatesToDeclaredFocus: titleRelatesToFocus
                ),
                distraction: ACEvalDistraction(
                    stableSince: now.addingTimeInterval(-contextSeconds),
                    lastAssessment: lastAssessment,
                    consecutiveDistractedCount: distractedCount
                ),
                activeProfile: profile
            ),
            expectation: ACEvalExpectation(
                focus: ACEvalFocusExpectation(
                    acceptedAssessments: accepted,
                    forbiddenAssessments: forbidden,
                    acceptedActions: acceptedActions,
                    forbiddenActions: forbiddenActions
                )
            )
        )
    }

    private static let chrome = "com.google.Chrome"
    private static let xcode = "com.apple.dt.Xcode"

    // MARK: - Everyday-mode focus cases

    private static var everydayFocusCases: [ACEvalCase] {
        [
            focus(
                id: "syn-everyday-work-xcode",
                name: "Everyday: coding in Xcode",
                categories: ["everyday_mode", "good_behavior", "false_positive"],
                rationale:
                    "Genuine productive work in the editor. Must be focused/none — never nudged.",
                app: "Xcode", bundleID: xcode, title: "AC — LLMMonitorAlgorithm.swift",
                goals:
                    "Mostly building and studying. Short check-ins are fine; long scrolling is not.",
                profile: everyday, contextSeconds: 600,
                switches: [
                    switchTo(
                        "Xcode", "AC — LLMMonitorAlgorithm.swift", agoSeconds: 600,
                        from: "Google Chrome")
                ],
                usageRecords: usage([("Xcode", 5_400), ("Google Chrome", 300)]),
                clearlyProductive: true,
                accepted: [.focused], acceptedActions: [.none],
                forbidden: [.distracted], forbiddenActions: [.nudge, .overlay]
            ),
            focus(
                id: "syn-everyday-work-writing",
                name: "Everyday: drafting notes in an editor",
                categories: ["everyday_mode", "good_behavior", "false_positive"],
                rationale: "Writing/planning is productive work. Focused/none.",
                app: "Obsidian", bundleID: "md.obsidian", title: "Q3 roadmap — Obsidian",
                goals: "Build my product and keep planning sharp.",
                profile: everyday, contextSeconds: 480,
                usageRecords: usage([("Obsidian", 1_800)]),
                clearlyProductive: true,
                accepted: [.focused, .unclear], acceptedActions: [.none, .abstain],
                forbidden: [.distracted], forbiddenActions: [.nudge, .overlay]
            ),
            focus(
                id: "syn-everyday-break-instagram",
                name: "Everyday: brief Instagram break after a long coding stretch",
                categories: ["everyday_mode", "good_behavior", "false_positive"],
                rationale:
                    "Default profile, ~80s into a break after a long work stretch (well under the 225s everyday tolerated window). Acceptable-but-not-work: tolerated/none. Must NOT nudge (interrupting a legit short break is a false positive) and must NOT be cached as focused (a break that turns into drift needs a short recheck).",
                app: "Google Chrome", bundleID: chrome, title: "Instagram",
                goals:
                    "I mostly want to build and study. Short check-ins are fine; long scrolling sessions are not.",
                profile: everyday, contextSeconds: 80,
                switches: [
                    switchTo("Google Chrome", "Instagram", agoSeconds: 80, from: "Xcode"),
                    switchTo(
                        "Xcode", "AC — BrainService.swift", agoSeconds: 1_800, from: "Google Chrome"
                    ),
                ],
                usageRecords: usage([("Xcode", 5_400), ("Google Chrome", 240)]),
                browser: true,
                accepted: [.tolerated], acceptedActions: [.none],
                forbidden: [.distracted], forbiddenActions: [.nudge, .overlay],
                backend: .online
            ),
            focus(
                id: "syn-everyday-errand-shopping",
                name: "Everyday: shopping for sunscreen",
                categories: ["everyday_mode", "good_behavior"],
                rationale:
                    "Everyday life admin/shopping is explicitly fine. Tolerated/none; not focused work.",
                app: "Google Chrome", bundleID: chrome, title: "Sonnencreme Gesicht | dm",
                goals: "Build and study most of the day; errands and life admin are fine.",
                profile: everyday, contextSeconds: 120,
                usageRecords: usage([("Xcode", 4_000), ("Google Chrome", 500)]),
                browser: true,
                accepted: [.tolerated], acceptedActions: [.none],
                forbidden: [.distracted], forbiddenActions: [.nudge, .overlay],
                backend: .online
            ),
            focus(
                id: "syn-everyday-quick-message",
                name: "Everyday: quick WhatsApp reply",
                categories: ["everyday_mode", "good_behavior", "false_positive"],
                rationale: "A brief personal message in everyday mode is fine. Must not nudge.",
                app: "WhatsApp", bundleID: "net.whatsapp.WhatsApp", title: "WhatsApp",
                goals: "Build and study; short messages are fine.",
                profile: everyday, contextSeconds: 60,
                usageRecords: usage([("Xcode", 3_600), ("WhatsApp", 120)]),
                accepted: [.tolerated, .focused, .unclear], acceptedActions: [.none, .abstain],
                forbidden: [.distracted], forbiddenActions: [.nudge, .overlay]
            ),
            focus(
                id: "syn-everyday-life-admin-banking",
                name: "Everyday: online banking",
                categories: ["everyday_mode", "good_behavior", "false_positive"],
                rationale: "Banking/taxes/life admin is fine in everyday mode. Must not nudge.",
                app: "Google Chrome", bundleID: chrome, title: "Überweisung — Online Banking",
                goals: "Build and study; life admin and taxes are fine.",
                profile: everyday, contextSeconds: 200,
                usageRecords: usage([("Xcode", 4_200), ("Google Chrome", 600)]),
                browser: true,
                accepted: [.tolerated, .focused, .unclear], acceptedActions: [.none, .abstain],
                forbidden: [.distracted], forbiddenActions: [.nudge, .overlay],
                backend: .online
            ),
            focus(
                id: "syn-everyday-drift-instagram",
                name: "Everyday: sustained Instagram scroll (~11 min)",
                importance: .high,
                categories: ["everyday_mode", "false_negative"],
                rationale:
                    "~11 min on Instagram with the recent timeline dominated by social, no allowance — past the everyday tolerated window. Should be distracted/nudge; staying silent here is a real miss.",
                app: "Google Chrome", bundleID: chrome, title: "Instagram",
                goals:
                    "I mostly want to build and study. Short check-ins are fine; long scrolling sessions are not.",
                profile: everyday, contextSeconds: 660,
                switches: [
                    switchTo("Google Chrome", "Instagram", agoSeconds: 660, from: "Google Chrome"),
                    switchTo("Google Chrome", "Reels • Instagram", agoSeconds: 400),
                    switchTo("Google Chrome", "Instagram", agoSeconds: 120),
                ],
                usageRecords: usage([("Google Chrome", 1_200), ("Xcode", 1_800)]),
                browser: true,
                accepted: [.distracted], acceptedActions: [.nudge, .overlay],
                forbidden: [.focused, .tolerated], forbiddenActions: [.none, .abstain],
                backend: .online
            ),
            focus(
                id: "syn-everyday-drift-youtube",
                name: "Everyday: entertainment YouTube binge (~15 min)",
                categories: ["everyday_mode", "false_negative"],
                rationale:
                    "Long entertainment-video session with a social/video timeline. Should be distracted/nudge.",
                app: "Google Chrome", bundleID: chrome,
                title: "Funny Cat Compilation 2026 - YouTube",
                goals:
                    "Build and study most of the day; long entertainment binges are not the plan.",
                profile: everyday, contextSeconds: 900,
                switches: [
                    switchTo(
                        "Google Chrome", "Funny Cat Compilation 2026 - YouTube", agoSeconds: 900),
                    switchTo("Google Chrome", "Top 10 Fails - YouTube", agoSeconds: 500),
                ],
                usageRecords: usage([("Google Chrome", 1_500)]),
                browser: true,
                accepted: [.distracted], acceptedActions: [.nudge, .overlay],
                forbidden: [.focused, .tolerated], forbiddenActions: [.none, .abstain],
                backend: .online
            ),
            focus(
                id: "syn-everyday-ambiguous-newtab",
                name: "Everyday: blank New Tab",
                importance: .medium,
                categories: ["everyday_mode", "browser", "false_positive"],
                rationale:
                    "A blank new tab is a momentary surface with no signal. Must not nudge; abstain/unclear is the designed behavior.",
                app: "Google Chrome", bundleID: chrome, title: "New Tab",
                goals: "Build and study; short check-ins are fine.",
                profile: everyday, contextSeconds: 15,
                browser: true,
                accepted: [.unclear, .focused, .tolerated], acceptedActions: [.none, .abstain],
                forbidden: [.distracted], forbiddenActions: [.nudge, .overlay]
            ),
            focus(
                id: "syn-everyday-ambiguous-chatgpt",
                name: "Everyday: blank ChatGPT surface",
                importance: .medium,
                categories: ["everyday_mode", "browser"],
                rationale:
                    "An AI start surface with no visible task is explicitly ambiguous. Abstain until evidence appears.",
                app: "Google Chrome", bundleID: chrome, title: "ChatGPT",
                goals: "Build and study; short check-ins are fine.",
                profile: everyday, contextSeconds: 15,
                browser: true,
                accepted: [.unclear], acceptedActions: [.abstain],
                forbidden: [.distracted], forbiddenActions: [.nudge, .overlay],
                backend: .online
            ),
            focus(
                id: "syn-everyday-rule-disallow-instagram",
                name: "Everyday: Instagram with an active disallow rule",
                categories: ["everyday_mode", "false_negative"],
                rationale:
                    "User installed a 'no Instagram' rule. Even early in the visit, the active restrictive rule makes Instagram distracted/nudge.",
                app: "Google Chrome", bundleID: chrome, title: "Instagram",
                goals: "Build and study.",
                policyMemory: disallowMemory(
                    summary: "No Instagram during the day", titleContains: ["instagram"]),
                profile: everyday, contextSeconds: 200,
                browser: true,
                accepted: [.distracted], acceptedActions: [.nudge, .overlay],
                forbidden: [.focused, .tolerated], forbiddenActions: [.none, .abstain],
                backend: .online
            ),
            focus(
                id: "syn-everyday-allowance-scroll",
                name: "Everyday: user allowed 15 min of scrolling",
                categories: ["everyday_mode", "good_behavior", "false_positive"],
                rationale:
                    "User explicitly allowed a scrolling break. Must not nudge; tolerated/none (or focused/none if the deterministic allowance fires).",
                app: "Google Chrome", bundleID: chrome, title: "Instagram",
                goals: "Build and study; short breaks are fine.",
                userMessages: ["[2026-05-23 16:55] 15 minutes of scrolling after lunch is fine"],
                profile: everyday, contextSeconds: 300,
                browser: true,
                accepted: [.tolerated, .focused], acceptedActions: [.none],
                forbidden: [.distracted], forbiddenActions: [.nudge, .overlay],
                backend: .online
            ),
            focus(
                id: "syn-everyday-done-relaxing",
                name: "Everyday: user said they're done for the day",
                categories: ["everyday_mode", "good_behavior", "false_positive"],
                rationale:
                    "Newest message says work is over and they're relaxing — an allowance for now. Must not nudge.",
                app: "Google Chrome", bundleID: chrome, title: "YouTube",
                goals: "Build and study during the day.",
                userMessages: [
                    "[2026-05-23 19:30] I'm done with work for today, just relaxing now"
                ],
                profile: everyday, contextSeconds: 300,
                browser: true,
                accepted: [.tolerated, .focused], acceptedActions: [.none],
                forbidden: [.distracted], forbiddenActions: [.nudge, .overlay],
                backend: .online
            ),
        ]
    }

    // MARK: - Named-session focus cases

    private static var sessionFocusCases: [ACEvalCase] {
        [
            focus(
                id: "syn-session-coding-on-task",
                name: "Session: coding in Xcode during a Coding session",
                categories: ["focus_session", "good_behavior", "false_positive"],
                rationale: "On-task work inside the declared session. Focused/none.",
                app: "Xcode", bundleID: xcode, title: "AC — BrainService.swift",
                goals: "Ship AC.",
                profile: named(
                    "coding-1", "Coding",
                    description: "Coding work: implementation, debugging, docs, and tutorials."),
                contextSeconds: 600,
                usageRecords: usage([("Xcode", 2_400)]),
                clearlyProductive: true,
                accepted: [.focused], acceptedActions: [.none],
                forbidden: [.distracted], forbiddenActions: [.nudge, .overlay]
            ),
            focus(
                id: "syn-session-coding-research",
                name: "Session: Stack Overflow research during Coding",
                categories: ["focus_session", "browser", "false_positive"],
                rationale:
                    "Adjacent research for a broad Coding archetype is on-task. Must not nudge — interrupting legitimate research is a bug.",
                app: "Google Chrome", bundleID: chrome,
                title: "URLSession dataTask example - Stack Overflow",
                goals: "Ship AC.",
                profile: named(
                    "coding-1", "Coding",
                    description: "Coding work: implementation, debugging, docs, and tutorials."),
                contextSeconds: 240,
                browser: true, titleRelatesToFocus: true,
                accepted: [.focused, .unclear], acceptedActions: [.none, .abstain],
                forbidden: [.distracted], forbiddenActions: [.nudge, .overlay],
                backend: .online
            ),
            focus(
                id: "syn-session-broad-tutorial-focused",
                name: "Session: tutorial video in a BROAD Coding profile",
                categories: ["focus_session", "false_positive"],
                rationale:
                    "Broad 'Coding' archetype with no narrowing description includes tutorials. Focused/none.",
                app: "Google Chrome", bundleID: chrome,
                title: "Build a macOS menu bar app - YouTube",
                goals: "Ship AC.",
                profile: named("coding-1", "Coding", description: nil),
                contextSeconds: 300,
                browser: true, titleRelatesToFocus: true,
                accepted: [.focused, .tolerated, .unclear], acceptedActions: [.none, .abstain],
                forbidden: [.distracted], forbiddenActions: [.nudge, .overlay],
                backend: .online
            ),
            focus(
                id: "syn-session-strict-tutorial-distracted",
                name: "Session: tutorial video in a STRICT code-writing profile",
                categories: ["focus_session", "false_negative"],
                rationale:
                    "Profile description narrows scope to code writing only, no tutorials/videos. The same tutorial is now distracted/nudge.",
                app: "Google Chrome", bundleID: chrome,
                title: "Build a macOS menu bar app - YouTube",
                goals: "Ship AC.",
                profile: named(
                    "coding-strict", "Coding",
                    description: "Focused code writing only — no tutorials or videos."),
                contextSeconds: 300,
                browser: true,
                accepted: [.distracted], acceptedActions: [.nudge, .overlay],
                forbidden: [.focused, .tolerated], forbiddenActions: [.none, .abstain],
                backend: .online
            ),
            focus(
                id: "syn-session-brief-detour-whatsapp",
                name: "Session: one WhatsApp reply during Coding",
                categories: ["focus_session", "good_behavior", "false_positive"],
                rationale:
                    "A brief personal message during a focus session is a tolerated detour, not a distraction. Must not nudge a 90s message.",
                app: "WhatsApp", bundleID: "net.whatsapp.WhatsApp", title: "WhatsApp",
                goals: "Ship AC.",
                profile: named(
                    "coding-1", "Coding",
                    description: "Coding work: implementation, debugging, docs, and tutorials."),
                contextSeconds: 90,
                accepted: [.tolerated, .focused, .unclear], acceptedActions: [.none, .abstain],
                forbidden: [.distracted], forbiddenActions: [.nudge, .overlay],
                backend: .online
            ),
            focus(
                id: "syn-session-offtask-instagram",
                name: "Session: Instagram during a Writing session",
                categories: ["focus_session", "false_negative"],
                rationale:
                    "Sustained (~9 min) off-task social with the recent timeline dominated by Instagram, no allowance, during an active Writing session. A brief glance would be a tolerated detour, but this is clear drift → distracted/nudge.",
                app: "Google Chrome", bundleID: chrome, title: "Instagram",
                goals: "Finish the thesis chapter.",
                profile: named("writing-1", "Writing", description: "Drafting the thesis chapter."),
                contextSeconds: 540,
                switches: [
                    switchTo("Google Chrome", "Instagram", agoSeconds: 540, from: "Pages"),
                    switchTo("Google Chrome", "Reels • Instagram", agoSeconds: 300),
                    switchTo("Google Chrome", "Instagram", agoSeconds: 90),
                ],
                usageRecords: usage([("Pages", 2_400), ("Google Chrome", 700)]),
                browser: true,
                accepted: [.distracted], acceptedActions: [.nudge, .overlay],
                forbidden: [.focused, .tolerated], forbiddenActions: [.none, .abstain],
                backend: .online
            ),
            focus(
                id: "syn-session-offtask-shopping",
                name: "Session: shopping during a Writing session",
                categories: ["focus_session", "false_negative"],
                rationale:
                    "Sustained (~9 min) shopping with the recent timeline dominated by the shop, during an active Writing session with no allowance. Named sessions are stricter, so prolonged shopping here is off-task → distracted/nudge.",
                app: "Google Chrome", bundleID: chrome, title: "Sonnencreme Gesicht | dm",
                goals: "Finish the thesis chapter.",
                profile: named("writing-1", "Writing", description: "Drafting the thesis chapter."),
                contextSeconds: 540,
                switches: [
                    switchTo("Google Chrome", "Sonnencreme Gesicht | dm", agoSeconds: 540, from: "Pages"),
                    switchTo("Google Chrome", "Warenkorb | dm", agoSeconds: 220),
                    switchTo("Google Chrome", "Sonnencreme Gesicht | dm", agoSeconds: 70),
                ],
                usageRecords: usage([("Pages", 2_400), ("Google Chrome", 760)]),
                browser: true,
                accepted: [.distracted], acceptedActions: [.nudge, .overlay],
                forbidden: [.focused, .tolerated], forbiddenActions: [.none, .abstain],
                backend: .online
            ),
            focus(
                id: "syn-session-repeated-overlay",
                name: "Session: repeated Instagram distraction (streak 2)",
                importance: .medium,
                categories: ["focus_session", "regression"],
                rationale:
                    "Sustained (~9 min) off-task social, and the distracted streak is already 2 with no newer allowance. The model should propose overlay (escalation); nudge is acceptable since the deterministic gate also escalates a repeated nudge.",
                app: "Google Chrome", bundleID: chrome, title: "Instagram",
                goals: "Finish the thesis chapter.",
                profile: named("writing-1", "Writing", description: "Drafting the thesis chapter."),
                contextSeconds: 540, distractedCount: 2, lastAssessment: .distracted,
                switches: [
                    switchTo("Google Chrome", "Instagram", agoSeconds: 540, from: "Pages"),
                    switchTo("Google Chrome", "Reels • Instagram", agoSeconds: 250),
                    switchTo("Google Chrome", "Instagram", agoSeconds: 80),
                ],
                usageRecords: usage([("Pages", 1_800), ("Google Chrome", 900)]),
                browser: true,
                accepted: [.distracted], acceptedActions: [.overlay, .nudge],
                forbidden: [.focused, .tolerated], forbiddenActions: [.none, .abstain],
                backend: .online
            ),
            focus(
                id: "syn-session-offscope-productive",
                name: "Session: coding during a Presentation-prep session",
                importance: .medium,
                categories: ["focus_session", "false_negative"],
                rationale:
                    "Productive work that doesn't fit the declared session scope is still a distraction (coding during slide-building).",
                app: "Xcode", bundleID: xcode, title: "AC — ContentView.swift",
                goals: "Have the deck ready for Monday's review.",
                profile: named(
                    "present-1", "Presentation prep",
                    description: "Building slides for Monday's review."),
                contextSeconds: 240,
                clearlyProductive: true,
                accepted: [.distracted], acceptedActions: [.nudge, .overlay],
                forbidden: [.focused], forbiddenActions: [.none, .abstain],
                backend: .online
            ),
            focus(
                id: "syn-session-grace-adjacent",
                name: "Session: plausible adjacent work 3 min into Research",
                categories: ["focus_session", "false_positive"],
                rationale:
                    "Just-activated session (3 min): plausible on-topic reading (arXiv during Research) should be focused, not nudged on thin early evidence.",
                app: "Google Chrome", bundleID: chrome, title: "Attention Is All You Need — arXiv",
                goals: "Research transformer architectures for the project.",
                profile: named(
                    "research-1", "Research",
                    description: "Reading papers and notes on ML architectures.", activatedAgo: 180),
                contextSeconds: 100,
                browser: true, titleRelatesToFocus: true,
                accepted: [.focused, .unclear], acceptedActions: [.none, .abstain],
                forbidden: [.distracted], forbiddenActions: [.nudge, .overlay],
                backend: .online
            ),
            focus(
                id: "syn-session-correction-research",
                name: "Session: deal site is competitor research (user said so)",
                categories: ["focus_session", "false_positive"],
                rationale:
                    "A deal-hunting title would normally look off-task in a Coding session, but the newest user message says it's competitor pricing research for the project. The user's current-session statement wins. Focused/none.",
                app: "Google Chrome", bundleID: chrome,
                title: "(99+) mydealz - Deine Nr.1 Schnäppchen & Deals Community",
                goals: "Ship AC.",
                userMessages: [
                    "[2026-05-23 16:40] the mydealz tab is competitor pricing research for our paywall page"
                ],
                profile: named(
                    "coding-1", "Coding",
                    description: "Coding work: implementation, debugging, docs, and tutorials."),
                contextSeconds: 180,
                browser: true,
                accepted: [.focused, .tolerated], acceptedActions: [.none],
                forbidden: [.distracted], forbiddenActions: [.nudge, .overlay],
                backend: .online
            ),
            focus(
                id: "syn-everyday-correction-youtube",
                name: "Everyday: YouTube is the project's setup guide (user said so)",
                categories: ["everyday_mode", "false_positive"],
                rationale:
                    "A YouTube title looks like leisure, but the newest user message says it's the setup guide for what they're building. Match the visible activity to the stated intent. Focused/none.",
                app: "Google Chrome", bundleID: chrome,
                title: "Setting up llama.cpp on macOS - YouTube",
                goals: "Build my product.",
                userMessages: [
                    "[2026-05-23 14:55] this youtube video is the setup guide for the project I'm building"
                ],
                profile: everyday, contextSeconds: 240,
                browser: true, titleRelatesToFocus: true,
                accepted: [.focused, .tolerated], acceptedActions: [.none],
                forbidden: [.distracted], forbiddenActions: [.nudge, .overlay],
                backend: .online
            ),
        ]
    }

    // MARK: - Chat case builder + cases

    private static func chatContext(app: String, title: String?) -> ACEvalChatContext {
        ACEvalChatContext(
            frontmostAppName: app,
            frontmostWindowTitle: title,
            idleSeconds: 0,
            timestamp: now,
            recentSwitches: [],
            usage: []
        )
    }

    private static func chat(
        id: String,
        name: String,
        importance: ACEvalImportance = .high,
        categories: [String],
        rationale: String,
        userMessage: String,
        goals: String = "Ship AC and stay focused on engineering work.",
        memory: String = "",
        policyRules: String = "",
        app: String = "Xcode",
        title: String? = "AC",
        expectation: ACEvalChatExpectation,
        backend: ACEvalRecommendedBackend = .online
    ) -> ACEvalCase {
        ACEvalCase(
            id: id,
            name: name,
            kind: .chat,
            importance: importance,
            categories: categories,
            rationale: rationale,
            createdAt: now,
            updatedAt: now,
            source: ACEvalSource(appName: "Chat", timestamp: now),
            recommendedBackend: backend,
            chatInput: ACEvalChatInput(
                userMessage: userMessage,
                goals: goals,
                memory: memory,
                policyRules: policyRules,
                context: chatContext(app: app, title: title),
                history: [],
                character: "mochi",
                activeProfileContext: "",
                workflow: .staged
            ),
            expectation: ACEvalExpectation(chat: expectation)
        )
    }

    private static var chatCases: [ACEvalCase] {
        [
            chat(
                id: "syn-chat-start-coding",
                name: "Chat: start a coding focus session",
                categories: ["chat", "profile"],
                rationale:
                    "Explicit request to enter a focus mode should produce a profile action plus a friendly reply.",
                userMessage: "Let's focus on coding for the next hour.",
                expectation: ACEvalChatExpectation(requiredActionKinds: [.profile])
            ),
            chat(
                id: "syn-chat-remember-breaks",
                name: "Chat: remember a standing preference",
                categories: ["chat", "memory"],
                rationale: "A stated standing preference should be captured as a memory action.",
                userMessage: "Remember that I like to take a short break every hour.",
                expectation: ACEvalChatExpectation(requiredActionKinds: [.memory])
            ),
            chat(
                id: "syn-chat-allow-youtube",
                name: "Chat: allow YouTube for 20 minutes",
                categories: ["chat", "focus_policy"],
                rationale:
                    "A temporary allowance for a specific activity should produce a focus-policy action.",
                userMessage: "Let me watch YouTube for the next 20 minutes, that's fine.",
                expectation: ACEvalChatExpectation(requiredActionKinds: [.focusPolicy])
            ),
            chat(
                id: "syn-chat-vent-no-action",
                name: "Chat: emotional vent (no action)",
                importance: .medium,
                categories: ["chat", "regression"],
                rationale:
                    "A vent is not an instruction. AC should reply warmly but take no profile/memory/policy action.",
                userMessage: "Ugh, today has been so exhausting and nothing is working.",
                expectation: ACEvalChatExpectation(forbiddenActionKinds: [
                    .profile, .memory, .focusPolicy, .recurringNudge,
                ])
            ),
            chat(
                id: "syn-chat-recurring-break",
                name: "Chat: recurring daily break reminder",
                importance: .medium,
                categories: ["chat", "chat_action"],
                rationale: "A daily timed reminder should produce a recurring-nudge action.",
                userMessage: "Remind me to take a break every day at 3pm.",
                expectation: ACEvalChatExpectation(requiredActionKinds: [.recurringNudge])
            ),
        ]
    }

    // MARK: - Chat-action case builder + cases

    private static func chatAction(
        id: String,
        name: String,
        importance: ACEvalImportance = .high,
        categories: [String],
        rationale: String,
        action: CompanionChatAction,
        latestUserMessage: String,
        goals: String = "Ship AC and stay focused on engineering work.",
        memory: String = "",
        policyRules: String = "",
        activeProfile: ACEvalProfileSummary = ACEvalProfileSummary(
            id: PolicyRule.defaultProfileID, name: "Everyday", description: nil, isDefault: true),
        availableProfiles: [ACEvalProfileSummary] = [],
        expectation: ACEvalChatActionExpectation,
        backend: ACEvalRecommendedBackend = .online
    ) -> ACEvalCase {
        ACEvalCase(
            id: id,
            name: name,
            kind: .chatAction,
            importance: importance,
            categories: categories,
            rationale: rationale,
            createdAt: now,
            updatedAt: now,
            source: ACEvalSource(appName: "Chat Action", timestamp: now),
            recommendedBackend: backend,
            chatActionInput: ACEvalChatActionInput(
                action: action,
                latestUserMessage: latestUserMessage,
                recentUserMessages: [latestUserMessage],
                goals: goals,
                freeFormMemory: memory,
                policyRules: policyRules,
                context: ACEvalFrontmostContext(
                    bundleIdentifier: xcode, appName: "Xcode", windowTitle: "AC"),
                activeProfile: activeProfile,
                availableProfiles: availableProfiles
            ),
            expectation: ACEvalExpectation(chatAction: expectation)
        )
    }

    private static var chatActionCases: [ACEvalCase] {
        [
            chatAction(
                id: "syn-action-memory-breaks",
                name: "Chat-action: resolve a memory write",
                categories: ["chat_action", "memory"],
                rationale:
                    "The memory executor should produce a memory action whose text captures the preference.",
                action: CompanionChatAction(
                    kind: .memory, instruction: "remember I like a short break every hour"),
                latestUserMessage: "remember I like a short break every hour",
                expectation: ACEvalChatActionExpectation(kind: .memory, textContains: "break")
            ),
            chatAction(
                id: "syn-action-profile-create-narrow",
                name: "Chat-action: create a narrow Essay profile (not reuse broad Thesis)",
                categories: ["chat_action", "profile"],
                rationale:
                    "User wants pure essay writing; the only candidate is a broad Thesis profile that also allows research/admin. The executor should produce a profile action (ideally create, not reuse the looser profile).",
                action: CompanionChatAction(
                    kind: .profile,
                    instruction: "focus on writing my essay — just writing, nothing else"),
                latestUserMessage: "focus on writing my essay — just writing, nothing else",
                availableProfiles: [
                    ACEvalProfileSummary(
                        id: "thesis-1", name: "Thesis",
                        description: "Thesis work: writing, research, reading sources, and admin.",
                        isDefault: false)
                ],
                expectation: ACEvalChatActionExpectation(kind: .profile)
            ),
            chatAction(
                id: "syn-action-profile-activate-broad",
                name: "Chat-action: reuse the broad Coding profile",
                importance: .medium,
                categories: ["chat_action", "profile"],
                rationale:
                    "A broad 'coding for an hour' request matches an existing broad Coding profile; the executor should produce a profile action that reuses it.",
                action: CompanionChatAction(
                    kind: .profile, instruction: "help me focus on coding for an hour"),
                latestUserMessage: "help me focus on coding for an hour",
                availableProfiles: [
                    ACEvalProfileSummary(
                        id: "coding-1", name: "Coding",
                        description:
                            "Coding work, including implementation, debugging, docs, and tutorials.",
                        isDefault: false)
                ],
                expectation: ACEvalChatActionExpectation(kind: .profile)
            ),
            chatAction(
                id: "syn-action-focus-policy-allow",
                name: "Chat-action: resolve a focus-policy allowance",
                categories: ["chat_action", "focus_policy"],
                rationale: "A temporary allowance should resolve to a focus-policy action.",
                action: CompanionChatAction(
                    kind: .focusPolicy, instruction: "let me use YouTube for 20 minutes"),
                latestUserMessage: "let me use YouTube for 20 minutes",
                expectation: ACEvalChatActionExpectation(kind: .focusPolicy)
            ),
        ]
    }
}

//
//  MonitoringLLMClientPromptTests.swift
//  ACTests
//
//  Created by Codex on 15.04.26.
//

import Foundation
import Testing
@testable import AC

struct MonitoringLLMClientPromptTests {

    @Test
    func visionPayloadIncludesMemoryAndInterventionHistory() {
        let payload = MonitoringLLMClient.makeVisionPayload(
            snapshot: makeSnapshot(timestamp: Date(timeIntervalSince1970: 7_200)),
            goals: "I want to spend most of my time studying, building, and gaining experience.",
            recentActions: makeRecentActions(),
            heuristics: makeHeuristics(),
            distraction: DistractionMetadata(
                contextKey: "com.google.Chrome|Instagram",
                stableSince: Date(timeIntervalSince1970: 100),
                lastAssessment: .distracted,
                consecutiveDistractedCount: 2,
                nextEvaluationAt: Date(timeIntervalSince1970: 200)
            ),
            memory: """
            User's focus areas are studying, building, and gaining experience.
            User's focus areas are studying, building, and gaining experience.
            Don't let me waste time on Instagram.
            Keep social check-ins short.
            """
        )

        #expect(payload.memory == "Don't let me waste time on Instagram.\nKeep social check-ins short.")
        #expect(payload.interventionHistory.nudgeCount == 1)
        #expect(payload.interventionHistory.dismissOverlayCount == 1)
        #expect(payload.interventionHistory.recentNudgeMessages == [
            "Still worth it?"
        ])
        #expect(payload.interventionHistory.recentInterventions.count == 3)
    }

    @Test
    func promptsReferenceHistorySoFallbackKeepsContextToo() {
        let actions = makeRecentActions()
        let heuristics = makeHeuristics()
        let distraction = DistractionMetadata(
            contextKey: "com.google.Chrome|Instagram",
            stableSince: Date(timeIntervalSince1970: 100),
            lastAssessment: .distracted,
            consecutiveDistractedCount: 1,
            nextEvaluationAt: Date(timeIntervalSince1970: 200)
        )
        let payload = MonitoringLLMClient.makeVisionPayload(
            snapshot: makeSnapshot(),
            goals: "Ship focused work",
            recentActions: actions,
            heuristics: heuristics,
            distraction: distraction,
            memory: "Instagram should stay short."
        )
        let payloadJSON = MonitoringLLMClient.encodePayload(payload)
        let profile = PromptCatalog.defaultMonitoringPromptProfile
        let userPrompt = MonitoringLLMClient.makeUserPrompt(
            payloadJSON: payloadJSON,
            promptProfile: profile,
            variant: .visionPrimaryUser
        )
        let fallbackPrompt = MonitoringLLMClient.makeUserPrompt(
            payloadJSON: payloadJSON,
            promptProfile: profile,
            variant: .fallbackUser
        )

        #expect(userPrompt.contains("interventionHistory"))
        #expect(userPrompt.contains("Instagram should stay short."))
        #expect(userPrompt.contains("do not repeat the same wording"))
        #expect(fallbackPrompt.contains("interventionHistory"))
        #expect(fallbackPrompt.contains("Instagram should stay short."))
        #expect(fallbackPrompt.contains("do not repeat recent nudges"))
    }

    @Test
    func promptStaysCompactWithNoisyHistory() {
        let noisyMemoryLines =
            Array(repeating: "User's focus areas are studying, building, and gaining experience.", count: 12) +
            ["Don't let me scroll Instagram for long.", "Keep social breaks short."]
        let noisyMemory = noisyMemoryLines.joined(separator: "\n")
        let prompt = MonitoringLLMClient.makeUserPrompt(
            snapshot: makeSnapshot(timestamp: Date(timeIntervalSince1970: 7_200)),
            goals: "I want to spend most of my time studying, building, and gaining experience.",
            recentActions: makeRecentActions(),
            heuristics: makeHeuristics(),
            distraction: DistractionMetadata(
                contextKey: "com.google.Chrome|Instagram",
                stableSince: Date(timeIntervalSince1970: 100),
                lastAssessment: .distracted,
                consecutiveDistractedCount: 1,
                nextEvaluationAt: Date(timeIntervalSince1970: 200)
            ),
            memory: noisyMemory
        )

        #expect(prompt.contains("Debug nudge") == false)
        #expect(prompt.contains("\"recentActions\"") == false)
        #expect(prompt.contains("\"responseSchema\"") == false)
        #expect(prompt.count < 4000)
    }

    private func makeSnapshot(timestamp: Date = Date(timeIntervalSince1970: 1)) -> AppSnapshot {
        AppSnapshot(
            bundleIdentifier: "com.google.Chrome",
            appName: "Google Chrome",
            windowTitle: "Instagram",
            recentSwitches: [
                AppSwitchRecord(
                    fromAppName: "Xcode",
                    toAppName: "Google Chrome",
                    toWindowTitle: "Instagram",
                    timestamp: timestamp.addingTimeInterval(-10)
                ),
                AppSwitchRecord(
                    fromAppName: "Google Chrome",
                    toAppName: "Google Chrome",
                    toWindowTitle: "Instagram",
                    timestamp: timestamp.addingTimeInterval(-20)
                ),
                AppSwitchRecord(
                    fromAppName: "ACInspector",
                    toAppName: "Google Chrome",
                    toWindowTitle: "Rive Pricing",
                    timestamp: timestamp.addingTimeInterval(-30)
                ),
            ],
            perAppDurations: [
                AppUsageRecord(appName: "Google Chrome", seconds: 4_000),
                AppUsageRecord(appName: "Xcode", seconds: 2_000),
                AppUsageRecord(appName: "Codex", seconds: 1_000),
                AppUsageRecord(appName: "ACInspector", seconds: 500),
                AppUsageRecord(appName: "Claude", seconds: 250),
            ],
            screenshotArtifact: ArtifactRef(
                id: "shot",
                kind: .screenshotOriginal,
                relativePath: "shot.png",
                sha256: nil,
                byteCount: 0,
                width: nil,
                height: nil,
                createdAt: Date(timeIntervalSince1970: 1)
            ),
            screenshotThumbnail: nil,
            screenshotPath: "/tmp/shot.png",
            idle: false,
            timestamp: timestamp
        )
    }

    private func makeHeuristics() -> TelemetryHeuristicSnapshot {
        TelemetryHeuristicSnapshot(
            clearlyProductive: false,
            browser: true,
            helpfulWindowTitle: true,
            periodicVisualReason: "browser"
        )
    }

    private func makeRecentActions() -> [ActionRecord] {
        [
            ActionRecord(
                kind: .nudge,
                message: "Debug nudge: time to check that the panel is visible.",
                timestamp: Date(timeIntervalSince1970: 1_000)
            ),
            ActionRecord(
                kind: .nudge,
                message: "Hey there, make sure this is how you want to spend your time.",
                timestamp: Date(timeIntervalSince1970: 100)
            ),
            ActionRecord(
                kind: .nudge,
                message: "Still worth it?",
                timestamp: Date(timeIntervalSince1970: 6_900)
            ),
            ActionRecord(
                kind: .dismissOverlay,
                message: nil,
                timestamp: Date(timeIntervalSince1970: 6_930)
            ),
            ActionRecord(
                kind: .backToWork,
                message: "Xcode",
                timestamp: Date(timeIntervalSince1970: 6_950)
            ),
        ]
    }
}

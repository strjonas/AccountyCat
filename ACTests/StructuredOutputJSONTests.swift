//
//  StructuredOutputJSONTests.swift
//  ACTests
//
//  Created by Codex on 20.04.26.
//

import Foundation
import Testing
@testable import AC

struct StructuredOutputJSONTests {

    @Test
    func extractsFinalDecisionAfterTruncatedPromptEcho() {
        let output = """
        > Decide AC's action from this text-only context.
        {"activitySummary":"Using Codex in an unclear way.","heuristics":{"browser":false,"helpfulWindowTitle":false ... (truncated)

        |^H-^H\\^H|^H/^H-^H ^H{"assessment":"focused","suggested_action":"none","confidence":0.91,"reason_tags":["coding"]}
        """

        let decision = LLMOutputParsing.extractDecision(from: output)

        #expect(decision?.assessment == .focused)
        #expect(decision?.suggestedAction == .some(.none))
        #expect(decision?.reasonTags == ["coding"])
    }

    @Test
    func normalizesUnclearDecisionToAbstain() {
        let output = """
        {"assessment":"unclear","suggested_action":"nudge","confidence":0.85,"reason_tags":["perception_fallback"],"nudge":"Try to focus on your study goals."}
        """

        let decision = LLMOutputParsing.extractDecision(from: output)

        #expect(decision?.assessment == .unclear)
        #expect(decision?.suggestedAction == .abstain)
    }

    @Test
    func perceptionEnvelopeDecodesStringNotes() {
        let output = """
        > The screenshot is attached.
        {"frontmostApp":"Codex","memory":"Keep YouTube short." ... (truncated)

        {"scene_summary":"Editing code and reading docs in Codex","focus_guess":"focused","reason_tags":["coding","docs"],"notes":"Working in a development environment."}
        """

        let envelope = StructuredOutputJSON.decode(MonitoringPerceptionEnvelope.self, from: output)

        #expect(envelope?.activitySummary == "Editing code and reading docs in Codex")
        #expect(envelope?.focusGuess == .focused)
        #expect(envelope?.notes == ["Working in a development environment."])
    }

    @Test
    func sharedPerceptionEnvelopeDecodesStringNotes() {
        let output = """
        > The screenshot is attached.
        {"appName":"Codex","windowTitle":"AC" ... (truncated)

        {"scene_summary":"Editing code and reading docs in Codex","focus_guess":"focused","reason_tags":["coding","docs"],"notes":"Working in a development environment."}
        """

        let envelope = StructuredOutputJSON.decode(MonitoringPerceptionEnvelope.self, from: output)

        #expect(envelope?.activitySummary == "Editing code and reading docs in Codex")
        #expect(envelope?.focusGuess == .focused)
        #expect(envelope?.notes == ["Working in a development environment."])
    }

    @Test
    func chatFallbackRecoversPartialReplyWithoutUsageMetadata() {
        let output = """
        reply": "Time to hit the hay,
        usage prompt_tokens=2056 completion_tokens=320 total_tokens=2376 cost=0.000361944
        """

        let cleaned = LLMOutputParsing.cleanChatOutput(output)

        #expect(cleaned == "Time to hit the hay,")
    }

    @Test
    func chatFallbackDropsRuntimeUsageLineFromPlainReply() {
        let output = """
        Go to bed. No more work tonight.
        usage prompt_tokens=2056 completion_tokens=320 total_tokens=2376 cost=0.000361944
        """

        let cleaned = LLMOutputParsing.cleanChatOutput(output)

        #expect(cleaned == "Go to bed. No more work tonight.")
    }

    @Test
    func chatResultParsesEmptyActions() throws {
        let output = """
        {"reply":"Just chatting.","actions":[],"schedule":null}
        """

        let result = try #require(LLMOutputParsing.extractChatResult(from: output))

        #expect(result.reply == "Just chatting.")
        #expect(result.actions.isEmpty)
        #expect(result.schedule?.delayMinutes == nil)
    }

    @Test
    func chatResultParsesMultipleActions() throws {
        let output = """
        {"reply":"Got it.","actions":[{"kind":"profile","instruction":"start coding for one hour"},{"kind":"memory","text":"User prefers short breaks."},{"kind":"focus_policy","intent":"allow","target":{"type":"current_context"},"duration":"profile_session"}],"schedule":null}
        """

        let result = try #require(LLMOutputParsing.extractChatResult(from: output))

        #expect(result.actions.count == 3)
        #expect(result.actions[0].kind == .profile)
        #expect(result.actions[1].text == "User prefers short breaks.")
        #expect(result.actions[2].target?.type == "current_context")
    }

    @Test
    func actionResolutionParsesWrappedAction() throws {
        let output = """
        {"action":{"kind":"focus_policy","intent":"allow","scope":"active_profile","target":{"type":"current_context"},"duration":"profile_session","locked":true}}
        """

        let action = try #require(LLMOutputParsing.extractChatAction(from: output, expectedKind: .focusPolicy))

        #expect(action.kind == .focusPolicy)
        #expect(action.intent == "allow")
        #expect(action.locked == true)
    }

    @Test
    func memoryRenderingDoesNotScopeLegacyProfileEntries() {
        let createdAt = Date(timeIntervalSince1970: 1_745_423_400)
        let entries = [
            MemoryEntry(
                createdAt: createdAt,
                text: "No work after 22:00",
                profileID: "coding",
                profileName: "Coding"
            )
        ]

        let prompt = MemoryRendering.renderForPrompt(
            entries: entries,
            now: Date(timeIntervalSince1970: 1_745_423_700),
            maxLines: 5,
            maxCharacters: 400
        )

        #expect(prompt.contains("[Coding]") == false)
        #expect(prompt.contains("No work after 22:00"))
    }
}

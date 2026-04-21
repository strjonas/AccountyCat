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

        let envelope = StructuredOutputJSON.decode(LegacyFocusPerceptionEnvelope.self, from: output)

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
}

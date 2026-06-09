import Foundation
import Testing
@testable import AC

/// Guards the incompatible-local-model detector: output dominated by reserved /
/// special tokens (e.g. Gemma's `<unused50>` runaway on a runtime that can't
/// decode the model) must be flagged, while legitimate chat / decision output —
/// including Qwen's reasoning-off `<think></think>` block, JSON payloads, and
/// code with generics — must pass untouched.
struct LocalModelRuntimeCompatibilityTests {

    // MARK: - Incompatible output (must flag)

    @Test
    func flagsReservedUnusedTokenSpam() {
        let garbage = String(repeating: "<unused50>", count: 40)
        #expect(LocalModelRuntime.looksLikeIncompatibleModelOutput(garbage))
    }

    @Test
    func flagsLeakedChannelMarkersFollowedByReservedTokens() {
        let garbage = "<|channel>thought\n<channel|>" + String(repeating: "<unused25>", count: 30)
        #expect(LocalModelRuntime.looksLikeIncompatibleModelOutput(garbage))
    }

    @Test
    func flagsAFewReservedTokensEvenWithSurroundingText() {
        let garbage = "Hello <unused3> there <unused7> friend <unused12> done"
        #expect(LocalModelRuntime.looksLikeIncompatibleModelOutput(garbage))
    }

    @Test
    func flagsRepeatedBracketTokenRunWithoutUnusedKeyword() {
        // A degenerate loop on a non-"unused" special token.
        let garbage = String(repeating: "<pad>", count: 8)
        #expect(LocalModelRuntime.looksLikeIncompatibleModelOutput(garbage))
    }

    // MARK: - Legitimate output (must NOT flag)

    @Test
    func acceptsQwenReasoningOffBlock() {
        let valid = "<think>\n\n</think>\n\nI'm AC, here to help you stay focused on your current task."
        #expect(!LocalModelRuntime.looksLikeIncompatibleModelOutput(valid))
    }

    @Test
    func acceptsPlainProse() {
        let valid = "Sure — let's get you back on track. What are you working on right now?"
        #expect(!LocalModelRuntime.looksLikeIncompatibleModelOutput(valid))
    }

    @Test
    func acceptsJSONDecisionPayload() {
        let valid = #"{"assessment":"focused","suggestedAction":"none","confidence":0.82}"#
        #expect(!LocalModelRuntime.looksLikeIncompatibleModelOutput(valid))
    }

    @Test
    func acceptsCodeWithGenericsAndTags() {
        let valid = """
        Here's the snippet:
        ```swift
        let names: Array<String> = []
        let map: Dictionary<String, Int> = [:]
        ```
        And some HTML: <div>hi</div>.
        """
        #expect(!LocalModelRuntime.looksLikeIncompatibleModelOutput(valid))
    }

    @Test
    func acceptsSingleUnusedMentionInProse() {
        // A passing mention of the literal text — not a runaway — stays under the threshold.
        let valid = "The token <unused0> is a reserved placeholder in some vocabularies."
        #expect(!LocalModelRuntime.looksLikeIncompatibleModelOutput(valid))
    }

    @Test
    func acceptsEmptyOrWhitespace() {
        #expect(!LocalModelRuntime.looksLikeIncompatibleModelOutput(""))
        #expect(!LocalModelRuntime.looksLikeIncompatibleModelOutput("   \n  "))
    }
}

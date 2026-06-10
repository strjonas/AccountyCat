import Foundation
import Testing
@testable import AC

/// Guards version-aware `llama-server` flag selection. The checkpoint-spacing
/// flag was renamed across llama.cpp versions
/// (`--checkpoint-every-n-tokens` → `--checkpoint-min-step`); AC must pass the
/// form the installed binary accepts, and omit it entirely when it can't tell —
/// so a pinned-commit bump never breaks a user still on an older runtime.
struct LocalModelRuntimeFlagTests {

    @Test
    func prefersMinStepWhenSupported() {
        // b9571-style help.
        let help = "-ctxcp, --ctx-checkpoints N ...\n-cms, --checkpoint-min-step N minimum spacing ...\n"
        #expect(
            LocalModelRuntime.checkpointSpacingArguments(fromHelpText: help)
                == ["--checkpoint-min-step", "512"]
        )
    }

    @Test
    func fallsBackToLegacyFlagOnOlderRuntime() {
        // Old (Apr) help.
        let help = "-cpent, --checkpoint-every-n-tokens N create a checkpoint every n tokens ...\n"
        #expect(
            LocalModelRuntime.checkpointSpacingArguments(fromHelpText: help)
                == ["--checkpoint-every-n-tokens", "512"]
        )
    }

    @Test
    func prefersMinStepWhenBothPresent() {
        let help = "--checkpoint-every-n-tokens N ...\n--checkpoint-min-step N ...\n"
        #expect(
            LocalModelRuntime.checkpointSpacingArguments(fromHelpText: help)
                == ["--checkpoint-min-step", "512"]
        )
    }

    @Test
    func omitsFlagWhenNeitherPresent() {
        #expect(LocalModelRuntime.checkpointSpacingArguments(fromHelpText: "").isEmpty)
        #expect(
            LocalModelRuntime
                .checkpointSpacingArguments(fromHelpText: "--ctx-size N\n--batch-size N\n")
                .isEmpty
        )
    }
}

# AccountyCat — Agent Guide

## What this is

Native macOS Swift app (Apple Silicon). Menu bar focus companion that uses LLMs to evaluate screenshots and active-app context, then nudges you when you drift off-task. Ships with local `llama.cpp` runtime or BYOK via OpenRouter.

## Build & test

```bash
# Run unit tests (no code signing needed)
xcodebuild test -project AC.xcodeproj -scheme AC -destination 'platform=macOS' -only-testing:ACTests CODE_SIGNING_ALLOWED=NO

# Build the inspector companion
xcodebuild build -project AC.xcodeproj -scheme ACInspector CODE_SIGNING_ALLOWED=NO
```

No linter/formatter/CI configured. Just make sure tests pass before PRs.

## Architecture (read `docs/system-overview.md` for the full picture (be careful though, the document might not always be up to date))

Runtime flow:
1. `AppController` — owns persisted state, setup, settings (singleton, `@MainActor`)
2. `BrainService` — polls frontmost context, decides when evaluation is due
3. `MonitoringAlgorithmRegistry` — resolves the configured algorithm seam (currently only `llm_monitor_v1`)
4. `LLMMonitorAlgorithm` — skip / nudge / abstain / escalate decision
5. `ExecutiveArm` — renders nudge or overlay

Key directories:
- `AC/Core/` — orchestration (AppController, BrainService, MonitoringAlgorithm)
- `AC/Services/` — LLM client, runtime setup, storage, snapshots, prompts
- `AC/Models/` — data types and state definitions
- `AC/UI/` — SwiftUI views
- `ACShared/` — code shared between AC and ACInspector (prompts, model config, telemetry)
- `_Legacy/` — old monitoring implementations excluded from build; always ignore this directory, never reference or modify it

## Testing

- Tests are in `ACTests/`. Use `FakeRuntimeFixture` to inject deterministic LLM outputs without calling a real model.
- `ACTests/Goldens/` holds golden JSON files for snapshot-style tests.
- UI tests exist in `ACUITests/` but are minimal.
- **Never use `AppController.shared` or `StorageService()` in tests.** Both write to the user's real state file at `~/Library/Application Support/AC/state.json`. Use `AppController.makeForTesting(storageService: .temporary())` or `StorageService.temporary()` instead. The test host launches `AppDelegate`, which now detects XCTest and skips real initialization — but explicit isolation in test code is still required for correctness.
- **Never let `runtimePathOverride` from a `FakeRuntimeFixture` leak into the real state file.** A fixture path persisted as `runtimePathOverride` routes all LLM calls (including chat) through the fakery script, which returns wrong-format JSON for anything it doesn't recognize. `ACState.sanitizeRuntimePathOverride` discards override paths under `NSTemporaryDirectory` or containing `ac-fake-runtime` on decode, and `AppController.updateRuntimeOverride` applies the same guard when set via Settings.

## V1 roadmap

`docs/V1_VISION.md` is the detailed V1 plan (8 phases). Several phases have inline **status notes** marking completed work as of 2026-05-02 — read those before touching related code. Key V1 concepts an agent should know:

- **Focus profiles** (Phase 5, keystone feature): `FocusProfile` in `AC/Models/ACModels.swift`. Profiles scope `PolicyRule`s; the default is "General". Profile lifecycle is chat-driven or menu-bar-popover-driven. Expiry is checked on tick, not timer-driven. Max 8 + default, LRU eviction.
- **Vision gate** (Phase 4): title-length heuristic in `MonitoringHeuristics.canRelyOnTitleAlone` skips screenshots for long descriptive titles. Threshold is user-configurable (default 30). One-shot escalation retries with screenshot on `unclear`.
- **StatsView** (Phase 1): debug-only pane showing calls/hour, decision mix, skip causes, vision attach rate, per-stage cost. Wire changes through this for observability.
- **MonitoringRequestScopeContext** (Phase 2e): payload built once per evaluation tick and reused across all LLM stages — don't re-encode fields per stage.
- **Prompt assets** — all staging prompt text lives inline in `ACShared/ACPromptSets.swift` (the single source of truth). `PromptCatalog.swift` is a thin accessor that forwards directly to `ACPromptSets.policyDefaultPromptSet`.

## Conventions

- Prompt assets live inline in `ACShared/ACPromptSets.swift`, which is the single source of truth. Use `PromptCatalog.swift` (a thin accessor) to consume them at runtime — do not read prompt files from disk.
- When touching the setup/first-run flow: keep disk-space checks, partial-download cleanup, user-readable errors, and explicit "done" signal. Test on a clean macOS environment if possible.
- `MonitoringConfiguration.algorithmID` exists for extensibility; historical IDs normalize to `llm_monitor_v1` on decode.

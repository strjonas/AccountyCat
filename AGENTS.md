# AccountyCat — Agent Guide

## Start Here

AccountyCat ("AC") is a native macOS focus companion for Apple Silicon. It lives in the menu bar and as a floating orb, watches frontmost-app context plus screenshots when needed, and uses LLMs to decide whether to stay quiet, nudge, or escalate.

Read this file first. Then load more context selectively:

- Always for non-trivial work: `docs/README.md`
- Always when changing product behavior or UX: `docs/core/north-star.md`
- Always when changing architecture or unfamiliar code: `docs/core/codebase-map.md`
- Monitoring pipeline work: `docs/reference/monitoring-pipeline.md`
- Runtime / model / provider / onboarding setup work: `docs/reference/runtime-providers-and-setup.md`
- State / persistence / tests / migrations: `docs/reference/state-persistence-and-testing.md`
- Telemetry / Inspector / debug bundles: `docs/reference/telemetry-inspector-and-debugging.md`
- Live/runtime debugging from telemetry, logs, Inspector output, or an exported debug bundle: read `dev/agents/accountycat-debugger/SKILL.md` first, then follow its triage flow

Do not load the whole `docs/` tree into every session. `core/` is the default context; `reference/` and `experiments/` are on-demand.

Never reference or modify `_Legacy/`. It is intentionally out of the active build.

## What Must Stay True

- AC should feel useful, quiet, and deeply integrated into macOS.
- Interrupting legitimate work is a bug.
- Everyday mode should be lenient; named focus sessions should be stricter.
- Reliability beats feature count. No hacky workarounds.
- The codebase should stay easy for agents to navigate and edit.
- All prompts live in `ACShared/ACPromptSets.swift`. That file is the single source of truth.

## Build & Test

```bash
# Run unit tests (no code signing needed)
xcodebuild test -project AC.xcodeproj -scheme AC -destination 'platform=macOS' -only-testing:ACTests CODE_SIGNING_ALLOWED=NO

# Build the inspector companion
xcodebuild build -project AC.xcodeproj -scheme ACInspector CODE_SIGNING_ALLOWED=NO
```

No formatter/linter/CI is configured. Run tests before finishing meaningful code changes.

## Architecture Snapshot

1. `AC/ACApp.swift`
   App entry point, `AppDelegate`, status item, popover/orb wiring, shutdown.
2. `AC/Core/AppController.swift`
   Main-actor app singleton. Owns persisted state, bootstrapping, setup flow, settings mutations, chat side effects, memory updates, and brain wiring.
3. `AC/Core/BrainService.swift`
   Timer-driven runtime loop. Polls context, applies heuristics, schedules evaluations, records telemetry, and feeds actions to the executive arm.
4. `AC/Core/MonitoringAlgorithm.swift` + `AC/Core/LLMMonitorAlgorithm.swift`
   The active monitoring seam. `llm_monitor_v1` is the only live algorithm.
5. `AC/Core/ExecutiveArm.swift`
   Executes UI consequences: nudge, overlay, app minimization, rescue-app launch, companion visibility.
6. `AC/Services/`
   Runtime setup, local/online inference, provider routing, chat, policy memory, memory consolidation, snapshotting, storage, logs, debug bundles.
7. `ACShared/`
   Shared prompts, model/runtime catalogs, structured-output helpers, telemetry models/store.
8. `ACInspector/`
   Local telemetry viewer and Prompt Lab for replaying scenarios and comparing prompt/runtime configurations.

## Repo Map

- `AC/Core/`: orchestration and decision flow
- `AC/Services/`: IO, inference, persistence, platform integrations
- `AC/Models/`: persisted state and domain models
- `AC/UI/`: app UI, settings, orb, overlays, skins
- `ACShared/`: shared prompts, schemas, telemetry types
- `ACInspector/`: inspector app and prompt-lab tooling
- `ACTests/`: unit and golden tests, fake runtime fixture
- `docs/`: durable onboarding docs and volatile reference docs
- `dev/agents/accountycat-debugger/`: debugging skill and telemetry triage references

## Testing Footguns

- Never use `AppController.shared` in tests.
- Never use `StorageService()` in tests. It writes to the real state file at `~/Library/Application Support/AC/state.json`.
- Use `AppController.makeForTesting(storageService: .temporary())` or `StorageService.temporary()`.
- Never persist a fake runtime path into real state. `runtimePathOverride` is sanitized for temp/fake paths, and tests should keep using isolated state anyway.
- Verbose telemetry is effectively Debug-build only. Do not assume release builds have the same artifacts available.

## Change-Specific Guardrails

- Setup / first run: keep disk-space checks, interrupted-download cleanup, user-readable subprocess errors, and an explicit completion signal.
- Monitoring: preserve the distinction between cheap deterministic gates and expensive LLM calls.
- Prompt work: update prompt text only in `ACShared/ACPromptSets.swift`.
- Online routing: OpenRouter is the default path; direct OpenAI is currently an experiment documented separately.

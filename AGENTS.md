# AccountyCat — Agent Guide

This file is the agent entrypoint: read it first, then load the canonical docs it points to.

## Start Here

AccountyCat ("AC") is a native macOS focus companion for Apple Silicon. It lives in the menu bar and as a floating orb, watches frontmost-app context plus screenshots when needed, and uses LLMs to decide whether to stay quiet, nudge, or escalate.

Read this file first. Then load more context selectively.

Always read:

- `docs/core/north-star.md` — source of truth for product principles, engineering principles, taste, and the current quality bar

Read on most non-trivial tasks:

- `docs/README.md` — docs map and read-routing
- `docs/core/codebase-map.md` — architecture map, ownership seams, and where behavior lives

Load on demand:

- `docs/reference/monitoring-pipeline.md` — monitoring pipeline work
- `docs/reference/runtime-providers-and-setup.md` — runtime / model / provider / onboarding setup work
- `docs/reference/state-persistence-and-testing.md` — state / persistence / tests / migrations
- `docs/reference/telemetry-inspector-and-debugging.md` — telemetry / Inspector / debug bundles
- `dev/agents/accountycat-debugger/SKILL.md` — live/runtime debugging from telemetry, logs, Inspector output, or an exported debug bundle

Do not load the whole `docs/` tree into every session. `core/` is the default context; `reference/` and `experiments/` are on-demand.

If this file and a canonical doc disagree, the canonical doc wins. `north-star.md` is the source of truth for principles, `codebase-map.md` for architecture, and `reference/*` for area-specific implementation details.

## Non-Negotiables

- Never reference or modify `_Legacy/`. It is intentionally out of the active build.
- All prompts live in `ACShared/ACPromptSets.swift`. That file is the single source of truth.
- Never use `AppController.shared` in tests.
- Never use `StorageService()` in tests. It writes to the real state file at `~/Library/Application Support/AC/state.json`. Use `AppController.makeForTesting(storageService: .temporary())` or `StorageService.temporary()` for isolated state in tests.
- Verbose telemetry is effectively Debug-build only. Do not assume release builds have the same artifacts available.
- Avoid to scan the whole filesystem so that MacOS permission popups appear en mass. Similarly avoid to do anything that requires permission or keychain popups (especially relevant in tests).
- Never call `CGRequestScreenCaptureAccess()` or `SCShareableContent` to "register" the app. These trigger the system permission dialog. Use `CGPreflightScreenCaptureAccess()` (read-only check) instead, and gate all capture calls behind it.

## Build & Test

```bash
# Run unit tests (no code signing needed — tests mock capture and runtime)
xcodebuild test -project AC.xcodeproj -scheme AC -destination 'platform=macOS' -only-testing:ACTests CODE_SIGNING_ALLOWED=NO

# Build the inspector companion
xcodebuild build -project AC.xcodeproj -scheme ACInspector CODE_SIGNING_ALLOWED=NO
```

No formatter/linter/CI is configured. Run tests before finishing meaningful code changes. Do not start overlapping `xcodebuild test` runs; if a run is interrupted or appears stuck during finalization, check for stale `xcodebuild`, `debugserver`, or `AC.app` test-host processes before rerunning. For architecture, use `docs/core/codebase-map.md`. For testing/storage details, use `docs/reference/state-persistence-and-testing.md`.

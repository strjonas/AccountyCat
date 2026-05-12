# Telemetry, Inspector, and Debugging

This doc explains the runtime-debugging surfaces. For actual live-debugging workflows, read `dev/agents/accountycat-debugger/SKILL.md` first.

## Primary Files

- `ACShared/Telemetry/TelemetryStore.swift`
- `AC/Core/BrainService+Telemetry.swift`
- `AC/Core/TelemetryAdapters.swift`
- `AC/Services/LLMTelemetryRecorder.swift`
- `AC/Services/ACDebugBundleService.swift`
- `ACInspector/InspectorController.swift`
- `ACInspector/TelemetryIndexStore.swift`
- `ACInspector/PromptLabRunner.swift`

## Telemetry Model

`TelemetryStore` is the source of truth for verbose runtime telemetry.

It manages:

- telemetry sessions
- JSONL event append/load
- prompt/input/output artifacts
- screenshot artifacts and thumbnails
- session heartbeats
- retention cleanup

Sessions live under `~/Library/Application Support/AC/telemetry`.

## Important Constraint

Verbose telemetry is effectively Debug-build only.

`TelemetryPersistencePolicy.storesVerboseTelemetry(debugMode:)` currently returns `ACBuild.isDebug`, so toggling `state.debugMode` does not make Release builds behave like Debug builds.

## Runtime Breadcrumbs vs Source of Truth

Use the right artifact for the job:

- `activity.log` is for human-readable breadcrumbs
- telemetry events are the source of truth for reconstructing behavior
- debug bundles are portable snapshots for offline triage
- ACInspector is the best local UI for browsing episodes and prompt artifacts

## ACInspector

`ACInspector` has two big jobs:

- inspect recorded telemetry episodes
- run Prompt Lab scenario replays

Prompt Lab lets you:

- import telemetry episodes into structured scenarios
- compare prompt sets, pipeline profiles, and runtime profiles
- inspect rendered prompts and outputs without changing the main app

## Debug Bundles

`ACDebugBundleService` exports a compact, agent-readable bundle containing:

- a redacted current-state snapshot
- a summary of recent telemetry
- copied raw telemetry for the selected session
- activity log
- OpenRouter health snapshot when present

Bundles are a good handoff artifact when live inspection is inconvenient.

## Live Debugging Entry Point

When the task is "why did AC do this?" or "why is runtime behavior wrong?", start here:

1. `dev/agents/accountycat-debugger/SKILL.md`
2. relevant references under `dev/agents/accountycat-debugger/references/`
3. this doc for storage/file-layout context

That skill is the intended triage path for telemetry-heavy debugging.

## If You Change This Area

- Preserve enough telemetry to explain decisions after the fact.
- Keep Inspector assumptions aligned with emitted event schemas and artifact names.
- Update debug-bundle summaries when new event kinds become operationally important.

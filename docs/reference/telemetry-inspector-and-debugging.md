# Telemetry, Inspector, and Debugging

This doc explains the runtime-debugging surfaces. For actual live-debugging workflows, read `dev/agents/accountycat-debugger/SKILL.md` first.

## Primary Files

- `ACShared/Telemetry/TelemetryStore.swift`
- `AC/Core/BrainService+Telemetry.swift`
- `AC/Core/TelemetryAdapters.swift`
- `AC/Services/LLMTelemetryRecorder.swift`
- `AC/Services/ACDebugBundleService.swift`
- `ACShared/Evals/ACEvalModels.swift`
- `ACShared/Evals/ACEvalStore.swift`
- `ACInspector/InspectorController.swift`
- `ACInspector/TelemetryIndexStore.swift`
- `ACInspector/PromptLabRunner.swift`
- `ACTests/AgentEvalRunnerTests.swift`
- `dev/agents/accountycat-eval/SKILL.md`

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
- capture and inspect durable eval cases from selected episodes

Prompt Lab lets you:

- import telemetry episodes into structured scenarios
- compare prompt sets, pipeline profiles, and runtime profiles
- inspect rendered prompts and outputs without changing the main app

The Eval Cases tab lists saved eval cases from `~/Library/Application Support/AC/evals/`.
Use **Create Eval Case** from a selected episode to prefill a case from focus, chat,
or chat-action telemetry. Unsupported LLM interaction kinds remain inspectable but
are not eval-capturable until they have a case schema.

Eval case capture stores:

- one `case.json` per case under `evals/cases/<id>/`
- copied screenshots/artifacts under that case folder so telemetry cleanup does not
  delete the eval evidence
- `manifest.json`, regenerated on save/delete, with agent-readable summaries:
  id, name, kind, importance, categories, app/title context, screenshot presence,
  expected outcome summary, and recommended backend

Captured evals compare structured behavior, not exact wording. Focus evals compare
assessment/action expectations. Chat evals compare action kinds and optional schedule
kind while requiring a non-empty reply by default. Chat-action evals compare normalized
action fields such as kind, intent, target, scope, duration, profile fields, memory
text containment, and locked flag.

## Agent Eval Runner

Agents should use `dev/agents/accountycat-eval/SKILL.md` when changing prompts,
monitoring behavior, chat command parsing, or action resolution.

Common commands:

```bash
swift dev/agents/accountycat-eval/scripts/ac-eval-runner.swift list --json
swift dev/agents/accountycat-eval/scripts/ac-eval-runner.swift list --kind focus --importance high,critical --category false_positive --json
swift dev/agents/accountycat-eval/scripts/ac-eval-runner.swift run --backend local --importance critical,high --limit 30 --json
swift dev/agents/accountycat-eval/scripts/ac-eval-runner.swift run --backend local --ids <case-id> <case-id> --json
```

Runner execution delegates to `ACTests/AgentEvalRunnerTests.swift` so evals reuse the
same AC code paths as tests. Online runs are explicit:

```bash
AC_EVAL_OPENROUTER_API_KEY=... swift dev/agents/accountycat-eval/scripts/ac-eval-runner.swift run --backend online --online-model <model> --ids <case-id> --json
AC_EVAL_OPENAI_API_KEY=... swift dev/agents/accountycat-eval/scripts/ac-eval-runner.swift run --backend online --online-model <model> --ids <case-id> --json
```

The eval runner does not read Keychain. The shell wrapper writes any supplied online
API key into the temporary runner request so the `xcodebuild`-hosted eval path sees
the same credential. Prefer local evals and filtered online slices; eval cases can
contain personal titles, chat messages, and screenshots.

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

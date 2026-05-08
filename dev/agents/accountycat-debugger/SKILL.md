---
name: accountycat-debugger
description: Debug AccountyCat runtime behavior from agent debug bundles, telemetry JSONL, Inspector summaries, activity logs, and headless checks. Use when AC gave a bad chat reply, missed or made a wrong nudge, OpenRouter failed, screenshots were wrong or missing, memory/rules/profiles changed incorrectly, safelist promotion behaved unexpectedly, or the user says AC just did something bad.
---

# AccountyCat Debugger

Use this skill when investigating live AC behavior. Prefer the agent debug bundle over ad hoc file hunting.

## First Pass

1. Locate the newest bundle under `~/Library/Application Support/AC/debug-bundles/` unless the user gave a path.
2. Read `summary.json` first.
3. Read `inspector_index_summary.json` and identify the one or two relevant episodes/interactions.
4. Read only the artifact paths referenced by those relevant records.
5. Use `current_state_redacted.json` to verify active profile, monitoring config, memory, rules, recent actions, and permissions.
6. Use `activity.log` only as breadcrumbs.

For telemetry field meanings, read `references/telemetry.md`.
For issue-specific workflows, read `references/triage.md`.

## Useful Commands

```bash
swift dev/agents/accountycat-debugger/scripts/summarize-bundle.swift "/path/to/agent-debug-bundle"
swift dev/agents/accountycat-debugger/scripts/ac-debug-runner.swift chat --message "help me focus for 30 minutes" --fake-runtime
swift dev/agents/accountycat-debugger/scripts/ac-debug-runner.swift monitor --context context.json --fake-runtime
swift dev/agents/accountycat-debugger/scripts/ac-debug-runner.swift golden --runtime local
xcodebuild test -project AC.xcodeproj -scheme AC -destination 'platform=macOS' -only-testing:ACTests CODE_SIGNING_ALLOWED=NO
```

## Ground Rules

- Do not load every prompt or artifact into context. Follow `artifactPaths`.
- Do not treat `activity.log` as complete; telemetry is the source of truth.
- Never use `AppController.shared` or `StorageService()` in tests.
- For deterministic behavior checks, prefer fake-runtime tests before real OpenRouter calls.
- Browser or computer-use tools are secondary; AC is a native macOS app, so telemetry and runners are usually faster and more reliable.

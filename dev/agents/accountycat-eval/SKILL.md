---
name: accountycat-eval
description: Seed, list, select, and run AccountyCat local eval cases — a curated synthetic suite plus cases captured from ACInspector. Use when improving AC prompts, monitoring decisions, chat actions, focus nudges, memory/profile/focus-policy behavior, or when the user asks to run evals before or after algorithm changes.
---

# AccountyCat Eval Runner

Use this skill when AC behavior should be checked against saved human-reviewed eval cases. Evals are private local files under `~/Library/Application Support/AC/evals/`; do not assume they are in git. For the wider design — what the evals measure, the suite composition, results, and known limitations — see `docs/reference/eval-suite.md`.

## Workflow

0. (When the synthetic suite changed, or on a fresh machine) write/refresh it. This rebuilds the test target and writes `SyntheticEvalCases.all` into the eval root:

```bash
swift dev/agents/accountycat-eval/scripts/ac-eval-runner.swift seed
```

1. List available cases before choosing what to run:

```bash
swift dev/agents/accountycat-eval/scripts/ac-eval-runner.swift list --json
```

2. Select the smallest useful slice:

```bash
swift dev/agents/accountycat-eval/scripts/ac-eval-runner.swift list --kind focus --importance high,critical --category false_positive --json
swift dev/agents/accountycat-eval/scripts/ac-eval-runner.swift list --kind chat-action --category memory --json
```

3. Run local evals first:

```bash
swift dev/agents/accountycat-eval/scripts/ac-eval-runner.swift run --backend local --importance critical,high --limit 30 --json
swift dev/agents/accountycat-eval/scripts/ac-eval-runner.swift run --backend local --ids <case-id> <case-id> --json
```

4. The pass bar is the balanced online tier. A single run uses ONE `--online-model`, so run title-only and vision cases separately:

```bash
# Title-only (everyday/session focus + chat + chat-action) — text model
AC_EVAL_OPENROUTER_API_KEY=... swift dev/agents/accountycat-eval/scripts/ac-eval-runner.swift run --backend online --online-model deepseek/deepseek-v4-flash --ids <case-id> --json
# Vision cases (cases with a screenshot) — vision model
AC_EVAL_OPENROUTER_API_KEY=... swift dev/agents/accountycat-eval/scripts/ac-eval-runner.swift run --backend online --online-model qwen/qwen3.6-35b-a3b --ids <case-id> --json
```

## Selection Rules

- Prefer `critical,high` before broader suites.
- For monitoring changes, run `--kind focus` and the category touched by the change, such as `false_positive`, `false_negative`, `browser`, or `focus_session`.
- For chat command parsing, run `--kind chat` first, then `--kind chat-action` for the specific action category: `profile`, `memory`, or `focus_policy`.
- Use `manifest.json` summaries to decide. The manifest includes kind, importance, categories, source app/title, screenshot presence, expected outcome summary, and recommended backend.

## Cost And Safety

- `xcodebuild` does not forward the runner's environment to the test host, so `run` (`AgentEvalCommandRunnerTests`) and `seed` (`ACEvalSeedTests`) are gated by a short-lived handoff file at a fixed `/tmp` path carrying `allowTestHostRun: true` + an expiry, which each command writes immediately before invoking `xcodebuild`. A normal `xcodebuild test` finds no fresh handoff and no-ops. Keep eval-related environment variables scoped to deliberate runner invocations rather than global shell exports.
- Local evals are the default. They use the installed local runtime, or `--runtime-path` if supplied.
- Online evals are explicit and require `AC_EVAL_OPENROUTER_API_KEY` or `AC_EVAL_OPENAI_API_KEY`. The runner must not read Keychain. Pass the key inline per invocation; never commit it or write it to files/memory.
- Do not run broad online suites casually. Filter by id/category/importance and keep the count small.
- Eval files can contain personal titles, messages, and screenshots. Do not copy them into git or broad debug output.
- If a run appears stuck, the build is rarely the cause (`xcodebuild build-for-testing` completes in seconds). A stale `debugserver` / `xcodebuild` / `AC.app` test-host process from a prior run can wedge the test-host launch and hang `xcodebuild test` indefinitely. Clear them (`pkill -f LLDB.framework/Resources/debugserver`) before retrying — do not start overlapping runs that share build/test paths.

## Interpreting Results

The runner prints JSON with pass/fail, reason, parsed structured output, model used, latency, and artifact paths. Treat failures as behavior deltas to inspect, not as exact text mismatches. Focus evals compare structured assessment/action; chat evals compare action kinds and schedule; chat-action evals compare normalized action fields.

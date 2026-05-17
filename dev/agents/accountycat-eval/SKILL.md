---
name: accountycat-eval
description: List, select, and run AccountyCat local eval cases captured from ACInspector. Use when improving AC prompts, monitoring decisions, chat actions, focus nudges, memory/profile/focus-policy behavior, or when the user asks to run evals before or after algorithm changes.
---

# AccountyCat Eval Runner

Use this skill when AC behavior should be checked against saved human-reviewed eval cases. Evals are private local files under `~/Library/Application Support/AC/evals/`; do not assume they are in git.

## Workflow

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

4. Use online evals only when the case requires the hosted model or vision behavior:

```bash
AC_EVAL_OPENROUTER_API_KEY=... swift dev/agents/accountycat-eval/scripts/ac-eval-runner.swift run --backend online --online-model <model> --ids <case-id> --json
AC_EVAL_OPENAI_API_KEY=... swift dev/agents/accountycat-eval/scripts/ac-eval-runner.swift run --backend online --online-model <model> --ids <case-id> --json
```

## Selection Rules

- Prefer `critical,high` before broader suites.
- For monitoring changes, run `--kind focus` and the category touched by the change, such as `false_positive`, `false_negative`, `browser`, or `focus_session`.
- For chat command parsing, run `--kind chat` first, then `--kind chat-action` for the specific action category: `profile`, `memory`, or `focus_policy`.
- Use `manifest.json` summaries to decide. The manifest includes kind, importance, categories, source app/title, screenshot presence, expected outcome summary, and recommended backend.

## Cost And Safety

- Local evals are the default. They use the installed local runtime, or `--runtime-path` if supplied.
- Online evals are explicit and require `AC_EVAL_OPENROUTER_API_KEY` or `AC_EVAL_OPENAI_API_KEY`. The runner must not read Keychain.
- Do not run broad online suites casually. Filter by id/category/importance and keep the count small.
- Eval files can contain personal titles, messages, and screenshots. Do not copy them into git or broad debug output.

## Interpreting Results

The runner prints JSON with pass/fail, reason, parsed structured output, model used, latency, and artifact paths. Treat failures as behavior deltas to inspect, not as exact text mismatches. Focus evals compare structured assessment/action; chat evals compare action kinds and schedule; chat-action evals compare normalized action fields.

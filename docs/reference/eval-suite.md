# Eval Suite

This doc owns AccountyCat's **offline judgment eval suite**: the curated synthetic cases, the seeder, the run workflow, what the evals actually measure, the current results, and the known limitations to pick up in v2. It is a current seam that should track the live code.

For the operational "just run it" steps, see `dev/agents/accountycat-eval/SKILL.md`. For how individual cases are captured from real sessions in the Inspector, see `reference/telemetry-inspector-and-debugging.md`. This doc is the wider context.

## Why this exists

The hard part of AC is non-deterministic LLM judgment: deciding `focused` / `tolerated` / `distracted` / `unclear` and the matching action. Unit tests pin the deterministic machinery (caching, cooldowns, escalation gates); they cannot pin judgment. The eval suite captures real-shaped situations with human-reviewed acceptance criteria so that a prompt or algorithm change can be checked against "does AC still make the right call" rather than only "does it compile."

The bar: the suite should encode the north-star priorities — **never interrupt legitimate work** (false positives are the worst failure), **don't stay silent on sustained real drift**, and **tolerate short breaks/detours**.

## What the eval actually measures (important)

A `focus` case is fed straight into `LLMMonitorAlgorithm.evaluate(...)` and the result compares two fields:

- `result.decision.assessment` — `focused` / `tolerated` / `distracted` / `unclear`
- `result.decision.suggestedAction` — `none` / `nudge` / `overlay` / `abstain`

`result.decision` is the **model's verdict** (after `confidenceAdjustedDecision`), **not** the deterministically-gated final action. Consequences:

- The escalation gate (nudge→overlay), the overlay-threshold gate, the cadence/cooldown/cache skips, and the stable-context settle are **bypassed** here. Those are deterministic and covered by `LLMMonitorAlgorithmCooldownTests` / `CompanionPolicyTests`. So a `distracted/overlay` eval result means "the model proposed overlay," not "an overlay was shown."
- Two algorithm steps *do* run and can change the compared verdict:
  - **confidence rewrite**: a `distracted` verdict with `confidence < 0.60` is rewritten to `unclear/abstain` (`LLMMonitorAlgorithm.confidenceAdjustedDecision`).
  - **explicit-allowance text override** (`LLMMonitorAlgorithm+ExplicitDirectives.swift`): structured phrasings like "X is allowed until …", "for the next 20 minutes", or standing "never flag X" short-circuit to `focused/none` *without an LLM call*. Natural prose ("this is research") falls through to the model — so most cases exercise real judgment.

Chat (`CompanionChatService.chat`) and chat-action (`resolveAction`) cases compare action kinds / normalized action fields instead.

Two levers the synthetic cases rely on:
- **`distraction.stableSince`** sets `currentContextSeconds = now − stableSince` — this is how a case depicts "80s into a break" (tolerated) vs "9 min into a scroll" (distracted).
- **`activeProfile.id` must equal `"general"`** for Everyday cases — the prompt's `isDefault` is derived as `id == PolicyRule.defaultProfileID`. Any other id runs the named-session prompt. Default cadence is `balanced` (everyday tolerated window ≈ 225s).

## Where it lives

| Piece | File |
| --- | --- |
| Case + expectation models | `ACShared/Evals/ACEvalModels.swift` |
| Case store (load/save/manifest, copies screenshots) | `ACShared/Evals/ACEvalStore.swift` |
| Run harness (focus/chat/chat-action executors, online provider) | `ACTests/AgentEvalRunnerTests.swift` |
| Synthetic case data + builders | `ACTests/SyntheticEvalCases.swift` |
| Seeder (gated test that writes the suite) | `ACTests/ACEvalSeedTests.swift` |
| CLI: `list` / `run` / `seed` | `dev/agents/accountycat-eval/scripts/ac-eval-runner.swift` |
| Stored cases (local, not git) | `~/Library/Application Support/AC/evals/` |
| Vision screenshots (local, not git) | `~/Library/Application Support/AC/evals/fixtures/vision/` |

## The synthetic suite

37 hand-authored cases (`SyntheticEvalCases.all`) targeting ~95% of real usage. Composition:

| Group | n | Covers |
| --- | --- | --- |
| Everyday focus | 13 | work, short break/errand/life-admin/message (`tolerated`), sustained drift (`distracted`), ambiguous surfaces (`unclear`), active restrictive rule, user allowance/"I'm done", correction-wins |
| Named-session focus | 12 | on-task + adjacent work (`focused`), brief detour (`tolerated`), clear/repeated off-task drift (`distracted`/overlay), strict-vs-broad profile scope, just-activated grace, off-scope-but-productive, correction-wins |
| Vision (real screenshots) | 3 | dev-tool YouTube → `focused` (legit-YouTube guard), arXiv paper behind an opaque URL title → `focused`, social feed in a session (guard) |
| Chat | 5 | start session (`profile`), remember (`memory`), allow (`focus_policy`), vent (no action), recurring nudge |
| Chat-action | 4 | resolve memory / profile create-vs-reuse / focus-policy allow |

The 3 originally-captured Inspector cases also live in the store; they are vision cases and not part of `SyntheticEvalCases`.

### Expectation style: guard vs discrimination

- **Guard** (most cases): forbid the harmful outcome (nudging legit work; staying silent on real drift) and accept any defensible verdict. Low flakiness; still catches regressions. This is the default and it directly encodes "don't interrupt legitimate work."
- **Discrimination** (a tagged subset): assert the exact verdict where the distinction is behaviorally load-bearing — e.g. a short break must be `tolerated`, not `focused` (focused is cached with a long TTL; tolerated gets a short recheck, so the distinction matters for whether a break that turns into drift is caught).

## Running it

Pass bar = the **balanced online tier**: `deepseek/deepseek-v4-flash` (text) and `qwen/qwen3.6-35b-a3b` (vision). Local runs are informational (they exercise the shipping local model, which is weaker on nuance).

```bash
# 1. Write/refresh the suite into the eval root (rebuilds the test target).
swift dev/agents/accountycat-eval/scripts/ac-eval-runner.swift seed

# 2. List what's there.
swift dev/agents/accountycat-eval/scripts/ac-eval-runner.swift list --json

# 3a. Title-only cases (everyday/session focus + chat + chat-action) — text model.
AC_EVAL_OPENROUTER_API_KEY=... swift dev/agents/accountycat-eval/scripts/ac-eval-runner.swift \
  run --backend online --online-model deepseek/deepseek-v4-flash --ids <title-only ids>

# 3b. Vision cases — vision model. (A single run uses ONE --online-model, so run vision separately.)
AC_EVAL_OPENROUTER_API_KEY=... swift dev/agents/accountycat-eval/scripts/ac-eval-runner.swift \
  run --backend online --online-model qwen/qwen3.6-35b-a3b --ids syn-vision-everyday-dev-youtube syn-vision-session-x-feed syn-vision-everyday-arxiv-paper

# Offline: same, with --backend local (uses the installed runtime or --runtime-path).
```

### Gotchas (these cost real time the first time)

- **`xcodebuild` does not forward the runner's environment to the test host.** Both `seed` and `run` therefore gate on a short-lived handoff file at a fixed `/tmp` path (`allowTestHostRun: true` + `expiresAt`), read directly by the test (`ACEvalSeedTests` / `AgentEvalCommandRunnerTests`). Env-only gating silently no-ops.
- **A single online run uses one `--online-model`.** Title-only cases need the text model; vision cases need the vision model. Run them as two invocations.
- **Clear stale `debugserver` / `xcodebuild` / `AC.app` test-host processes between runs.** A leftover `debugserver` from a prior session wedged the test-host launch and hung `xcodebuild test` indefinitely (the build itself was fine — `build-for-testing` completed in 2s). If a run appears stuck, `pkill -f LLDB.framework/Resources/debugserver` and retry. (`AGENTS.md` warns about this.)
- **Vision fixtures are local, not git.** `SyntheticEvalCases` references them under `~/Library/Application Support/AC/evals/fixtures/vision/` via `homeDirectoryForCurrentUser` (no hardcoded path). If a fixture is missing, the seeder *skips* that case rather than silently downgrading it to title-only. On a fresh machine the vision cases simply won't seed until screenshots are placed there.

## Results snapshot (2026-05-23, balanced online tier)

**35 / 37 passing.** The core monitoring judgment holds: `focused` work, the `tolerated` break/detour path, clear and repeated `distracted` drift (→ model proposes overlay at streak ≥ 2), user corrections overriding profile/rules, active restrictive rules, ambiguous→`abstain`, and the vision guards (dev YouTube stays `focused`; an opaque arXiv URL resolves to `focused` via the screenshot).

Two known limitations remain (see below). They are a rare hard case and a secondary-surface reliability gap — not core monitoring bugs.

## Known limitations (v2 targets)

1. **Off-scope-but-productive work** (`syn-session-offscope-productive`): coding in Xcode during a "Presentation prep" session is judged `focused`, title-only, on the flash text model — its "coding = productive = focused" prior overrides the declared session scope, even with a rule and a few-shot in the decision prompt. **Do not brute-force this in the prompt:** a forceful "productive work in the wrong app is distracted" rule threatens the more important false-positive guards (research / docs / adjacent work during a Coding session must stay `focused`). Better v2 fixes: a stronger model, a vision-backed variant, or a structural session-scope signal — not heavier prompt text.

2. **Chat allowance reliability** (`syn-chat-allow-youtube`): for "let me watch YouTube for 20 minutes", the flash model produces a correct reply (even "no nudges") but only *sometimes* emits the `focus_policy` allow action. This is a small-model structured-output reliability gap, not comprehension — the chat prompt now explicitly instructs it (mirroring the `memory` self-commitment guard). The robust fix is **code-level**, not prompt: when a chat reply commits to a temporary allowance but no `focus_policy` action was emitted, synthesize one in `CompanionChatService`. Deferred as secondary surface; consequence is mild (AC might still glance during a verbally-allowed short break).

3. **Vision social-feed case is a guard, by design** (`syn-vision-session-x-feed`): an X feed during an *app-release* session is genuinely ambiguous (could be launch buzz), so a cautious `unclear`/abstain is accepted; the case only forbids `focused`/`tolerated`. Not a bug — a deliberately weaker assertion on an ambiguous scenario.

### Title-only vs vision constraint

Synthetic cases can't fabricate screenshots, and the decision prompt deliberately biases away from `distracted` when no screenshot is present. So:
- Title-decidable drift (a clear social/entertainment title sustained past tolerance) works title-only — a decision few-shot teaches that "clearly-entertainment title past tolerance is clearly-distracting text," while generic/dual-use titles (a bare "YouTube", "ChatGPT", a tutorial title) stay `unclear`/`focused`.
- Content-dependent cases need a real screenshot. We mine a few from telemetry (below) rather than synthesize them.

## Calibration lessons (for whoever authors cases next)

- **A short detour is not drift.** A 2-minute Instagram glance during a session is correctly `tolerated`; expecting `distracted` there is an author error, not an algorithm bug. For a "should nudge" case, depict *sustained* drift: set `contextSeconds` well past the tolerated window (≈ 500s+) **and** add a `recentActivityTimeline` dominated by the off-task app. This was the single most common mis-calibration found.
- **Prefer guards; reserve discrimination for load-bearing distinctions.** Don't relax an expectation just to go green — but do recognize when an expectation was over-strict for a genuinely ambiguous scenario (the x-feed guard) versus when the algorithm is actually wrong.
- **Everyday is lenient on purpose** ("a miss is cheaper than a wrong nudge"). Title-only entertainment is borderline; prefer a vision case over teaching the model to nudge bare app titles.

## Continuing for v2

- **Add cases** via the builders in `SyntheticEvalCases.swift` (`focus(...)`, `chat(...)`, `chatAction(...)`), then `seed` + `run`. Keep the guard/discrimination split.
- **Mine a vision case from telemetry**: each `eval-<id>` episode under `~/Library/Application Support/AC/telemetry/<session>/artifacts/` has a `payload-online_decision-*.txt` (the full decision context — maps cleanly onto `ACEvalFocusInput`: profile, app, title, switches, usage) and a `screenshot-*.png`. View the screenshot to assign the verdict, copy it into the vision fixtures dir, and add a `focus(...)` case with `screenshotPath: visionShot("<name>.png")`. Avoid screenshots with sensitive personal content (e.g. mail).
- **The loop**: change prompt/algorithm → `seed` → `run` (full suite, both models) → triage each failure as *real bug* vs *mis-calibrated case*, fix the right one, and re-run the full suite to guard against regressions. The two known-limits above are the first things to retest when the model tier or chat action-emission changes.

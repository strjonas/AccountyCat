# Monitoring Pipeline

This doc explains the live monitoring path. It is narrower and more volatile than the core docs.

## Primary Files

- `AC/Core/BrainService.swift`
- `AC/Core/BrainService+Telemetry.swift`
- `AC/Core/MonitoringAlgorithm.swift`
- `AC/Core/LLMMonitorAlgorithm.swift`
- `AC/Core/LLMMonitorAlgorithm+ExplicitDirectives.swift`
- `AC/Core/CompanionPolicy.swift`
- `AC/Core/DistractionLadder.swift`
- `AC/Core/MonitoringHeuristics.swift`
- `AC/Core/ExecutiveArm.swift`
- `ACShared/ACPromptSets.swift`

## Tick Flow

`BrainService` drives two timers:

- a 10-second polling tick
- a 5-second context-change probe

The probe is cheap and mostly detects whether the frontmost context changed enough to justify a real tick.

Each real tick does roughly this:

1. Read the latest `ACState` snapshot from `stateProvider`.
2. Apply clock-driven state changes before any LLM work:
   - soft profile expiry / pre-warning / auto-extension
   - recurring profile activation
   - pause / permission / readiness gating
3. Read frontmost app + title from `SnapshotService.frontmostContext()`.
4. Build deterministic heuristics with `MonitoringHeuristics`.
5. Ask `MonitoringAlgorithmRegistry` for an evaluation plan.
6. Skip immediately when deterministic rules or caches make the result obvious.
7. If needed, capture a screenshot and build `MonitoringDecisionInput`.
8. Run `LLMMonitorAlgorithm.evaluate(...)`.
9. Feed the result through `CompanionPolicy` to produce a concrete `CompanionAction`.
10. Hand the action to `ExecutiveArm`.
11. Persist updated algorithm state, telemetry, reactions, and any policy-memory updates.

## Deterministic Gates Before LLM Calls

The monitoring path tries to avoid unnecessary LLM calls.

Important fast paths:

- explicit active `allow` rules can skip evaluation entirely
- recently cached focused decisions can skip re-evaluation in the same context
- a recent user correction or approved appeal installs a short, cadence-scaled cooldown (`recentInteractionAllowances` on `LLMPolicyAlgorithmState`) so AC doesn't immediately re-flag the same activity
- cadence delays defer evaluation until a context has been stable long enough
- browser contexts still pass through the stable-context gate, but use a much shorter settle window than native apps so tab switches are checked quickly
- title-only context can suppress screenshots for non-ambiguous apps
- online monitoring does a read-only connectivity gate before any provider call; true offline state skips evaluation quickly with a banner and a short recheck
- repeated online vision timeouts can temporarily degrade the *effective* pipeline to online text-only for a few minutes; this is transient runtime state in `BrainService`, not a persisted settings change
- when the local inference backend is active and a user-interactive (chat) request is in flight, `BrainService` skips the evaluation tick and defers the next check by 10 seconds (`local_runtime_busy` skip reason); this ensures the shared llama.cpp server is never reconfigured or interrupted mid-chat

The design intent is to spend LLM calls where judgment is needed, not on obvious repeats.

## Screenshot Policy

`MonitoringHeuristics.canRelyOnTitleAlone(...)` decides when the title is strong enough to skip a screenshot.

Biases:

- browsers never qualify for title-only mode
- browser tab-title lookup is cached only briefly because stale browser titles can hide a real context switch
- known ambiguous-content apps keep screenshots
- clearly productive IDE/editor titles can skip screenshots more easily
- descriptive titles can skip screenshots even outside IDEs

`ScreenshotCaptureMode` supports active-window vs full-screen capture, with a periodic full-screen safety check.

When transient online text-only degradation is active, the effective pipeline for that tick no longer requires a screenshot, so AC skips capture/upload until the short degradation window expires or monitoring succeeds again on the normal path.

## Algorithm Shape

`MonitoringAlgorithmRegistry` currently resolves exactly one live algorithm: `llm_monitor_v1`.

`LLMMonitorAlgorithm` owns:

- evaluation planning
- per-context decision caching
- explicit allow/block directive parsing
- distraction metadata updates
- prompt-stage execution
- appeal review
- optional policy-memory updates such as safelist promotions

Historical algorithm ids still decode, but normalize to the current algorithm.

## Prompt Stages

Prompts live in `ACShared/ACPromptSets.swift`.

The active stage catalog includes:

- `perception_title`
- `perception_vision`
- `online_decision`
- `decision`
- `nudge_copy`
- `appeal_review`
- `policy_memory`
- `safelist_appeal`

The prompt file is the single source of truth for:

- prompt text
- stage schemas
- chat workflow instructions
- memory-consolidation prompt
- policy-memory prompt rendering

## Profiles, Modes, and Learning

The monitoring payload is profile-aware.

- Default profile (`general` / "Everyday") is lenient by design.
- Named focus profiles raise the bar for off-task behavior, but the monitor judges the visible content/task before broad app category.
- Sparse profile names such as Coding, Writing, Research, or Studying are treated as broad archetypes. Adjacent docs, tutorials, examples, planning, project chat, reference material, and debugging can be focused unless the profile description or rules narrow the scope.
- Specific profile descriptions and rules narrow the scope. A profile like "code writing only, no tutorials" should make tutorial/video content nudge-eligible.
- `activeProfile.activatedAt` is included in the decision payload. During the first few minutes of a newly activated named profile, the model should require stronger evidence before nudging plausible adjacent work, while still nudging clear unrelated drift.
- `recentlyEndedSession` keeps the just-finished task visible to the model for about 30 minutes.
- Policy rules are profile-scoped.
- Free-form memory remains globally visible, but entries carry profile labels.

## Appeals, Rewards, and Escalation

- Nudges can receive explicit positive/negative feedback from the user.
- `BrainService` converts those reactions into normalized reward signals and passes them back into the active algorithm. The current `LLMMonitorAlgorithm` treats this as telemetry/reinforcement plumbing only; it does not update behavior from numeric rewards directly.
- A positive nudge rating records telemetry plus a `postNudgeReturnToFocus` behavioral signal. It should not create persistent "liked nudge" memory or policy rules.
- A negative "it's fine" nudge rating is explicit false-positive correction. It records app/title/profile context, emits `nudgeMarkedFine`, installs a short recent-interaction allowance, and can drive a narrow profile-scoped rule or proposal through the policy-memory pipeline. For browser, media, social, chat, and email surfaces, this signal must not allow the whole app by itself.
- Hard escalations can reopen if the user returns to the blocked app.
- Overlay appeals go back through `LLMMonitorAlgorithm.reviewAppeal(...)`.
- An approved appeal or a chat-based correction installs a short cooldown on the intervened activity. `RecentInteractionAllowance.make` widens the scope to whole-app for browsers (research spans adjacent tabs) and keeps it window-scoped for everything else. Duration is set per cadence mode.

## Safelist Promotion

`SafelistPromotionService` watches repeated focused observations and can propose short-lived `allow` rules.

Important constraints:

- browsers and title-scoped apps must safelist by title, never by whole app
- restrictive user rules block auto-promotion
- trusted promotions require more evidence than probationary ones
- named profiles are allowed to promote faster than Everyday mode

## If You Change This Area

- Preserve the distinction between deterministic gates and LLM judgment.
- Keep temporary degradation state transient. Do not silently rewrite the user's saved monitoring backend or pipeline settings to handle network trouble.
- Preserve the "legitimate work interruption is a bug" principle.
- Update prompts and code together when schemas change.
- Keep telemetry meaningful enough that the Inspector can reconstruct why a decision happened.

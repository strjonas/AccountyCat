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
- a 30-second fallback context-change probe

The probe is now belt-and-braces rather than the main driver. Normal frontmost-app changes are event-driven:

- `NSWorkspace.didActivateApplicationNotification` re-attaches monitoring to the new frontmost PID
- `AppFocusAXObserver` subscribes to `kAXFocusedWindowChangedNotification` on the app and `kAXTitleChangedNotification` on its focused window
- browser-title cache entries are explicitly invalidated on those AX callbacks before the next tick is scheduled

If AX subscription fails for a PID, `BrainService` falls back to a 5-second fast poll until the user switches away again. Cooperative apps stay on the 30-second fallback probe.

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
- recently cached focused decisions can skip re-evaluation in the same context and keep the normal focused follow-up cadence rather than checking again on the next polling tick
- a recent user correction or approved appeal installs a short, cadence-scaled cooldown (`recentInteractionAllowances` on `LLMPolicyAlgorithmState`) so AC doesn't immediately re-flag the same activity
- a short global LLM cooldown (`lastLLMEvalAt`) suppresses rapid back-to-back fresh evaluations after app switching: 5s on `sharp`, 10s on `balanced`, 20s on `gentle`
- cadence delays defer evaluation until a context has been stable long enough
- browser contexts still pass through the stable-context gate, but use a much shorter settle window than native apps so tab switches are checked quickly
- title-only context can suppress screenshots for non-ambiguous apps
- online monitoring does a read-only connectivity gate before any provider call; true offline state skips evaluation quickly with a banner and a short recheck
- repeated online vision timeouts can temporarily degrade the *effective* pipeline to online text-only for a few minutes; this is transient runtime state in `BrainService`, not a persisted settings change
- when the local inference backend is active and a user-interactive (chat) request is in flight, `BrainService` skips the evaluation tick and defers the next check by 10 seconds (`local_runtime_busy` skip reason); this ensures the shared llama.cpp server is never reconfigured or interrupted mid-chat

The global cooldown does not suppress scheduled follow-up cycles from prior focused/unclear/distracted decisions, and restrictive rules still override it.

The design intent is to spend LLM calls where judgment is needed, not on obvious repeats.

## Screenshot Policy

`MonitoringHeuristics.canRelyOnTitleAlone(...)` decides when the title is strong enough to skip a screenshot.

Biases:

- browsers never qualify for title-only mode
- browser tab-title lookup is cached briefly (5 seconds) because stale browser titles can hide a real context switch, but AX-driven invalidation clears the cache immediately when the browser window or tab title actually changes
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
- chat workflow instructions and staged action executors (including `profileActionExecutorSystemPrompt`)
- memory-consolidation prompt
- policy-memory prompt rendering

## Profiles, Modes, and Learning

The monitoring payload is profile-aware.

- Default profile (`general` / "Everyday") is lenient by design.
- Named focus profiles raise the bar for off-task behavior, but the monitor judges the visible content/task before broad app category.
- **Decision payload ordering vs truth ordering are intentionally different.** Payload field order is optimized for prefix caching and recency: most-static fields first (`activeProfile`, `matchingRuleSummary`), then current-profile `recentUserMessages`, then `freeFormMemory`, then `calendarContext`, then live surface evidence. A compact `decisionFrame` repeats "where the user is" and "where the user should be" at the end of the payload for recency bias.
- **Truth ordering (which source wins on conflict) is customer-first**: `recentUserMessages` for this exact activity > `activeProfile` + `matchingRuleSummary` (both profile-scoped) > `freeFormMemory` (cross-mode soft truth) > `calendarContext` > live evidence. The prompt's "Decision contract" section is the authoritative copy of this hierarchy.
- For v1.0 the user is always king: a clear, current-session message that relaxes a profile rule for this exact activity wins. A future "accountability mode" may introduce non-negotiable / fixed rules that chat cannot relax — that is a deliberate v1.1+ scope (hard to get right; not on the v1.0 critical path).
- Sparse profile names such as Coding, Writing, Research, or Studying are treated as broad archetypes. Adjacent docs, tutorials, examples, planning, project chat, reference material, and debugging can be focused unless the profile description or rules narrow the scope.
- Specific profile descriptions and rules narrow the scope. A profile like "code writing only, no tutorials" should make tutorial/video content nudge-eligible.
- `activeProfile.activatedAt` is included in the decision payload. During the first few minutes of a newly activated named profile, the model should require stronger evidence before nudging plausible adjacent work, while still nudging clear unrelated drift.
- `recentUserMessages` is scoped to the currently active profile window, including `Everyday` — up to `recentUserChatCount` messages, oldest→newest, capped by `recentUserChatTotalCharacters`.
- `matchingRuleSummary` is the prompt-facing summary of active profile/context-matched policy rules. It is not the profile description.
- Free-form memory remains globally visible, but entries carry profile labels as capture provenance, not scope.
- Profile activation from chat or policy memory reuses an existing profile only when **both** its name and description fit the user's stated intent for the session. A similar keyword or broad archetype name is not enough if the stored description is broader, stricter, or otherwise different (e.g. pure essay writing vs a broad "Thesis" profile that also allows research). When the user narrows scope, create a new profile rather than activating a loose match. Broad requests ("coding for an hour") may activate a general Coding-like profile when descriptions align. Shared prompt copy and few-shot examples live in `ACPromptSets` (`profileReuseMatchingBlock`; policy-memory stage, chat system prompt, and `profileActionExecutorSystemPrompt`).
- `ProfileActionParser` (`AC/Services/ProfileActionParser.swift`) is a fast path for explicit profile names in natural-language instructions; it does not perform semantic profile matching.

## Appeals, Rewards, and Escalation

- Nudges can receive explicit positive/negative feedback from the user.
- `BrainService` converts those reactions into normalized reward signals and passes them back into the active algorithm. The current `LLMMonitorAlgorithm` treats this as telemetry/reinforcement plumbing only; it does not update behavior from numeric rewards directly.
- A positive nudge rating records telemetry plus a `postNudgeReturnToFocus` behavioral signal. It should not create persistent "liked nudge" memory or policy rules.
- A negative "it's fine" nudge rating is explicit false-positive correction. It records app/title/profile context, emits `nudgeMarkedFine`, installs a short recent-interaction allowance, and can drive a narrow profile-scoped rule or proposal through the policy-memory pipeline. For browser, media, social, chat, and email surfaces, this signal must not allow the whole app by itself.
- Hard escalations can reopen if the user returns to the blocked app.
- Overlay appeals go back through `LLMMonitorAlgorithm.reviewAppeal(...)`.
- An approved appeal or a chat-based correction installs a short cooldown on the intervened activity. `RecentInteractionAllowance.make` keeps browsers and other title-scoped surfaces narrow so one tab/thread correction does not exempt unrelated content in the same app a moment later. Less ambiguous native apps still use the exact current context key. Duration is set per cadence mode.
- Chat actions that mutate monitored state (profile changes, memory writes, focus-policy changes including safelist-like allows/disallows) call `BrainService.invalidateContextAndCooldown(reason:)`. This clears the current-context decision cache and resets the global cooldown without scheduling an immediate tick; the next natural app/context change drives a fresh evaluation. Any in-flight appeal session is preserved so a correction in chat does not silently dismiss an open appeal sheet.

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

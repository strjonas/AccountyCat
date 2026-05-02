# AC V1: Profiles, Smarter Cadence, Vision Gate, Tighter Prompts

## Context

AC works well today but isn't ready for V1 release: monitoring fires too often in research/dev workflows, safelisting is conservative-to-the-point-of-unused, prompts duplicate context across stages, vision is always-on (locking us out of cheap text-only models like DeepSeek V4 Flash), and there is no way to measure whether a prompt change made things better or worse. The user is one developer working on this on the side — every change must be **non-brittle, intelligence-preserving, and verifiable from existing tooling** rather than requiring a custom eval harness.

The keystone idea: **focus profiles**. Instead of a single flat safelist that AC is too cautious to populate (because rules persist forever), AC owns a small set of profiles (e.g. "Coding", "Presentation prep") plus a long-lived "General" default. Each profile has its own scoped safelist of `PolicyRule`s. Profiles themselves persist (coding looks similar week to week); rule freshness is handled by the existing per-rule `expiresAt` machinery. Profile switches are user-chat-driven, calendar-suggested, or popover-selected, and AC announces them in chat without interrupting focus. The menu bar always shows a chip with the active profile name + remaining time — clicking it opens a small control popover (pause / end / switch / start with timer) which is the manual fallback for users who prefer not to chat. Combined with title-length-based vision gating, an interval-aware skip-on-safelist-hit, and tighter prompts, AC becomes both more efficient and more transparent.

**Guiding principles (do not violate):**
1. Don't make AC stupider. Every prompt cut must preserve behavior on the recorded edge cases — and must remain robust on weaker local models that need clearer rules and the role/personality framing.
2. Non-brittle: deterministic signals (title length, profile expiry by clock, calendar event lookups) over LLM judgment-driven fallbacks.
3. Transparent: the user can see the active profile, its safelist, and its remaining time; AC announces switches in chat; nothing happens silently.
4. Reuse existing infrastructure (`PolicyMemory`, `PolicyRule`, `safelist_appeal`, `PromptLabRunner`) — do not rebuild.
5. Statistics-first for any heuristic tuning.
6. Online and offline must both work *in principle*. The user will tune model floors after implementation.

---

## What Already Exists (do not rebuild)

- **Cadence tiers**: `MonitoringMode.sharp/balanced/gentle` with `stableContextDelay`, `focusedFollowUp`, `distractedFollowUp` ([AC/Models/MonitoringModels.swift:46](AC/Models/MonitoringModels.swift:46))
- **Skip logic**: same-context cache, idle-reset-at-60s, `recent_allow_override`, `canRelyOnTitleAlone` ([AC/Core/LLMMonitorAlgorithm.swift:90](AC/Core/LLMMonitorAlgorithm.swift:90), [AC/Core/MonitoringHeuristics.swift](AC/Core/MonitoringHeuristics.swift))
- **Safelist machinery**: `PolicyMemory`, `PolicyRule` with `scope`, `schedule.expiresAt`, `isLocked`, `isAutoSafelistRule`, `PolicyRuleSource` ([AC/Models/PolicyMemoryModels.swift:214](AC/Models/PolicyMemoryModels.swift:214))
- **LLM-driven safelist promotion**: `safelist_appeal` stage with 6h throttle and observation-count thresholds ([ACShared/MonitoringPromptTuning.swift](ACShared/MonitoringPromptTuning.swift))
- **Inspector + telemetry**: 1,369 episodes in SQLite, `PromptLabScenario`/`PromptLabRunner.runMatrix()` for replay ([ACInspector/PromptLabModels.swift](ACInspector/PromptLabModels.swift), [ACInspector/PromptLabRunner.swift](ACInspector/PromptLabRunner.swift))
- **Idle detection**: `CGEventSource.secondsSinceLastEventType` ([AC/Services/SnapshotService.swift:18](AC/Services/SnapshotService.swift:18))

---

## Phase 1 — Foundations: token logging + debug statistics

**Why first:** without token counts and decision-mix stats, every later optimization is faith-based. The user explicitly asked for statistics in debug mode.

### Token usage capture
- Parse `usage` block from OpenRouter response (`prompt_tokens`, `completion_tokens`, `total_tokens`). Add to `RuntimeProcessOutput` (or a sibling type) in [AC/Services/OnlineModelService.swift](AC/Services/OnlineModelService.swift).
- Local runtime: `llama-cli` prints token counts to stderr — parse if present, else fall back to `(promptCharCount + completionCharCount) / 4` heuristic.
- Persist into existing telemetry event stream (`events.jsonl`) — add a `tokenUsage` field on `modelOutput` events.
- Plumb a small `TokenUsage(prompt:completion:cacheRead:imageTokens:)` struct end-to-end.

### Statistics view (debug-only tab)
Add a new `Stats` debug pane (only in DEBUG builds, accessible from the existing `.logs` tab gate in `ACPopoverTab`). Aggregates from inspector SQLite over the last 24h / 7d:
- Calls/hour rolling
- Avg tokens (prompt / completion / image) per call
- **Decision mix**: % focused / distracted / unclear / abstain (user explicitly asked: if 90% focused, the algorithm still isn't efficient)
- **Skip causes**: % skipped-by-safelist, % skipped-by-cache, % skipped-by-idle, % skipped-by-obviously-productive — each as a counter
- **Vision attach rate**: % calls that included a screenshot
- **Per-stage cost breakdown**: decision, nudge_copy, policy_memory, safelist_appeal
- **Per-profile aggregates** (after Phase 5): calls/hour, decision mix per profile

Status note (2026-05-02): the Stats pane now also includes a compact watch list that flags unhealthy unclear/retry/call-volume/vision-attach patterns so the title-only gate can be tuned from observed behavior instead of raw numbers alone.

**Files:** [AC/Services/OnlineModelService.swift](AC/Services/OnlineModelService.swift), [ACShared/Telemetry/](ACShared/Telemetry/) event types, new [AC/UI/StatsView.swift](AC/UI/StatsView.swift), wire in [AC/UI/ContentView.swift](AC/UI/ContentView.swift).

---

## Phase 2 — Prompt optimization (intelligence-preserving)

**Goal:** ~25–35% token reduction on the hot path (DECISION + ONLINE_DECISION + VISION) without behavior regression on the 15-scenario golden set (Phase 6). **Compression must not strip role/personality or examples that weak local models depend on.**

### 2a. Tighten DECISION system prompt (~520w → ~320w; conservative)
Current prompt (in [ACShared/MonitoringPromptTuning.swift](ACShared/MonitoringPromptTuning.swift) `policyDefaultPromptSet`) repeats rules across rule blocks and re-states output shape multiple times. Rewrite to:
- **Keep the role/personality framing intact** (`You are AccountyCat, the user's offline accountability companion.` + tone rules) — weak models lose voice without it.
- **Keep at least one concrete example of an ambiguous case** so weak models have a worked anchor.
- One bullet list of decision rules (no prose intro), but each rule kept short and unambiguous.
- Output schema once at the bottom.
- Drop: redundant "never threaten / never overstate confidence" — fold into one clause.
- Drop: the multi-paragraph re-statement of payload semantics already present in the user template.

### 2b. Tighten ONLINE_DECISION (~310w → ~220w)
Same approach. Online has its own block — share the rule set with DECISION via a shared `monitoringRulesCommon` constant in `MonitoringPromptTuning.swift` so future edits stay aligned.

### 2c. Vision prompts ([AC/Resources/Prompts/Monitoring/focus_default_v2/vision_system.md](AC/Resources/Prompts/Monitoring/focus_default_v2/vision_system.md))
The user flagged: "image prompt I think doesn't make sense." Concrete fixes:
- Drop "The screenshot is attached" preamble in `vision_user.md` (the model can see the image).
- Drop the bulleted re-statement of payload semantics — already in system prompt.
- Replace with: one line orienting the model to use vision as additional evidence, not the primary signal (title + goals are primary; vision disambiguates).
- **Adversarial-case fix** (for "I'm a social media influencer" / "Reddit mod"): explicitly instruct: *"If the user's stated goals describe activity that looks like leisure to most people (content creation, moderation, research about media), trust the goals. Match the visible activity against the goals, not against generic notions of productivity."*

### 2d. Output schema trims — carefully
Output-shape changes can confuse weaker models. Strategy: **make fields optional, don't reorder, document concisely.**
- `abstain_reason` → keep field; instruction reads "include only when assessment is unclear." Saves ~10 tokens per `focused`/`distracted` decision.
- `overlay_headline`, `overlay_body`, `overlay_prompt` → instruction reads "include only when suggested_action is overlay." Saves ~30 tokens per non-overlay decision.
- Verify with golden set after the change — if any model starts emitting malformed JSON, revert that specific field's optionality.

### 2e. Payload dedup
`policySummary`, `goals`, `freeFormMemory`, `recentUserMessages` are sent to up to 6 different stages. The hot path (DECISION + NUDGE_COPY) renders both. Add a single `RequestScopeContext` assembled once per evaluation tick and reused; ensures no field is encoded twice with different truncation.

Status note (2026-05-02): the monitoring hot path now builds a single `MonitoringRequestScopeContext` per evaluation and reuses it across allow-override checks, decision / online-decision, nudge-copy, and safelist-promotion appeal calls. This also removed one lingering hardcoded app-name budget so prompt caps now come from `MonitoringPromptContextBudget` consistently.

### 2f. Profile awareness in prompts (depends on Phase 5)
DECISION + ONLINE_DECISION get a new field: `activeProfile: { name, isDefault, expiresAt }`. Prompt instructs:
- "If `isDefault` is true, the user is in general/everyday mode — be conservative; everyday utilities (Finder, Mail, calendar) are fine."
- "If a named profile is active, judge strictly against the profile's name + goals; activities outside that scope are distractions even if normally productive (e.g. coding when profile is 'presentation prep')."

**Files:** [ACShared/MonitoringPromptTuning.swift](ACShared/MonitoringPromptTuning.swift), [AC/Resources/Prompts/Monitoring/focus_default_v2/](AC/Resources/Prompts/Monitoring/focus_default_v2/), [AC/Services/MonitoringLLMClient.swift](AC/Services/MonitoringLLMClient.swift) (payload assembly).

---

## Phase 3 — Algorithm refinements (intervals + skips)

### 3a. Interval semantics on safelist hit (per user spec)
Current behavior: every monitoring tick that runs an LLM call resets `nextEvaluationAt` to `now + interval`. Required change in `LLMMonitorAlgorithm.evaluationPlan`:
- **Safelist short-circuit**: do NOT reset `nextEvaluationAt`. Leave the timer where it was. Effect: if balanced mode says "next check in 5 min" and 2 min later user switches to a safelisted app, AC stays silent until 3 min from then — exactly user-described behavior.
- **Title-equality short-circuit** (new): same app + same title hash within `focusedDecisionCacheTTL` → also do not reset timer.
- **Real LLM call returns `focused`**: reset to `focusedFollowUp` (existing).
- **Real LLM call returns `distracted`**: reset to `max(60s, focusedFollowUp / 3)` — e.g. balanced 5 min → ~100 s. Replaces the current `distractedFollowUp` constant. Floor of 60s prevents a churn loop on weak models.
- **Real LLM call returns `unclear`**: reset to `focusedFollowUp / 2` (probe sooner, less aggressively than distracted).

### 3b. Idle detection (verify, no change)
Already correct ([AC/Core/BrainService.swift:380](AC/Core/BrainService.swift:380)). Just add a stat counter for "ticks-skipped-due-to-idle" so we can see in the Phase 1 dashboard.

### 3c. Models — DEFER
Per user: do not phase out small local models in this batch. The user will retune model selection / minimum-intelligence floor after the rest is implemented and tested.

**Files:** [AC/Core/LLMMonitorAlgorithm.swift](AC/Core/LLMMonitorAlgorithm.swift) (evaluationPlan, schedule-next), [AC/Models/MonitoringModels.swift](AC/Models/MonitoringModels.swift) (interval constants).

---

## Phase 4 — Vision gate by title length + one-shot escalation

### 4a. Default rule
If `windowTitle.count >= 30` AND title contains at least one informative character class (alpha + space, not all-caps app name), use **text-only** call. Else, capture screenshot and use vision.

This is one signal, deterministic, measurable. Long descriptive titles ("Refactor LLMMonitorAlgorithm.swift — AC.xcodeproj", "Phase 4 Vision Gate by Title Length — Notion") carry enough context to skip the screenshot.

Implementation: extend `MonitoringHeuristics.canRelyOnTitleAlone` ([AC/Core/MonitoringHeuristics.swift](AC/Core/MonitoringHeuristics.swift)) with a new branch:
```
if title.count >= titleLengthForTextOnlyThreshold &&
   !title.allSatisfy({ $0.isUppercase || $0.isWhitespace }) &&
   !MonitoringHeuristics.titleScopedBundleIdentifiers.contains(bundleID) {
   return true
}
```

`titleScopedBundleIdentifiers` (Slack/Discord/YouTube) keeps vision on regardless — even a long title there can be misleading.

**Threshold (30) is configurable** via `state.monitoringConfiguration.titleLengthForTextOnly` so the user can retune from the Stats dashboard if the unclear rate spikes.

Status note (2026-05-02): this threshold is now exposed in Settings as a polished "Vision gate" control with a slider, presets (`20 / 30 / 50`), and inline guidance about when to lower or raise it.

### 4b. One-shot escalation when text-only returns `unclear`
Per user's revision: if the text-only path returns `assessment == "unclear"` AND a screenshot was not sent, immediately retry **once** with the screenshot attached. If still unclear, accept and do nothing for this tick.

Implementation: in `LLMMonitorAlgorithm.runOnlineDecisionStage` / local equivalent, wrap the result. On unclear-without-image, capture a snapshot and re-issue. Bound: max one retry per tick. Track a `retried_with_vision` counter for the Stats panel.

### 4c. Verification
Phase 1 statistics already track `decision_mix`. After flipping this on, watch:
- Unclear rate. If ≥15% (vs ~5% today), bump threshold to 50 or revert.
- Retry rate. If >20% of calls retry with vision, the title-length heuristic is too lax — raise threshold.

**Files:** [AC/Core/MonitoringHeuristics.swift](AC/Core/MonitoringHeuristics.swift), [AC/Core/LLMMonitorAlgorithm.swift](AC/Core/LLMMonitorAlgorithm.swift).

---

## Phase 5 — Focus profiles (the keystone)

### Data model
Add to [AC/Models/ACModels.swift](AC/Models/ACModels.swift):
```swift
struct FocusProfile: Codable, Identifiable, Equatable {
    let id: String                  // "general" or e.g. "coding-2026-04-30"
    var name: String                // "General", "Coding", "Presentation prep"
    var isDefault: Bool             // exactly one default
    var description: String?        // human-readable, e.g. "Deep coding work in this repo"
    let createdAt: Date
    var lastUsedAt: Date            // for LRU eviction
    var activatedAt: Date?
    var expiresAt: Date?            // nil for default; set on activation, cleared on switch
    var createdReason: String       // "user said: 'help me focus on the presentation'"
}
```

**Profiles themselves are long-lived.** Per user feedback: coding workflows don't change much week to week; reusing profile shells avoids re-promoting the same rules. **Per-rule expiry (existing `PolicyRule.schedule.expiresAt`) handles freshness.**

LRU cap: max 8 profiles. When adding a 9th, evict the one with the oldest `lastUsedAt` (default cannot be evicted). The model receives the existing list with name/description/safelists when the user proposes a session, and decides match-or-create.

Add to [AC/Models/PolicyMemoryModels.swift](AC/Models/PolicyMemoryModels.swift):
- `PolicyRule.profileID: String` — defaults to `"general"`. Backward-compatible Codable with fallback to general.
- `PolicyMemory.activeRules(at:matching:profileID:)` — extend existing query to filter by profile.

Add to `ACState`:
- `profiles: [FocusProfile]` — always contains a `general` entry, seeded on first launch.
- `activeProfileID: String` — defaults to `"general"`.

### Default-profile naming
Show the default profile in the menu bar too (per user). Proposed name: **"General"** — neutral, distinct from "default" (which sounds system-y), avoids leisure connotations of "Free" or "Open". User can rename in Brain tab. Plan uses "General" throughout; final name is the user's call.

### Profile lifecycle
- **Activation (chat-driven, primary):** the existing `policy_memory` pipeline LLM stage gets two new operation types alongside the current rule ops:
  - `activate_profile { profileID, expiresAt? }` — switch to existing profile
  - `create_and_activate_profile { name, description, durationHint, initialRulesHint }` — create new + activate
- The model receives the existing profiles' (name, description, key rule summary) so it can decide match-or-create.
- AC's chat reply announces the switch (see UX below).
- If user gives no time, AC chooses: short tasks (1h), focus blocks (90m), end-of-day (until 18:00 or `goalsText`-derived). Capped at 4h. The chat announcement always states the chosen time so the user can override ("just an hour").

### Profile expiry (check-time, not timer-driven)
At every monitoring tick (`BrainService.scheduleTickIfNeeded`):
```swift
if let active = activeProfile, !active.isDefault,
   let exp = active.expiresAt, exp <= now {
    swap to general profile, log event, post non-interrupting chat note
}
```
No separate scheduler. Non-brittle (sleeps/timezones can't break it; if AC was off when expiry hit, it expires on next wake).

### Rule promotion within a profile
The existing `safelist_appeal` LLM stage stays, but:
- **Lower threshold inside named profiles** (e.g. 2 focused observations instead of 5) — named profiles are explicit user-scoped, so being aggressive is safe and is the whole point ("after a few cycles most window titles like Xcode, Claude, VS Code, important browser tabs are all in the safelist").
- **General profile keeps the conservative threshold** — promoted there only after many days of consistent productive observation.
- Promoted rule's `profileID` = current `activeProfileID`.
- Promoted rule's `schedule.expiresAt` retained as today (rules stay fresh even though the profile shell persists).

### Memory entries: profile prefix
Per user. When an entry is added to memory (free-form notes captured during chat), prefix with active profile context: e.g. `[Coding] User dislikes vague nudges during deep work`. Helps the chat / decision stages reason about which memories apply when. Add `profileID: String?` field to memory entries; render the bracket prefix only in prompt assembly, store the structured field for filtering.

### UI

**Menu bar chip (always visible):**
- Default: `"AC · General"` (or whatever the user names default).
- Named profile active: `"AC · Coding · 47m"` showing remaining time.
- Click → opens a small popover (separate from the main popover) with:
  - **Pause** button — pauses monitoring (resume on next click or after a chosen duration).
  - **End** button — only enabled for non-default; switches back to General.
  - **Switch to** list — shows the other profiles. Click to activate.
  - **Custom timer** field — small `+30m / +1h / +2h / Custom` chooser when starting / extending. This is the **manual fallback** for users who prefer not to chat.
  - **Empty-state hint** when only General exists: small subtitle *"Tip: tell AC 'help me focus on coding for 2 hours' to start a session."*

"Hidden until found" UX: chip is present but quiet (small font, subtle color); the popover is rich for users who discover it but doesn't lecture new users.

Status note (2026-05-02): the menu bar chip now opens a dedicated quick-control popover instead of the full app popover once setup is complete. That surface supports pause/resume, end session, switching to saved profiles with an explicit timer, `+2h`, and a custom minute entry; the old compact header control was upgraded to reuse the same richer flow. Manual profile actions from this surface and the Brain tab also clear the unread badge immediately so AC does not show a fresh deferred-dot for a switch the user just triggered themselves.

**Brain tab additions:**
- Profile picker at top (shows active profile, switches view to that profile's safelist).
- Active profile's rules list with delete/lock buttons (reuse existing `toggleRuleLocked`/`deleteRule`, scoped by `profileID`).
- "Edit profile name / description" inline.
- "Manage all profiles" button → list of all profiles with last-used dates and rule counts.

Status note (2026-05-01): the Brain tab now includes this saved-profile overview, plus guarded deletion so a profile with locked scoped rules cannot be removed into an orphaned state.

**Chat announcement UX (non-interrupting):**
- AC posts a chat message describing the switch + chosen duration.
- A small dot badge appears on the menu-bar AC icon when there are unread chat messages.
- The orb (CompanionView) does **not** pop up for profile announcements — those are only for nudges.
- If the user is currently focused (recent decision was `focused` and idle < threshold), AC waits to deliver until the user becomes idle OR opens the popover OR the current profile's session ends. Implementation: queue chat messages with an `interruptionPolicy: .deferred` field; flush when idle event fires or popover opens.

Status note (2026-05-01): focused test coverage now exists for policy-memory-driven profile operations. The routing path also hardens multi-op responses by announcing only the final effective profile state once, instead of queuing multiple contradictory deferred messages.

### Anti-brittleness measures
- AC announces every switch in chat. User sees and can correct.
- Profile-match LLM call (existing `policy_memory` stage with new ops) is single-shot; if it returns nothing, no switch happens — fail-closed.
- LRU cap of 8 stored profiles + default. Beyond that, oldest unused gets pruned.
- General profile cannot be deleted, only its rules edited (`isDefault = true` flag).
- No automatic creation without user intent (chat trigger or calendar suggestion that the user accepts).

**Files:** [AC/Models/ACModels.swift](AC/Models/ACModels.swift), [AC/Models/PolicyMemoryModels.swift](AC/Models/PolicyMemoryModels.swift), [AC/Core/AppController.swift](AC/Core/AppController.swift) (lifecycle methods), [AC/Core/LLMMonitorAlgorithm.swift](AC/Core/LLMMonitorAlgorithm.swift) (expiry check + profile-aware rule lookup), [ACShared/MonitoringPromptTuning.swift](ACShared/MonitoringPromptTuning.swift) (add ops to `policy_memory` schema, lower `safelist_appeal` threshold for named profiles, profile context to DECISION/NUDGE_COPY), [AC/UI/BrainView.swift](AC/UI/BrainView.swift) (profile picker + scoped rules), new [AC/UI/MenuBarChipView.swift](AC/UI/MenuBarChipView.swift) and [AC/UI/ProfileControlPopover.swift](AC/UI/ProfileControlPopover.swift), [AC/UI/CompanionView.swift](AC/UI/CompanionView.swift) (queue deferred messages).

---

## Phase 6 — Calendar awareness

Per user. Worth doing if not too brittle.

### Behavior
- **Only when `general` profile is active** (named profiles are explicit user choice — don't override).
- Every `monitoringMode.focusedFollowUp × 6` (e.g. 30 min in balanced) AND user is not idle, query macOS Calendar (EventKit) for current-now event in user-selected calendars.
- If a non-empty event exists with a meaningful title (≥4 chars, not all-caps), feed event title + description + duration to a small LLM call alongside the existing profiles list. Prompt: *"Should AC suggest activating a focus profile? If yes, which existing one (by id) or propose a new name and description?"*
- If the model proposes a switch, AC posts a **deferred chat message** (uses the same non-interrupting queue from Phase 5): *"Your calendar shows 'Sprint planning' until 11am — want me to switch to your Meetings profile?"*. Two inline-action buttons in the chat row: `Accept` and `Dismiss`.
- Until user accepts, no switch. If user dismisses, AC marks that event as ignored and won't ask again for that event id.

### Permission flow
- EventKit requires explicit user permission. Request it during onboarding (added as an optional step) or lazily the first time calendar awareness fires. If permission denied, the feature is silently disabled — AC behaves as if there were no calendar.

### Why this is doable, not brittle
- Deterministic trigger (clock-driven, not LLM-driven).
- No silent state change — user must accept the switch.
- LLM call is bounded (~once per 30 min, only when general profile active).
- Failure mode is "no suggestion" — falls back to current behavior cleanly.
- The new prompt for this is small and self-contained.

**Files:** new [AC/Services/CalendarService.swift](AC/Services/CalendarService.swift) (EventKit wrapper), [AC/Core/BrainService.swift](AC/Core/BrainService.swift) (cadence trigger), [ACShared/MonitoringPromptTuning.swift](ACShared/MonitoringPromptTuning.swift) (new `calendar_profile_suggest` prompt), [AC/UI/CompanionView.swift](AC/UI/CompanionView.swift) (inline-action chat row).

---

## Phase 7 — Lightweight regression check (solo-dev-friendly)

**Not** a full eval harness. Just enough to catch obvious regressions when prompts change.

1. **Curate 15 golden scenarios** from existing inspector data (~30 min of work):
   - 5 clear-focused (Xcode editing, Notion writing, terminal in repo)
   - 4 clear-distracted (YouTube non-research, social feeds, off-topic browsing)
   - 3 ambiguous (browser with vague title, Slack at work, calendar)
   - 3 adversarial: "I'm a social media influencer" + Twitter, "Reddit mod" + Reddit, "researching AI distractions" + YouTube
   - Hand-label each with expected `assessment` + `suggested_action`. Store as JSON in `ACTests/Goldens/v1_baseline.json`.

2. **Replay command** (Inspector or DEBUG-only popover button): runs `PromptLabRunner.runMatrix(scenarios:..., promptSets:[current], runtimes:[balanced])` and prints a one-line summary: `"v1_baseline: 13/15 match, 2 differ (scenario_3, scenario_11)"`.

3. **Run online and offline both** so the user can spot tier-specific regressions. The user will tune model floors from the results.

4. **No automated assertions in CI** — solo dev, eyeball the diff. Runs in ~20 seconds per check.

**Files:** new `ACTests/Goldens/v1_baseline.json`, small extension in [ACInspector/PromptLabRunner.swift](ACInspector/PromptLabRunner.swift) with a `runGolden()` helper.

---

## Phase 8 — Documentation

After implementation, write `docs/HOW_AC_WORKS.md` covering:
- The monitoring loop (cadence, skip rules, idle, profile expiry-on-tick, calendar-suggest)
- Profiles (lifecycle, default vs named, LRU eviction, promotion thresholds, UI surfaces)
- Vision gate (title-length rule, threshold knob, one-shot escalation, statistics to watch)
- Prompt structure (one-line per stage, when fired, token budget target)
- The 15-scenario golden set + how to run it
- Token-cost expectations (per-tier monthly estimates with the new prompt sizes)
- Stats panel reading guide (what each metric means and what an unhealthy value looks like)

If any phase is partially implemented, document what's missing in a `# Deferred to V1.1` section at the bottom — explicitly per user instruction.

---

## Sequence and effort estimate

| Phase | Effort | Why this order |
|---|---|---|
| 1. Token logging + stats | 2–3h | Foundation; needed to verify everything else |
| 2. Prompt optimization | 3–4h | Independent; quickest win once stats is in place |
| 3. Algorithm refinements | 2–3h | Independent of profiles; pure interval logic |
| 4. Vision gate + escalation | 2h | Standalone; statistics from Phase 1 verify |
| 5. Profiles | 8–10h | Largest piece; depends on Phases 1–3 being stable |
| 6. Calendar awareness | 2–3h | Builds on profiles; gated by EventKit permission |
| 7. Golden set + runner | 1h | Run after Phase 2 lands; rerun after each later phase |
| 8. Documentation | 1h | Last |

Total: ~21–27h. Splittable across multiple sessions; phases 1–4 ship cleanly without 5+. If time runs short, the natural cut line is to ship 1–5 and defer 6 to V1.1.

---

## Verification

After each phase, run:
1. **Build**: `xcodebuild -project AC.xcodeproj -scheme AC build`
2. **Existing tests**: `xcodebuild -project AC.xcodeproj -scheme AC test` — `ACTests/` covers prompt assembly, algorithm transitions, safelist promotion. None of these phases should break those.
3. **Golden replay** (after Phase 7 lands): trigger from debug popover; expect ≥13/15 match against baseline labels, both online and offline.
4. **Live smoke test**: 30-minute session with the user's normal workflow (mix of Xcode + browser + Slack). Spot-check decision mix and skip rate in the new Stats panel — distracted rate should be plausible (5–15%), not 0% (= too lenient) or 50% (= too strict).
5. **Adversarial smoke**: temporarily set goals to "I'm a social media manager researching trending Reels"; open Instagram for 3 minutes; expect `focused`, not `distracted`.
6. **Profile smoke**: chat "help me focus on coding for an hour"; verify menu bar chip switches; verify Xcode promotes to safelist after ~2 focused observations; switch back to general and verify the rule no longer applies.

---

## Risks and mitigations

- **Profile-match LLM picks the wrong profile to activate** → AC announces in chat with one-line correction path; defaults to "create new" rather than "match existing" if confidence is low.
- **LRU eviction loses a profile the user actually wanted** → 8 is generous; UI shows last-used dates so the user can pin (lock) their favorites. Add a `pinned: Bool` to FocusProfile if needed (V1.1).
- **Title-length heuristic causes unclear rate to spike** → Phase 1 stats show this within hours; threshold is a single tunable; one-shot vision retry catches the real ambiguities anyway.
- **Prompt tightening regresses an edge case on a weak local model** → Phase 7 golden set runs both tiers; user retunes model floor after.
- **`distracted` interval becoming `focusedFollowUp / 3` is too aggressive on weak models** → absolute floor of 60s prevents churn loops.
- **Calendar suggestions become noisy** → ignored events stay ignored per session; cap of one suggestion per event-id ever.
- **Chat queue swells if user is focused for hours** → cap at 5 deferred messages; older suggestions self-expire (not relevant anymore).
- **Memory entries growing with profile prefixes** → already capped by existing memory consolidation pass.

---

## What is explicitly NOT in V1

- Full automated eval harness with CI gates (V1.1 if useful)
- Multi-run majority-vote scoring (V1.1)
- Per-tier prompt variants (current setup of one prompt across tiers is fine)
- Auto-escalation beyond one retry from text-only to vision (one retry only; further unclear → no action)
- Profile templates / sharing between users
- Model selection / minimum-intelligence floor changes (the user will retune after the rest is in)
- Profile pinning UI (V1.1 if LRU evicts something painful)

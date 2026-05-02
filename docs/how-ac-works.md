# How AC works

## Overview

AC is a menu-bar focus companion that takes periodic screenshots, evaluates whether you're on-task using local or cloud LLMs, and nudges you when you drift. You interact with it through a chat window, a menu bar chip, and the Brain tab.

This document explains the runtime flow: what happens when you send a chat message, how profiles scope your rules, how memory evolves, and how monitoring decisions are made.

---

## The two LLM pipelines

AC has two separate LLM pipelines that talk to each other:

| Pipeline | Trigger | Purpose | LLM call count |
|---|---|---|---|
| **Monitoring** | Periodic tick (BrainService) | Evaluate current activity against goals + rules | 1–4 per tick (perception, decision, nudge) |
| **Chat + policy** | User sends chat message | Reply, extract memory, handle profile/rule changes | 1 chat call, optionally +1 policyMemory call |

They share state through `ACState` (persisted to disk) and communicate via structured output fields.

---

## Chat flow — what happens when you send a message

### Step 1: Context assembly

`AppController.sendChatMessage()` (`AC/Core/AppController.swift:1928`) builds a prompt with these sections:

```
[Context]               Frontmost app, window title, idle time, today's usage
[Active profile]        Name, description, expiry, whether it's the default
[Available profiles]    Names + descriptions of other saved profiles
[User goals]            Your stated goals
[Persistent memory]     Chronological memory entries with [ProfileName] prefixes
[Brain rules]           Policy rules filtered to the active profile
[Recent conversation]   Last 8 chat messages (capped at 4000 characters)
[New user message]      Your input
```

Profile context is injected via `ACPromptSets.chatProfileContextSection()` in `ACShared/ACPromptSets.swift`, called from `AppControllerChatSupport.makeProfileContextForChatPrompt()`.

### Step 2: LLM call

`CompanionChatService.chat()` (`AC/Services/CompanionChatService.swift:40`) sends the system prompt (character voice + base chat prompt from `ACPromptSets`) and user prompt to the LLM.

### Step 3: Response parsing

`LLMOutputParsing.extractChatResult()` (`AC/Services/LLMOutputParsing.swift:18`) parses the LLM's JSON:

```json
{"reply": "...", "memory": null, "profile_action": null}
```

All three fields are parsed. `memory` accepts `memory`, `memoryUpdate`, or `memory_update` as key names for backwards compatibility. `profile_action` accepts `profile_action` or `profileAction`. Values of `null`, `"none"`, or empty string are normalized to nil.

### Step 4: Post-processing

`AppController.sendChatMessage()` does three things after the reply:

**4a. Memory extraction (if `memory` is non-nil)**

A `MemoryEntry` is created and stamped with the active profile:

```swift
MemoryEntry(
    text: update,
    profileID: activeProfile.id,      // scoped to current profile
    profileName: activeProfile.name
)
```

Memory is rendered in future prompts via `ACState.memoryForPrompt()` (`AC/Models/ACModels.swift:776`), which includes `[ProfileName]` prefixes for non-default profiles. Memory is **not** filtered by profile — all entries are shown regardless of which profile captured them. The LLM uses the prefix as context.

**4b. Profile action (if `profile_action` is non-nil)**

The profile_action string (e.g. `"activate profile Coding for 60 min"`) is passed to `schedulePolicyMemoryUpdate()` which triggers a separate **policyMemory LLM call**. This second call receives the full profile context (active profile, available profiles, goals, memory, rules) and converts the intent into structured operations:

```json
{"operations": [{"type": "activate_profile", "profileID": "...", "profileDurationMinutes": 60}]}
```

These operations are applied by `AppController.applyProfileOperations()` (`AC/Core/AppController.swift:2404`), which calls `activateProfile()`, `createAndActivateProfile()`, or `endActiveProfile()`.

If `profile_action` is present, the policyMemory call is made; the chat reply is not blocked by it. If the policyMemory call fails (network, model error), the profile switch does not happen — fail-closed.

**4c. Rule updates (if `memory` was added)**

When memory is added, `schedulePolicyMemoryUpdate()` is also called to let the policyMemory LLM decide whether new rules should be created, updated, or expired. This handles cases like "don't let me use Instagram today" → `add_rule {kind: disallow, scope: app, target: Instagram}`.

**Key optimization**: policyMemory is only called when there's actual work — a `profile_action` field or a `memory` addition. Before, it ran after *every* chat message regardless.

### Step 5: Memory consolidation

`maybeConsolidateMemory()` (`AC/Core/AppController.swift:2471`) runs asynchronously after chat. It triggers when:

- Memory exceeds 15 entries (soft cap)
- At least 24 hours have passed since the last consolidation (to prune stale "today" entries)

Consolidation sends all memory entries through a separate LLM call (`MemoryConsolidationService`) that merges duplicates, removes expired entries, and enforces a target of ≤10 entries. The consolidated list replaces the previous list. If the LLM fails to produce valid output, the existing memory is kept.

---

## Profiles

### Data model

`FocusProfile` (`AC/Models/ACModels.swift:841`):

| Field | Purpose |
|---|---|
| `id` | UUID or `"general"` for the default |
| `name` | User-visible label |
| `isDefault` | Exactly one profile has this set |
| `activatedAt` | When the profile was last switched to |
| `expiresAt` | When this session ends (nil for default) |

`ACState` stores `profiles: [FocusProfile]` (max 8 named + default) and `activeProfileID: String`.

### Profile operations

| Operation | Method | Source |
|---|---|---|
| Activate existing | `activateProfile(id:)` | Chat (policyMemory), menu bar popover, Brain tab |
| Create + activate | `createAndActivateProfile(name:duration:)` | Chat (policyMemory) |
| End session | `endActiveProfile()` | Chat (policyMemory), menu bar popover, expiry on tick |
| Extend | `extendActiveProfile(byMinutes:)` | Menu bar popover |
| Delete | `deleteProfile(id:)` | Brain tab (blocked if locked rules exist) |

All operations persist state immediately and maintain the LRU cap (least-recently-used eviction when exceeding 8 named profiles). The default profile cannot be deleted.

### Profile expiry

Profiles don't use timers. On each monitoring tick, `BrainService` (`AC/Core/BrainService.swift:393`) checks:

```swift
if !activeProfile.isDefault, activeProfile.isExpired(at: now) {
    // Swap to default
    // Append chat announcement
    // Record metric
}
```

This is tick-driven by design (per AGENTS.md): if AC is paused or the tick loop is delayed, the profile overstays its welcome until the next evaluation. This avoids brittle timer logic across sleep/wake cycles.

When a profile expires, its rules are **immediately** excluded from the current tick's monitoring evaluation — `scopedPolicyMemory` is rebuilt after the swap.

### How profiles scope rules

`PolicyRule` has a `profileID: String` field (`AC/Models/PolicyMemoryModels.swift:88`). Rules are filtered by profile:

- **Monitoring**: `scopedPolicyMemory.rules.filter { $0.profileID == activeProfileID }` (`BrainService.swift:507`)
- **Chat prompt**: `policyMemory.chatSummary(profileID: activeProfileID)` (`ACModels.swift:794`)
- **Safelist promotion**: New rules are stamped with the current `activeProfileID`

The `[Active profile]` section injected into the chat user prompt tells the chat LLM which profile is active, so it can decide whether a `profile_action` is warranted.

### Rule expiry vs profile expiry

These are independent systems:

- **Profile expiry** (`FocusProfile.expiresAt`): the whole profile session ends, its rules are excluded. No rules are deleted — they remain scoped to the profile for future sessions.
- **Rule expiry** (`PolicyRule.schedule.expiresAt`): individual rules within a profile have their own expiry. A rule like "don't let me use Instagram today" expires at midnight while the profile remains active.

---

## Monitoring flow

### Tick loop

`BrainService` runs a monitoring tick loop. On each tick:

1. **Profile expiry check**: if the active named profile has expired, swap to General
2. **Context capture**: frontmost app, window title, idle time
3. **Rule scoping**: filter `PolicyMemory.rules` to `activeProfileID`
4. **Skip checks**: safelist hit, idle, same-context cache, explicit allowances
5. **Pipeline selection**: `LLMPolicyCatalog.pipelineProfile(id:)` determines whether to use vision or text-only
6. **Evaluation**: perception stage(s) → decision stage → (if distracted) nudge copy stage
7. **Action**: if nudge or overlay is warranted, `ExecutiveArm` renders it

### Profile context in monitoring prompts

The monitoring LLM receives profile context in the JSON payload at every stage:

```json
{
  "activeProfile": {
    "id": "...",
    "name": "Coding",
    "isDefault": false,
    "description": "Deep coding work",
    "expiresAt": "2026-05-02T20:20:36Z"
  }
}
```

This is built by `LLMMonitorAlgorithm.MonitoringRequestScopeContext` (`AC/Core/LLMMonitorAlgorithm.swift:30`) from the `MonitoringDecisionInput` constructed in `BrainService`. The decision prompt instructs:

- Default profile → conservative, everyday utilities are usually fine
- Named profile → judge strictly against the profile's name + goals

### Named profiles get lower safelist thresholds

`SafelistPromotionService` (`AC/Services/SafelistPromotionService.swift:148`) uses `inNamedProfile` to lower promotion requirements:

- Named profiles: 4 focused observations, 1 distinct day
- Default profile: 6 focused observations, 2 distinct days

This makes safelist promotion more aggressive during explicit focus sessions.

---

## Prompt architecture

All system prompts live in `ACShared/ACPromptSets.swift` — the single source of truth for LLM-facing prompt text. There is no `PromptCatalog.swift`; access goes directly through `ACPromptSets`.

### Monitoring stages

| Stage | Enum | Purpose |
|---|---|---|
| `perceptionTitle` | `.perceptionTitle` | Infer activity from app/title/usage |
| `perceptionVision` | `.perceptionVision` | Describe what's on screen from screenshot |
| `onlineDecision` | `.onlineDecision` | Single-round decision + nudge (online models) |
| `decision` | `.decision` | Policy decision after perception (local models) |
| `nudgeCopy` | `.nudgeCopy` | Write the nudge text |
| `appealReview` | `.appealReview` | Review typed appeal against a nudge |
| `policyMemory` | `.policyMemory` | Convert chat intent to structured memory/profile ops |
| `safelistAppeal` | `.safelistAppeal` | Decide whether to auto-allow an app |

### Chat prompt

`ACPromptSets.chatSystemPrompt(withPersonality:)` builds the chat system prompt by prepending the character's personality prefix (Mochi/Nova/Sage) to the base chat prompt. The user prompt is built dynamically in `CompanionChatService.makeChatPrompt()` with sections for context, profiles, goals, memory, rules, and conversation history.

### Memory consolidation prompt

`ACPromptSets.memoryConsolidationSystemPrompt` holds the curation rules. `ACPromptSets.renderMemoryConsolidationUserPrompt()` renders the user prompt with ISO timestamps, goals, recent messages, and current entries spliced in.

---

## Key data flow diagram

```
User sends "focus on coding for 60 min"
    │
    ▼
Chat LLM
    │  System: character voice + base chat prompt
    │  User: context + [Active profile] + [Available profiles]
    │        + memory + brain rules + history + message
    │
    ├─► reply: "On it! Coding profile activated for 60 min."
    └─► profile_action: "activate profile Coding for 60 min"
         │
         ▼
    schedulePolicyMemoryUpdate()
         │  Sends: profile_action, activeProfile, availableProfiles,
         │         goals, memory, rules, frontmost context
         ▼
    PolicyMemory LLM (separate call)
         │  System: ACPromptSets.policyMemorySystemPrompt
         │  User: JSON payload with all context
         │
         └─► {"operations": [{"type": "create_and_activate_profile",
                               "profileName": "Coding",
                               "profileDurationMinutes": 60,
                               "reason": "User requested coding focus"}]}
              │
              ▼
         AppController.applyProfileOperations()
              │
              ├─► createAndActivateProfile(name: "Coding", duration: 3600)
              │      └─► state.activeProfileID = newProfile.id
              │
              └─► announceProfileSwitch()
                     └─► chat message: "Switching to your Coding profile until XX:XX"
```

```
Monitoring tick (BrainService)
    │
    ├─► Profile expired? → swap to General, announce
    │
    ├─► scopedPolicyMemory = rules filtered by activeProfileID
    │
    ├─► Skip checks (safelist, cache, idle, allowance)
    │
    ├─► Decision input: includes activeProfile{id, name, isDefault, description, expiresAt}
    │
    ├─► LLM perception → LLM decision → LLM nudge (if distracted)
    │
    └─► ExecutiveArm renders nudge/overlay or stays silent
```

---

## Notable design decisions

**Chat LLM doesn't execute profile operations directly.** It outputs a `profile_action` hint field, which triggers a separate policyMemory LLM call that converts the hint into structured operations. This separation keeps chat conversational and policyMemory precise. Both calls use the same LLM routing (local or OpenRouter).

**Profile expiry is tick-driven, not timer-driven.** No `Timer` or `DispatchQueue` is involved. The check happens at the top of every monitoring tick. If AC is paused or delayed (e.g., system sleep), the profile overstays until the next evaluation fires.

**Memory entries are stamped with profileID but rendered across all profiles.** When you're in "Chill" mode, you still see memory from your "Coding" session — the `[Coding]` prefix provides context. This is intentional: memory should persist across sessions, not vanish when you switch profiles.

**PolicyMemory is no longer called after every chat message.** It only fires when the chat LLM outputs a `profile_action` or `memory` field. This avoids wasteful LLM calls for casual chat messages.

**Safelist promotion is twice as aggressive in named profiles.** If you're explicit about focusing on "Coding", AC trusts that and promotes safe apps faster.

---

## File index

| File | Role |
|---|---|
| `ACShared/ACPromptSets.swift` | Single source of truth for all LLM-facing prompt text |
| `AC/Core/AppController.swift` | Chat dispatch, profile lifecycle, memory management, policyMemory triggering |
| `AC/Core/BrainService.swift` | Monitoring tick loop, profile expiry on tick, decision input assembly |
| `AC/Core/LLMMonitorAlgorithm.swift` | Staged LLM evaluation, request scope context with profile payload |
| `AC/Services/CompanionChatService.swift` | Chat prompt assembly and LLM call |
| `AC/Services/PolicyMemoryService.swift` | Policy memory LLM call (converts intent to structured operations) |
| `AC/Services/MemoryConsolidationService.swift` | Memory deduplication and pruning LLM call |
| `AC/Services/LLMOutputParsing.swift` | JSON response parsing for all LLM outputs |
| `AC/Services/SafelistPromotionService.swift` | Auto-safelist eligibility and LLM promotion call |
| `AC/Models/ACModels.swift` | `ACState`, `FocusProfile`, `ACCharacter`, memory rendering |
| `AC/Models/PolicyMemoryModels.swift` | `PolicyMemory`, `PolicyRule`, rule scoping by profileID |
| `ACShared/MonitoringPolicyPromptSchemas.swift` | `MonitoringActiveProfilePromptPayload`, decision payload schemas |

# Plan: AccountyCat UI redesign to match `design_handoff_AC/`

## Context

The user brainstormed a cleaner redesign with another Claude session that didn't have access to the codebase. The design lives in `design_handoff_AC/` (HTML/JSX reference + spec README). The goal is a UI/UX refactor to match that design while preserving the existing business logic (services, algorithm, persistence). The redesign introduces a few small business-logic deltas — most notably a per-profile **blocklist** alongside the existing safelist (the design's simpler model replaces the surface area of the current general-purpose "rules" UI for end users) — but the underlying `PolicyRule` system stays in place beneath a thinner surface.

The user's key constraints:
- **Don't touch DebugSheet** — keep developer panel as-is, just add a DEBUG-only opener button in the new top bar.
- **Rename old views with `_Legacy` suffix** instead of deleting, so the old UI can be reverted if the redesign feels worse.
- **Don't reinvent existing systems**: safelist (per-profile) already exists; just add blocklist. Memory already has lock/delete. Animations already exist. Profiles, characters, AI mode toggling all already work.
- **Start with 3 skins**: Bubble, Pixel, Liquid (defer Line and Mono).
- **Profile timer ring deferred**, voice input is a disabled placeholder, JSON storage stays, max 7 profiles.
- Mostly: rules → blocklist rebrand, plus prompt tweaks. The bulk of the work is UI.

---

## Mapping: existing → design

### Already exists (reuse / minor binding only)
| Design element | Current implementation |
|---|---|
| Characters Mochi/Nova/Sage with palettes | `ACCharacter` enum in [ACModels.swift](AC/Models/ACModels.swift) with full palette |
| Per-profile safelist | `PolicyRule kind=.allow` scoped by `profileID` in [PolicyMemoryModels.swift](AC/Models/PolicyMemoryModels.swift) |
| Memory entries with cleanup | `ACState.memoryEntries` + [MemoryConsolidationService.swift](AC/Services/MemoryConsolidationService.swift) |
| Memory lock | Verify `MemoryEntry.isLocked` exists; if not, add the field + UI |
| Stats: focused today, streak | `MonitoringStatsSnapshot` already has `focusedSeconds` and `streakDays` |
| Nudge tooltip view | [NudgeView.swift](AC/UI/NudgeView.swift) — needs visual refresh |
| Escalation overlay | [OverlayView.swift](AC/UI/OverlayView.swift) — needs visual refresh to visual-novel layout |
| Floating cat widget | [CompanionView.swift](AC/UI/CompanionView.swift) with bob/pulse animations |
| Pixel cat rendering | [PixelCatView.swift](AC/UI/PixelCatView.swift) + [PixelCatGrid.swift](AC/UI/PixelCatGrid.swift) |
| AI backend toggle | `MonitoringInferenceBackend` enum (.local/.byok/.managed) |
| Cadence/intensity | `MonitoringCadenceMode` (sharp/balanced/gentle) — maps to design's intensity slider |
| Onboarding | [OnboardingWizardView.swift](AC/UI/OnboardingWizardView.swift) — minor tone refresh later |
| Profile model: name, isDefault, expiresAt, lastUsedAt | `FocusProfile` in ACModels |
| Active session ring math | `expiresAt - activatedAt` already drives ring elsewhere |

### Needs change / extension
| Design element | Action |
|---|---|
| Per-profile **blocklist** | New field `blocklist: [String]` on `FocusProfile`; surface in profiles tab |
| Profile **emoji**, **color**, **description**, **defaultDurationMin** | Add fields on `FocusProfile`; backwards-compat decoding |
| 5 design profiles (writing, deep coding, social mgmt, admin, design) + **everyday** | Seed list; "everyday" is `isDefault` and has no safelist/blocklist/timer |
| **Skin** system (Pixel/Bubble/Liquid for v1) | New `ACSkin` enum + 3 Canvas renderers + per-character palette already there |
| **Expressions** matrix (7) | Map `CompanionMood` → `ACCatExpression` (`neutral / happy / sleep / alert / drift / celebrate / concern`) |
| **6-tab Settings** (look / profiles / ai / nudges / persona / you) | New `SettingsView` replacing `SettingsSheet` (rename old to `_Legacy`) |
| **Stat strip** above chat (focused / % of day / streak with milestone glow) | Replaces inline stats card in current `ChatPopoverView` |
| **Profile bar** at top of panel | Replaces current `ProfileControlBar` chip in header |
| **Profile picker popover-inside-panel** | Replaces `ProfileQuickPopoverView` |
| **Composer** (mic disabled + pill input + send circle) | Replaces current input row in `ChatView` |
| **Always-visible footer pause** | New element below chat: status dot, model name, last check, pause/resume button |
| **DEBUG opener in topbar** | Adds button in new compact header → opens existing `DebugSheet` (no change to DebugSheet) |
| **Shortcut gating** (only when panel open) | Refactor shortcut listeners to gate on panel key state |
| Memory **per-entry lock toggle** in You tab | Verify model field; expose toggle |
| Voice input | Disabled placeholder mic button |

### Not in design / kept hidden
| What | Why keep |
|---|---|
| `PolicyRule` kinds `.discourage`, `.limit`, `.tonePreference` | Stay in storage; not exposed in v1 UI (algorithm still uses them via learned facts and policy memory). Could surface in a future advanced panel. |
| `ContextBar` collapsed/expanded UI | Folded into chat (context emerges through conversation per design); the manual goals/rules/memory editors move into Profiles + You tabs. |
| `RulesSheet`, `BrainView` | Replaced by Profiles tab (safelist/blocklist) + You tab (memory). Rename to `_Legacy`. |
| `StatsView` (debug telemetry) | Untouched; reachable via DebugSheet. |

### Mapping table for "rules" → new model
- `PolicyRule kind=.allow` (profileID-scoped) → exposed as `profile.safelist` in UI; underlying storage unchanged.
- `PolicyRule kind=.disallow` (profileID-scoped) → **plus** a new explicit `profile.blocklist: [String]`. Decision point below.
- `PolicyRule kind=.discourage / .limit / .tonePreference` → no UI; algorithm continues to consume.

**Decision (recommended):** add `blocklist: [String]` directly on `FocusProfile` for clean storage and a simple JSON shape that matches the design exactly. The algorithm gets a tiny adapter that, at evaluation time, treats blocklist entries as `.disallow`-equivalent matches, so `LLMMonitorAlgorithm` and `BrainService` need only one helper change. The alternative (storing blocklist entries as `.disallow` rules) would avoid the adapter but muddies the model. The user explicitly said "don't reinvent the wheel"; a clean field is the smaller change here.

---

## Phasing

Each phase is independently shippable and leaves the app working. Old views are renamed `_Legacy.swift` so they remain in-tree but unused.

### Phase 1 — Skin renderer foundation
**New files**
- `AC/UI/Skins/ACSkin.swift` — enum `pixel / bubble / liquid` (line, mono come later).
- `AC/UI/Skins/ACCatExpression.swift` — `neutral / happy / sleep / alert / drift / celebrate / concern`.
- `AC/UI/Skins/CatRendererPixel.swift` — wraps existing `PixelCatGrid` lookups in a Canvas closure.
- `AC/UI/Skins/CatRendererBubble.swift` — sticker style, soft fills, cheek blush, drop shadow.
- `AC/UI/Skins/CatRendererLiquid.swift` — radial-gradient glass blob with specular highlight.
- `AC/UI/Skins/CatView.swift` — picks the renderer for `(character, skin, expression, size)`; caches `CGImage` keyed by combo.

**Modify**
- `AC/Models/ACModels.swift` — add `ACSkin` enum + a `selectedSkin` `@AppStorage` accessor; add `CompanionMood ⇄ ACCatExpression` mapping.
- `AC/UI/CompanionView.swift` — replace inline pixel rendering with `CatView`.

**Defer / keep**
- `PixelCatView.swift`, `PixelCatGrid.swift` stay (the new Pixel renderer reuses the grid).

### Phase 2 — Profile model extension + blocklist
**Modify**
- `AC/Models/ACModels.swift` — extend `FocusProfile` with `emoji: String`, `color: String` (hex), `description: String`, `blocklist: [String]`, `defaultDurationMin: Int`. Decode missing fields with defaults so existing JSON still loads.
- `AC/Services/StorageService.swift` — verify migration on load (no-op if defaults handle it).
- Seed: writing / deep coding / social mgmt / admin / design + everyday. Everyday has `isDefault = true`, no safelist or blocklist, no timer.
- Profile cap: enforce 7 (currently 8) by adjusting the eviction rule.
- `AC/Core/LLMMonitorAlgorithm.swift` and/or `AC/Core/BrainService.swift` — small helper: treat `blocklist` matches as a `.disallow` signal in the decision pipeline.

### Phase 3 — New main panel shell
**New files** (under `AC/UI/v2/` to make the seam obvious)
- `ChatPanelView.swift` — composes the new layout.
- `ProfileBarView.swift` — active state (color tint + emoji + name + remaining + start time + `+15m` + `end`); empty state ("no focus active · pick a focus →"). Countdown ring deferred.
- `ProfilePickerView.swift` — popover-inside-panel: profile list (everyday first) + duration chips + "start {name} →".
- `CompactHeaderView.swift` — mini cat avatar + character name + status dot + status text + gear + close + `#if DEBUG` hammer button → opens existing `DebugSheet`.
- `StatStripView.swift` — three columns; bind to `MonitoringStatsSnapshot`.
- `ChatScrollView.swift` — day separators + cat/user bubbles + win/nudge/context cards.
- `ComposerView.swift` — disabled mic + pill text input + accent send circle.
- `PanelFooterView.swift` — status dot + model name + last-check ago + pause/resume.

**Rename → `_Legacy.swift`**
- `ChatPopoverView.swift`, `ProfileControlBar.swift`, `ProfileQuickPopoverView.swift`, `ContextBar.swift`.
- Keep the legacy types under their renamed names so they compile but are no longer routed.

**Modify**
- `AC/Services/AppController.swift` — switch the popover host to `ChatPanelView`.
- `AC/UI/WindowCoordinator.swift` — point the panel at the new view.

### Phase 4 — New SettingsView (6 tabs)
**New files** (`AC/UI/v2/Settings/`)
- `SettingsView.swift` — tab host (look / profiles / ai / nudges / persona / you).
- `LookTab.swift` — skin grid (3 cards in v1) + expression preview chips (7) + accent override pill.
- `ProfilesTab.swift` — chip row of profiles (everyday first, locked) + editor (name, emoji, color, description, safelist rows, blocklist chips, default duration).
- `AITab.swift` — mode pills (Managed disabled, Local, OpenRouter), intensity slider mapped to `MonitoringCadenceMode`, tier radios mapped to existing model identifiers, OpenRouter key field, today's spend, ⓘ vision explainer.
- `NudgesTab.swift` — toggles (escalation overlay, auto-quiet on calls), sound toggles (chime, celebration), read-only shortcuts list.
- `PersonaTab.swift` — three character cards with blurbs + "look is in the look tab" note.
- `YouTab.swift` — name, learned facts (per-entry lock toggle + delete), version, privacy / export / reset / quit.

**Rename → `_Legacy.swift`**
- `SettingsSheet.swift`, `RulesSheet.swift`, `BrainView.swift`.

**Modify**
- `AC/Services/MemoryConsolidationService.swift` — verify locked entries are skipped during consolidation; if `isLocked` doesn't exist on `MemoryEntry`, add it and gate consolidation.

### Phase 5 — Nudge + overlay refresh
- Refresh [NudgeView.swift](AC/UI/NudgeView.swift) to 240pt tooltip with 2pt accent top border, mini cat avatar (using new `CatView`), persona name, message, two buttons. Auto-dismiss 12s (already exists?). If divergence is large, save legacy as `NudgeView_Legacy.swift` and write `NudgeTooltipView.swift`.
- Refresh [OverlayView.swift](AC/UI/OverlayView.swift) to visual-novel layout: large cat portrait left, vibrancy dialog right, 4 selectable reason chips, free-text input, "snooze 5 min" / "got it — back to work", quiet ×.

### Phase 6 — Companion widget polish
- Update [CompanionView.swift](AC/UI/CompanionView.swift) to render via `CatView` (selected skin + character + mood-mapped expression).
- Tint glow by active profile color.
- Profile timer ring **deferred** per user.

### Phase 7 — Wire-up + behavior
- **DEBUG opener**: in `CompactHeaderView`, `#if DEBUG` button → present existing `DebugSheet`. No DebugSheet changes.
- **Shortcut gating**: refactor `Cmd+K` / `Cmd+,` / Esc listeners (declared in `ACDesignSystem.swift`) to fire only when the panel is key/visible.
- **Stats binding**: `StatStripView` reads `MonitoringStatsSnapshot`. Compute "% of day" as `focusedSeconds / 86400 * 100`. Milestone glow triggers when `streakDays % 7 == 0` or `streakDays == 12`.
- **Voice input**: mic button visible but disabled, with tooltip "voice input — coming soon".
- **Profile cap**: enforce 7.

---

## Critical files to read before/during implementation

Models / data
- [AC/Models/ACModels.swift](AC/Models/ACModels.swift) — `FocusProfile`, `ACCharacter`, `CompanionMood`, `MemoryEntry`, `ACState`.
- [AC/Models/PolicyMemoryModels.swift](AC/Models/PolicyMemoryModels.swift) — `PolicyRule` (allow/disallow/etc.), `profileID` scoping.
- `AC/Models/MonitoringModels.swift` — `MonitoringCadenceMode`, `MonitoringInferenceBackend`, `MonitoringConfiguration`.

Services
- [AC/Services/AppController.swift](AC/Services/AppController.swift) — popover host + state.
- `AC/Services/PolicyMemoryService.swift` — safelist / rules CRUD.
- `AC/Services/MemoryConsolidationService.swift` — needs lock awareness.
- `AC/Services/StorageService.swift` — JSON persistence + migration.
- `AC/Services/CompanionChatService.swift` — chat flow for win/nudge/context cards.

UI (current — to map)
- [AC/UI/ChatPopoverView.swift](AC/UI/ChatPopoverView.swift) — shortcut handling, onboarding routing.
- [AC/UI/CompanionView.swift](AC/UI/CompanionView.swift) — animations + cat rendering points.
- [AC/UI/ACDesignSystem.swift](AC/UI/ACDesignSystem.swift) — extend tokens (panel radius 18, bubble 13, accent flow).
- [AC/UI/SettingsSheet.swift](AC/UI/SettingsSheet.swift) — section structure to migrate.
- [AC/UI/ContextBar.swift](AC/UI/ContextBar.swift) — what moves where (memory → You, rules → Profiles).

Reference (read-only)
- [design_handoff_AC/README.md](design_handoff_AC/README.md) — spec.
- `design_handoff_AC/reference/panel.jsx`, `settings.jsx`, `profiles.jsx`, `skins.jsx`, `cats.jsx` — exact layouts and tokens.

Untouched
- [AC/UI/DebugSheet.swift](AC/UI/DebugSheet.swift) — read only to understand presentation; no edits.
- [AC/UI/StatsView.swift](AC/UI/StatsView.swift) — debug telemetry stays.

---

## Verification

Per phase
1. **Skins**: DEBUG-only `SkinPreviewGrid` showing 3 skins × 3 characters × 7 expressions renders cleanly.
2. **Profile model**: existing on-disk profiles load with new fields default-filled; seed profiles appear on fresh install.
3. **Panel shell**: Cmd+K opens new panel; profile bar shows correct active/empty state; chat scrolls; legacy panel no longer routed.
4. **Settings**: all 6 tabs render; can edit safelist + blocklist on a profile; switching skin updates the cat live; AI tab pills/slider/radios bind to existing config.
5. **Nudge / overlay**: trigger a drift → see new nudge tooltip; ignore for 3 min → see new overlay; appeal flow round-trips.
6. **Widget**: floating cat uses selected skin + reflects mood; bob + glow tint visible.
7. **DEBUG opener**: `#if DEBUG` only — opens DebugSheet unchanged.
8. **Shortcuts**: Cmd+K only fires when panel is open / key.
9. **Memory lock**: locking an entry survives a manual "clean up" trigger; deleting works.

End-to-end smoke
- Run a fresh install, complete onboarding.
- Pick the writing profile (60m), open a non-safelist app, observe nudge → overlay → appeal → resume.
- Switch character, switch skin to Liquid, edit the design profile (add safelist + blocklist entries), restart, verify persistence.
- Toggle Local ↔ OpenRouter mode, verify backend swap.
- Confirm legacy `_Legacy` files compile but are unreferenced (`grep` for callers).

---

## Confirmed decisions

1. **Blocklist storage** → new `blocklist: [String]` field directly on `FocusProfile`. The algorithm gets a small adapter that treats blocklist matches as `.disallow` signals; existing `PolicyRule` storage remains for `.discourage / .limit / .tonePreference`.
2. **New view layout** → all new files under `AC/UI/v2/` (and `AC/UI/v2/Settings/`, `AC/UI/Skins/`). Old views renamed in place to `*_Legacy.swift`.
3. **Profile color** → fixed 7-color palette matching the design tokens (everyday + writing + deep coding + social mgmt + admin + design + 1 spare). Stored as the token name on the profile, resolved to hex at render time.
4. **Memory `isLocked`** → first task in Phase 4: read `MemoryEntry` definition. If `isLocked` is absent, add it, gate `MemoryConsolidationService` on it, and expose the lock toggle in the You tab.

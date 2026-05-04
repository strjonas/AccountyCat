# Handoff: AccountyCat v1 — macOS app

## Overview

AccountyCat (AC) is a macOS **focus companion**. A persistent floating cat watches your screen via periodic screenshots + on-device AI, helps you stay in the focus profile you've started, and intervenes when you drift — first with a chat message, then a nudge tooltip, then (only if ignored) a full-screen visual-novel overlay.

The cat has a **character** (Mochi/Nova/Sage — voice/personality) and a **skin** (Pixel/Line/Liquid/Bubble/Mono — visual style). These are decoupled; the user mixes any character × skin. The app's primary concept is **focus profiles**: structured modes ("write for 1h", "deep coding") each with their own safelist. When no profile is active, AC runs in passive "everyday" mode.

Open `reference/AccountyCat.html` in a browser to see all states. Use the **Tweaks** panel (toolbar, bottom-right) to switch scenarios, persona, skin, and surfaces.

## About the Design Files

Files in `reference/` are **design references in HTML/JSX** — not production code. Your task is to **recreate them as a native SwiftUI + AppKit macOS app** (macOS 14+). Use SwiftUI materials, system fonts, and HIG conventions.

## Fidelity

**High-fidelity** visuals (exact tokens below), **interaction-fidelity** for all flows.

---

## Architecture

### Surfaces

| Surface | macOS impl | Notes |
|---|---|---|
| **Cat widget** | `NSPanel` `.statusBar` level, `canBecomeKey = false` | Always on top, never steals focus, draggable. Shows profile ring when active. |
| **Main panel** | Sibling `NSPanel`, anchored above widget | `.popover` material, 400pt wide, max 640pt tall |
| **Profile picker** | Popover within main panel | Not a separate window |
| **Nudge tooltip** | Small `NSPanel` above widget | Auto-dismiss 12s |
| **Overlay** | Fullscreen `NSWindow` `.modalPanel` | Has quiet dismiss ×, never traps user |
| **Menu bar** | `MenuBarExtra` | Shows profile chip + countdown when active |

### Data

- **SwiftData** (or Core Data): `Profile`, `SafelistEntry`, `DailyStats`, `ChatMessage`, `LearnedFact`
- **Keychain**: OpenRouter API key
- **UserDefaults**: character, skin, active profile session, nudge/sound prefs, AI mode/tier

### Models

```swift
struct Profile: Identifiable, Codable {
    let id: UUID
    var name: String              // "writing", "deep coding"
    var emoji: String
    var color: Color              // stored as hex
    var description: String       // free text — sent to VLM as context
    var safelist: [SafelistEntry]
    var blocklist: [String]
    var defaultDurationMin: Int
    var isDefault: Bool           // "everyday" mode — never deleted
}

struct SafelistEntry: Identifiable, Codable {
    let id: UUID
    var kind: SafelistKind        // .app or .site
    var value: String
    var note: String
    var limit: TimeInterval?
}

enum SafelistKind: String, Codable { case app, site }

struct ActiveSession {            // ephemeral, saved to UserDefaults for crash recovery
    let profileId: UUID
    let startedAt: Date
    var durationMin: Int
    var endedAt: Date?
}

enum Character: String, Codable { case mochi, nova, sage }
enum Skin: String, Codable { case pixel, line, liquid, bubble, mono }
enum AiMode: String, Codable { case local, openrouter }
enum AiTier: String, Codable { case economy, balanced, smartest }

struct LearnedFact: Identifiable {
    let id: UUID
    var text: String
    var locked: Bool              // survives cleanup consolidation
}
```

### Vision pipeline

1. Periodic `CGWindowListCreateImage` capture — interval driven by **intensity** setting (calm ≈ 90s, balanced ≈ 45s, sharp ≈ 20s).
2. Pass to local VLM (MLX-Swift or llama.cpp bindings) **or** OpenRouter (tier decides model).
3. Output: `{ activeApp, activeURL?, onSafelist: Bool, distractionScore: 0–1 }`.
4. Drift: N consecutive frames `onSafelist == false` → nudge.
5. Escalation: nudge ignored ~3 min → overlay.

---

## Screens

### 1. Cat Widget (`reference/widget.jsx`)

80×80pt `NSPanel`, default bottom-right (36pt margins).

- **Cat sprite** — rendered per `Skin` × `Character` × expression. Build as `Canvas` view. 7 expressions: `neutral / happy / sleep / alert / drift / celebrate / concern`.
- **Bob animation** — translateY 0→−3pt, 3.2s ease-in-out loop. Stop when `sleep` or `paused`.
- **Glow** — radial gradient below, tinted by active profile color.
- **Profile timer ring** — SVG circle r=36, 2pt stroke, draining clockwise as time elapses. Glowing drop-shadow in profile color. Grays out when paused.
- **Badge dot** — 9pt, top-right, 1.6s pulse. For: drift, celebrate, unread.
- **Hover hint** — dark chip above: profile+time if active, "⏸ paused" if paused, else persona hint.
- **Pause state** — opacity 0.75, sleep expression, ⏸ badge top-right.
- **Right-click menu** — "Pause / Resume", "Start focus →", "Open panel", "Quit".

### 2. Menu Bar (`reference/desktop.jsx → MenuBar`)

`MenuBarExtra` with inline view:
- When profile active: `{emoji} {name} {remaining}m` chip (rounded, semi-transparent white bg). Click → toggle main panel.
- Cat icon (persona-tinted "ぅ" glyph). Always visible.

### 3. Main Panel (`reference/panel.jsx`)

400pt × max 640pt. `.popover` material, 18pt radius.

**Layout top→bottom:**

#### a. Profile Bar
Most important. Tinted bg/border by active profile color (8%/20%).

Active: countdown ring (28pt) + `focus: {name} ▾` + remaining time + started-at. Buttons: `+15m` and `end` (red-tint). Click left side → opens picker.

No profile: "no focus active · open mode" italic + "pick a focus →" black CTA.

#### b. Compact header
Mini cat avatar (24pt, expression from scenario) + character name + status dot + pulsing label. Right: gear icon (→ settings) + × close.

Settings view: gear highlights in accent. Replaced by "← back" text button when in settings.

#### c. Stat strip (3 columns)
- **focused today** — `2h 04m` (JetBrains Mono 19pt semibold)
- **% of day** — `68%` (replaces "longest block")
- **streak** — `𖤍 11 days` in accent color. Flame animates (scale 1↔1.08, 1.6s). On milestone (every 7 days / 12): ✦ sparkle top-right + radial glow behind. Trend line below: `+2 vs last wk`.

#### d. Chat scroll
Day separators (uppercase 10.5pt). Cat bubbles left (with mini avatar), user bubbles right (accent-tinted). Inline cards: win-card, nudge-card, context-card (see reference). Auto-scroll to bottom on new message.

#### e. Composer
Row: mic button (circle, secondary) + pill input + send button (circle, accent, ↑).

#### f. Footer
`● {watching|paused} · gemma 4b · 38s ago` (mono 9.5pt) + `⏸ pause` / `▶ resume` right-aligned tiny button. This is an always-visible quick pause.

### 4. Profile Picker Popover (`reference/profiles.jsx → ProfilePicker`)

Inside the main panel (not a system popover). 5 profiles listed + "+ custom…" duration chips + "start {name} →" CTA.

The **everyday** profile is always listed first. It has no duration, no safelist — AC watches passively.

### 5. Nudge Tooltip (`reference/interventions.jsx → Nudge`)

240pt wide, above widget. 2pt accent top border. Mini cat avatar + persona name + message text (persona-specific copy). Two buttons: "back to work" (filled) / "it's research" (ghost). Animates in 0.3s. Auto-dismiss 12s.

### 6. Overlay / Visual Novel (`reference/interventions.jsx → Overlay`)

Borderless fullscreen window. Left: large cat portrait (concern, floating). Right: vibrancy dialog — accusation referencing active profile + behavior + duration. 4 reason chips (selectable). Free-text input. "snooze 5 min" / "got it — back to work". Quiet × in window corner.

### 7. Settings (`reference/settings.jsx`)

Inside main panel, replaces chat. Gear icon → settings, "← back" → chat. **Six tabs:**

#### look
- 5-card skin grid (Pixel / Line / Liquid / Bubble / Mono). Each shows a live cat preview.
- Expression preview chips to try all expressions per skin.
- Accent: follows character (default), or override.

#### profiles
- Horizontal chip row of profiles. "everyday" always first (no delete, no safelist).
- Selected profile editor: name (editable), description (textarea), safelist rows (kind + value + note + time-limit + × delete), blocklist chips, + add buttons.

#### ai
- **Mode toggle** (3 pills): `Managed` (coming soon, disabled), `Local`, `OpenRouter`.
- **Intensity slider**: calm → sharp. Label explains cost/compute tradeoff. No "frame interval" knob.
- **Intelligence tier** (3 radio rows): Economy / Balanced / Smartest. Explainer sub-text. No model-picker in normal mode.
- Advanced mode toggle → reveals raw model selection (future).
- Local: shows installed models with size + last-used + delete button. "Browse library →" link.
- OpenRouter: single key field (masked). Today's spend.
- ⓘ info button on "vision" label → short explanation of what screenshots are used for.

#### nudges
- Toggles: escalation overlay, auto-quiet on calls.
- Sound: nudge chime, celebration sound.
- Shortcuts list (read-only): ⌘⌥C open panel, ⌘⌥V toggle vision, ⌘⌥F start focus, ⌘⌥↑ extend +15m, ⌘⌥P pause. "Customize in shortcuts.app →" link.

#### persona
- 3 character cards (Mochi/Nova/Sage). Each shows cat in "bubble" skin (most expressive). Name + blurb.
- Note: "character is separate from style — change look in the 'look' tab."

#### you
- Your name (editable).
- Learned facts: each item has × delete, 🔒 lock toggle (locked = survives cleanup). `+ add` and `clean up` buttons in section header.
- Version, Privacy, Export, Reset all data, **Quit AccountyCat** (last item, muted).

---

## States & Scenarios (Tweaks panel mirrors these)

| Scenario | Cat expression | Profile bar | Badge | Nudge | Overlay |
|---|---|---|---|---|---|
| monitoring | neutral | active, timing | — | — | — |
| drift | drift | active | dot | tooltip | — |
| explaining | happy | active | — | — | — |
| celebrating | celebrate | active | dot | — | — |
| escalation | concern | active | dot | — | fullscreen |
| sleeping | sleep | — | — | — | — |
| noProfile | neutral | empty, CTA | — | — | — |
| paused | sleep | dims | — | — | — |

### Profile lifecycle
1. Start profile + duration → session begins, ring drains, menu bar chip appears.
2. Vision compares frames to safelist → monitoring / drift states.
3. `+15m` → extends session. `end` → flush stats, return to noProfile.
4. Timer expires → "done. {duration}. good block." win-card. Return to noProfile.

### Everyday mode
No safelist, no timer. AC watches and learns; only intervenes if explicitly asked in chat. The default — user never has to "pick a mode".

---

## Animations

| Element | Duration | Easing | Behavior |
|---|---|---|---|
| Cat bob | 3.2s | ease-in-out infinite | translateY 0 → −3pt |
| Cat alarmed | 0.7s | ease-in-out infinite | translateX ±1.5pt |
| Sleep z float | 3.0s | ease-out infinite | y −22pt, opacity 0→1→0 |
| Sparkle | 1.6s | ease-in-out infinite | scale 0.6→1, opacity 0→1 |
| Flame | 1.6s | ease-in-out infinite | scale 1→1.08, rotate −1°→2° |
| Streak glow | 2.4s | ease-in-out infinite | scale 1→1.05, opacity 0.6→1 |
| Pulse dot | 2.2s | ease-in-out infinite | opacity 0.5→1 |
| Nudge enter | 0.3s | spring (0.2,0.8,0.3,1.2) | scale 0.95→1 + fade |
| Panel open | 0.22s | spring | scale 0.97→1 + fade |
| Overlay | 0.5s | ease | fade |
| Cat float (overlay) | 4.0s | ease-in-out infinite | translateY 0→−6pt |

---

## Design Tokens

### Character palettes

| | mochi | nova | sage |
|---|---|---|---|
| body | `#F4D9B8` | `#7A6FA0` | `#A8B58E` |
| inner | `#FCEDD8` | `#A99CD0` | `#CFD8B6` |
| shadow | `#D9B188` | `#574E78` | `#7E8C68` |
| accent | `#E89B7A` | `#C7B6FF` | `#D9C48E` |
| nose | `#C77A5A` | `#3A3252` | `#5A5238` |
| eye | `#2A1B12` | `#F4FF8B` | `#2A2418` |

Character accent = the app's primary interactive color for that character.

### Profile colors

| Profile | hex |
|---|---|
| everyday | `#9aa1a8` |
| writing | `#7BA3D9` |
| deep coding | `#A88BFF` |
| social mgmt | `#E89B7A` |
| admin | `#A8B58E` |
| design | `#D9A8C7` |

### System colors

| | hex |
|---|---|
| ink-1 | `#1d1b16` |
| ink-2 | `rgba(29,27,22,0.55)` |
| ink-3 | `rgba(29,27,22,0.4)` |
| ok-green | `#34c759` |
| amber | `#FFB347` |
| red-end | `#c44d3a` |

### Materials

| Surface | SwiftUI |
|---|---|
| Main panel | `.background(.ultraThinMaterial)` + custom radius |
| Nudge | `.regularMaterial` |
| Overlay backdrop | `.thickMaterial` |
| Profile bar bg | profile color × 0.08 opacity |

### Type

- Body: SF Pro 13pt / 1.4 line-height
- Mono numbers: SF Mono (JetBrains Mono fallback) — used for stats, counters, model sizes, keys
- Serif: SF Serif — overlay persona name (18pt semibold), portrait label (14pt)
- Captions: 10.5pt semibold uppercase, letter-spacing 0.06em

### Spacing + radius

| Token | value |
|---|---|
| Panel radius | 18pt |
| Dialog radius | 20pt |
| Bubble radius | 13pt (4pt tail corner) |
| Button radius | 7–9pt |
| Pill radius | 999pt |
| Hairline | 0.5pt |
| Panel shadow | `0 24pt 70pt black × 0.32` |

---

## Cat Skin Reference (`reference/skins.jsx`)

Five skins, each a separate `Canvas` draw function:

| Skin | Description | Key visual |
|---|---|---|
| **pixel** | Chunky retro grid, crispEdges | 16-unit grid scaled up |
| **line** | Single-stroke vector | All shapes outlines-only, no fill on body |
| **liquid** | Glass blob | Radial gradient fill, specular highlights, softened |
| **bubble** | Solid sticker, rounded | Bold fills, drop shadow, pronounced cheeks |
| **mono** | Flat silhouette | Single accent-color fill, white cut-out features |

Recommend: render each as a SwiftUI `Canvas` closure keyed on `(character, skin, expression)` → cache as `CGImage` for widget performance.

---

## Copy / Tone

All lowercase. Never preachy.

**Mochi** — warm, rooting for you. Uses 🥺 occasionally:
> "hey — r/programming for 11 min. that's not on writing's safelist 🥺"

**Nova** — concise, no hand-holding:
> "you said writing focus. r/programming for 11 min — outside safelist. course-correct?"

**Sage** — reflective, mirrors back:
> "writing focus is on — r/programming isn't on the safelist. notice it. choose."

Full copy in `reference/boot.jsx` (nudge text per character) and `reference/panel.jsx` (SAMPLE_CHAT per scenario).

---

## Privacy + Security

- Default: **all vision is local** — screenshots never leave device. State this loudly in onboarding.
- OpenRouter key: Keychain, user's account, never sent anywhere except openrouter.ai.
- Frames: never stored. Only the structured VLM output is kept (purgeable via Settings → you → reset).
- Daily spend cap (default $0.10) — enforced client-side.

---

## Build Order (suggested)

1. **Shell** — menu bar item, floating NSPanel with bobbing cat. Get all 5 skins × 3 characters × 7 expressions rendering correctly. This is the core visual identity.
2. **Profile model + SwiftData** — seed 5 profiles + everyday. Picker popover. Active session ring.
3. **Main panel** — profile bar, stat strip, chat (mock data), settings navigation.
4. **Vision (local)** — MLX-Swift integration, one model, drift detection.
5. **Nudge → escalation** — timing, sounds, dismiss logic.
6. **Settings full** — profiles tab (safelist editor), AI tab (intensity slider, tiers, OpenRouter key), nudges tab, persona tab, about tab (learned facts with lock).
7. **Polish** — animations, milestone celebration, onboarding, permission screens.

---

## File Reference

```
reference/
  AccountyCat.html     entry point — open in browser, use Tweaks toolbar
  styles.css           full CSS spec (sizes, radii, colors, animations)
  boot.jsx             top-level app + scenario state + all copy
  cats.jsx             cat palettes + face/expression drawing (SVG)
  skins.jsx            5 skin renderers (Pixel/Line/Liquid/Bubble/Mono)
  desktop.jsx          faux macOS chrome (menu bar, dock, fake windows)
  widget.jsx           floating cat widget + profile ring + pause state
  panel.jsx            main panel: profile bar, stats, chat, composer
  profiles.jsx         Profile model + ProfileBar + ProfilePicker
  settings.jsx         all settings tabs (look/profiles/ai/nudges/persona/you)
  interventions.jsx    nudge tooltip + escalation overlay
  tweaks-panel.jsx     prototype-only Tweaks panel — DO NOT port
```

# AccountyCat Website Agent Handoff

## Goal

Build the first public website for AccountyCat (AC), a native macOS focus companion. The site should explain what AC does, earn trust around privacy-sensitive permissions, collect demand for Managed mode, and give users a clear path to download or follow the project.

This brief is for a website-building agent. Treat it as the product source of truth for the website, but keep the sections marked `TODO owner` editable because model names, pricing, RAM, and download details are not fully final.

## Required Routes

### `/`

Main landing page.

Primary goals:

- Explain AC in one screen: a context-aware focus companion for macOS that nudges instead of blocks.
- Show the actual product UI early, not an abstract mascot-only hero.
- Drive to download/source when available.
- Drive to `/managed-waitlist` for the hosted "no API key, no local model setup" option.
- Build trust around permissions and privacy before asking users to install.

### `/privacy`

Privacy and data page. This route is already linked from the app in `AC/UI/v2/Settings/YouTab.swift`.

This page must be readable by normal users, not only lawyers. It should explain:

- Why AC asks for Screen Recording.
- Why AC asks for Accessibility.
- What is stored locally.
- What is discarded.
- What changes between Local mode and OpenRouter BYOK mode.
- What Managed mode will imply when it launches.
- How to export or reset data.

### `/managed-waitlist`

Waitlist page for Managed mode.

Managed mode is "coming soon" in the app UI and is linked from `AC/UI/v2/Settings/AITab.swift` as `https://accountycat.com/managed-waitlist`.

Important: `AC/UI/OnboardingWizardView.swift` currently links Managed waitlist to `https://accountycat.com/waitlist`. Either add a redirect from `/waitlist` to `/managed-waitlist`, or update the app link later. The website should support both paths until the app is corrected.

### Optional Routes

- `/download`: Useful once notarized builds exist. If not ready, keep download CTAs pointing to GitHub Releases or "coming soon".
- `/github`: Optional redirect to the repository.
- `/openrouter-setup`: Optional support page if BYOK setup creates too much copy pressure on the homepage.

## Product Summary

AccountyCat is a native macOS menu bar focus companion. It periodically checks the active app, window title, and sometimes a screenshot. It uses an LLM, either local or via OpenRouter, to decide whether the user is still on task. Most checks do nothing. If the user drifts, AC sends a short nudge from a cat companion. If nudges are ignored repeatedly, it can escalate to a larger overlay.

AC is intentionally not a hard blocker. The product promise is judgment, context, and accountability, not lockdown.

Good one-line descriptions:

- "A focus companion for macOS that understands context."
- "A tiny cat in your menu bar that notices when you drift."
- "Context-aware focus help without blunt website blocking."

Avoid:

- "AI productivity coach" as the only framing. It sounds generic.
- "Screen monitoring" without immediately explaining privacy and user control.
- "Blocks distractions" unless qualified. AC nudges; it does not primarily block.

## Core Product Truths

- AC is a native macOS app, currently Apple Silicon oriented.
- It lives in the menu bar and can show a floating companion panel.
- It asks for Screen Recording so it can analyze screenshots for context.
- It asks for Accessibility to read the active app and window context. It does not need this for keystroke logging.
- Screenshots are analyzed and discarded. They are not permanently stored as user data.
- Local mode runs on-device through `llama.cpp`.
- BYOK mode uses the user's OpenRouter API key, stored in macOS Keychain.
- BYOK requests go directly from the user's Mac to OpenRouter, not through an AccountyCat server.
- OpenRouter requests set provider ZDR enforcement in code via `"provider": { "zdr": true }`. The website can say AC enforces OpenRouter's Zero Data Retention routing, but link to current OpenRouter docs and avoid overpromising beyond that.
- Managed mode is planned, not available yet. It should be presented as a waitlist, not as a launch-ready plan.
- Focus profiles are a key V1 feature: users can start named focus sessions like Coding or Presentation prep. Each profile can have scoped safelists and blocklists.
- The default mode is open/passive/general. Users do not have to pick a focus profile to use the app.
- The companion can have different characters/personas: Mochi, Nova, Sage.
- The cat visual style is customizable separately from persona: Bubble, Pixel, Liquid.

## Differentiation

Most focus tools use static blocklists. AC's pitch is that real work is contextual:

- YouTube can be a distraction or a tutorial.
- Slack can be procrastination or a necessary answer.
- Reddit can be avoidance or a developer lookup.
- A browser tab can be on-task in one profile and off-task in another.

AC evaluates the activity against goals, current profile, recent chat, and rules. It nudges only when context suggests the user has drifted.

Key phrase: "Getting interrupted during legitimate work is treated as a bug."

## Target Users

Primary:

- Indie developers, students, researchers, writers, and knowledge workers who work on a Mac.
- People who dislike hard blockers because their work uses distracting-looking sites.
- Privacy-conscious users who want local-first or BYOK control.

Secondary:

- ADHD-adjacent users who want a gentle external accountability cue.
- People who already use LLM tools and are comfortable with local models or OpenRouter.

Tone:

- Honest, technically literate, calm.
- Warm enough to fit the cat companion, but not childish.
- Avoid fake enterprise polish. AC should feel like a serious native Mac tool with a small personality.

## Homepage Structure

### 1. Hero

First viewport should include:

- Product name: `AccountyCat`.
- Literal category: `Context-aware focus companion for macOS`.
- One sharp value prop: AC nudges when you drift, without blunt blocking.
- Real or realistic product visual: menu bar + panel + cat + nudge or profile bar.
- Primary CTA: Download / Get AccountyCat / View releases, depending on release state.
- Secondary CTA: Join Managed waitlist.
- Small privacy trust line: Local mode available; screenshots are analyzed and discarded.

Do not make the hero only a mascot illustration. The first viewport needs to reveal that this is a macOS utility.

Example hero copy:

> AccountyCat is a tiny macOS companion that notices when your work stops looking like your work. It checks context, stays quiet when you are on track, and nudges gently when you drift.

CTA labels:

- `Download for macOS`
- `Join Managed waitlist`
- `View on GitHub`

### 2. Problem

Explain why static blockers fail:

- Work often happens inside "distracting" tools.
- The same app can be productive or distracting depending on intent.
- Hard blocks create friction when the user has a legitimate reason.

Use concrete examples: YouTube tutorials, Slack, Reddit, browser research.

### 3. How It Works

Use a 3-step section:

1. `Set your context`
   Chat with AC or start a focus profile like Coding, Writing, or Presentation prep.

2. `AC watches quietly`
   It checks active app, title, idle state, and when useful, a screenshot.

3. `Nudges, not lockdown`
   If activity looks off-task, AC sends a short nudge. If you explain that it is legitimate, AC can let it go and learn.

Optional detail cards:

- Focus profiles
- Context-aware screenshots
- Gentle nudge
- Escalation overlay only after ignored nudges

### 4. Focus Profiles

Explain profiles as the key concept.

Good copy:

> Start "Coding" for an hour and AC judges your activity against coding. Switch to "Presentation prep" and the same browser tab might be treated differently.

Facts:

- Default/general mode exists for everyday passive use.
- Named profiles can have their own safelists and blocklists.
- Profiles have timers and can be extended or ended.
- AC can be controlled through chat or menu bar popover.

### 5. Privacy And AI Modes

This should be a strong homepage section, not buried.

Three mode cards:

#### Local

- Runs on the user's Mac.
- No account or API key.
- Local `llama.cpp` runtime.
- Best privacy posture.
- Requires one-time model download and enough RAM.

#### Bring Your Own Key

- Uses user's OpenRouter account.
- API key stored in macOS Keychain.
- Requests go from the user's Mac to OpenRouter.
- AC enforces OpenRouter ZDR routing with the `zdr` provider preference.
- User controls spend in OpenRouter.

#### Managed

- Coming soon.
- Flat monthly fee idea.
- No OpenRouter account or local model setup.
- Route CTA to `/managed-waitlist`.

TODO owner: final model names, prices, RAM, and managed price. Use placeholders or mark "subject to change" until confirmed.

### 6. Product Tour

Show a concise sequence of visuals:

- Menu bar chip with active focus profile and remaining time.
- Main panel with profile bar, stats, chat, composer.
- Settings -> AI with Local/OpenRouter/Managed.
- Settings -> Profiles with safelist/blocklist.
- Nudge tooltip.
- Escalation overlay.

Do not overload with every settings tab. The landing page should sell the workflow.

### 7. Trust

Short trust claims:

- Open source and auditable.
- Local-first option.
- Screenshots are analyzed and discarded.
- BYOK traffic does not pass through AccountyCat servers.
- Export and reset are available from Settings.

If using the OpenRouter ZDR claim, link to official docs: `https://openrouter.ai/docs/features/zdr`.

### 8. Managed Waitlist CTA

Repeat near the end:

> Want AC without local model setup or API keys? Join the Managed waitlist.

CTA: `Join Managed waitlist`

### 9. FAQ

Suggested questions:

- Does AC record my screen?
- Are screenshots stored?
- Does AC send data to the cloud?
- Can I run it fully offline?
- Why does it need Accessibility?
- Does it block apps?
- What is Managed mode?
- How much RAM does local mode need?
- How much does OpenRouter mode cost?
- Is it open source?

For RAM/pricing answers, keep the wording provisional.

## Privacy Page Content

The `/privacy` page should be direct and specific. It does not need to read like a dense legal policy at first, but legal review may be needed before launch.

Recommended sections:

### Short Version

- Local mode can run fully on-device.
- Screenshots are analyzed and discarded.
- AC stores settings, chat history, memory, profiles, rules, and telemetry locally under `~/Library/Application Support/AC`.
- OpenRouter BYOK mode sends prompts and screenshots directly from the user's Mac to OpenRouter.
- AC does not run its own cloud relay for BYOK.
- API keys are stored in macOS Keychain.

### Permissions

Screen Recording:

- Used for periodic screenshots so AC can understand context.
- Not a continuous video recording.
- Screenshots are temporary and discarded after analysis.
- In BYOK mode, screenshots may be sent to OpenRouter when vision is needed.

Accessibility:

- Used to read the active application/window context.
- Used for app/window awareness, not keylogging.
- The website should avoid saying "never reads anything" because it does read active app/window metadata.

Calendar:

- Calendar support appears in the app as optional intelligence.
- It is not required for core monitoring.
- If enabled, explain that calendar context can help suggest focus profiles. TODO owner: verify exact shipped behavior before publishing.

### What AC Stores Locally

Known local data:

- App settings.
- Profiles.
- Policy rules, safelists, blocklists.
- Learned memory entries.
- Chat history.
- Recent context and usage summaries.
- Debug/telemetry events when enabled or available.
- Downloaded local model files.

Storage location:

- `~/Library/Application Support/AC`

API keys:

- OpenRouter API key is stored in macOS Keychain.

### What AC Does Not Store Permanently

- Raw screenshots as normal user data.
- Continuous screen recordings.
- Keystrokes.

Be careful: debug telemetry can include references/artifacts depending on debug build settings. Phrase as "normal user data" and ask the app owner to verify release telemetry behavior before publishing.

### Local Mode

- Uses local models through `llama.cpp`.
- No AI requests leave the Mac.
- One-time model/runtime download required.
- RAM and disk usage depend on the selected tier.

### OpenRouter BYOK Mode

- User supplies their own OpenRouter API key.
- Requests go to OpenRouter's API endpoint.
- AC includes provider ZDR enforcement in the request.
- The website should link to OpenRouter's current ZDR docs and avoid making guarantees beyond OpenRouter's policy.

### Managed Mode

For now:

- Planned, not launched.
- Explain that managed mode will necessarily involve AccountyCat-operated infrastructure or billing.
- Do not make final privacy commitments until the managed architecture is known.

### Export And Reset

The app has user-facing actions for:

- `privacy & data`
- `export everything`
- `reset all data`
- `quit AccountyCat`

These appear in Settings -> You.

## Managed Waitlist Page

Purpose: validate demand for a hosted version where users do not need a local model download or OpenRouter key.

Headline options:

- `Managed AccountyCat`
- `AccountyCat without model setup`
- `Join the Managed mode waitlist`

Copy:

> Managed mode is for people who want AccountyCat to just work: no local model setup, no OpenRouter account, no model picking. Join the waitlist and help shape pricing, privacy, and launch priority.

Recommended form fields:

- Email, required.
- Name, optional.
- Mac type/RAM, optional. Useful because local model friction is a key reason for Managed.
- Current preferred mode: Local, OpenRouter, Managed, Not sure.
- Main reason for Managed: no API key, low RAM, simpler setup, predictable billing, privacy/compliance question, other.
- Optional notes.

After submit:

- Thank the user.
- Set expectation: "We'll email you when Managed mode is ready for early testers."
- No promise of launch date.

Data handling:

- Link to `/privacy`.
- Add a short form-specific note about using email only for AccountyCat Managed updates unless the owner wants a newsletter.

Implementation:

- Use a simple backend or waitlist service.
- Protect against spam.
- Store consent timestamp and source route.
- Add redirect `/waitlist` -> `/managed-waitlist`.

## Copy Bank

Use these as raw material, not necessarily final copy.

### Short Pitch

AccountyCat is a macOS focus companion that understands context. It watches what you are doing, compares it to what you meant to be doing, and nudges you when you drift.

### Problem Copy

Most focus apps treat apps and websites as either good or bad. Real work is messier. YouTube might be a tutorial. Slack might be an answer. Reddit might be procrastination or research. AC looks at context before interrupting.

### Privacy Copy

AC asks for serious permissions, so the privacy model needs to be explicit. In local mode, AI analysis runs on your Mac. In OpenRouter mode, requests go directly from your Mac to OpenRouter using your own key. Screenshots are analyzed and discarded.

### Nudge Copy

AC does not lock you out. It asks a small question at the moment you start drifting. If you are actually doing research, tell it. If you are not, take the nudge and return.

### Managed Copy

Managed mode is planned for users who want AC without local model downloads or OpenRouter setup. Join the waitlist if you want a flat, hosted option.

## Pricing, Models, RAM: Use As Draft Only

The app currently contains these user-facing tiers, but the owner said they may not be final. Do not design the page so these numbers are hard to change.

### Current Local Draft

| Tier | Model | RAM draft |
| --- | --- | --- |
| Economy | Qwen 3.5 4B | ~2-3 GB RAM |
| Default | Qwen 3.5 9B | ~5-7 GB RAM |
| Smartest | Qwen 3.6 27B | ~15-18 GB RAM |

### Current OpenRouter Draft

| Tier | Text model | Vision model | Monthly cost draft |
| --- | --- | --- | --- |
| Economy | Nemotron-3 Super 120B | Qwen 3.5 9B | TODO owner |
| Default | DeepSeek V4 Flash | Gemma 4 31B | TODO owner |
| Smartest | DeepSeek V4 Flash | Gemini 3 Flash | TODO owner |

Current code has cost estimates in `ACShared/AITier.swift`, but README has slightly different ranges. Treat all pricing as provisional until the owner gives final numbers.

Recommended presentation:

- On homepage: use qualitative labels and "from" copy, or avoid exact numbers.
- In FAQ: say "Exact model tiers and usage estimates are still being tuned."
- Do not make Managed price promises yet.

## Visual Direction

The website should feel like:

- Native Mac utility.
- Calm, focused, precise.
- Slightly warm because of the cat companion.
- Product-led, not mascot-led.

Use actual UI screenshots or faithful UI mockups. Avoid abstract AI gradients and generic productivity stock images.

Homepage first viewport should include the product interface. A generated cat illustration can support the brand, but should not replace product UI.

Color/style cues from app:

- Soft macOS materials.
- Small rounded panels.
- Accent colors can follow characters.
- Characters: Mochi, Nova, Sage.
- Skins: Bubble, Pixel, Liquid.

Avoid making the whole website one pastel/purple gradient theme. AC is a tool first.

## Assets Needed

### Essential Screenshots

Ask the app owner for real screenshots when possible:

1. Menu bar chip with active focus profile.
2. Main chat panel with profile bar, stats strip, and chat.
3. Onboarding mode selection showing Local, BYOK, Managed coming soon.
4. Settings -> AI showing Managed, Local, OpenRouter.
5. Settings -> Profiles showing profile editor, safelist, blocklist.
6. Nudge tooltip near the cat.
7. Escalation overlay.
8. Settings -> You showing privacy/export/reset if used on privacy page.

### Good-To-Have Screenshots

- Persona selector with Mochi/Nova/Sage.
- Look tab with skin selector.
- Local model install/progress screen.
- OpenRouter key field.

### Existing Visual Sources In Repo

- `AC/UI/img/mochi_l.png`
- `AC/UI/img/mochi_s.png`
- `AC/UI/img/nova_l.png`
- `AC/UI/img/nova_s.png`
- `AC/UI/img/sage_l.png`
- `AC/UI/img/sage_s.png`
- `AC/Assets.xcassets/*`
- `design_handoff_AC/reference/AccountyCat.html`
- `design_handoff_AC/reference/*.jsx`
- `AC/UI/v2/*`
- `AC/UI/v2/Settings/*`
- `AC/UI/Skins/*`

### If Real Screenshots Are Not Ready

Use the existing design handoff HTML as a mockup source:

- Open `design_handoff_AC/reference/AccountyCat.html`.
- Use the Tweaks panel to switch states.
- Capture marketing-safe mockups of the panel, widget, nudge, overlay, and settings.
- Clearly treat them as product mockups if exact UI is still changing.

Alternative:

- Generate clean product mockups from the SwiftUI/v2 code and app assets, but preserve actual layout concepts: profile bar, stat strip, chat, AI mode cards, profile editor, nudge tooltip.

Do not generate fake screenshots that imply nonexistent features. If a visual is aspirational, label it internally and confirm before launch.

## Website Agent Implementation Notes

- Make the landing page responsive, but the primary product visual should still look like a Mac app on desktop.
- Use image assets rather than purely CSS/SVG decoration.
- Keep legal/privacy content static and easy to update.
- Add metadata for social sharing.
- Add analytics only if compatible with the privacy posture. If used, avoid invasive tracking and disclose it.
- Add `/waitlist` redirect to `/managed-waitlist`.
- Link `/privacy` from footer and from any waitlist form.
- Do not ship exact model or pricing tables until owner confirms.

## Open Questions For Owner

Before publishing:

- What is the canonical domain? Code assumes `accountycat.com`.
- What is the primary CTA today: direct download, GitHub Releases, TestFlight-like waitlist, or "coming soon"?
- Is there a notarized macOS build available?
- What macOS version and hardware requirements should be listed?
- Are Apple Silicon-only claims final?
- Are exact local model names final?
- Are RAM estimates final?
- Are OpenRouter monthly cost estimates final?
- What should Managed pricing be, if mentioned at all?
- What email/list backend should `/managed-waitlist` use?
- Should the site include GitHub/open-source links prominently?
- What release telemetry behavior ships in production builds?
- Is Calendar awareness shipping at launch or should it stay out of marketing copy?

## Source Files Read For This Brief

- `README.md`
- `docs/system-overview.md`
- `docs/how-ac-works.md`
- `docs/V1_VISION.md`
- `AC/UI/OnboardingWizardView.swift`
- `AC/UI/v2/ChatPanelView.swift`
- `AC/UI/v2/ProfileBarView.swift`
- `AC/UI/v2/Settings/AITab.swift`
- `AC/UI/v2/Settings/ProfilesTab.swift`
- `AC/UI/v2/Settings/YouTab.swift`
- `AC/UI/NudgeView.swift`
- `AC/UI/OverlayView.swift`
- `ACShared/AITier.swift`
- `AC/Services/OnlineModelService.swift`
- `AC/UI/OpenRouterKeyField.swift`
- `design_handoff_AC/README.md`
- OpenRouter ZDR docs: `https://openrouter.ai/docs/features/zdr`

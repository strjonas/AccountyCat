# AccountyCat

**A macOS focus companion that catches you drifting — and pulls you back.**

<p align="center">
  <img alt="License: MIT" src="https://img.shields.io/github/license/strjonas/AccountyCat?color=black" />
  <img alt="Platform: macOS 14+" src="https://img.shields.io/badge/platform-macOS%2014%2B-black" />
  <img alt="Apple Silicon" src="https://img.shields.io/badge/chip-Apple%20Silicon-black" />
  <img alt="Built with Swift" src="https://img.shields.io/badge/built%20with-Swift-black" />
  <img alt="Latest release" src="https://img.shields.io/github/v/release/strjonas/AccountyCat?color=black&label=release" />
  <img alt="Downloads" src="https://img.shields.io/github/downloads/strjonas/AccountyCat/total?color=black&label=downloads" />
</p>

<p align="center">
  <a href="https://www.producthunt.com/products/accountycat?embed=true&amp;utm_source=badge-featured&amp;utm_medium=badge&amp;utm_campaign=badge-accountycat" target="_blank" rel="noopener noreferrer"><img alt="AccountyCat - A focus companion that actually gets context | Product Hunt" width="185" height="40" src="https://api.producthunt.com/widgets/embed-image/v1/featured.svg?post_id=1153540&amp;theme=light&amp;t=1779778442873"></a>
</p>

Tell AC what you're working on. It watches what's on your screen and pulls you back the moment you slip into a rabbit hole — without blocking the tutorial, doc, or Slack thread that's part of the job.



https://github.com/user-attachments/assets/53e66f6e-4245-4ad3-b0f1-920a0b3d1386



---

## The problem with focus apps

A block list can't tell work from procrastination. Reddit might be where you lose an hour — or where you find the exact answer. Same site, opposite intent. Block it and you lose the answer; allow it and you lose the hour. So most blockers end up switched off.

AccountyCat sits in your menu bar, reads the active app and window title, and pulls in a screenshot only when that text isn't enough to judge. When you drift, it doesn't lock anything — it just says one short thing to get you back on task. Tell it you genuinely need to watch this one video, and if that holds up, it lets it go. It reads your context instead of enforcing a policy.

Getting interrupted during legitimate work is treated as a bug. The goal isn't maximum restriction — it's staying honest with yourself.

---

## How it works

Every few minutes — or when you switch apps — AccountyCat checks the active app, window title, recent context, and your current focus profile. When the title is descriptive enough, it can decide on a text-only call. When the app is inherently ambiguous, the title is missing, or the text-only result comes back unclear, AC attaches a screenshot and asks a vision-capable model once.

When you've genuinely drifted, AC steps in with one short message to get you back. Keep ignoring it and it escalates — but it won't pile on while you're actually working.

The model behind that decision is configurable. You choose how much intelligence you want and where it runs.

---

## How it stays out of your way

AccountyCat behaves differently when you're in a focus session versus everyday life. In a session it's attentive — it expects you to stick to the activity you declared, and asks if you drift. In everyday mode it's relaxed by default; life happens, errands and short detours are fine, and AC stays quiet unless something clearly conflicts with your stated goals or a rule you've set.

What makes it sharp over time is memory. When you correct AC, set a rule, or click "it's fine" on a nudge, AC remembers. Repeated patterns surface as suggestions rather than silent rules — you accept or dismiss them in the **You** tab, and a small "AC learned" toast with an undo affordance is shown whenever something is applied automatically. Every learned entry is editable.

---

## Open source, auditable, private

AccountyCat asks for Screen Recording and Accessibility permissions. Those are serious. So the source code is fully open — you can read exactly what happens with them. The short answer: Accessibility is used to read the active app and window title; screenshots are captured only when visual context is needed, analyzed, and discarded. Nothing is stored permanently. Nothing is sent anywhere you didn't configure.

Whether you run fully offline or with a cloud API, the privacy model is explicit and verifiable.

---

## AI modes

### Run fully on-device

No account, no API key, no internet. Everything runs locally via `llama.cpp` using the Qwen model family (multimodal, works for both text and screenshots).

| Tier | Model | RAM footprint | Notes |
|------|-------|---------------|-------|
| Economy | Qwen 3.5 4B | ~2–3 GB | Fits 8 GB Macs · reduced accuracy |
| Default | Qwen 3.5 9B | ~5–7 GB | Recommended for most users |
| Smartest | Qwen 3.6 27B | ~15–18 GB | Best local reasoning |

The app detects your available memory and suggests the right tier automatically.

### Bring your own API key (OpenRouter)

Connect your own [OpenRouter](https://openrouter.ai) account. You control the spend. All requests use OpenRouter's Zero Data Retention (ZDR) enforcement, meaning providers contractually cannot log or train on your data.

AccountyCat selects the right model based on what you're doing:
- **Text-only decisions**: Uses optimized text-only models for speed and cost when the app/title/profile context is enough
- **Screenshot checks**: Uses a vision-capable model for ambiguous apps, missing or weak titles, and one-shot retries when a text-only decision is unclear

| Tier | Text-only model | Image model | Approx. cost/month\* |
|------|-----------------|-------------|----------------------|
| Economy | DeepSeek V4 Flash | Qwen 3.5 9B | $0.80–$1.50 |
| Default | DeepSeek V4 Flash | Qwen 3.6 35B | $1.50–$3.00 |
| Smartest | Kimi K2.6 | Kimi K2.6 | $3.00–$5.00 |

\* Rough steady-state estimates. The first few days run a little higher — AC hasn't yet learned which apps and contexts are on-task for you, so more decisions reach the model. As it builds up your safelist, common contexts get recognized and skipped before any model call, which is the main driver of cost over time. Actual spend varies with how much you use your Mac. Only OpenRouter is supported for BYOK — one integration, clean privacy controls, one cost dashboard.

> **Managed mode (waitlist):** A fully hosted option is in planning — pay a flat monthly fee, no OpenRouter account needed, just works out of the box. [Join the waitlist](https://www.accountycat.com/#waitlist) to signal demand and get early access.

---

## What's in the repo

- Native Swift app, Apple Silicon
- Local `llama.cpp` runtime with in-app installer
- `ACInspector` — companion app for reviewing past sessions and telemetry locally
- One active monitoring algorithm; older alternatives parked under [`_Legacy/`](_Legacy)

---

## Getting started

### Download

Grab the latest release from the [Releases page](../../releases). Precompiled binary, no Xcode needed.

### Build from source

```sh
git clone https://github.com/strjonas/AccountyCat.git
cd AccountyCat
open AC.xcodeproj
# Set your development team if prompted, then run the AC target
```

On first launch: grant Screen Recording and Accessibility permissions, then let the app install the local runtime (or install `git`, `cmake`, and `ninja` yourself first).

---

## Permissions

| Permission | Why | What happens to the data |
|------------|-----|--------------------------|
| Screen Recording | Periodic screenshots for context | Analyzed locally or via your API key, then discarded. Never stored. |
| Accessibility | Read the active app name | Used only for the nudge decision. Never logged. |

---

## Data & storage

Everything stays under `~/Library/Application Support/AC`. With BYOK, screenshots and a short system prompt go directly from your Mac to OpenRouter — never through any AccountyCat server.

---

## Docs

- [Docs index](docs/README.md)
- [Codebase map](docs/core/codebase-map.md)
- [Contributing](CONTRIBUTING.md)

---

## License

MIT. See [LICENSE](LICENSE).

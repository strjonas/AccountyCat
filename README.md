# AccountyCat

A focus companion for macOS that actually understands context.

<img width="1000" height="600" alt="AccountyCat in the menu bar" src="https://github.com/user-attachments/assets/9f197866-1215-41cd-9791-d6ddc64df4c9" />

---

## The problem with focus apps

Most focus apps are blunt instruments. They block a list of websites and call it done. But that's not how real work operates.

Sometimes you need YouTube — for that one tutorial. Sometimes Slack is a distraction, sometimes it's where the answer is. Sometimes you're on Reddit because you're procrastinating; sometimes because you're looking up a bash flag. A blocking rule can't tell the difference. AccountyCat can.

AccountyCat sits in your menu bar, reads the active app and window title, and uses screenshots only when that text context is not enough. It nudges you when you drift — not by locking anything, just a small message from a cat. If you're doing something that looks off-task, it'll ask. If you tell it you need to watch this one video, and that makes sense, it'll let it go. It learns your context instead of enforcing a policy.

Getting interrupted during legitimate work is treated as a bug. The goal isn't maximum restriction — it's staying honest with yourself.

---

## How it works

Every few minutes — or when you switch apps — AccountyCat checks the active app, window title, recent context, and your current focus profile. When the title is descriptive enough, it can make the decision as a text-only call. When the app is inherently ambiguous, the title is missing, or the text-only result comes back unclear, AC attaches a screenshot and asks a vision-capable model once.

Most checks still result in nothing happening. When AC does say something, it's short. Escalation only happens after repeated ignored nudges.

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

Connect your own [OpenRouter](https://openrouter.ai) account. You control the spend — typical usage runs well under a dollar a month. All requests use OpenRouter's Zero Data Retention (ZDR) enforcement, meaning providers contractually cannot log or train on your data.

AccountyCat intelligently selects the right model based on what you're doing:
- **Text-only decisions**: Uses optimized text-only models for speed and cost when the app/title/profile context is enough
- **Screenshot checks**: Uses a vision-capable model for ambiguous apps, missing or weak titles, and one-shot retries when a text-only decision is unclear

| Tier | Text-only model | Image model | Approx. cost/month |
|------|-----------------|-------------|----------------------|
| Economy | Nemotron-3 Super 120B | Qwen 3.5 9B | $0.10–$0.25 |
| Default | DeepSeek V4 Flash | Gemma 4 31B | $0.20–$0.50 |
| Smartest | DeepSeek V4 Flash | Kimi K2.6 | $0.50–$1.00 |

Cost range reflects normal to heavy usage. Only OpenRouter is supported for BYOK — one integration, clean privacy controls, one cost dashboard.

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
git clone https://github.com/yourname/accountycat
cd accountycat
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
- [North star](docs/core/north-star.md)
- [Codebase map](docs/core/codebase-map.md)
- [Monitoring pipeline](docs/reference/monitoring-pipeline.md)
- [Runtime, providers, and setup](docs/reference/runtime-providers-and-setup.md)
- [State, persistence, and testing](docs/reference/state-persistence-and-testing.md)
- [Telemetry, Inspector, and debugging](docs/reference/telemetry-inspector-and-debugging.md)
- [Direct OpenAI routing experiment](docs/experiments/direct-openai-routing.md)
- [Contributing](CONTRIBUTING.md)

---

## License

MIT. See [LICENSE](LICENSE).

# AccountyCat

A focus companion for macOS that actually understands context.

<img width="1000" height="600" alt="AccountyCat in the menu bar" src="https://github.com/user-attachments/assets/9f197866-1215-41cd-9791-d6ddc64df4c9" />

---

## The problem with focus apps

Most focus apps are blunt instruments. They block a list of websites and call it done. But that's not how real work operates.

Sometimes you need YouTube — for that one tutorial. Sometimes Slack is a distraction, sometimes it's where the answer is. Sometimes you're on Reddit because you're procrastinating; sometimes because you're looking up a bash flag. A blocking rule can't tell the difference. AccountyCat can.

AccountyCat sits in your menu bar, watches what you're actually doing, and nudges you when you drift — not by locking anything, just a small message from a cat. If you're doing something that looks off-task, it'll ask. If you tell it you need to watch this one video, and that makes sense, it'll let it go. It learns your context instead of enforcing a policy.

Getting interrupted during legitimate work is treated as a bug. The goal isn't maximum restriction — it's staying honest with yourself.

---

## How it works

Every few minutes — or when you switch apps — AccountyCat looks at a screenshot and the active app, decides whether anything is worth mentioning, and usually does nothing. When it does say something, it's short. Escalation only happens after repeated ignored nudges.

The model behind that decision is configurable. You choose how much intelligence you want and where it runs.

---

## Open source, auditable, private

AccountyCat asks for Screen Recording and Accessibility permissions. Those are serious. So the source code is fully open — you can read exactly what happens with them. The short answer: screenshots are analyzed and discarded. Nothing is stored permanently. Nothing is sent anywhere you didn't configure.

Whether you run fully offline or with a cloud API, the privacy model is explicit and verifiable.

---

## AI modes

### Run fully on-device

No account, no API key, no internet. Everything runs locally via `llama.cpp` using the Gemma 4 model family.

| Tier | Model | RAM footprint | Notes |
|------|-------|---------------|-------|
| Economy | Gemma 4 E2B | ~1.3 GB | Instant responses, vision-capable |
| Default | Gemma 4 E4B | ~3–4 GB | Better reasoning, still very fast |
| Smartest | Gemma 4 26B A4B | ~10–12 GB | Near cloud quality, MoE architecture |

The app detects your available memory and suggests the right tier automatically. The E2B model uses about as much RAM as a browser tab.

### Bring your own API key (OpenRouter)

Connect your own [OpenRouter](https://openrouter.ai) account. You control the spend — typical usage runs well under a dollar a month. All requests use OpenRouter's Zero Data Retention (ZDR) enforcement, meaning providers contractually cannot log or train on your data.

| Tier | Model | Approx. cost/month |
|------|-------|--------------------|
| Economy | Gemma 4 26B A4B | $0.25–$0.50 |
| Default | Gemma 4 31B Dense | $0.35–$0.70 |
| Smartest | Gemini 2.5 Flash | $0.95–$1.90 |

Cost range reflects normal to heavy usage. Only OpenRouter is supported for BYOK — one integration, clean privacy controls, one cost dashboard.

> **Managed mode (waitlist):** A fully hosted option is in planning — pay a flat monthly fee, no OpenRouter account needed, just works out of the box. [Join the waitlist](#) to signal demand and get early access.

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

- [System overview](docs/system-overview.md)
- [Contributing](CONTRIBUTING.md)

---

## License

MIT. See [LICENSE](LICENSE).

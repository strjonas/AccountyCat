# AccountyCat

<p align="center">
  <strong>A macOS focus companion that catches you drifting and pulls you back.</strong>
</p>

<p align="center">
  <a href="https://accountycat.com">Website</a>
  ·
  <a href="https://accountycat.com/download">Download</a>
  ·
  <a href="https://accountycat.com/videos/ac-release-v1.mp4">Watch demo</a>
  ·
  <a href="https://accountycat.com/privacy">Privacy</a>
  ·
  <a href="https://github.com/strjonas/AccountyCat">Source</a>
  ·
  <a href="https://www.linkedin.com/in/jonas-strabel/">Developer</a>
</p>

<p align="center">
  <a href="https://github.com/strjonas/AccountyCat/blob/main/LICENSE"><img alt="License: MIT" src="https://img.shields.io/badge/license-MIT-black" /></a>
  <a href="https://accountycat.com/download"><img alt="macOS 14+" src="https://img.shields.io/badge/macOS-14%2B-black" /></a>
  <a href="https://accountycat.com/download"><img alt="Signed and notarized by Apple" src="https://img.shields.io/badge/signed%20%26%20notarized-Apple-black" /></a>
  <a href="https://github.com/strjonas/AccountyCat/releases"><img alt="Latest release" src="https://img.shields.io/github/v/release/strjonas/AccountyCat?color=black&label=release" /></a>
  <a href="https://github.com/strjonas/AccountyCat/releases"><img alt="Downloads" src="https://img.shields.io/github/downloads/strjonas/AccountyCat/total?color=black&label=downloads" /></a>
</p>

<p align="center">
  <a href="https://www.producthunt.com/products/accountycat?embed=true&utm_source=badge-featured&utm_medium=badge&utm_campaign=badge-accountycat"><img alt="AccountyCat on Product Hunt" src="https://api.producthunt.com/widgets/embed-image/v1/featured.svg?post_id=1153540&theme=neutral&t=1779978760491" height="40" /></a>
</p>

<p align="center">
  <video src="https://accountycat.com/videos/ACDemo.mp4" poster="https://accountycat.com/videos/ACDemo-poster.jpg" controls width="900">
    Your browser does not support the video tag.
  </video>
</p>

<p align="center">
  <sub>14-second demo.</sub>
</p>

## Why it exists

Most focus apps rely on blocklists. That breaks down fast: the same site can be either the answer you need or the rabbit hole that kills an hour.

AccountyCat lives in your menu bar, reads the active app and window title, and only pulls in a screenshot when text is not enough to judge. When you drift, it does not lock anything. It gives you a short nudge, then gets out of the way.

Interrupting legitimate work is a bug. Letting obvious drift continue for too long is a bug too.

## How it works

Every few minutes, or when you switch apps, AccountyCat checks the active app, window title, recent context, and your current focus profile.

- If the title and app context are clear, it makes a text-only decision.
- If the app is ambiguous or the title is weak, it can attach a screenshot and ask a vision-capable model once.
- If you are on task, it stays quiet.
- If you have drifted, it nudges.
- If you correct it, it learns.

AccountyCat behaves differently in a named focus session versus everyday mode. Focus sessions are stricter because you opted in. Everyday mode is more tolerant of errands, breaks, and life admin.

## Run it your way

### Private cloud mode

Connect your own [OpenRouter](https://openrouter.ai) account. AC chooses the right model for the job: text-only when it can, vision when it needs to. Requests use OpenRouter's Zero Data Retention policy, and spend stays under your control.

| Tier | Text model | Vision model | Rough monthly cost* |
| --- | --- | --- | --- |
| Economy | DeepSeek V4 Flash | Qwen 3.5 9B | ~$0.80-$1.50 |
| Default | DeepSeek V4 Flash | Qwen 3.6 35B | ~$1.50-$3.00 |
| Smartest | Kimi K2.6 | Kimi K2.6 | ~$3.00-$5.00 |

### Local mode

Run fully on-device through `llama.cpp` with the Qwen multimodal family. No account, no API key, no internet.

| Tier | Model | RAM footprint | Notes |
| --- | --- | --- | --- |
| Economy | Qwen 3.5 4B | ~2-3 GB | Best for 8 GB Macs |
| Default | Qwen 3.5 9B | ~5-7 GB | Recommended for most users |
| Smartest | Qwen 3.6 27B | ~15-18 GB | Best local quality |

\* Real cost depends on how much you use your Mac. Early usage can be slightly higher before AC has learned your common on-task contexts.

> Hosted mode is planned: flat monthly fee, no OpenRouter key, nothing to configure. Join the [waitlist](https://accountycat.com/#waitlist).

## Privacy

AccountyCat asks for serious permissions, so the source is fully open and the privacy model is explicit.

| Permission | Why it is needed | What happens to the data |
| --- | --- | --- |
| Screen Recording | Periodic screenshots for context when text is not enough | Analyzed locally or via your configured provider, then discarded |
| Accessibility | Read the active app and window title | Used only for focus judgment and UI behavior |

- Nothing is routed through AccountyCat servers during normal inference.
- In private cloud mode, requests go directly from your Mac to OpenRouter.
- In local mode, nothing leaves your Mac.
- App state lives under `~/Library/Application Support/AC`.

Read the full [privacy policy](https://accountycat.com/privacy).

## What is in this repo

- Native Swift app for macOS on Apple Silicon
- Local `llama.cpp` runtime with in-app installer
- `ACInspector`, a local companion app for telemetry review and prompt replay
- Tests, docs, and focused internal tooling for monitoring and evaluation

## Getting started

### Download the app

Get the signed build from the [latest release](https://github.com/strjonas/AccountyCat/releases) or from [accountycat.com/download](https://accountycat.com/download).

### Build from source

```sh
git clone https://github.com/strjonas/AccountyCat.git
cd AccountyCat
open AC.xcodeproj
```

On first launch, grant Screen Recording and Accessibility permissions, then either let the app install its local runtime or configure OpenRouter.

## Docs

- [Docs index](docs/README.md)
- [Codebase map](docs/core/codebase-map.md)
- [Contributing](CONTRIBUTING.md)

## License

[MIT](LICENSE)

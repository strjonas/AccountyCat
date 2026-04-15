# AccountyCat

A local macOS focus companion. Sits quietly in the background, watches what you're doing, and nudges you when you drift — not by blocking anything, just a gentle heads-up from a little cat in your menu bar.

Runs entirely on-device. No accounts, no cloud, nothing phoning home.

## Why open source

Screen Recording and Accessibility are serious permissions to hand over. Open source means you can read exactly what happens with them. The answer is: nothing leaves your machine.

## How it works

Every few minutes (or when you switch apps), a local LLM looks at a screenshot and the active app, then decides what to do. Usually nothing. Sometimes a short nudge. Escalation only happens after repeated ignored nudges.

Getting interrupted during legitimate work is treated as a bug, not an acceptable tradeoff.

## What's here

- Native Swift app, Apple Silicon
- Local `llama.cpp` runtime (Gemma 4 E2B, ~4.4 GB RAM)
- In-app runtime installer
- `ACInspector` — a companion app for reviewing past sessions and telemetry locally

## Run locally

1. Open `AC.xcodeproj` in Xcode
2. Set your development team if prompted
3. Run the `AC` target
4. Grant Screen Recording and Accessibility when asked
5. Let the app install the local runtime, or install `git`, `cmake`, and `ninja` yourself first

## Data

Everything stays under `~/Library/Application Support/AC` — screenshots, telemetry, logs, runtime files, all of it.

## Docs

- [Architecture](docs/architecture.md)
- [Runtime](docs/runtime.md)
- [Contributing](CONTRIBUTING.md)

## License

MIT. See [LICENSE](LICENSE).


# North Star

This is the durable product and engineering context for AccountyCat. It should change slowly.

## What AC Is

AC is a focus companion that should feel:

- actually useful
- native to macOS
- non-intrusive
- effortless to use
- finished, not like a bag of features

The product is not a blocker or a rules engine first. It is a context-aware companion that helps the user stay honest with themselves.

## Product Principles

- Interrupting legitimate work is a bug.
- AC should work even if the user mainly interacts through chat.
- Everyday mode should tolerate errands, breaks, life admin, and short detours.
- Named focus sessions should be stricter because the user opted in.
- AC should learn over time from user interaction, corrections, appeals, and repeated patterns.
- AC should have what it needs and nothing more.

## Engineering Principles

- More is less.
- Reliability over features.
- Build for production, not demos.
- Build user-centric behavior, not technically clever behavior that feels wrong.
- Keep the codebase optimized for agents: clear seams, low surprise, minimal duplication.
- No workaround-driven architecture. If something is unclear, ask or trace the code properly.
- Efficiency matters, but AC's judgment quality matters more.

## Bar for V1.0 (Current Sprint)

Shipping quality means:

- AC can run for days without crashes, runaway memory usage, or setup drift.
- AC is genuinely helpful for focus, not just visibly active.
- AC avoids obvious false-positive nudges and doesn't stay silent for obvious positives.
- The UI is intuitive enough that the user does not need a manual.
- Intelligent behavior from AC's side is the number one priority. The second is efficiency (minimize battery usage and token consumption)

## Implementation Consequences

- The "north star" doc should not try to mirror every implementation detail.
- Default agent context should stay lean. Stable docs should orient; volatile docs should be loaded only on demand.
- Prompt text belongs in exactly one place: `ACShared/ACPromptSets.swift`.
- The app should preserve a clear split between stable principles and volatile implementation notes.
- Docs that primarily explain current seams or experiments belong in `docs/reference/` or `docs/experiments/`, not here.

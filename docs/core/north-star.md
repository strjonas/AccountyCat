# North Star

This file is the source of truth for AccountyCat's product principles, engineering principles, taste, and quality bar.

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

- Interrupting legitimate work is a bug, so is AC letting user drift away from their work for long. 
- AC should work even if the user mainly interacts through chat.
- Everyday mode should tolerate errands, breaks, life admin, and short detours.
- Named focus sessions should be stricter because the user opted in.
- AC should learn over time from user interaction, corrections, appeals, and repeated patterns. (Every user interaction should potentially become memory -> AC should seem like its listening to the user. There is nothing more annoying than having to correct AC continuously)
- AC should have what it needs and nothing more.
- AC shouldn't just nag, but also celerate with the user. (non-intrusive)

## Engineering Principles

- More is less.
- Reliability over features.
- Build for production, not demos.
- Build user-centric behavior, not technically clever behavior that feels wrong.
- Keep the codebase optimized for agents: clear seams, low surprise, minimal duplication.
- No workaround-driven architecture. If something is unclear, ask or trace the code properly.
- Efficiency matters, but AC's judgment quality matters more.
- Prompts should be crisp. They should tap into frontier models' capability but respect smaller, local models. Split difficult tasks into multiple steps (for local models), give few-shot examples, minimize output complexity requirements and parse output graciously.
- Algorithm should be bullet-proof and concise like an embedded-system state machine. 

## Bar for V1.0 (Current Sprint)

Shipping quality means:

- AC can run for days without crashes, runaway memory usage, or setup drift.
- AC is genuinely helpful for focus, not just visibly active.
- AC avoids obvious false-positive nudges and doesn't stay silent for obvious positives.
- The UI is intuitive and easy as well as a joy to use.
- Intelligent behavior from AC's side is the number one priority. The second is efficiency (minimize battery usage and token consumption)

## Implementation Consequences

- The "north star" doc should not try to mirror every implementation detail.
- `AGENTS.md` should route agents here rather than duplicating this content.
- Default agent context should stay lean. Stable docs should orient; volatile docs should be loaded only on demand.
- Prompt text belongs in exactly one place: `ACShared/ACPromptSets.swift`.
- The app should preserve a clear split between stable principles and volatile implementation notes.
- Docs that primarily explain current seams or experiments belong in `docs/reference/` or `docs/experiments/`, not here.

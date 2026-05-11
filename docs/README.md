# AccountyCat Docs

This file is the docs map: it explains which document owns what and what to read for a given task.

This folder is split by how often a doc should be read and how often it is expected to change. The goal is to keep default session context lean: start with `AGENTS.md`, then `core/`, and load `reference/` or `experiments/` only when the task actually touches them.

## Ownership

| File | Owns |
| --- | --- |
| `../AGENTS.md` | Agent entrypoint, routing, and a few non-negotiable guardrails |
| `core/north-star.md` | Source of truth for product principles, engineering principles, taste, and the current quality bar |
| `core/codebase-map.md` | Source of truth for architecture map, ownership seams, and where major behavior lives |
| `reference/*` | Area-specific implementation details that should track the live code |
| `experiments/*` | Temporary notes for active experiments or transitions |
| `../README.md` | Public repo readme for humans visiting the repository |

## Read Order

### Read on most non-trivial tasks

These are the durable onboarding docs. They should stay compact and relatively stable.

| File | Why it exists | Volatility |
| --- | --- | --- |
| `core/north-star.md` | Product philosophy, engineering values, and the bar for V1.0. | Low |
| `core/codebase-map.md` | Current repo map, ownership seams, and where major behavior lives. | Medium |

### Read only when the task touches that area

These are implementation references. They are intentionally narrower and more likely to evolve with the code.

| File | Load when you are touching | Volatility |
| --- | --- | --- |
| `reference/monitoring-pipeline.md` | Brain loop, evaluation flow, appeals, policy updates, nudges/escalations. | Medium-high |
| `reference/runtime-providers-and-setup.md` | First-run setup, local runtime install, model selection, OpenRouter/OpenAI routing. | Medium-high |
| `reference/state-persistence-and-testing.md` | `ACState`, storage paths, migrations, test isolation, fixtures. | Medium |
| `reference/telemetry-inspector-and-debugging.md` | Telemetry sessions/artifacts, ACInspector, debug bundles, runtime triage. | Medium |

### Temporary / removable docs

These are experiments or transition notes. Keep them out of default reading unless the task is directly related.

| File | Purpose |
| --- | --- |
| `experiments/direct-openai-routing.md` | Notes for the temporary direct-OpenAI bypass experiment. |

## Doc Hygiene Rules

- Keep `AGENTS.md` as the top-level entry point.
- Keep `core/` opinionated and durable. It should explain what AC is trying to be and how the repo is organized, not every implementation detail.
- Put volatile details in `reference/` or `experiments/`.
- Update `core/codebase-map.md` whenever directory ownership or major seams move.
- Update `reference/*` when behavior changes in a way that would mislead the next engineer.
- Delete temporary docs when the experiment is removed rather than letting them rot.

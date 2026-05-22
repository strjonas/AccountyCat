# Model-Driven `tolerated` Recheck Interval

## Goal

Answer one narrow question: can the decision model pick a *better* recheck cadence for
`tolerated` detours than a fixed per-mode constant?

A `tolerated` verdict means "acceptable right now, but not focused work — glance again soon."
A fixed `toleratedFollowUp` (balanced 150s, ×1.5 everyday = 225s) is correct for a quick message
but wasteful when the user has explicitly allowed a longer break ("15 min scrolling after lunch is
fine"). This experiment lets the model propose the interval, with deterministic clamps so a bad
value can never make AC brittle.

## What Was Changed

One optional output field, parsed and clamped in one place:

- **Schema** — `recheck_seconds` added to `decisionSchema` in `ACShared/ACPromptSets.swift`
  (single source of truth). Output rules + tolerated few-shots teach when to set it.
- **Model** — `recheckSeconds: Int?` on `LLMDecision` (`AC/Models/ACModels.swift`) and
  `MonitoringDecisionEnvelope` (`ACShared/MonitoringPolicyPromptSchemas.swift`), carried through
  `asLLMDecision` and `makeDecisionEnvelope`.
- **Clamp** — in `LLMMonitorAlgorithm`'s `.tolerated` record case: the next recheck is
  `clamp(recheck_seconds ?? toleratedFollowUp, lower, upper)` where
  `lower = adjustedDelay(toleratedFollowUp)` (never nag faster than baseline) and
  `upper = adjustedDelay(focusedFollowUp)` (never go silent as long as genuine focus).
- **Inspector** — `PromptLabRunner` parses `recheck_seconds` from raw model JSON.

## Why It's Safe / Reversible

- The field is **optional with a hard fallback**: a model that omits it (or any pre-existing
  cached/persisted decision) behaves exactly as before — `nextEvaluationAt = now + toleratedFollowUp`.
- The clamp bounds the effect to `[toleratedFollowUp, focusedFollowUp]`. A garbage value
  (0, negative, 99999) collapses to the baseline or the focused window — never unbounded silence,
  never a tight nag loop.
- Only `tolerated` reads it; all other assessments ignore it.

## How To Reverse If It Doesn't Work Reliably

If the model picks bad intervals (e.g. always max, or erratic), revert to the fixed cadence with a
one-line change and no schema migration needed:

1. In `LLMMonitorAlgorithm`'s `.tolerated` case, replace the clamp block with the original:
   `distraction.nextEvaluationAt = input.now.addingTimeInterval(toleratedWindowSeconds)`.

That alone restores the prior behavior. The dangling `recheck_seconds` field is harmless (decodes
to an ignored optional). For a full clean removal, also drop: the field from `decisionSchema`, the
output-rule line and the `recheck_seconds` values in the tolerated few-shots, `recheckSeconds` from
`LLMDecision` / `MonitoringDecisionEnvelope` (+ `asLLMDecision`, `makeDecisionEnvelope`), and the
parse in `PromptLabRunner`.

## How To Evaluate

In the Inspector, on a `tolerated` verdict confirm `nextEvaluationAt` tracks the model's
`recheck_seconds` (clamped): a quick message → ~baseline; an explicit "10–15 min is fine" memory →
near the upper bound; no field → baseline.

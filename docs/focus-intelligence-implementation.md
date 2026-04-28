# Focus Intelligence Implementation Notes

Date: 2026-04-28

This note documents the first implementation slice from the AccountyCat product/algorithm plan.

## Implemented

- Added `MonitoringCadenceMode` with `sharp`, `balanced`, and `gentle` modes.
  - Cadence controls initial stable-context delay, focused/unclear/distracted recheck intervals, and focused decision cache TTL.
  - The setting is exposed in Settings -> AI as "Check timing".

- Added local drift state via `FocusSignalState`.
  - Model confidence now feeds a smoothed `driftEMA`.
  - Low-confidence distracted decisions below `0.60` are converted to `unclear`/`abstain`, preventing weak nudges from incrementing the distraction streak.
  - This is the foundation for future ambient cat expressions and glow without extra model calls.

- Added persistent focus timeline segments.
  - `ACState.focusSegments` records compact focused/distracted/unclear blocks while monitoring runs.
  - Segments are retained for 14 days and capped to avoid unbounded state growth.
  - Recent interventions now carry optional IDs, evaluation IDs, app/title context, and can be attached to timeline segments.

- Updated the Home stats.
  - Replaced raw tracked/nudges/rescues cards with a mini timeline, focused time today, best focused block, and focus streak.
  - "Rescue" is still stored as Back to Work count internally, but the display now emphasizes positive focus metrics.

- Softer overlay interaction.
  - Default overlay copy now uses "This looks a bit off-track — what's going on?" instead of the adversarial gatekeeper wording.
  - Added quick reason chips: Research, Break, Got stuck, Related to my task.

- Added correction foundation.
  - Chat messages like "that wasn't a distraction" or "false positive" now mark the recent intervention segment as focused, reset local drift, and append a memory correction.

- Added rule-based win celebrations.
  - When the user opens the panel after meaningful focused time, AC can append a lightweight celebration message to chat.
  - This is deterministic and does not add a model call.

## Not Yet Implemented

- Keyboard typing / scroll / interaction velocity.
  - Current app code only has "seconds since any input"; adding real typing-rate signals needs a new event tap or Accessibility-based input sampler.

- Full visual cat state mapping.
  - `driftEMA` exists, but the floating cat still mostly uses the existing `CompanionMood` states.
  - Next step: map drift bands to calm / alert / concerned / celebrating expressions and a subtle glow.

- True session replay / rich analytics.
  - Timeline segments are persisted, but there is no detailed review screen yet.

- One-time overlay snooze.
  - Reason chips are implemented; snooze requires per-overlay episode state to prevent repeated snoozing.

- TTS / voice output.
  - The sound toggle exists, but local `AVSpeechSynthesizer` delivery is not wired yet.

- STT / voice input.
  - Deferred due to privacy and interaction complexity.

- Full gamified visual-novel overlay.
  - The current overlay is still the existing soft modal with chips, not a sprite/dialogue-box redesign.

## Verification

- `xcodebuild build -scheme AC -destination 'platform=macOS,arch=arm64' -skipPackagePluginValidation -quiet` passed.
- `xcodebuild test -scheme AC -destination 'platform=macOS,arch=arm64' -only-testing:ACTests -skipPackagePluginValidation -quiet` passed.
- Full scheme test run still fails in `ACUITests.testExample()` after a 60s app launch timeout. Unit tests pass; the UI test target appears to be the existing placeholder launch test behavior.

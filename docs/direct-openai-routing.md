# Direct OpenAI Routing Experiment

## Goal

This experiment exists to answer one narrow question:

- Are recent online failures caused by OpenRouter and its fallback stack, or by AC's own request pipeline?

It is intentionally not a full multi-provider architecture. The current design keeps one surgical routing seam and one UI switch so the experiment can be enabled or removed cleanly.

## What was changed

The routing decision now lives in one place:

- `AC/Services/OnlineProviderRouting.swift`

That file owns:

- the "direct OpenAI" toggle state
- the OpenRouter API key lookup
- the direct OpenAI API key lookup
- the effective online provider selection
- the forced direct OpenAI model identifier (`gpt-5.4-nano`)

`OnlineModelService` still owns the actual HTTP request execution, retry logic, telemetry, and OpenRouter-specific fallback behavior. It now asks `OnlineProviderRouting` which provider/model to use before each online request.

## Current behavior

When the switch is OFF:

- all online traffic uses OpenRouter
- AC keeps its OpenRouter model selection, retries, and fallback chain

When the switch is ON:

- all online traffic uses OpenAI directly
- the request bypasses OpenRouter entirely
- OpenRouter fallback models are not used
- all online request sources are affected:
  - monitoring text
  - monitoring vision
  - chat
  - chat actions
  - policy memory
  - memory consolidation
  - safelist appeal

## UI surface

The experiment is intentionally exposed in one place only:

- `AC/UI/Settings/AITab.swift`

It adds:

- one switch: direct OpenAI on/off
- one OpenAI API key field
- a small status hint when a key is present

## Cleanup / removal

If this experiment is no longer needed, remove it in this order:

1. Delete `AC/Services/OnlineProviderRouting.swift`.
2. Remove the direct OpenAI switch and key field from `AC/UI/Settings/AITab.swift`.
3. Remove the direct OpenAI state fields/helpers from `AC/Core/AppController.swift`.
4. Replace `OnlineProviderRouting` calls in `OnlineModelService` with fixed OpenRouter routing.
5. Remove the direct OpenAI tests from `ACTests/OnlineModelServiceTests.swift`.

That should fully remove the experiment without touching unrelated monitoring, prompt, or local-runtime code.

## Non-goals

This experiment does not yet introduce:

- a general provider plugin system
- per-feature provider selection
- per-user provider selection
- provider-specific request executors behind separate protocols

Those are possible future directions, but they would add complexity that is not needed for this debugging pass.

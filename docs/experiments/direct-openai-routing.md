# Direct OpenAI Routing Experiment

## Goal

This experiment exists to answer one narrow question:

- are recent online failures caused by OpenRouter and its fallback stack, or by AC's own request pipeline?

It is intentionally not a full multi-provider architecture. The current design keeps one surgical routing seam and one UI switch so the experiment can be enabled or removed cleanly.

## What Was Changed

The routing decision lives in one place:

- `AC/Services/OnlineProviderRouting.swift`

That file owns:

- the direct-OpenAI toggle state
- the OpenRouter API-key lookup
- the direct-OpenAI API-key lookup
- the effective online provider selection
- the forced direct-OpenAI model identifier (`gpt-5.4-nano`)

`OnlineModelService` still owns:

- HTTP execution
- retry logic
- telemetry
- OpenRouter-specific fallback behavior

It now asks `OnlineProviderRouting` which provider/model to use before each online request.

## Current Behavior

When the switch is off:

- all online traffic uses OpenRouter
- AC keeps its OpenRouter model selection, retries, and fallback chain

When the switch is on:

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

## UI Surface

The experiment is intentionally exposed in one place only:

- `AC/UI/Settings/AITab.swift`

It adds:

- one switch: direct OpenAI on/off
- one OpenAI API-key field
- a small status hint when a key is present

## Cleanup / Removal

If this experiment is no longer needed, remove it in this order:

1. Delete `AC/Services/OnlineProviderRouting.swift`.
2. Remove the direct-OpenAI switch and key field from `AC/UI/Settings/AITab.swift`.
3. Remove the direct-OpenAI state fields/helpers from `AC/Core/AppController.swift`.
4. Replace `OnlineProviderRouting` calls in `OnlineModelService` with fixed OpenRouter routing.
5. Remove the direct-OpenAI tests from `ACTests/OnlineModelServiceTests.swift`.

## Non-Goals

This experiment does not introduce:

- a general provider plugin system
- per-feature provider selection
- per-user provider selection
- provider-specific request executors behind separate protocols

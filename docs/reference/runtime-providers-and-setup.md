# Runtime, Providers, and Setup

This doc covers first-run setup, local runtime management, and online-provider routing.

## Primary Files

- `AC/Core/AppController+RuntimeSetup.swift`
- `AC/Services/RuntimeSetupService.swift`
- `AC/Services/DependencyInstallerService.swift`
- `AC/Services/LocalModelRuntime.swift`
- `AC/Services/OnlineModelService.swift`
- `AC/Services/OnlineProviderRouting.swift`
- `ACShared/AITier.swift`
- `AC/UI/OnboardingDialogView.swift`
- `AC/UI/OnboardingWizardView.swift`
- `AC/UI/Settings/AITab.swift`

## Local Runtime

The local path is `llama.cpp` plus managed model artifacts.

Key facts:

- runtime repo remote: `https://github.com/ggml-org/llama.cpp.git`
- pinned commit lives in `RuntimeSetupService.pinnedLlamaCommit`
- preferred install root is under `~/Library/Application Support/AC/runtime`
- legacy installs under `~/accountycat` are still detected

`RuntimeSetupService` owns:

- runtime diagnostics
- free-disk-space checks
- clone / fetch / checkout / build
- managed Hugging Face cache paths
- warm-up and readiness polling
- cleanup helpers for managed models

## Setup Guardrails

When changing first run or setup, preserve all of these:

- free-disk-space verification before large writes
- cleanup of interrupted downloads / partial state
- user-readable subprocess failures
- an explicit "setup is done" signal

Setup bugs are high-impact because they block the whole product.

## Monitoring Backend Selection

`MonitoringConfiguration.inferenceBackend` selects the backend:

- `.local`
- `.openRouter`

The current default is local inference.

Model selection is split by text vs image where supported:

- `onlineModelIdentifierText`
- `onlineModelIdentifierImage`
- `localModelIdentifierText`
- `localModelIdentifierImage`

`AITier` supplies the user-facing defaults.

## Online Routing

`OnlineModelService` owns HTTP execution, retry behavior, telemetry, and OpenRouter fallback handling.

`OnlineProviderRouting` owns:

- active provider selection
- direct-OpenAI toggle lookup
- ZDR (Zero Data Retention) toggle lookup
- provider-specific API-key lookup
- effective model identifier when direct OpenAI is enabled

Current behavior:

- default online path: OpenRouter
- temporary experiment: direct OpenAI for all online traffic
- API keys live in macOS Keychain via `OnlineProviderCredentialStore`
- direct-OpenAI and ZDR toggles live in `UserDefaults` via `OnlineProviderRoutingStore`
- ZDR is on by default; users can opt out from the AI tab's advanced section after an explicit confirmation alert

The direct-OpenAI experiment is documented separately in `docs/experiments/direct-openai-routing.md`.

### OpenRouter request shape

Each OpenRouter request sets:

- `response_format: {"type": "json_object"}`
- `reasoning: {"enabled": false}` whenever `options.thinkingEnabled` is false. This is the documented OpenRouter shape; the older `{"max_reasoning_tokens": 0}` form was silently ignored by some providers (notably Together-served Kimi) and produced empty completions.
- `max_tokens`: the larger of `options.maxTokens` and `OnlineModelService.openRouterMinMaxTokens` (currently 1500). Local stage configs are tuned for `llama.cpp` memory pre-allocation; online billing is per-actual-token, so the floor avoids `finish_reason=length` when a provider emits hidden reasoning before content.
- `provider`: ZDR flag (per `OnlineProviderRouting.isZDREnforced()`), `allow_fallbacks: true`, `require_parameters: true`, `sort: "latency"`, and a `preferred_max_latency` profile per request source.

### Fallback chain

`OnlineModelService.requestFallbackModelIdentifiers` builds the per-request chain in three layers, then filters by `OpenRouterHealthStatsService.sortedHealthyModels`:

1. The non-`:free` variant of the requested model, when applicable.
2. Tier alternatives. Image requests fall back to `AITier.economy.byokModelIdentifierImage` then `AITier.smartest.byokModelIdentifierImage`. Text requests interleave the balanced image model first (it handles text well) then the economy and smartest text models.
3. For premium-path requests (the first few successful monitoring/chat calls of a session), the balanced and smartest image models are appended as extra runway.

The chain is capped to `maxOpenRouterModelsArrayCount` (currently 3) and passed to OpenRouter via the `models` array.

### Tier → model identifiers

Defaults live in `ACShared/AITier.swift`. As of v1.0:

| Tier | Text | Image |
|------|------|-------|
| Economy | `deepseek/deepseek-v4-flash` | `qwen/qwen3.5-9b` |
| Balanced (Default) | `deepseek/deepseek-v4-flash` | `qwen/qwen3.6-35b-a3b` |
| Smartest | `moonshotai/kimi-k2.6` | `moonshotai/kimi-k2.6` |

If you change a tier's model, also update the friendly-name lookups in `AppController.shortModelName` and `AppController.veryShortModelName` (`AC/Core/AppController+RuntimeSetup.swift`) so the menu bar, settings, and onboarding render the new model.

## Request Sources

Online requests are tagged by source:

- chat
- chat-action resolution
- policy memory
- memory consolidation
- monitoring text
- monitoring vision
- safelist appeal

This matters because fallback behavior and telemetry are source-aware.

## Practical Ownership

If the change is about:

- install/build/download behavior: start in `RuntimeSetupService` and `AC/Core/AppController+RuntimeSetup.swift`
- local inference execution or runtime stdout/stderr handling: start in `LocalModelRuntime`
- remote HTTP failures or fallback chains: start in `OnlineModelService`
- provider toggles or key lookup: start in `OnlineProviderRouting`
- settings/onboarding copy or controls: start in `AITab` and the onboarding views

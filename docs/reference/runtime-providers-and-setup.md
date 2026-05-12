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
- provider-specific API-key lookup
- effective model identifier when direct OpenAI is enabled

Current behavior:

- default online path: OpenRouter
- temporary experiment: direct OpenAI for all online traffic
- API keys live in macOS Keychain via `OnlineProviderCredentialStore`
- direct-OpenAI toggle lives in `UserDefaults` via `OnlineProviderRoutingStore`

The direct-OpenAI experiment is documented separately in `docs/experiments/direct-openai-routing.md`.

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

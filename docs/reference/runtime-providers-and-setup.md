# Runtime, Providers, and Setup

This doc covers first-run setup, local runtime management, and online-provider routing.

## Primary Files

- `AC/Core/AppController+RuntimeSetup.swift`
- `AC/Services/RuntimeSetupService.swift`
- `AC/Services/DependencyInstallerService.swift`
- `AC/Services/LocalModelRuntime.swift`
- `AC/Services/OnlineModelService.swift`
- `AC/Services/OnlineProviderRouting.swift`
- `AC/Services/PromoRedemptionService.swift`
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

### Build-tool PATH for setup subprocesses

A GUI app launched from Finder inherits launchd's minimal PATH
(`/usr/bin:/bin:/usr/sbin:/sbin`), which omits the Homebrew prefixes
(`/opt/homebrew/bin`, `/usr/local/bin`) where users install `cmake`/`ninja`. AC
finds the tools itself via `resolvedToolPath` (which checks those prefixes
explicitly), but the build subprocesses it spawns do not — so cmake could find
`ninja` only at lookup time, then fail at configure time with "CMake unable to
find a build program corresponding to Ninja". `runStreaming` therefore prepends
the standard tool prefixes to the subprocess `PATH` (`augmentedSubprocessPATH`),
and `installRuntime` additionally passes the resolved ninja path to cmake via
`-DCMAKE_MAKE_PROGRAM`. This only reproduces in a packaged `.app` launched from
Finder; running from Xcode masks it because Xcode passes the developer's shell
PATH.

### Model download authentication (HF token)

Models download via `llama-cli -hf <id>`, which is a single-stream libcurl fetch from the
Hugging Face CDN. Hugging Face's response headers explicitly ask for a token "to enable
higher rate limits and faster downloads," and rate-limits unauthenticated traffic.

`HuggingFaceTokenService.fetchToken()` fetches a token from
`https://accountycat.com/api/hf-token` (override with `AC_HF_TOKEN_ENDPOINT`), caches it in
memory for an hour, and **returns nil on any failure**. `installRuntime` fetches it and passes
it to `warmUpRuntime`, which only sets `HF_TOKEN` in the llama.cpp env when non-empty. No
token → unauthenticated download, identical to the prior behavior — a server outage or
missing key never blocks setup.

Server contract: a `200` JSON body `{ "token": "hf_..." }` enables auth; anything else
(including `204`) → unauthenticated fallback. The app sends an `X-AC-Install` header (the
per-install id) so the endpoint can rate-limit abuse via Upstash if desired.

The token **must** be fine-grained, read-only, public-repos-only. It is effectively public
(any user can extract it from the endpoint), so it guards only access to files that are
already public — a leak exposes nothing private; worst case the server rotates it. Never use
a write-scoped or account-wide token here.

Measured download throughput is logged to the activity log as `setup-download-speed`
(`X MB in Ys (Z MB/s) [authenticated|unauthenticated]`) on real downloads only, so we can
tell in the wild whether users are throttle-capped or pipe-limited. Note: unauthenticated
speed is highly variable (measured 1.4–6.8 MB/s on the same file/connection), so the token is
a cheap insurance/rate-limit win, not a guaranteed speedup — let the telemetry decide whether
it's worth deeper investment (e.g. a self-hosted mirror).

## Setup Guardrails

When changing first run or setup, preserve all of these:

- free-disk-space verification before large writes
- cleanup of interrupted downloads / partial state
- user-readable subprocess failures
- an explicit "setup is done" signal
- cancellable installs: switching away from Local (or to another tier whose model is
  already present) must actually stop an in-flight install, not just orphan it

Setup bugs are high-impact because they block the whole product.

### Install cancellation

`RuntimeSetupService.runStreaming` wraps the subprocess wait in
`withTaskCancellationHandler` and calls `process.terminate()` on cancel, then throws
`CancellationError`. Swift task cancellation is cooperative, so without the explicit
terminate the `git` / `cmake` / `llama-cli` subprocess would keep running to completion
after the user switched away — leaving `installingRuntime == true`, which pins
`setupStatus` at `.installing` until an app restart.

`AppController.cancelRuntimeInstall()` is the single entry point that cancels the install
task, stops byte-progress polling, and resets `installingRuntime` + all `setupProgress*` /
`setupDownloaded/TotalBytes` state. It is invoked from `updateMonitoringInferenceBackend`
(switch to OpenRouter) and the local-tier-change path in `applyTierToActiveBackend`. The
install task's own cancellation branch deliberately leaves these flags for the canceller
to reset.

Terminating mid-download leaves llama.cpp's `*.downloadInProgress` blobs in place; the
next Local install resumes them via range requests rather than restarting from zero.

### Download progress

Progress is reported two ways, with byte-level data preferred:

- `AppController.startDownloadProgressPolling(modelIdentifier:)` polls
  `RuntimeSetupService.downloadedModelBytes(for:)` (sum of `blobs/` file sizes, including
  `*.downloadInProgress` partials) every ~0.6s, and fetches the expected total once from
  the Hugging Face tree API via `RuntimeSetupService.expectedDownloadBytes(for:)`
  (best-effort; nil on failure). This drives a determinate bar and the "X of Y" display in
  `AITab`.
- `AppController.updateSetupProgress(from:)` scrapes percentages from subprocess log lines
  as a fallback, but defers to byte polling whenever a real total is known
  (`setupTotalBytes != nil`) so the two don't fight.

### Surfacing failures

`setupErrorMessage` is rendered in both `OnboardingDialogView` and the `AITab`
local-model section (with a "Try again" button). A failure after onboarding must not be
silent — the AI tab is where post-onboarding local-model management lives.

## Local Runtime Request Coordination

`LocalModelRuntime` runs a single shared llama.cpp server process for all inference (monitoring and chat).

Two request counters gate concurrent access:

- `activeSharedServerRequests` — incremented for every in-flight server request (monitoring or chat)
- `activeInteractiveRequests` — incremented only for user-facing chat requests via `withInteractiveRequest { }`

When the server needs to be reconfigured (different model or capacity), `LocalModelRuntime` waits up to 60 seconds for `activeSharedServerRequests` to reach zero before stopping the old server. This prevents mid-request kills and double-RAM fallbacks.

`BrainService` reads `hasInteractiveRequestInFlight()` at the start of each monitoring tick and defers evaluation when a chat request is in flight (see monitoring-pipeline.md, "Deterministic Gates").

### Shared llama-server defaults

`LocalModelRuntime` keeps one shared `llama-server` alive for local monitoring and chat. The shared server is launched with a fixed performance-oriented flag set that does not participate in capacity reuse decisions:

- `-ngl 999` to offload all supported layers to Metal
- `--threads <perf-core-count>` where the count comes from `hw.perflevel0.physicalcpu` when available, else `ProcessInfo.processInfo.activeProcessorCount`
- `--cache-type-k q8_0`
- `--cache-type-v q8_0`

Prompt caching is enabled on every shared-server request via `cache_prompt: true`. AC currently uses a single shared slot and relies on the fact that the monitoring/system prompts are prefix-stable, so no explicit slot management is needed.

KV-cache quantization is a memory-saving tradeoff for local monitoring: q8 K/V materially lowers cache RAM pressure while keeping quality stable on the small Q4/Q5 local models AC targets for v1.0.

### Local prompt budgets

The default staged local runtime profile in `ACShared/ACPromptSets.swift` currently uses:

| Stage | ctxSize | batchSize | ubatchSize |
| --- | --- | --- | --- |
| `perception_vision` | 6144 | 2048 | 512 |
| `perception_title` | 2048 | 512 | 256 |
| `decision` | 3072 | 512 | 256 |
| `online_decision` | 3072 | 512 | 256 |
| `nudge_copy` | 2048 | 512 | 256 |
| `appeal_review` | 2048 | 512 | 256 |
| `policy_memory` | 3072 | 512 | 256 |
| `safelist_appeal` | 2048 | 768 | 384 |

The shared server therefore runs at the largest requested capacity (`ctxSize = 6144` for the vision stage) and smaller text stages reuse that server without forcing a restart.

### Prompt overflow guard

`PromptBudgetGuard` sits in front of local shared-server requests. It:

- estimates prompt size heuristically from text length plus vision tile count
- prefers preserving the rendered text payload intact: when the heuristic says a request is too large, AC first grows the per-request shared-server context budget (up to a bounded ceiling) instead of immediately trimming text
- on vision requests, progressively reduces the image max dimension before falling back to text truncation
- optionally calls `POST /tokenize` on the local `llama-server` when the heuristic is already close to the context limit
- only as a last resort, trims the user-prompt tail proportionally and verifies the reduced prompt once via `/tokenize`
- records `prompt_budget_truncated` telemetry/activity when truncation actually happens

If tokenization fails or times out, AC falls back to the heuristic path and continues the request rather than blocking inference.

## Monitoring Backend Selection

`MonitoringConfiguration.inferenceBackend` selects the backend:

- `.local`
- `.openRouter`

The current default is local inference.

When local inference is active and macOS Low Power Mode is on, `AppController` sets `localModelLowPowerNotice = true`. `ChatPanelView` renders this as a dismissible yellow banner. The notice auto-clears when either condition goes away and the dismissed state resets at that point so it reappears if the user re-enters the same condition.

Model selection is split by text vs image where supported:

- `onlineModelIdentifierText`
- `onlineModelIdentifierImage`
- `localModelIdentifierText`
- `localModelIdentifierImage`

`AITier` supplies the user-facing defaults.

## Limited Trial Redemption

The onboarding wizard includes an optional promo-code step before normal backend selection.

- A user without a code skips the step and follows the existing Local or BYOK setup flow.
- A valid code is redeemed through `PromoRedemptionService`, which contacts
  `https://accountycat.com/api/redeem` with the code and a random per-install identifier.
- The endpoint returns a capped OpenRouter key. AC saves that key using the same Keychain-backed
  BYOK credential path, switches to OpenRouter with the Balanced tier, and sends the user
  directly to permissions and completion.
- After activation, monitoring and chat traffic goes directly from AC to OpenRouter; it is not
  proxied through the AccountyCat site.
- The trial path is preserved through the permission-related app relaunch, and users can replace
  the trial key or switch to Local mode later in Settings -> AI.

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
- API keys live in macOS Keychain via `OnlineProviderCredentialStore`
- ZDR toggle lives in `UserDefaults` via `OnlineProviderRoutingStore`; on by default, opt-out via the AI tab's advanced section behind an explicit confirmation alert
- direct-OpenAI routing code exists in `OnlineProviderRouting` but its UI was removed from `AITab`; the toggle can be re-exposed if needed (see `docs/experiments/direct-openai-routing.md`)
- `ConnectivityService` provides a lightweight `NWPathMonitor`-backed reachability signal used by `BrainService` to pause online monitoring quickly when the machine is offline
- online monitoring may transiently use the online text-only pipeline after repeated vision timeouts, but this degradation lives only in `BrainService`; it does not rewrite `MonitoringConfiguration`

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

OpenRouter billing failures are not model reliability failures. A `402` (or a
provider response that clearly says the account/key has no credits, budget, or
balance) is surfaced as an OpenRouter budget problem, is not retried as a rate
limit, and does not count toward model bans. If every fallback candidate is
locally banned, AC keeps the original fallback chain so an external recovery
such as topping up credits can be observed without waiting for local ban expiry.
When key info later shows usable budget after a connection problem, AC clears
local OpenRouter bans and drops the cooldown.

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

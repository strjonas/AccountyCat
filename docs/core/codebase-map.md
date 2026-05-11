# Codebase Map

This is the practical map of the live codebase. Update it when major ownership seams move.

## High-Level Shape

The app has three main loops:

1. App/bootstrap loop
   `AC/ACApp.swift` and `AC/Core/AppController.swift`
2. Monitoring loop
   `AC/Core/BrainService.swift` driving `MonitoringAlgorithmRegistry` and `LLMMonitorAlgorithm`
3. Companion/support loops
   chat, memory consolidation, policy-memory updates, telemetry, and inspector replay

## Directory Map

### `AC/`

The shipping app target.

- `AC/ACApp.swift`
  App entry point, `AppDelegate`, menu bar item, orb/popover lifecycle.
- `AC/Core/`
  App orchestration and behavior seams.
- `AC/Models/`
  Persisted state, monitoring configuration, policy memory, focus profiles, chat models.
- `AC/Services/`
  IO and side-effect services: storage, screenshots, runtime setup, inference, logs, telemetry exports, calendar, permissions.
- `AC/UI/`
  SwiftUI views for the companion, chat, onboarding, overlays, stats, and settings.

### `ACShared/`

Shared code used by both `AC` and `ACInspector`.

- `ACShared/ACPromptSets.swift`
  Single source of truth for all prompt text and prompt rendering.
- `ACShared/AITier.swift`
  AI tier catalog and model defaults.
- `ACShared/Telemetry/`
  Telemetry event models, stats snapshots, and the file-backed telemetry store.

### `ACInspector/`

Local companion app for reading telemetry and replaying prompts.

- `InspectorController.swift`
  Inspector state, telemetry refresh loop, annotation flow, Prompt Lab orchestration.
- `TelemetryIndexStore.swift`
  Builds a queryable index over telemetry sessions.
- `PromptLabRunner.swift`
  Replays scenarios against selected prompt/runtime combinations.

### `ACTests/`

Unit tests, regression tests, and fixtures.

- `FakeRuntimeFixture.swift`
  Deterministic fake runtime for LLM-facing tests.
- `Goldens/`
  Golden JSON for prompt/output style regression coverage.

### Supporting folders

- `docs/`
  Onboarding and implementation references.
- `dev/agents/accountycat-debugger/`
  Runtime-debugging skill and triage references.
- `_Legacy/`
  Parked old implementations. Ignore.

## Ownership Seams

### App lifecycle and persisted state

- `AC/Core/AppController.swift`
- `AC/Services/StorageService.swift`
- `AC/Models/ACModels.swift`

If a change mutates settings, persisted state, chat side effects, setup status, onboarding state, profile activation, or UI wiring, start here.

### Monitoring and nudging

- `AC/Core/BrainService.swift`
- `AC/Core/MonitoringAlgorithm.swift`
- `AC/Core/LLMMonitorAlgorithm.swift`
- `AC/Core/CompanionPolicy.swift`
- `AC/Core/DistractionLadder.swift`
- `AC/Core/ExecutiveArm.swift`

This is the path from observed context to a user-visible nudge or overlay.

### Runtime, models, and provider routing

- `AC/Services/RuntimeSetupService.swift`
- `AC/Services/LocalModelRuntime.swift`
- `AC/Services/OnlineModelService.swift`
- `AC/Services/OnlineProviderRouting.swift`
- `ACShared/AITier.swift`
- `AC/Models/MonitoringModels.swift`

This area owns local setup, remote calls, model defaults, and the backend selection seam.

### Learning and memory

- `AC/Services/CompanionChatService.swift`
- `AC/Services/PolicyMemoryService.swift`
- `AC/Services/MemoryConsolidationService.swift`
- `AC/Services/SafelistPromotionService.swift`
- `AC/Models/PolicyMemoryModels.swift`
- `ACShared/MemoryEntry.swift`

This area is where AC learns user preferences, proposes or applies rules, and consolidates memory.

### Telemetry and debugging

- `ACShared/Telemetry/TelemetryStore.swift`
- `AC/Core/TelemetryAdapters.swift`
- `AC/Services/LLMTelemetryRecorder.swift`
- `AC/Services/ACDebugBundleService.swift`
- `ACInspector/*`

This is the main path for runtime debugging, Inspector views, and exported debug bundles.

## Current Runtime Flow

1. `AppDelegate` builds the UI shell and bootstraps `AppController`.
2. `AppController.bootstrap()` refreshes state, configures `BrainService`, and starts telemetry if applicable.
3. `BrainService` runs a periodic tick plus a faster context-change probe.
4. Each tick gathers context, heuristics, optional screenshot data, and policy/profile state.
5. `MonitoringAlgorithmRegistry` resolves `llm_monitor_v1`.
6. `LLMMonitorAlgorithm` decides whether to skip, stay silent, nudge, overlay, or abstain.
7. `CompanionPolicy` converts model output into a concrete `CompanionAction`.
8. `ExecutiveArm` renders the UI consequence.
9. `AppController` persists state, records chat/memory/policy side effects, and surfaces user feedback back into the system.

## Where To Edit Common Changes

| Change | Start here |
| --- | --- |
| App settings or onboarding | `AC/Core/AppController.swift`, `AC/UI/Settings/*`, `AC/UI/Onboarding*` |
| Monitoring cadence or heuristics | `AC/Models/MonitoringModels.swift`, `AC/Core/MonitoringHeuristics.swift`, `AC/Core/BrainService.swift` |
| Prompt wording or schemas | `ACShared/ACPromptSets.swift` |
| Rule learning or profile-scoped policy | `AC/Services/PolicyMemoryService.swift`, `AC/Models/PolicyMemoryModels.swift`, `AC/Core/AppController.swift` |
| Local runtime install or model download | `AC/Services/RuntimeSetupService.swift`, `AC/Services/DependencyInstallerService.swift`, `AC/UI/OnboardingDialogView.swift` |
| Online model failures or provider routing | `AC/Services/OnlineModelService.swift`, `AC/Services/OnlineProviderRouting.swift` |
| Telemetry/Inspector/debug bundles | `ACShared/Telemetry/TelemetryStore.swift`, `ACInspector/*`, `AC/Services/ACDebugBundleService.swift` |

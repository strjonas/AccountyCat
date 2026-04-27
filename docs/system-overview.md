# System Overview

AC currently ships with one active monitoring algorithm: `llm_monitor_v1`.

Older alternatives, including the legacy LLM path and the contextual bandit path, were moved out of the active targets into the repo-root [`_Legacy/`](../_Legacy/) folder. They are kept there as reference code in case work returns to them later, but they are intentionally excluded from the main build to reduce codebase clutter and avoid distracting future contributors and coding agents.

## Active path

The runtime flow is:

1. `AppController` owns persisted state, setup, and settings.
2. `BrainService` polls the current frontmost context and decides when evaluation is due.
3. `MonitoringAlgorithmRegistry` resolves the configured algorithm seam. In the current build it resolves only `llm_monitor_v1`.
4. `LLMMonitorAlgorithm` decides whether to skip, nudge, abstain, or escalate.
5. `ExecutiveArm` renders the resulting nudge or overlay.

## Key files

- [`AC/Core/AppController.swift`](../AC/Core/AppController.swift)
- [`AC/Core/BrainService.swift`](../AC/Core/BrainService.swift)
- [`AC/Core/MonitoringAlgorithm.swift`](../AC/Core/MonitoringAlgorithm.swift)
- [`AC/Core/LLMMonitorAlgorithm.swift`](../AC/Core/LLMMonitorAlgorithm.swift)
- [`AC/Models/MonitoringModels.swift`](../AC/Models/MonitoringModels.swift)
- [`AC/Models/LLMPolicyProfileModels.swift`](../AC/Models/LLMPolicyProfileModels.swift)
- [`AC/Services/PromptCatalog.swift`](../AC/Services/PromptCatalog.swift)
- [`ACShared/MonitoringPromptTuning.swift`](../ACShared/MonitoringPromptTuning.swift)

## Persistence and migration

- `MonitoringConfiguration.algorithmID` still exists so the selection seam remains extendible.
- Historical algorithm ids are normalized onto `llm_monitor_v1` during decode.
- `AlgorithmStateEnvelope` writes only the active `llmPolicy` slice, but its decoder still accepts older legacy keys so older state files continue to load safely.
- Telemetry still stores `algorithmID` and `algorithmVersion` so past sessions remain inspectable.

## Settings

The settings UI no longer exposes an algorithm picker. The active codebase is intentionally focused on the main LLM monitor while keeping the architecture extensible enough to add another algorithm back later if needed.

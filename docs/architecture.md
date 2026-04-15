# Architecture

This document describes the architecture that is implemented now, not a future design sketch.

## Goals

The monitoring stack is designed around four constraints:

1. Default behavior must stay conservative. False positives are worse than missed distractions.
2. The runtime loop should not need to change when trying a new monitoring algorithm.
3. Prompts should be explicit, versioned, and easy to inspect.
4. Telemetry should always say which algorithm and prompt profile produced a decision.

The current default path is:

- monitoring algorithm: `legacy_focus_v1`
- monitoring prompt profile: `focus_default_v2`

Those defaults are behavior-preserving wrappers around the pre-refactor implementation.

## Top-Level Layout

- `AC/`
  The main macOS app: menu bar UI, monitoring runtime, local chat, persistence, setup.
- `AC/Core/`
  Runtime orchestration and decision policy glue.
- `AC/Services/`
  Boundaries to external systems or specialized runtime helpers.
- `AC/Models/`
  Persistent app state and shared configuration models.
- `AC/Resources/Prompts/`
  Versioned prompt assets.
- `ACShared/Telemetry/`
  Shared telemetry models and storage used by both apps.
- `ACInspector/`
  Local telemetry inspector app. It builds a derived SQLite index from telemetry files for fast browsing.

The folder structure is intentionally simple. The main boundary is by responsibility, not by feature slice.

## Main Runtime

`BrainService` is the runtime coordinator.

File:
- [AC/Core/BrainService.swift](/Users/jonas/Code/AC/AC/AC/Core/BrainService.swift:12)

Responsibilities:

- run the observation timer
- react to session sleep/wake and active/inactive changes
- track idle resets and episode lifecycle
- capture snapshots
- discard stale decisions when the user switches context mid-evaluation
- dispatch visible UI actions through `ExecutiveArm`
- write telemetry around observations, evaluations, policy decisions, actions, and reactions

`BrainService` is intentionally not the place for algorithm-specific logic. It asks the selected monitoring algorithm what to evaluate and how to interpret the result, then executes the outcome.

## Monitoring Algorithm Seam

The pluggable seam is `MonitoringAlgorithm`.

File:
- [AC/Core/MonitoringAlgorithm.swift](/Users/jonas/Code/AC/AC/AC/Core/MonitoringAlgorithm.swift:10)

Key types:

- `MonitoringConfiguration`
  Which algorithm and monitoring prompt profile are selected.
- `MonitoringDecisionInput`
  The full input handed to one algorithm evaluation.
- `MonitoringDecisionResult`
  The algorithm output: execution metadata, raw LLM evaluation, parsed decision, policy result, updated algorithm state.
- `MonitoringAlgorithmRegistry`
  Resolves an algorithm from configuration and exposes available algorithms for debug UI.

### Default Algorithm

The current production behavior is wrapped in:

- [AC/Core/LegacyMonitoringAlgorithm.swift](/Users/jonas/Code/AC/AC/AC/Core/LegacyMonitoringAlgorithm.swift:10)

This algorithm preserves the existing ladder-based flow:

- wait for stable context
- allow periodic visual checks from heuristics
- call the monitoring LLM client
- update distraction ladder state
- pass the decision into `CompanionPolicy`

If you want to add a new algorithm later, do not edit `BrainService` first. Implement `MonitoringAlgorithm`, register it in `MonitoringAlgorithmRegistry`, and add an algorithm-specific state slice if needed.

### Algorithm State

Per-algorithm state lives in `AlgorithmStateEnvelope`.

File:
- [AC/Models/MonitoringModels.swift](/Users/jonas/Code/AC/AC/AC/Models/MonitoringModels.swift:10)

Current slices:

- `legacyFocus`
  Holds the distraction ladder state and last periodic visual-check timestamps.

Shared user state still lives in `ACState`:

- recent actions
- recent app switches
- usage by day
- memory
- chat history

That split is intentional:

- shared state is user/session-facing
- algorithm state is replaceable implementation detail

`ACState.resetAlgorithmProfile()` clears adaptive data and algorithm state, but preserves the selected algorithm and prompt profile.

## LLM and Prompt Architecture

The old single `LLMService` has been split into smaller services.

### Runtime Boundary

- [AC/Services/LocalModelRuntime.swift](/Users/jonas/Code/AC/AC/AC/Services/LocalModelRuntime.swift:15)

This file only knows how to run `llama.cpp` processes for vision and text inference. It does not know anything about monitoring policy.

### Monitoring Inference

- [AC/Services/MonitoringLLMClient.swift](/Users/jonas/Code/AC/AC/AC/Services/MonitoringLLMClient.swift:58)

This service owns:

- monitoring prompt rendering
- prompt fallback flow
- runtime invocation for monitoring
- strict JSON parsing into `LLMDecision`
- prompt template metadata and SHA capture

### Chat and Memory

- [AC/Services/CompanionChatService.swift](/Users/jonas/Code/AC/AC/AC/Services/CompanionChatService.swift:10)
- [AC/Services/MemoryService.swift](/Users/jonas/Code/AC/AC/AC/Services/MemoryService.swift:10)

These services are separate because they are not part of the monitoring algorithm experiment surface.

### Prompt Catalog

- [AC/Services/PromptCatalog.swift](/Users/jonas/Code/AC/AC/AC/Services/PromptCatalog.swift:30)

Prompt assets live under:

- `AC/Resources/Prompts/Monitoring/<profile>/...`
- `AC/Resources/Prompts/Chat/...`
- `AC/Resources/Prompts/Memory/...`

Important rule:

- monitoring prompt profiles are experiment-selectable
- chat and memory prompts are centralized and versioned, but not selectable in the debug experiment surface yet

## Telemetry

Shared telemetry lives in:

- [ACShared/Telemetry/TelemetryModels.swift](/Users/jonas/Code/AC/AC/ACShared/Telemetry/TelemetryModels.swift:194)
- [ACShared/Telemetry/TelemetryStore.swift](/Users/jonas/Code/AC/AC/ACShared/Telemetry/TelemetryStore.swift:544)

Each evaluation/policy/action may carry:

- `algorithmID`
- `algorithmVersion`
- `promptProfileID`
- `experimentArm`

Training export also distinguishes:

- short-term outcome labels
- long-term outcome labels

This is deliberate preparation for future algorithm comparison. The runtime does not yet perform automatic assignment or online bandit learning.

## Inspector

`ACInspector` is a read/write local analysis app for telemetry episodes.

Important files:

- [ACInspector/TelemetryIndexStore.swift](/Users/jonas/Code/AC/AC/ACInspector/TelemetryIndexStore.swift:11)
- [ACInspector/InspectorController.swift](/Users/jonas/Code/AC/AC/ACInspector/InspectorController.swift:12)
- [ACInspector/ACInspectorApp.swift](/Users/jonas/Code/AC/AC/ACInspector/ACInspectorApp.swift:12)

The inspector does not read telemetry JSONL files directly on every UI render. Instead it rebuilds a derived SQLite index from the telemetry store. That keeps the UI responsive and makes future filtering/search easier.

The SQLite index is disposable. If the schema changes, it may be migrated or rebuilt from telemetry files.

## Debug Selection

Debug-only controls for algorithm and monitoring prompt profile live in:

- [AC/Core/AppController.swift](/Users/jonas/Code/AC/AC/AC/Core/AppController.swift:146)
- [AC/ContentView.swift](/Users/jonas/Code/AC/AC/AC/ContentView.swift:305)

This is intentionally not the normal end-user product surface yet. The current use case is internal evaluation and prompt/algorithm iteration.

## How To Add a New Monitoring Algorithm

1. Add an algorithm state slice to `AlgorithmStateEnvelope` if the algorithm needs persistent per-user state.
2. Implement `MonitoringAlgorithm`.
3. Register it in `MonitoringAlgorithmRegistry`.
4. Return a `MonitoringAlgorithmDescriptor` with a stable `id` and explicit `version`.
5. Ensure the algorithm returns `MonitoringExecutionMetadata` so telemetry stays attributable.
6. Add focused regression tests for the algorithm behavior.
7. Optionally expose it in the debug selector via the registry.

What should not change for a new algorithm:

- `BrainService` timer/orchestration flow
- snapshot capture path
- telemetry lifecycle
- UI action dispatch

## How To Add a New Monitoring Prompt Profile

1. Add prompt files under `AC/Resources/Prompts/Monitoring/<profile>/`.
2. Register the profile in `PromptCatalog`.
3. Give it a stable profile id and version.
4. Use the debug selector or config to switch the active profile.
5. Confirm telemetry records the selected profile.

Do not scatter monitoring prompt strings through service code. `PromptCatalog` is the single source of truth.

## Current Tradeoffs

- `BrainService` is still a large coordinator. That is acceptable for now because the coordinator boundary is clear and the decision logic is no longer mixed into it.
- `ACInspector/` is still a flat folder. That is acceptable while the inspector remains small.
- Only monitoring algorithms are pluggable today. Chat and memory prompt/versioning are centralized, but they are not part of the first experiment-selection surface.

## Guiding Principle

When unsure, do less.

The monitoring system should be easy to extend, but the default runtime should remain conservative, explainable, and attributable. A future developer should be able to answer these questions quickly:

- which algorithm made this decision?
- which prompt profile did it use?
- where is that prompt defined?
- where does that algorithm store its state?
- what telemetry will let me compare it to another approach?

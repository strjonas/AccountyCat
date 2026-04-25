# AC System Overview

This document reflects the current shipped architecture in the repo as of April 2026. It is the single canonical architecture reference — start here.

The monitoring stack now has three production algorithms behind one seam:

- `llm_monitor_v1`: default. Current staged LLM monitor with structured policy memory, combined image-plus-title perception, split decision/copy, and typed soft appeals.
- `llm_focus_legacy_v1`: legacy conservative LLM path. It now runs screenshot-to-description first, then a text-only decision step through the old ladder/policy gates.
- `bandit_focus_v1`: contextual bandit path. Vision extraction plus LinUCB action selection.

`legacy_focus_v1`, `llm_focus_v1`, and `llm_policy_v1` still decode from persisted state, but they are normalized to the clearer runtime ids above.

## 1. Runtime Architecture

```mermaid
flowchart TB
    subgraph Entry["Entry / Lifecycle"]
        ACApp["ACApp.swift"]
        AppCtrl["AppController"]
        Store["StorageService<br/>state.json"]
    end

    subgraph Runtime["Monitoring Runtime"]
        Brain["BrainService<br/>10s tick"]
        Registry["MonitoringAlgorithmRegistry"]
        Exec["ExecutiveArm"]
        Snap["SnapshotService"]
    end

    subgraph Algorithms["Algorithms"]
        PolicyAlgo["LLMMonitorAlgorithm<br/>default"]
        FocusAlgo["LegacyLLMFocusAlgorithm<br/>legacy conservative"]
        BanditAlgo["BanditMonitoringAlgorithm"]
    end

    subgraph LLMServices["LLM Services"]
        RuntimeLLM["LocalModelRuntime<br/>llama.cpp subprocess"]
        LegacyClient["MonitoringLLMClient<br/>legacy 2-step eval"]
        PolicyMem["PolicyMemoryService"]
        Extractor["ScreenStateExtractorService"]
        Copywriter["NudgeCopywriterService"]
        Prompts["PromptCatalog"]
    end

    subgraph State["State / Telemetry"]
        ACState["ACState"]
        AlgoState["AlgorithmStateEnvelope"]
        PolicyState["PolicyMemory"]
        Telemetry["TelemetryStore"]
    end

    subgraph UI["UI"]
        Win["WindowCoordinator"]
        Nudge["NudgeView"]
        Overlay["OverlayView"]
        Content["ContentView / Chat"]
    end

    ACApp --> AppCtrl
    AppCtrl --> Store
    AppCtrl --> Brain
    Brain --> Snap
    Brain --> Registry
    Brain --> Exec
    Brain --> Telemetry
    AppCtrl --> ACState
    ACState --> AlgoState
    ACState --> PolicyState

    Registry --> PolicyAlgo
    Registry --> FocusAlgo
    Registry --> BanditAlgo

    FocusAlgo --> LegacyClient
    LegacyClient --> RuntimeLLM
    PolicyAlgo --> RuntimeLLM
    PolicyAlgo --> PolicyMem
    PolicyMem --> RuntimeLLM
    BanditAlgo --> Extractor
    BanditAlgo --> Copywriter
    Extractor --> RuntimeLLM
    Copywriter --> RuntimeLLM

    LegacyClient --> Prompts
    PolicyAlgo --> Prompts
    PolicyMem --> Prompts
    Extractor --> Prompts
    Copywriter --> Prompts

    Exec --> Win
    Win --> Nudge
    Win --> Overlay
    Win --> Content
```

## 2. Main Tick Flow

```mermaid
sequenceDiagram
    autonumber
    participant Timer as Tick timer (10s)
    participant Brain as BrainService
    participant Snap as SnapshotService
    participant Reg as MonitoringAlgorithmRegistry
    participant Algo as Selected Algorithm
    participant LLM as LocalModelRuntime
    participant Exec as ExecutiveArm
    participant UI as WindowCoordinator
    participant Tele as TelemetryStore

    Timer->>Brain: tick()
    Brain->>Snap: frontmostContext() + idleSeconds()
    Brain->>Reg: noteContext(...)
    Brain->>Reg: evaluationPlan(...)
    alt shouldEvaluate == true
        Brain->>Snap: capture screenshot only if plan.requiresScreenshot
        Brain->>Tele: observation + evaluation request
        Brain->>Algo: evaluate(input)
        Algo->>LLM: 1..N stage calls
        LLM-->>Algo: raw stdout/stderr
        Algo-->>Brain: decision + action + updated state
        Brain->>Tele: model input/output + parsed output + policy + action
        Brain->>Exec: perform(action)
        Exec->>UI: show nudge or overlay
    else
        Brain->>Brain: stay quiet and continue watching
    end
```

Important runtime behavior:

- Two timers run in parallel: a 10s tick timer drives `tick()` (full evaluation pipeline) and a 2s context-probe timer drives `probeForContextChange()` (cheap front-app/title checks that can promote a tick early). Both intervals live as constants on `BrainService`.
- `BrainService` does not branch on algorithm id. It asks the selected algorithm for an evaluation plan, then builds a snapshot only if needed.
- Screenshot capture is profile-aware. Title-only policy profiles do not capture screenshots.
- Telemetry records the effective algorithm, prompt profile, pipeline profile, and runtime profile in `MonitoringExecutionMetadata`.

## 3. Algorithms

### 3.1 `llm_monitor_v1` (default)

This is the current primary production path.

Pipeline stages:

1. `perception_vision` using the screenshot plus app/title context
2. `decision`
3. `nudge_copy` (optional, only when the decision chose `nudge` and the profile uses split copy)
4. `appeal_review`
5. `policy_memory` updates for explicit and implicit feedback paths

Deterministic rails still exist, but they are intentionally small:

- obvious productive shortcuts
- stable-context gating
- explicit recheck scheduling after each result
- stale-context discard
- permission gating

The model owns semantic interpretation and primary action choice. Deterministic code only enforces safety and anti-spam.

Focused decisions now schedule a long follow-up instead of re-triggering every poll, and explicit `allow` rules can suppress re-evaluation the same way obviously productive contexts do.

### 3.2 `llm_focus_legacy_v1`

This is the conservative legacy LLM path. It now uses a two-step structure:

1. screenshot -> concise activity description
2. text-only decision over that description plus memory, recent interventions, heuristics, and distraction state

After that, the old deterministic gates still apply:

- `DistractionLadder`
- `CompanionPolicy`

So this path is still not fully “LLM controls everything”. It is useful as a baseline and fallback comparison mode.

### 3.3 `bandit_focus_v1`

This path remains separate from the policy LLM.

Flow:

1. screenshot -> structured screen-state extraction
2. contextual bandit selects an arm
3. optional text-only nudge copy generation

The bandit still cannot directly reason over raw free-text user policy updates the way the policy LLM can. It learns from explicit and implicit reward signals on executed actions.

## 4. Shared State

### 4.1 `ACState`

Relevant fields now are:

- `monitoringConfiguration`
- `memory`: free-form chat/persona memory
- `policyMemory`: structured rules used by policy decisions and appeals
- `recentActions`
- `recentSwitches`
- `usageByDay`
- `algorithmState`

### 4.2 `AlgorithmStateEnvelope`

Per-algorithm slices:

- `llmFocus`
- `llmPolicy`
- `banditFocus`

`llmPolicy` now holds:

- current distraction state
- current context tracking
- last intervention timestamps
- recent nudge messages
- active typed appeal session metadata

### 4.3 `PolicyMemory`

Structured policy memory is separate from free-form memory.

It stores rules such as:

- allow / discourage / disallow / limit
- app and title scope
- time window / expiry
- allowed topics
- disallowed topics
- daily minute limit
- tone preference
- rule source and timestamps

The monitoring pipeline consumes a deterministic monitoring summary of active matching rules. The free-form chat memory is still preserved, but it is not the primary monitoring policy store anymore.

## 5. Monitoring Configuration

`MonitoringConfiguration` now carries:

- `algorithmID`
- `promptProfileID`
- `pipelineProfileID`
- `runtimeProfileID`
- `selectionMode`
- optional `experimentArmOverride`

Defaults:

- algorithm: `llm_monitor_v1`
- pipeline: `vision_split_default`
- runtime: `gemma_balanced_v1`

Legacy note:

- `promptProfileID` is mainly relevant to the legacy `llm_focus_legacy_v1` path.
- `pipelineProfileID` and `runtimeProfileID` drive `llm_monitor_v1`.

## 6. Pipeline Profiles

Current policy pipeline profiles:

- `vision_split_default`
- `title_only_default`
- `vision_single_call`
- `title_split_copy`

The main difference between them is whether screenshot perception is used and whether decision and nudge copy are split.

Permission impact:

- title-only profiles need Accessibility, but not Screen Recording
- vision-backed profiles need both Accessibility and Screen Recording

## 7. Runtime Profiles

Runtime profiles now define stage-specific `llama.cpp` options:

- model identifier
- max tokens
- temperature
- top-p
- top-k
- ctx-size
- batch size
- ubatch size
- timeout

Current built-in presets:

- `gemma_balanced_v1`
- `gemma_low_ram_v1`
- `llama_experiment_v1`

The balanced and llama presets now use larger context windows for the perception and decision stages than the previous implementation, because the staged prompts and policy context were overrunning smaller windows.

## 8. Prompting

### 8.1 Policy prompts

The current policy prompts are intentionally shorter than the first staged implementation, but more specific in the perception stages.

The perception prompts now explicitly ask for:

- what the user is doing right now
- which page / topic / video / conversation when visible
- whether they are scrolling, typing, replying, researching, watching, or coding

That means outputs should say things like:

- “Watching a YouTube SwiftUI state-management tutorial”
- “Scrolling Instagram Reels”
- “Replying in LinkedIn messages”
- “Reviewing a GitHub PR diff”

instead of generic summaries like “using Chrome”.

### 8.2 Legacy prompts

`llm_focus_legacy_v1` now shares the same style of screenshot perception prompt for the first step, then runs a shorter text-only decision prompt over the extracted description.

## 9. Appeals and Overlay

Overlay actions now carry an `OverlayPresentation` payload instead of a bare enum case.

That payload contains:

- headline
- body
- typed appeal prompt
- submit button title
- secondary button title
- evaluation id

Soft typed escalation flow:

1. decision stage chooses `overlay`
2. overlay asks for a typed justification
3. `appeal_review` returns `allow`, `deny`, or `defer`
4. `deny` stays soft in v1: the overlay remains and guidance is shown, but there is no hard enforcement loop

## 10. Telemetry

Telemetry now captures enough metadata to replay staged runs:

- observation
- evaluation request
- prompt payloads
- rendered prompts
- raw model outputs
- parsed outputs
- policy decision
- executed action
- user reactions
- annotations

For policy runs, telemetry also stores the effective:

- `promptProfileID`
- `pipelineProfileID`
- `runtimeProfileID`
- `experimentArm`

## 11. Inspector / Prompt Lab

`ACInspector` now has two tabs:

- episode browser
- Prompt Lab

Prompt Lab supports:

- telemetry-backed scenarios
- synthetic editable scenarios
- stage-by-stage prompt editing
- pipeline/runtime matrix replay
- side-by-side stage outputs
- per-result human annotations

Prompt Lab state is now persisted under the inspector support directory, so scenarios, prompt edits, run results, and replay annotations survive relaunches.

Prompt Lab is inspector-local on purpose:

- it reuses shared telemetry types
- it mirrors the production staged pipeline concepts
- it does not directly depend on the app target

## 12. First-Run Setup Flow

On first launch AC has nothing useful locally — no runtime, no model, and no permissions. The onboarding card in the Home tab walks the user through the whole sequence. Everything stays on-device.

```mermaid
flowchart TB
    Launch["App launch"] --> Inspect["RuntimeSetupService.inspect()"]
    Inspect --> Perms{"Permissions<br/>granted?"}
    Perms -- "no" --> AskPerms["Screen Recording + Accessibility<br/>(runtime requests)"]
    AskPerms --> Perms
    Perms -- "yes" --> Tools{"git, cmake, ninja<br/>installed?"}
    Tools -- "no" --> InstallTools["DependencyInstallerService<br/>(Homebrew)"]
    InstallTools --> Tools
    Tools -- "yes" --> DiskCheck["RuntimeSetupService.verifyFreeDiskSpace<br/>(≥ 6 GB required)"]
    DiskCheck --> Build["installRuntime: git clone + cmake build<br/>of pinned llama.cpp commit"]
    Build --> Cleanup["cleanupInterruptedDownloads<br/>(HF cache)"]
    Cleanup --> WarmUp["warmUpRuntime: llama-cli -hf<br/>pulls model + runs 8-token warm prompt"]
    WarmUp --> Ready["setupStatus = .ready<br/>→ BrainService.start() ticks"]
    Ready --> Banner["OnboardingDialogView<br/>shows 'Setup complete' for 5s"]
```

Key properties:

- **Pinned commit**: `RuntimeSetupService.pinnedLlamaCommit` pins llama.cpp so the same binary ships for every user. Bumping the commit is an explicit code change.
- **Disk space check**: `verifyFreeDiskSpace` refuses to start an install with less than `requiredFreeBytesForInstall` (6 GB) on the target volume. Both `installRuntime` and `warmUpRuntime` call it.
- **Resume story**: llama.cpp's `-hf` downloader does not reliably resume. On every `warmUpRuntime` attempt AC first calls `cleanupInterruptedDownloads` to delete stale `*.incomplete` / `*.partial` / `*.tmp` / `*.downloading` files older than 60s, so a retry starts from a clean slate rather than tripping over a truncated blob.
- **Progress surfacing**: `AppController.updateSetupProgress` only treats a `\d{1,3}%` match as real progress if the line also contains one of `download`, `fetch`, `pull`, `resolving`, `receiving`, `loading model`, `loading weights`, `load_tensors`, `warming`, or `warm up`. This avoids cmake/llama.cpp percentage noise from unrelated output jittering the progress bar.
- **Error surfacing**: `runStreaming` keeps a rolling 40-line stderr tail for each subprocess. `RuntimeSetupError.commandFailed` wraps this in a user-friendly message — e.g. `git clone` failures become "Couldn't download the llama.cpp runtime. Check your internet connection and try again."
- **Completion signal**: when `setupStatus` transitions to `.ready`, `AppController` sets `showingOnboardingCompletion = true` for 5 seconds. `ContentView` keeps the onboarding card mounted during that window and `OnboardingDialogView` shows a green "Setup complete — AC is now watching." banner, so the user gets an explicit "done" signal rather than the card silently vanishing.
- **Stale server cleanup**: `LocalModelRuntime.killStalePIDIfNeeded` reads `~/Library/Application Support/AC/llama-server.pid` on launch, verifies the PID still points at a `llama-server` process, and kills it. This catches llama-server orphans left behind by a crash or force-quit during a previous session.

### 12.1 Model caching

AC uses `llama.cpp`'s `-hf` flag to pull GGUF models directly from Hugging Face. The cache is rooted at:

```
~/Library/Application Support/AC/runtime/hf-cache
```

via the `HF_HOME` environment variable. Inspection also walks two fallback roots so previously-downloaded models are reused without a fresh pull:

- `$HF_HOME/hub/models--<org>--<name>/…` if `HF_HOME` is exported in the user's shell
- `~/.cache/huggingface/hub/models--<org>--<name>/…` (standard `huggingface_hub` default)

`hasModelArtifacts` considers the cache populated when the newest snapshot directory contains at least one non-`mmproj` `.gguf` whose basename matches the requested quantisation (e.g. `:Q4_0`).

### 12.2 Directory structure

- `AC/` — main macOS app target. Subdivided into `Core/` (orchestration + algorithms), `Services/` (LLM runtime, storage, snapshot, calendar, permissions, etc.), `Models/` (Codable state types), `UI/` (SwiftUI views + window coordinator), and `Resources/Prompts/` (versioned prompt assets loaded by `PromptCatalog`).
- `ACShared/` — types shared between the app and the inspector (telemetry payloads, monitoring configuration, `DevelopmentModelConfiguration`, structured-output JSON parsing).
- `ACInspector/` — standalone debugging / replay tool (Prompt Lab, episode browser). Does not depend on the app target.
- `ACTests/` — unit tests for algorithms, services, telemetry, and prompt rendering. `ACUITests/` is a thin UI-test target placeholder.
- `Config/` — shared `.xcconfig` files. `Config/LocalOverrides.xcconfig` is gitignored and the place to put your dev team / signing identity.
- `docs/` — `system-overview.md` is the only doc and the entry point.

## 13. Files to Start With

If you are tracing the current architecture, start here:

- [AC/Core/AppController.swift](../AC/Core/AppController.swift) — app-wide state, setup orchestration, onboarding transitions
- [AC/Services/RuntimeSetupService.swift](../AC/Services/RuntimeSetupService.swift) — disk-space check, install, warm-up, error wrapping
- [AC/Services/LocalModelRuntime.swift](../AC/Services/LocalModelRuntime.swift) — llama.cpp subprocess + HF cache + stale-server cleanup
- [AC/UI/OnboardingDialogView.swift](../AC/UI/OnboardingDialogView.swift) — first-run checklist + completion banner
- [ACShared/DevelopmentModelConfiguration.swift](../ACShared/DevelopmentModelConfiguration.swift) — model identifier + `AC_MODEL_IDENTIFIER` override
- [AC/Core/BrainService.swift](../AC/Core/BrainService.swift)
- [AC/Core/MonitoringAlgorithm.swift](../AC/Core/MonitoringAlgorithm.swift)
- [AC/Core/LLMMonitorAlgorithm.swift](../AC/Core/LLMMonitorAlgorithm.swift)
- [AC/Core/LegacyLLMFocusAlgorithm.swift](../AC/Core/LegacyLLMFocusAlgorithm.swift)
- [AC/Core/BanditMonitoringAlgorithm.swift](../AC/Core/BanditMonitoringAlgorithm.swift)
- [AC/Models/MonitoringModels.swift](../AC/Models/MonitoringModels.swift)
- [AC/Models/LLMPolicyProfileModels.swift](../AC/Models/LLMPolicyProfileModels.swift)
- [AC/Models/PolicyMemoryModels.swift](../AC/Models/PolicyMemoryModels.swift)
- [AC/Services/MonitoringLLMClient.swift](../AC/Services/MonitoringLLMClient.swift)
- [AC/Services/PolicyMemoryService.swift](../AC/Services/PolicyMemoryService.swift)
- [AC/Services/PromptCatalog.swift](../AC/Services/PromptCatalog.swift)
- [ACInspector/InspectorController.swift](../ACInspector/InspectorController.swift)
- [ACInspector/PromptLabModels.swift](../ACInspector/PromptLabModels.swift)
- [ACInspector/PromptLabRunner.swift](../ACInspector/PromptLabRunner.swift)

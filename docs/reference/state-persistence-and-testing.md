# State, Persistence, and Testing

This doc covers what AC persists, where it persists it, and how tests stay isolated.

## Primary Files

- `AC/Core/AppController.swift`
- `AC/Core/AppController+ConversationLearning.swift`
- `AC/Core/AppController+Interventions.swift`
- `AC/Core/AppController+Profiles.swift`
- `AC/Core/AppController+RuntimeSetup.swift`
- `AC/Models/ACModels.swift`
- `AC/Models/MonitoringModels.swift`
- `AC/Models/PolicyMemoryModels.swift`
- `AC/Services/StorageService.swift`
- `AC/Services/ActivityLogService.swift`
- `ACShared/Telemetry/TelemetryStore.swift`
- `ACTests/FakeRuntimeFixture.swift`

## Persisted State

`ACState` is the main persisted app snapshot.

It currently holds:

- UI preferences and character/skin state
- setup status and permissions
- goals and user name
- monitoring configuration and algorithm state
- recent actions, switches, and focus segments
- memory entries and consolidation metadata
- structured policy memory
- chat history
- calendar-intelligence configuration
- focus profiles and active profile id
- hard escalation state
- scheduled actions and recurring nudges
- recently ended session context
- proposed changes and recent behavioral signals

`AppController` and its focused extensions are the main mutation surface for this state.

## Disk Locations

AC stores data under `~/Library/Application Support/AC`.

Important paths:

- state file: `state.json`
- storage backup: `state.json.backup`
- activity log: `logs/activity.log`
- telemetry root: `telemetry/`
- Inspector support: `inspector/`
- runtime install: `runtime/`
- debug bundles: `debug-bundles/`

API keys do not live in `state.json`; they live in macOS Keychain.

## Migrations and Normalization

`ACState` and `MonitoringConfiguration` both normalize older persisted shapes.

Examples:

- historical monitoring algorithm ids decode to `llm_monitor_v1`
- old single-string memory is upgraded into `MemoryEntry` rows
- legacy chat history shapes are upgraded
- missing default profile is repaired on decode
- stale proposed changes / recent behavioral signals are pruned on load
- temporary fake runtime overrides are stripped during decode

When changing persisted models, keep decode-time migration logic instead of assuming a clean slate.

## Testing Rules

- Never use `AppController.shared` in tests.
- Never use `StorageService()` in tests.
- Use `AppController.makeForTesting(storageService: .temporary())`.
- Use `StorageService.temporary()` for isolated persistence.
- Use `FakeRuntimeFixture` for deterministic LLM-facing tests.

The real default storage path is the user's actual state file, so test isolation is non-optional.

Also avoid to trigger permission requests or keychain access in tests.

Tests use `CODE_SIGNING_ALLOWED=NO`, which produces an ad-hoc binary. macOS TCC keys Screen Recording and Accessibility grants to the binary's code signature, so ad-hoc test builds do not inherit those grants. This is fine because tests mock capture calls (`BrainService.screenshotCapture`) and runtime providers (`FakeRuntimeFixture`). The live app should always run with proper signing (via Xcode's Run action, which uses `LocalOverrides.xcconfig`).

## Useful Test Areas

- `LLMMonitorAlgorithmTests.swift`
- `BrainServiceConfigurationTests.swift`
- `BrainServiceTelemetryTests.swift`
- `MonitoringPromptModeTests.swift`
- `PolicyMemoryProposalTests.swift`
- `SafelistPromotionTests.swift`
- `SnapshotServiceTests.swift`
- `OnlineModelServiceTests.swift`
- `StorageServiceTests.swift`
- `AgentDebugBundleTests.swift`
- `StabilityLifecycleTests.swift`

## Build / Test Commands

```bash
xcodebuild test -project AC.xcodeproj -scheme AC -destination 'platform=macOS' -only-testing:ACTests CODE_SIGNING_ALLOWED=NO
xcodebuild build -project AC.xcodeproj -scheme ACInspector CODE_SIGNING_ALLOWED=NO
```

## Xcode Test Runner Hygiene

Avoid overlapping `xcodebuild test` runs. The macOS test host is `AC.app`, and interrupted runs can leave `xcodebuild`, `debugserver`, or the `AC.app` test host alive while XCTest is still finalizing logs. Starting another run in that state can make the next run look hung or can report the in-flight test as canceled.

If a run appears stuck after tests have mostly finished:

1. Check for stale runners:
   ```bash
   pgrep -fl "xcodebuild|debugserver|AC.app|xctest"
   ```
2. If those processes belong to an interrupted test run, stop them before rerunning:
   ```bash
   kill -TERM <pid>
   ```
3. Inspect the `.xcresult` summary before assuming a code failure:
   ```bash
   xcrun xcresulttool get test-results summary --path <path-to-xcresult>
   ```

A `Testing was canceled` failure on the last in-flight test after manually interrupting `xcodebuild` is runner state, not necessarily a product regression. Rerun the named test directly, then rerun the full `ACTests` command once the process list is clean.

## If You Change This Area

- Think about migration from existing `state.json` files.
- Avoid writing test-only paths or fake runtime overrides into real persisted state.
- Keep backups/restoration behavior in `StorageService`.
- Update docs when persisted ownership moves enough that the next engineer would look in the wrong place.

# State, Persistence, and Testing

This doc covers what AC persists, where it persists it, and how tests stay isolated.

## Primary Files

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

`AppController` is the main mutation surface for this state.

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
- temporary fake runtime overrides are stripped during decodegit 

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

## If You Change This Area

- Think about migration from existing `state.json` files.
- Avoid writing test-only paths or fake runtime overrides into real persisted state.
- Keep backups/restoration behavior in `StorageService`.
- Update docs when persisted ownership moves enough that the next engineer would look in the wrong place.

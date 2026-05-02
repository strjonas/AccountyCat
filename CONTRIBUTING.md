# Contributing

## Before opening a PR

Copy `Config/LocalOverrides.xcconfig.example` to `Config/LocalOverrides.xcconfig` and fill in your bundle ID prefix and development team. That file is gitignored.

Run the unit tests:

```bash
xcodebuild test -project AC.xcodeproj -scheme AC -destination 'platform=macOS' -only-testing:ACTests CODE_SIGNING_ALLOWED=NO
```

If you touch the inspector, also build it:

```bash
xcodebuild build -project AC.xcodeproj -scheme ACInspector CODE_SIGNING_ALLOWED=NO
```

## Where to look

- Architecture overview: [`docs/system-overview.md`](docs/system-overview.md). Start there before touching anything non-trivial.
- First-run / setup flow: `AC/Core/AppController.swift`, `AC/Services/RuntimeSetupService.swift`, `AC/Services/LocalModelRuntime.swift`, `AC/UI/OnboardingDialogView.swift`.
- Active monitoring path: `AC/Core/BrainService.swift`, `AC/Core/MonitoringAlgorithm.swift`, and `AC/Core/LLMMonitorAlgorithm.swift`.
- Parked alternatives: repo-root [`_Legacy/`](_Legacy). Those files are intentionally out of the active build while work stays focused on the main monitor.

## Changing the setup / first-run experience

AC's first run does a lot of work: permission prompts, tool install, llama.cpp clone + build, model download, warm-up, readiness polling. If you touch any of it, please keep:

- a disk-space check before anything that writes >1 GB (`RuntimeSetupService.verifyFreeDiskSpace`),
- partial-download cleanup on retry (`cleanupInterruptedDownloads`),
- a user-readable error on subprocess failure (don't let raw `git clone` or `cmake` errors leak through),
- an explicit "done" signal for the user when setup completes.

When in doubt, test on a clean macOS environment (VM or a fresh user account) with no llama.cpp checkout and no HF cache.

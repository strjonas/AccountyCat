# Contributing

Small, focused pull requests are preferred.

## Ground rules

- Don't weaken the local-first privacy model without a conversation first.
- Changes around monitoring and permissions should be conservative — when in doubt, do less.
- Clear code over clever abstractions. Short docs over exhaustive ones.
- Add or update tests when behavior changes.
- Keep prompts and UX copy short — AC should say as little as possible.

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

## Testing with a different model

The shipped build is pinned to one model (`unsloth/gemma-4-E2B-it-GGUF:Q4_0`). For development you can swap it by exporting `AC_MODEL_IDENTIFIER` before launching AC:

```bash
AC_MODEL_IDENTIFIER="unsloth/Qwen3-4B-GGUF:Q4_0" open -a AC
```

Caveats:

- The output-parsing logic in `AC/Services/LLMOutputParsing.swift` is tuned for Gemma. Qwen and Phi currently need their own parsing tweaks — see the notes in [`ACShared/DevelopmentModelConfiguration.swift`](ACShared/DevelopmentModelConfiguration.swift).
- Multimodal projector support varies between model families; the Phi GGUFs on the hub are text-only variants at the time of writing.

## Changing the setup / first-run experience

AC's first run does a lot of work: permission prompts, tool install, llama.cpp clone + build, model download, warm-up, readiness polling. If you touch any of it, please keep:

- a disk-space check before anything that writes >1 GB (`RuntimeSetupService.verifyFreeDiskSpace`),
- partial-download cleanup on retry (`cleanupInterruptedDownloads`),
- a user-readable error on subprocess failure (don't let raw `git clone` or `cmake` errors leak through),
- an explicit "done" signal for the user when setup completes.

When in doubt, test on a clean macOS environment (VM or a fresh user account) with no llama.cpp checkout and no HF cache.

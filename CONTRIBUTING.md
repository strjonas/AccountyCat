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

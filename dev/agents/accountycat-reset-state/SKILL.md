---
name: accountycat-reset-state
description: Reset AccountyCat on a Mac as close as possible to a fresh install without touching unrelated data. Use when the user wants AC wiped "like never installed", wants old OpenRouter/OpenAI credentials removed from Keychain, wants local state/logs/runtime/telemetry deleted, or wants AC-specific preferences, caches, containers, and privacy grants cleared before testing a release build.
---

# AccountyCat Reset State

Use this skill for destructive local cleanup of AC-owned macOS state. This is the "fresh install" reset path.

It removes:

- `~/Library/Application Support/AC` including state, logs, telemetry, debug bundles, evals, and managed runtime files
- AC-owned preferences, caches, HTTP storage, saved state, app containers, and application-script entries for discovered AC bundle IDs
- AC Keychain items under service `dev.accountycat.credentials`
- TCC/privacy grants for discovered AC bundle IDs

It must not delete broad `~/Library` trees or unrelated app data.

## Workflow

1. Use a dry run first if the user wants to inspect scope:

```bash
bash dev/agents/accountycat-reset-state/scripts/reset-ac-state.sh --dry-run
```

2. Run the actual reset:

```bash
bash dev/agents/accountycat-reset-state/scripts/reset-ac-state.sh
```

3. Report:

- whether `~/Library/Application Support/AC` was removed
- whether AC keychain items were removed
- whether AC defaults domains were removed
- any leftover container stubs that macOS refused to delete

## Ground Rules

- Search only common AC locations for bundle IDs: `/Applications`, `~/Applications`, repo `build/`, and `~/Library/Developer/Xcode/DerivedData`.
- Prefer the bundled script over ad hoc shell editing.
- Stop AC/ACInspector processes before deleting files.
- Delete only AC-owned paths derived from discovered bundle IDs plus the known legacy domain `dev.jon.accountycat`.
- If macOS leaves container directories containing only `.com.apple.containermanagerd.metadata.plist`, treat them as harmless leftovers and report them instead of forcing broader deletion.
- After reset, AC should behave like first launch: no saved key, no saved state, and permissions must be re-granted.

---
name: accountycat-release
description: "Build and ship AccountyCat public macOS releases: validate tests, tag, Developer ID sign, notarize, staple, create a drag-to-Applications DMG, upload GitHub release assets, and update/deploy the Vercel website download CTA."
---

# AccountyCat Release

Use this skill when the user asks to release AccountyCat, rebuild a public
download, notarize the app, publish GitHub release assets, or update the website
download link.

AccountyCat is a macOS app. Do not call the release artifact an APK. The default
public artifact should be a signed and notarized DMG containing:

- `AccountyCat.app`
- an `Applications` symlink, so users can drag the app into `/Applications`

A zip is acceptable as an internal submission/archive format, but the website
download should prefer the DMG.

## Preconditions

Run from the app repo unless noted:

```bash
cd /Users/jonas/Code/AC/AC
```

Required local setup:

- GitHub CLI authenticated for `strjonas/AccountyCat`
- Vercel CLI authenticated for the website account
- Apple signing identity: `Developer ID Application: Jonas Strabel (47DBQZ8928)`
- Notary keychain profile: `accountycat-notary`
- Website repo: `/Users/jonas/Code/ac-web`

Check setup first:

```bash
security find-identity -p codesigning -v
xcrun notarytool history --keychain-profile accountycat-notary --team-id 47DBQZ8928 --output-format json
```

If the notary profile is missing, ask the user to run this locally. They must use
an app-specific password and must not paste it into chat:

```bash
xcrun notarytool store-credentials accountycat-notary \
  --apple-id jonas.strabel@icloud.com \
  --team-id 47DBQZ8928
```

## Inputs

Resolve before starting:

- `VERSION`, for example `1.0`
- `TAG`, for example `v1.0`
- `BUILD`, usually `1` unless shipping a new build for the same version
- release source: existing tag, current commit, or a specified commit

If creating a new tag, validate first, create an annotated tag, push it, then
build from that tag. If the tag already exists, build from that tag in a detached
worktree so the binary matches the release source.

Do not build a release from a dirty app repo. If unrelated user changes exist,
stop and ask whether they should be included. Do not revert user changes.

## Validate Before Release

Run the repo-required checks before tagging or uploading:

```bash
xcodebuild test -project AC.xcodeproj -scheme AC -destination 'platform=macOS' -only-testing:ACTests CODE_SIGNING_ALLOWED=NO
xcodebuild build -project AC.xcodeproj -scheme ACInspector CODE_SIGNING_ALLOWED=NO
```

Do not start overlapping `xcodebuild test` runs that share build/test paths.

## Tag And Worktree

For a new release tag:

```bash
git status --short --branch
git tag -a "$TAG" -m "AccountyCat $TAG"
git push origin "$TAG"
```

Create an isolated build worktree:

```bash
rm -rf "build/worktrees/$TAG-release"
git worktree add --detach "build/worktrees/$TAG-release" "$TAG"
```

Run build/sign/notarize commands from that worktree. Remove it after the release
is uploaded and verified:

```bash
git worktree remove "build/worktrees/$TAG-release" --force
```

## Build And Sign

Build Apple Silicon only:

```bash
xcodebuild build \
  -project AC.xcodeproj \
  -scheme AC \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -derivedDataPath "build/ReleaseDerivedData-DeveloperID" \
  ACCOUNTYCAT_BUNDLE_ID_PREFIX=dev.accountycat \
  ACCOUNTYCAT_DEVELOPMENT_TEAM=47DBQZ8928 \
  DEVELOPMENT_TEAM=47DBQZ8928 \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY='Developer ID Application: Jonas Strabel (47DBQZ8928)' \
  ARCHS=arm64 \
  ONLY_ACTIVE_ARCH=NO \
  PRODUCT_NAME=AccountyCat \
  MARKETING_VERSION="$VERSION" \
  CURRENT_PROJECT_VERSION="$BUILD"
```

This project can receive the development entitlement
`com.apple.security.get-task-allow` from Xcode. Always re-sign the finished app
with the release entitlements file and a secure timestamp:

```bash
APP="build/ReleaseDerivedData-DeveloperID/Build/Products/Release/AccountyCat.app"
codesign --force --deep \
  --sign 'Developer ID Application: Jonas Strabel (47DBQZ8928)' \
  --options runtime \
  --timestamp \
  --entitlements AC/AC.entitlements \
  "$APP"
```

Verify:

```bash
codesign --verify --deep --strict --verbose=4 "$APP"
codesign -dvvv --entitlements :- "$APP"
file "$APP/Contents/MacOS/AccountyCat"
spctl -a -vvv -t execute "$APP"
```

Before notarization, `spctl` should reject with
`source=Unnotarized Developer ID`. If the app is unsigned, ad-hoc signed, or has
`get-task-allow`, fix signing before continuing.

## Notarize And Staple App

Create a temporary zip for notarizing the app bundle:

```bash
OUT="/Users/jonas/Code/AC/AC/build/release-$TAG-developer-id"
rm -rf "$OUT"
mkdir -p "$OUT"
ditto --norsrc --noextattr -c -k --keepParent "$APP" "$OUT/AccountyCat-$TAG-apple-silicon.zip"
```

Submit and wait:

```bash
xcrun notarytool submit "$OUT/AccountyCat-$TAG-apple-silicon.zip" \
  --keychain-profile accountycat-notary \
  --team-id 47DBQZ8928 \
  --wait \
  --output-format json
```

If the status is not `Accepted`, fetch the log and fix the issue:

```bash
xcrun notarytool log <submission-id> \
  --keychain-profile accountycat-notary \
  --team-id 47DBQZ8928
```

Staple and verify the app:

```bash
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl -a -vvv -t execute "$APP"
```

After stapling, `spctl` must accept with `source=Notarized Developer ID`.

## Create Drag-To-Applications DMG

Create a simple robust DMG with an Applications symlink. This is the reliable
default. A custom background/window layout is optional polish and should be added
only if explicitly requested, because it usually needs extra tooling or Finder
automation.

```bash
FINAL="/Users/jonas/Code/AC/AC/build/release-$TAG-notarized"
DMG_STAGE="$FINAL/dmg-staging"
DMG="$FINAL/AccountyCat-v${VERSION}-apple-silicon.dmg"
rm -rf "$FINAL"
mkdir -p "$DMG_STAGE"
ditto "$APP" "$DMG_STAGE/AccountyCat.app"
ln -s /Applications "$DMG_STAGE/Applications"
hdiutil create -volname "AccountyCat" -srcfolder "$DMG_STAGE" -ov -format UDZO "$DMG"
```

Sign the DMG, then notarize and staple the DMG itself:

```bash
codesign --force \
  --sign 'Developer ID Application: Jonas Strabel (47DBQZ8928)' \
  --timestamp \
  "$DMG"

xcrun notarytool submit "$DMG" \
  --keychain-profile accountycat-notary \
  --team-id 47DBQZ8928 \
  --wait \
  --output-format json

xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
spctl -a -vvv -t open --context context:primary-signature "$DMG"
shasum -a 256 "$DMG" > "$DMG.sha256"
```

Mount and verify the contained app:

```bash
MOUNT_DIR="$(mktemp -d)"
hdiutil attach "$DMG" -mountpoint "$MOUNT_DIR" -nobrowse -readonly
codesign --verify --deep --strict --verbose=4 "$MOUNT_DIR/AccountyCat.app"
xcrun stapler validate "$MOUNT_DIR/AccountyCat.app"
spctl -a -vvv -t execute "$MOUNT_DIR/AccountyCat.app"
hdiutil detach "$MOUNT_DIR"
rmdir "$MOUNT_DIR"
```

The final DMG and the contained app must both pass before uploading.

## GitHub Release

Create or update the release:

```bash
gh release view "$TAG" --repo strjonas/AccountyCat >/dev/null 2>&1 || \
  gh release create "$TAG" --repo strjonas/AccountyCat --title "AccountyCat $TAG" --latest --notes ""

gh release upload "$TAG" \
  "$DMG#AccountyCat $TAG Apple Silicon DMG" \
  "$DMG.sha256#SHA-256 checksum" \
  --repo strjonas/AccountyCat \
  --clobber
```

Release notes should include:

- download/install instructions: open DMG, drag `AccountyCat.app` to Applications
- version/build
- architecture `arm64`
- minimum macOS from `Info.plist`
- bundle identifier
- signing identity
- app notarization submission id
- DMG notarization submission id
- DMG SHA-256
- validation summary

## Website Update

Website repo:

```bash
cd /Users/jonas/Code/ac-web
```

Update `app/components/Download.tsx` so the direct URL points at:

```text
https://github.com/strjonas/AccountyCat/releases/download/<TAG>/AccountyCat-v<VERSION>-apple-silicon.dmg
```

The card copy should say the build is signed and notarized. The CTA can say
`Download DMG`.

Validate and deploy through Git/Vercel:

```bash
npm run build
git status --short --branch
git add app/components/Download.tsx
git commit -m "Update Mac download for $TAG"
git push origin main
vercel ls accountycat-website
vercel inspect <new-production-deployment-url>
```

Wait until the deployment is `Ready` and aliased to:

- `https://accountycat.com`
- `https://www.accountycat.com`

Verify live output:

```bash
curl -L --silent https://accountycat.com | tr ' ' '\n' | rg 'AccountyCat-v|dmg|Signed|notarized|Ad-hoc'
curl -L --silent "https://github.com/strjonas/AccountyCat/releases/download/$TAG/AccountyCat-v${VERSION}-apple-silicon.dmg.sha256"
curl -L --head --silent "https://github.com/strjonas/AccountyCat/releases/download/$TAG/AccountyCat-v${VERSION}-apple-silicon.dmg" | sed -n '1,45p'
```

## Final Report

Report:

- GitHub release URL
- direct DMG URL
- SHA-256
- app and DMG notarization submission ids
- Gatekeeper results for DMG and contained app
- website deployment URL / production domain
- tests/builds run
- dirty files left untouched

If you staged, committed, or pushed the website repo, include the Codex git
directives in the final response for that repo only.

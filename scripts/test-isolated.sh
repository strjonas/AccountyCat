#!/usr/bin/env bash

set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <runner-id> [extra xcodebuild args...]" >&2
  exit 1
fi

runner_id="$1"
shift

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
derived_data_path="${HOME}/Library/Developer/Xcode/DerivedData/AC-${runner_id}"
cloned_packages_path="${HOME}/.xcode-cloned-sources/${runner_id}"
swiftpm_cache_path="${HOME}/.swiftpm-cache/${runner_id}"

mkdir -p "$cloned_packages_path" "$swiftpm_cache_path"

cd "$repo_root"

xcodebuild test \
  -project AC.xcodeproj \
  -scheme AC \
  -destination "platform=macOS" \
  -only-testing:ACTests \
  -derivedDataPath "$derived_data_path" \
  -clonedSourcePackagesDirPath "$cloned_packages_path" \
  CODE_SIGNING_ALLOWED=NO \
  SWIFTPM_PACKAGE_CACHE_PATH="$swiftpm_cache_path" \
  "$@"

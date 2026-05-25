#!/usr/bin/env bash
set -euo pipefail

dry_run=0

for arg in "$@"; do
  case "$arg" in
    --dry-run)
      dry_run=1
      ;;
    *)
      echo "Unknown argument: $arg" >&2
      echo "Usage: $0 [--dry-run]" >&2
      exit 2
      ;;
  esac
done

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../../../.." && pwd)"

declare -a discovered_bundle_ids=()
declare -a removed_paths=()
declare -a skipped_paths=()
declare -a missing_paths=()

log() {
  printf '%s\n' "$*"
}

record_bundle_id() {
  local bundle_id="$1"
  local existing
  for existing in "${discovered_bundle_ids[@]:-}"; do
    [[ "$existing" == "$bundle_id" ]] && return 0
  done
  discovered_bundle_ids+=("$bundle_id")
}

discover_bundle_ids() {
  local app
  local bundle_id
  local patterns=(
    /Applications/AC.app
    /Applications/AccountyCat.app
    /Applications/ACInspector.app
    "$HOME"/Applications/AC.app
    "$HOME"/Applications/AccountyCat.app
    "$HOME"/Applications/ACInspector.app
    "$repo_root"/build/*/AC.app
    "$repo_root"/build/*/AccountyCat.app
    "$repo_root"/build/*/ACInspector.app
    "$HOME"/Library/Developer/Xcode/DerivedData/*/Build/Products/*/AC.app
    "$HOME"/Library/Developer/Xcode/DerivedData/*/Build/Products/*/AccountyCat.app
    "$HOME"/Library/Developer/Xcode/DerivedData/*/Build/Products/*/ACInspector.app
  )

  shopt -s nullglob
  for app in "${patterns[@]}"; do
    [[ -d "$app" ]] || continue
    bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist" 2>/dev/null || true)
    [[ -n "$bundle_id" ]] || continue
    record_bundle_id "$bundle_id"
  done
  shopt -u nullglob

  record_bundle_id "dev.accountycat.AC"
  record_bundle_id "dev.accountycat.ACInspector"
  record_bundle_id "dev.jon.AC"
  record_bundle_id "dev.jon.ACInspector"
  record_bundle_id "dev.jon.accountycat"
}

remove_path() {
  local path="$1"
  if [[ ! -e "$path" ]]; then
    missing_paths+=("$path")
    return 0
  fi

  if (( dry_run )); then
    removed_paths+=("$path")
    return 0
  fi

  if rm -rf "$path" 2>/dev/null; then
    removed_paths+=("$path")
  else
    skipped_paths+=("$path")
  fi
}

delete_keychain_item() {
  local service="$1"
  local account="$2"
  if (( dry_run )); then
    log "Would delete keychain item service=$service account=$account"
    return 0
  fi
  security delete-generic-password -s "$service" -a "$account" >/dev/null 2>&1 || true
}

reset_tcc() {
  local bundle_id="$1"
  if (( dry_run )); then
    log "Would reset TCC for $bundle_id"
    return 0
  fi
  tccutil reset All "$bundle_id" >/dev/null 2>&1 || true
}

delete_defaults_domain() {
  local bundle_id="$1"
  if (( dry_run )); then
    log "Would delete defaults domain $bundle_id"
    return 0
  fi

  # Removing the plist alone is insufficient while cfprefsd has the domain cached:
  # launching AC can recreate completion flags from memory after an apparent reset.
  defaults delete "$bundle_id" >/dev/null 2>&1 || true
}

discover_bundle_ids

log "Discovered AC bundle IDs:"
for bundle_id in "${discovered_bundle_ids[@]}"; do
  log "  $bundle_id"
done

if (( dry_run )); then
  log "Running in dry-run mode."
fi

pkill -f '/AC\.app/Contents/MacOS/AC' 2>/dev/null || true
pkill -f '/AccountyCat\.app/Contents/MacOS/AccountyCat' 2>/dev/null || true
pkill -f '/ACInspector\.app/Contents/MacOS/ACInspector' 2>/dev/null || true

delete_keychain_item "dev.accountycat.credentials" "openrouter_api_key"
delete_keychain_item "dev.accountycat.credentials" "direct_openai_api_key"
delete_keychain_item "dev.accountycat.credentials" "monitoring_openai_api_key"

remove_path "$HOME/Library/Application Support/AC"

for bundle_id in "${discovered_bundle_ids[@]}"; do
  delete_defaults_domain "$bundle_id"
  remove_path "$HOME/Library/Preferences/$bundle_id.plist"
  remove_path "$HOME/Library/Caches/$bundle_id"
  remove_path "$HOME/Library/HTTPStorages/$bundle_id"
  remove_path "$HOME/Library/Saved Application State/$bundle_id.savedState"
  remove_path "$HOME/Library/Containers/$bundle_id"
  remove_path "$HOME/Library/Application Scripts/$bundle_id"
  reset_tcc "$bundle_id"
done

log "Removed or scheduled for removal:"
if [[ "${#removed_paths[@]}" -eq 0 ]]; then
  log "  none"
else
  for value in "${removed_paths[@]}"; do
    log "  $value"
  done
fi

log "Skipped (usually macOS-protected container stubs):"
if [[ "${#skipped_paths[@]}" -eq 0 ]]; then
  log "  none"
else
  for value in "${skipped_paths[@]}"; do
    log "  $value"
  done
fi

if (( dry_run )); then
  exit 0
fi

log "Verification:"
if [[ -e "$HOME/Library/Application Support/AC" ]]; then
  log "  app support: present"
else
  log "  app support: absent"
fi

for account in openrouter_api_key direct_openai_api_key monitoring_openai_api_key; do
  if security find-generic-password -s dev.accountycat.credentials -a "$account" >/dev/null 2>&1; then
    log "  keychain $account: present"
  else
    log "  keychain $account: absent"
  fi
done

if defaults domains | tr ',' '\n' | sed 's/^ *//' | rg '(^|\.)(AC|ACInspector)($|\.)|accountycat' >/dev/null 2>&1; then
  log "  defaults domains: AC-related domains still present"
else
  log "  defaults domains: no AC-related domains found"
fi

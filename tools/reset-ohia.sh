#!/usr/bin/env bash
# reset-ohia.sh — first-run wipe: stop Ohia if running, then clear all local state
#
# Stops Ohia and worker processes when they are running, then removes persisted
# user/mail state so the next launch behaves like a fresh install (onboarding,
# no accounts, no vectors, no credentials, default prefs). Preserves downloaded
# Qwen weights under Application Support/Ohia/huggingface/.
#
# Usage:
#   tools/reset-ohia.sh           # first-run reset (default)
#   tools/reset-ohia.sh --soft    # onboarding flags only (keeps mail data)
#
# Does not touch the repo, DerivedData, or BundledModels/ in the project tree.

set -euo pipefail

BUNDLE_ID="org.jgkarlin.Ohia"
APP_SUPPORT="${HOME}/Library/Application Support"
OHIA_DIR="${APP_SUPPORT}/Ohia"
QWEN_CACHE_DIR="${OHIA_DIR}/huggingface"
SWIFTDATA_STORE="${APP_SUPPORT}/Ohia.store"
PREFS_PLIST="${HOME}/Library/Preferences/${BUNDLE_ID}.plist"

KEYCHAIN_SERVICES=(
  com.ohia.smtp
  com.ohia.imap
  com.ohia.oauth
)

SOFT=0

usage() {
  sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --soft) SOFT=1; shift ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown arg: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

ohia_processes_running() {
  pgrep -x Ohia >/dev/null 2>&1 \
    || pgrep -x OhiaRetrievalWorker >/dev/null 2>&1 \
    || pgrep -x OhiaGenerativeWorker >/dev/null 2>&1
}

stop_ohia_processes() {
  if ! ohia_processes_running; then
    printf 'Ohia is not running\n'
    return 0
  fi

  local attempt
  for attempt in 1 2 3; do
    printf 'Stopping Ohia and worker processes (attempt %s/3)\n' "$attempt"
    osascript -e 'quit app "Ohia"' 2>/dev/null || true
    sleep 0.5
    killall Ohia 2>/dev/null || true
    killall OhiaRetrievalWorker 2>/dev/null || true
    killall OhiaGenerativeWorker 2>/dev/null || true
    sleep 1
    if ! ohia_processes_running; then
      printf 'Ohia stopped\n'
      return 0
    fi
  done

  printf 'Sending SIGKILL to stuck Ohia processes\n'
  killall -9 Ohia 2>/dev/null || true
  killall -9 OhiaRetrievalWorker 2>/dev/null || true
  killall -9 OhiaGenerativeWorker 2>/dev/null || true
  sleep 0.5

  if ohia_processes_running; then
    fail "Ohia or a worker is still running. Close it in Activity Monitor and retry."
  fi
  printf 'Ohia stopped\n'
}

soft_reset() {
  stop_ohia_processes
  defaults delete "$BUNDLE_ID" hasCompletedOnboarding 2>/dev/null || true
  defaults delete "$BUNDLE_ID" hasCompletedFirstIngestion 2>/dev/null || true
  printf 'Soft reset OK: onboarding flags cleared. Mail data, credentials, and prefs preserved.\n'
  printf 'Relaunch Ohia to replay onboarding against existing data.\n'
}

drain_keychain_service() {
  local svc="$1"
  local count=0
  while security delete-generic-password -s "$svc" >/dev/null 2>&1; do
    count=$((count + 1))
  done
  printf '  keychain %s: removed %s entr(y/ies)\n' "$svc" "$count"
}

remove_path_if_present() {
  local label="$1"
  local path="$2"
  if [[ -e "$path" ]]; then
    rm -rf "$path"
    printf '  removed %s\n' "$label"
  else
    printf '  %s: not present\n' "$label"
  fi
}

# Delete everything under Application Support/Ohia except huggingface/ (Qwen
# generation downloads via GenerationModelStorage).
clear_ohia_app_support_preserving_qwen() {
  if [[ ! -d "$OHIA_DIR" ]]; then
    printf '  Application Support/Ohia: not present\n'
    return 0
  fi

  local had_qwen=0
  if [[ -d "$QWEN_CACHE_DIR" ]]; then
    had_qwen=1
  fi

  local entry name
  shopt -s dotglob nullglob
  for entry in "$OHIA_DIR"/*; do
    name=$(basename "$entry")
    if [[ "$name" == "huggingface" ]]; then
      continue
    fi
    rm -rf "$entry"
  done
  shopt -u dotglob nullglob

  if [[ "$had_qwen" -eq 1 ]]; then
    printf '  cleared Application Support/Ohia (preserved huggingface/ Qwen downloads)\n'
  else
    printf '  cleared Application Support/Ohia\n'
  fi
}

full_reset() {
  stop_ohia_processes

  printf 'First-run reset: clearing SwiftData, Application Support, prefs, and keychain\n'
  printf '  (preserving Application Support/Ohia/huggingface/ — downloaded Qwen models)\n'

  remove_path_if_present "SwiftData store" "${SWIFTDATA_STORE}"
  remove_path_if_present "SwiftData WAL" "${SWIFTDATA_STORE}-wal"
  remove_path_if_present "SwiftData SHM" "${SWIFTDATA_STORE}-shm"
  clear_ohia_app_support_preserving_qwen

  if defaults delete "$BUNDLE_ID" 2>/dev/null; then
    printf '  removed UserDefaults domain %s\n' "$BUNDLE_ID"
  else
    printf '  UserDefaults domain %s: not present\n' "$BUNDLE_ID"
  fi
  remove_path_if_present "preferences plist" "${PREFS_PLIST}"

  printf 'Keychain:\n'
  for svc in "${KEYCHAIN_SERVICES[@]}"; do
    drain_keychain_service "$svc"
  done

  if ohia_processes_running; then
    fail "Reset incomplete: Ohia started during wipe."
  fi
  if [[ -e "$SWIFTDATA_STORE" ]]; then
    fail "Reset incomplete: SwiftData store still exists."
  fi

  printf 'First-run reset OK. Relaunch Ohia — you should see the Welcome onboarding flow with no accounts.\n'
  if [[ -d "$QWEN_CACHE_DIR" ]]; then
    printf 'Downloaded Qwen models in huggingface/ were preserved.\n'
  fi
  printf 'BGE retrieval caches were cleared; use Settings or tools/fetch-bundled-bge.sh if needed.\n'
}

if [[ "$SOFT" -eq 1 ]]; then
  soft_reset
else
  full_reset
fi

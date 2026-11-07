#!/usr/bin/env bash
# fetch-bundled-bge.sh — populate BundledModels/ from Hugging Face Hub
#
# Downloads the same artifacts Ohia uses at runtime (Core ML repos + BAAI
# tokenizers) into BundledModels/ so Xcode can copy them into the app bundle.
# Large files stay gitignored; this script is the supported post-clone path.
#
# Usage:
#   tools/fetch-bundled-bge.sh              # embedder + reranker
#   tools/fetch-bundled-bge.sh --embedder   # bge-m3 only
#   tools/fetch-bundled-bge.sh --reranker   # bge-reranker-v2-m3 only
#
# Requires: huggingface-cli (`hf`), logged in for private repos if needed:
#   brew install huggingface-cli && hf auth login

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

EMBEDDER_COREML_REPO="JGKarlin/ohia-bge-m3-coreml"
EMBEDDER_TOKENIZER_REPO="BAAI/bge-m3"
EMBEDDER_NAME="bge-m3"
EMBEDDER_PACKAGE="bge-m3.mlpackage"

RERANKER_COREML_REPO="JGKarlin/ohia-bge-reranker-v2-m3-coreml"
RERANKER_TOKENIZER_REPO="BAAI/bge-reranker-v2-m3"
RERANKER_NAME="bge-reranker-v2-m3"
RERANKER_PACKAGE="bge-reranker-v2-m3.mlpackage"

TOKENIZER_FILES=(
  tokenizer.json
  tokenizer_config.json
  special_tokens_map.json
)

FETCH_EMBEDDER=1
FETCH_RERANKER=1

usage() {
  sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --embedder) FETCH_RERANKER=0; shift ;;
    --reranker) FETCH_EMBEDDER=0; shift ;;
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

require_hf() {
  if ! command -v hf >/dev/null 2>&1; then
    fail "huggingface-cli is required (provides the hf command). Install: brew install huggingface-cli"
  fi
}

bundle_dir() {
  printf '%s/BundledModels/%s' "$REPO_ROOT" "$1"
}

verify_bundle() {
  local name="$1"
  local package="$2"
  local dir
  dir="$(bundle_dir "$name")"
  local pkg="$dir/$package"

  [ -d "$dir" ] || fail "missing bundle directory: $dir"
  [ -f "$pkg/Manifest.json" ] || fail "missing $pkg/Manifest.json"
  [ -f "$pkg/Data/com.apple.CoreML/model.mlmodel" ] || fail "missing Core ML model in $pkg"
  [ -f "$pkg/Data/com.apple.CoreML/weights/weight.bin" ] || fail "missing Core ML weights in $pkg"

  local file
  for file in "${TOKENIZER_FILES[@]}"; do
    [ -f "$dir/$file" ] || fail "missing tokenizer file: $dir/$file"
  done
}

bundle_complete() {
  local name="$1"
  local package="$2"
  verify_bundle "$name" "$package" 2>/dev/null
}

fetch_model() {
  local name="$1"
  local package="$2"
  local coreml_repo="$3"
  local tokenizer_repo="$4"
  local dir
  dir="$(bundle_dir "$name")"

  if bundle_complete "$name" "$package"; then
    printf 'BundledModels/%s already complete — skipping download.\n' "$name"
    return 0
  fi

  mkdir -p "$dir"
  printf 'Fetching %s Core ML package from %s\n' "$name" "$coreml_repo"
  hf download "$coreml_repo" \
    --include "${package}/**" \
    --exclude "${package}/.cache/**" \
    --local-dir "$dir"

  printf 'Fetching %s tokenizer files from %s\n' "$name" "$tokenizer_repo"
  local include_args=()
  local file
  for file in "${TOKENIZER_FILES[@]}"; do
    include_args+=(--include "$file")
  done
  hf download "$tokenizer_repo" \
    "${include_args[@]}" \
    --local-dir "$dir"

  verify_bundle "$name" "$package"
  printf 'BundledModels/%s OK\n' "$name"
}

main() {
  require_hf
  cd "$REPO_ROOT"

  if [[ "$FETCH_EMBEDDER" -eq 1 ]]; then
    fetch_model "$EMBEDDER_NAME" "$EMBEDDER_PACKAGE" "$EMBEDDER_COREML_REPO" "$EMBEDDER_TOKENIZER_REPO"
  fi
  if [[ "$FETCH_RERANKER" -eq 1 ]]; then
    fetch_model "$RERANKER_NAME" "$RERANKER_PACKAGE" "$RERANKER_COREML_REPO" "$RERANKER_TOKENIZER_REPO"
  fi

  printf 'fetch-bundled-bge: done. Rebuild Ohia in Xcode to copy Models/ into the app bundle.\n'
}

main

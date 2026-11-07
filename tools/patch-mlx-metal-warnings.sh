#!/usr/bin/env bash
set -euo pipefail

marker="OHIA_MLX_METAL_WARNING_SUPPRESSION"

candidate_checkouts=()

add_candidate() {
  local path="$1"
  [[ -n "$path" ]] || return 0
  candidate_checkouts+=("$path")
}

add_derived_data_candidate() {
  local path="$1"
  [[ -n "$path" ]] || return 0

  case "$path" in
    */Build/*)
      add_candidate "${path%%/Build/*}/SourcePackages/checkouts/mlx-swift"
      ;;
  esac
}

add_derived_data_candidate "${BUILD_DIR:-}"
add_derived_data_candidate "${BUILD_ROOT:-}"
add_derived_data_candidate "${OBJROOT:-}"
add_derived_data_candidate "${PROJECT_TEMP_DIR:-}"

patch_file() {
  local file="$1"
  local marker_count
  marker_count="$(grep -c "$marker" "$file" || true)"

  if [[ "$marker_count" != 0 ]]; then
    if [[ "$marker_count" == 2 ]] \
      && grep -q '#pragma clang diagnostic ignored "-Wc++17-extensions"' "$file" \
      && grep -q '#pragma clang diagnostic ignored "-Wc++20-extensions"' "$file" \
      && grep -q '#pragma clang diagnostic pop' "$file"; then
      return 0
    fi

    echo "Ohia: partial MLX Metal warning patch found in $file; reset Swift packages and rebuild." >&2
    return 1
  fi

  chmod u+w "$file" 2>/dev/null || true

  local mode
  local tmp
  mode="$(stat -f "%Lp" "$file")"
  tmp="$(mktemp "$file.tmp.XXXXXX")"
  awk -v marker="$marker" '
    NR == 1 {
      print
      print ""
      print "#if defined(__clang__) // " marker
      print "#pragma clang diagnostic push"
      print "#pragma clang diagnostic ignored \"-Wc++17-extensions\""
      print "#pragma clang diagnostic ignored \"-Wc++20-extensions\""
      print "#endif"
      next
    }
    { print }
    END {
      print ""
      print "#if defined(__clang__) // " marker
      print "#pragma clang diagnostic pop"
      print "#endif"
    }
  ' "$file" > "$tmp"

  if [[ "$(grep -c "$marker" "$tmp" || true)" != 2 ]] \
    || ! grep -q '#pragma clang diagnostic ignored "-Wc++17-extensions"' "$tmp" \
    || ! grep -q '#pragma clang diagnostic ignored "-Wc++20-extensions"' "$tmp" \
    || ! grep -q '#pragma clang diagnostic pop' "$tmp"; then
    rm -f "$tmp"
    echo "Ohia: failed to prepare MLX Metal warning patch for $file." >&2
    return 1
  fi

  mv "$tmp" "$file"
  chmod "$mode" "$file" 2>/dev/null || true
}

checkout_count=0
missing=0
seen=":"

for checkout in "${candidate_checkouts[@]}"; do
  [[ -d "$checkout" ]] || continue
  case "$seen" in
    *:"$checkout":*) continue ;;
  esac
  seen="$seen$checkout:"
  checkout_count=$((checkout_count + 1))

  for file in \
    "$checkout/Source/Cmlx/mlx-generated/metal/steel/utils/integral_constant.h" \
    "$checkout/Source/Cmlx/mlx-generated/metal/steel/attn/kernels/steel_attention.h"; do
    if [[ ! -f "$file" ]]; then
      echo "Ohia: expected MLX Metal header not found: $file" >&2
      missing=1
      continue
    fi

    patch_file "$file"
  done
done

if [[ "$checkout_count" == 0 ]]; then
  echo "Ohia: active mlx-swift checkout not found; cannot patch Metal warning pragmas." >&2
  exit 1
fi

if [[ "$missing" != 0 ]]; then
  exit 1
fi

echo "Ohia: MLX Metal warning pragmas are installed."

#!/bin/bash
set -euo pipefail

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
helper_dir="${1:-$repo_root/Vendor/LiteParseHelper}"

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

[ "$(uname -s)" = "Darwin" ] || fail "LiteParse helper verification must run on macOS"
[ "$(uname -m)" = "arm64" ] || fail "Ohia is Apple Silicon only; verifier is running on $(uname -m)"
[ -d "$helper_dir" ] || fail "missing helper directory: $helper_dir"
[ -x "$helper_dir/lit" ] || fail "missing executable LiteParse wrapper: $helper_dir/lit"
[ -x "$helper_dir/node/bin/node" ] || fail "missing executable bundled Node: $helper_dir/node/bin/node (run tools/fetch-liteparse-node.sh)"
[ -f "$helper_dir/node_modules/@llamaindex/liteparse/dist/cli.js" ] || fail "missing LiteParse CLI"
[ -f "$helper_dir/node_modules/@llamaindex/liteparse-darwin-arm64/liteparse.darwin-arm64.node" ] || fail "missing LiteParse Darwin arm64 native module"
[ -f "$helper_dir/node_modules/@llamaindex/liteparse-darwin-arm64/libpdfium.dylib" ] || fail "missing bundled PDFium dylib"

require_arm64() {
  local file="$1"
  local archs
  archs=$(/usr/bin/lipo -archs "$file")
  [ "$archs" = "arm64" ] || fail "$file is not arm64-only; found architectures: $archs"
}

require_arm64 "$helper_dir/node/bin/node"
require_arm64 "$helper_dir/node_modules/@llamaindex/liteparse-darwin-arm64/liteparse.darwin-arm64.node"
require_arm64 "$helper_dir/node_modules/@llamaindex/liteparse-darwin-arm64/libpdfium.dylib"

binary_report=$(
  /usr/bin/find "$helper_dir" -type f \( -perm -111 -o -name "*.node" -o -name "*.dylib" -o -name "*.so" -o -name "*.dll" \) -print0 |
    /usr/bin/xargs -0 /usr/bin/file
)

if printf '%s\n' "$binary_report" | /usr/bin/grep -E 'x86|Intel|ELF|PE32|universal binary' >/dev/null; then
  printf '%s\n' "$binary_report" >&2
  fail "LiteParse helper contains a non-Apple-Silicon binary payload"
fi

if /usr/bin/find "$helper_dir" -type f \( -name "*.so" -o -name "*.dll" \) -print -quit | /usr/bin/grep -q .; then
  fail "LiteParse helper contains non-macOS native library files"
fi

tmp_dir=$(/usr/bin/mktemp -d)
trap '/bin/rm -rf "$tmp_dir"' EXIT
marker="LiteParse bundled smoke invoice 5597381202"
text_file="$tmp_dir/smoke.txt"
pdf_file="$tmp_dir/smoke.pdf"
json_file="$tmp_dir/smoke.json"
stderr_file="$tmp_dir/stderr.txt"

printf '%s\nTotal JPY 91\n' "$marker" > "$text_file"
/usr/sbin/cupsfilter -m application/pdf "$text_file" > "$pdf_file" 2>"$stderr_file" ||
  fail "cupsfilter failed while creating smoke PDF: $(/bin/cat "$stderr_file")"

"$helper_dir/lit" parse "$pdf_file" --format json --no-ocr --max-pages 3 -o "$json_file" 2>"$stderr_file" ||
  fail "bundled LiteParse parse failed: $(/bin/cat "$stderr_file")"

"$helper_dir/node/bin/node" - "$json_file" "$marker" <<'NODE'
const fs = require("node:fs");
const [, , jsonPath, marker] = process.argv;
const parsed = JSON.parse(fs.readFileSync(jsonPath, "utf8"));
if (!Array.isArray(parsed.pages) || parsed.pages.length < 1) {
  throw new Error("LiteParse smoke output did not contain pages");
}
const text = parsed.pages.map((page) => page.text || "").join("\n");
if (!text.includes(marker)) {
  throw new Error("LiteParse smoke output did not contain expected text");
}
NODE

printf 'LiteParse helper OK: Apple Silicon arm64 runtime, bundled Node, bundled LiteParse, smoke parse passed.\n'

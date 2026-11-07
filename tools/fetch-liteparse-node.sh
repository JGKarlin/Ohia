#!/bin/bash
# fetch-liteparse-node.sh — install the Node.js runtime the LiteParse helper needs
#
# Ohia bundles LiteParse (document text extraction) with its own arm64 Node.js
# so users never install Node. The runtime is the official Node.js release
# binary, downloaded from nodejs.org and verified against a pinned SHA-256
# before it is placed at Vendor/LiteParseHelper/node/bin/node.
#
# Run once after cloning, and again whenever NODE_VERSION changes:
#   tools/fetch-liteparse-node.sh

set -euo pipefail

NODE_VERSION="v24.16.0"
ARCHIVE_SHA256="39189dab4eeb15706c424af0ac08a3044c9e48f7db12a7d77f6b7aafc7dd5df6"
NODE_SHA256="1ee75375e33b94fc34b3b19aede049e11dae90efb63b374dc96d6bdace70c4b8"

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
destination="$repo_root/Vendor/LiteParseHelper/node/bin/node"
archive_name="node-$NODE_VERSION-darwin-arm64.tar.gz"
url="https://nodejs.org/dist/$NODE_VERSION/$archive_name"

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

[ "$(uname -s)" = "Darwin" ] || fail "Ohia builds on macOS only"
[ "$(uname -m)" = "arm64" ] || fail "Ohia is Apple Silicon only; this Mac is $(uname -m)"

if [ -f "$destination" ] && [ "$(/usr/bin/shasum -a 256 "$destination" | cut -d' ' -f1)" = "$NODE_SHA256" ]; then
  echo "Node.js $NODE_VERSION is already in place."
  exit 0
fi

work=$(/usr/bin/mktemp -d)
trap '/bin/rm -rf "$work"' EXIT

echo "Downloading Node.js $NODE_VERSION (darwin-arm64)"
/usr/bin/curl --fail --location --silent --show-error --output "$work/$archive_name" "$url" \
  || fail "download failed: $url"

actual=$(/usr/bin/shasum -a 256 "$work/$archive_name" | cut -d' ' -f1)
[ "$actual" = "$ARCHIVE_SHA256" ] || fail "checksum mismatch for $archive_name: expected $ARCHIVE_SHA256, got $actual"

/usr/bin/tar -xzf "$work/$archive_name" -C "$work" "node-$NODE_VERSION-darwin-arm64/bin/node" \
  || fail "could not extract bin/node from $archive_name"

actual=$(/usr/bin/shasum -a 256 "$work/node-$NODE_VERSION-darwin-arm64/bin/node" | cut -d' ' -f1)
[ "$actual" = "$NODE_SHA256" ] || fail "checksum mismatch for bin/node: expected $NODE_SHA256, got $actual"

/bin/mkdir -p "$(dirname "$destination")"
/bin/cp -f "$work/node-$NODE_VERSION-darwin-arm64/bin/node" "$destination"
/bin/chmod 755 "$destination"

"$repo_root/tools/verify-liteparse-helper.sh"
echo "Installed Node.js $NODE_VERSION at Vendor/LiteParseHelper/node/bin/node"

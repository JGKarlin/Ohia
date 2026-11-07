LiteParse helper bundle
=======================

Ohia is an Apple Silicon-only app. This directory vendors the complete
Apple Silicon LiteParse runtime needed by the app:

- `lit`: wrapper script discovered by Swift first.
- `node/bin/node`: bundled Node.js arm64 runtime.
- `node_modules/@llamaindex/liteparse`: LiteParse JavaScript CLI/library.
- `node_modules/@llamaindex/liteparse-darwin-arm64`: LiteParse native parser
  and bundled PDFium dylib for macOS arm64.

The bundled helper must not include x64, Intel, Linux, Windows, Homebrew, or
global-command runtime dependencies. Ohia does not require users to install
Node, LiteParse, LibreOffice, Homebrew, or any other document helper.

Swift looks here for a bundled LiteParse command in this order:

1. `Resources/LiteParseHelper/lit`
2. `Resources/LiteParseHelper/bin/lit`
3. `Resources/LiteParseHelper/node/bin/node` plus
   `Resources/LiteParseHelper/node_modules/@llamaindex/liteparse/dist/cli.js`
4. The legacy Node layout:
   `Resources/LiteParseHelper/node_modules/@llamaindex/liteparse/dist/src/index.js`

The runtime code also honors `OHIA_LITEPARSE_HELPER` for development and tests.
Do not rely on a globally installed `lit` command in production builds.

After changing this directory, run:

```bash
tools/verify-liteparse-helper.sh
```

Release note: each Ohia release pins the LiteParse helper version bundled in
this directory. Before cutting a release, check the latest maintained
LiteParse Apple Silicon/macOS CLI package, refresh this vendored payload when a
newer version should ship, and rerun the verifier on both the source helper and
the built `Ohia.app` copy. Do not auto-update LiteParse at runtime.

LiteParse is Apache-2.0 licensed and Commander is MIT licensed. The upstream
LiteParse npm package declares the Apache-2.0 license in package metadata; keep
that metadata and bundled transitive license notices intact when refreshing the
payload.

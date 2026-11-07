# bge-m3 bundled model drop-in

Place the local bge-m3 Core ML artifacts in this directory when you want Ohia
to ship with the embedder inside the app bundle:

- `bge-m3.mlpackage/`
- `tokenizer.json`
- `tokenizer_config.json`
- `special_tokens_map.json`

These large/generated files are ignored by git. The Ohia Xcode target copies a
complete local payload from here into the app bundle at:

`Ohia.app/Contents/Resources/Models/bge-m3/`

At runtime, Ohia checks this bundled directory first. If it is missing or
incomplete, Ohia falls back to the Application Support cache populated by the
optional Hugging Face downloader.

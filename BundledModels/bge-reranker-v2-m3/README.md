# bge-reranker-v2-m3 bundled artifacts

Place the converted Core ML package and tokenizer files here for a fully local reranker bundle:

- `bge-reranker-v2-m3.mlpackage/`
- `tokenizer.json`
- `tokenizer_config.json`
- `special_tokens_map.json`

These generated artifacts are ignored by git. Recreate them with `tools/convert-bge-reranker-to-coreml.py` and the commands in `tools/README.md`.

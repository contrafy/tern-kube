# Tern type definitions

`tern.d.luau` is not vendored. `make bootstrap` (`scripts/bootstrap.sh`) downloads it from the MIT-licensed
[stencil-hq/tern-sdk](https://github.com/stencil-hq/tern-sdk) at a pinned commit and verifies its SHA-256:

- source: `https://raw.githubusercontent.com/stencil-hq/tern-sdk/78ba204e19c6ee1eae5e102a83a551220180c69f/plugins/tern.d.luau`
- sha256: `f56084a35c5cdb24e33b7bacda8baa9a3d1504fd3e31a20d3a8c31f3e0c0a32b`
- installed to: `.tools/types/tern.d.luau` (gitignored)

The same file is what `tern plugin types DIR` writes for Tern 0.9.8.

`make typecheck` and editor setups use that file as is:

```
luau-lsp analyze --platform=standard --definitions=@tern=.tools/types/tern.d.luau plugin tests
```

For VS Code, set `luau-lsp.types.definitionFiles` to `{"@tern": ".tools/types/tern.d.luau"}` and
`luau-lsp.platform.type` to `standard`.

Use the `tern` global in plugin code. luau-lsp does not resolve `require("tern")`.

## Updating

Bump the commit and checksum in `scripts/bootstrap.sh` and this file together, then run `make bootstrap check`.

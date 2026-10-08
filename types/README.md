# Tern type definitions

`tern.d.luau` is not vendored. `make bootstrap` (`scripts/bootstrap.sh`) downloads it from the MIT-licensed
[stencil-hq/tern-sdk](https://github.com/stencil-hq/tern-sdk) at a pinned commit and verifies its SHA-256:

- source: `https://raw.githubusercontent.com/stencil-hq/tern-sdk/19658cb2a3205ce57c67ad8c5c1c54ed80fefa7e/plugins/tern.d.luau`
- sha256: `84682931deee44134bdd38502f81be37fd14ac1697618985228f5cab7e25c51f`
- installed to: `.tools/types/tern.d.luau` (gitignored)

The same file is what `tern plugin types DIR` writes for the installed Tern.

## luau-lsp copy

The upstream file uses the type `userdata` (`WindowCx:wait`), which Luau does not define; luau-lsp then rejects
the whole definitions file and reports `tern` as an unknown global. Bootstrap therefore also writes
`.tools/types/tern.lsp.d.luau`: the pristine file prefixed with `declare extern type userdata with end`.
`make typecheck` and editor setups should point at that copy:

```
luau-lsp analyze --platform=standard --definitions=@tern=.tools/types/tern.lsp.d.luau plugin tests
```

For VS Code, set `luau-lsp.types.definitionFiles` to `{"@tern": ".tools/types/tern.lsp.d.luau"}` and
`luau-lsp.platform.type` to `standard`.

Use the `tern` global in plugin code. luau-lsp does not resolve `require("tern")`.

## Updating

Bump the commit and checksum in `scripts/bootstrap.sh` and this file together, then run `make bootstrap check`.

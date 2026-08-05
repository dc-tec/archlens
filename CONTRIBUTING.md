# Contributing to ArchLens

ArchLens is experimental. Changes should preserve bounded, progressive
analysis and keep language-specific behavior behind adapters or providers.

## Development environment

Enter the Nix development shell:

```sh
nix develop
```

The shell provides formatting, static-analysis, and core test tools.

## Validation

Run the package, unit, integration, formatting, and Lua static-analysis checks:

```sh
nix flake check
```

Run an individual headless test directly when iterating:

```sh
nvim --headless -u NONE --noplugin -i NONE -l tests/run.lua
```

Language-focused suites live under `tests/languages/`. Integration coverage
should use real tools where it can remain deterministic and offline.

## Performance report

Run the local report with:

```sh
nix run .#benchmark
```

It measures time to the first useful Tree-sitter relationship for the Go,
Rust, Nix, and OCaml fixtures, plus bounded rendering of a large result set.
Set `ARCHLENS_BENCHMARK_ITERATIONS` to change the default of 50 samples.

The benchmark is comparative rather than a pass/fail threshold. Compare
results on the same machine before and after a change.

## Documentation

- Keep the README focused on evaluation and first use.
- Put daily workflows in `docs/guide.md`.
- Put ecosystem-specific behavior in `docs/languages.md`.
- Put extension contracts in `docs/extensions.md`.
- Keep exact configuration defaults synchronized with `doc/archlens.txt` and
  `lua/archlens/config.lua`.

User-facing behavior changes should update `CHANGELOG.md` when appropriate.

## Commits

Use scoped conventional commits and include a DCO sign-off:

```sh
git commit -s -m 'fix(scope): describe the change'
```

See [RELEASING.md](RELEASING.md) for the release process.

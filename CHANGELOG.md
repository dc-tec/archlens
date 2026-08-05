# Changelog

Notable user-facing changes to ArchLens are recorded here.

## [Unreleased]

### Added

- Follow Go symbols outward through real package, module, and `go.work`
  workspace boundaries without treating directories as architecture.
- Show bounded, build-aware package dependencies and dependents, including
  separate test-only relationships and workspace member modules.
- Add language-neutral extension points for build-boundary discovery and
  build-tool health checks.
- Follow Rust symbols into Cargo package and workspace boundaries, with bounded
  normal, build, and dev dependency relationships from offline metadata.

### Changed

- Keep source-symbol analysis available while slower boundary discovery runs,
  and return from a boundary view to function or type focus when following
  source code.

### Fixed

- Update package, module, and workspace context after build metadata changes
  and a manual refresh.
- Show test-only Go packages as dependents and recognize quoted module paths in
  `go.mod`.

## [0.1.1] - 2026-08-05

### Fixed

- Classify callers from test code under `Referenced from tests` while keeping
  production callers under `Entered through` and preserving their combined
  semantic and structural evidence.

### Changed

- Update repository metadata and documentation to use the canonical
  `archlens.nvim` repository name.

## [0.1.0] - 2026-08-04

- Initial release.

[Unreleased]: https://github.com/dc-tec/archlens.nvim/compare/v0.1.1...HEAD
[0.1.1]: https://github.com/dc-tec/archlens.nvim/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/dc-tec/archlens.nvim/releases/tag/v0.1.0

# Roadmap

ArchLens aims to help developers understand the architectural role,
relationships, and consequences of the code under their cursor without leaving
Neovim or first building a global repository model.

This roadmap describes the direction of the project rather than a fixed release
schedule. Priorities may change as ArchLens is used across more projects and
languages.

## Principles

- Start from the current symbol or file, or from a language or build boundary.
- Prioritize comprehension and navigation over graph completeness.
- Keep analysis bounded and the editor responsive.
- Show useful results while slower analysis continues.
- Distinguish semantic facts from structural candidates and retain their
  evidence.
- Keep the relationship model language-neutral and language behavior in
  adapters.
- Require no hosted service, LLM, or persistent project index.
- Let providers extend the model without turning the pane into an unstructured
  result list.

## Current direction

### Language and build boundaries

ArchLens should move between local code and larger contexts only when a
language or build system provides a real identity. Directories are not treated
as packages by default.

Go is the first language with a package, module, and workspace boundary chain.
ArchLens uses `go.mod` and `go.work` metadata to identify each boundary.

From a symbol, you can move outward to its package, module, and workspace.
Package views distinguish production relationships from test-only relationships
for the active build configuration. When build information is unavailable,
ArchLens keeps syntax-derived relationships available and reports the
limitation. Module views summarize production relationships between active
workspace modules. Workspace views list active member modules without repeating
their dependency graph.

Next steps may include:

- Package or module identities for other ecosystems with authoritative metadata
- Configuration relationships at boundary level
- Optional project-specific boundary annotations without assuming one
  architectural style

Future boundary support should use authoritative ecosystem metadata, retain
identity evidence, and preserve bounded on-demand analysis. Each ecosystem can
use its own boundary levels instead of adopting Go's vocabulary. Slow build
discovery must not block local symbol results. Health checks should report only
the tools relevant to the current language.

## Longer-term direction

### Guided exploration

Some architectural questions require following more than one relationship.
ArchLens may support bounded, on-demand exploration such as:

- How an entry point reaches the current focus
- Which nearby code may be affected by a change
- How two symbols or modules differ in their relationships
- Which evidence supports a derived path

These features should remain responsive and explainable without requiring a
complete repository model.

### Extension ecosystem

Language and project integrations should be able to evolve outside the core
while preserving a consistent experience.

Future work may include:

- Stable provider, relation, adapter, and graph interfaces
- Compatibility and deprecation guidance
- Tested examples for language adapters and project-specific providers
- Consistent evidence requirements for extensions

## Possible future work

The following ideas would broaden the project or change how it operates. They
remain possibilities rather than planned requirements:

- An optional incremental or persistent project index
- A repository-wide graphical view
- Git ownership, churn, or co-change relationships
- Architecture-rule enforcement
- Exporting context to external tools or AI assistants

These additions should be driven by observed limitations. None is required for
the core ArchLens experience.

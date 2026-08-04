# Roadmap

ArchLens aims to help developers understand the architectural role,
relationships, and consequences of the code under their cursor without leaving
Neovim or first building a global repository model.

This roadmap describes the direction of the project rather than a fixed release
schedule. Priorities may change as ArchLens is used across more projects and
languages.

## Principles

- Start from the current symbol, file, or module.
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

The first vertical slice is a Go package, module, and workspace boundary chain.
The Go adapter derives package identity from the nearest `go.mod` module path
and the source directory, module identity from the declared module path, and
workspace identity from an effective `go.work` that explicitly uses the current
module.
A symbol view shows only its immediate package in the existing focus hierarchy;
focusing outward reveals its module and then workspace. Go package focus uses
bounded `go list` output as the authority for active production edges and
enriches those edges with exact Tree-sitter import sites. When build analysis
is unavailable, the source-derived package view remains available. Module
focus aggregates actual production package imports between active Go workspace
modules, retaining one relationship per real module boundary rather than
listing every external manifest requirement. Workspace focus exposes its
bounded active member modules without repeating their dependency graph.

Next steps may include:

- Package or module identities for other ecosystems with authoritative metadata
- Test and configuration relationships at boundary level
- Optional project-specific boundary annotations without assuming one
  architectural style

Each step should keep boundary resolution in language adapters, retain evidence
for the identity, and preserve bounded on-demand analysis.

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
- Consistent health reporting and evidence requirements for extensions

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

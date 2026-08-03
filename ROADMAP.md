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

## Near-term direction

### Context and navigation

The pane should communicate how the current focus fits into its surroundings,
not only list individual relationships.

Possible improvements include:

- A clearer indication of the current exploration path and available back
  history
- An optional mode that follows the source cursor while retaining the current
  pinned behavior
- Relevance ordering that preserves lower-confidence evidence

## Longer-term direction

### Module and package context

ArchLens currently begins with local code. A natural extension is to move
between symbols, files, modules, and packages while preserving the same bounded
and explainable model.

This may include:

- Module or package focus where the language provides a useful boundary
- Aggregated dependency and dependent views
- Test and configuration relationships at module level
- Navigation between a symbol, its containing module, and neighboring modules
- Optional project-specific boundary annotations without assuming one
  architectural style

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

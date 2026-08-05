# Extending ArchLens

ArchLens keeps its relationship graph language-neutral. Language adapters
provide syntax and presentation, while project-analysis providers contribute
bounded graph deltas.

Extension APIs are experimental and may change before a stable release.

## Language adapters

Register an adapter before opening ArchLens:

```lua
require("archlens.adapters").register("zig", {
  treesitter = {
    root_markers = { "build.zig", ".git" },
    symbol_types = {
      function_declaration = "Function",
    },
  },
  ast_grep = { language = "zig" },
})
```

An adapter maps Neovim filetypes to a canonical language. It can define:

- Tree-sitter symbols and imports;
- project root markers;
- language or build boundaries;
- ast-grep behavior;
- configuration detection;
- relationship and row presentation.

### Boundary resolution

The optional `boundaries.resolve(path, root, context)` hook returns `nil` when
no authoritative boundary exists. Otherwise, return a non-empty list ordered
from the innermost boundary outward.

Each boundary provides:

- stable `id`, concise `name`, and `kind_name`;
- `path`, `level`, and `class` (`"language"` or `"build"`);
- optional `representative_path`, `import_keys`, and LSP `symbol_kind`;
- an evidence record.

`level` is an opaque lowercase identifier rather than a universal taxonomy.
An ecosystem can use target, package, module, workspace, or another accurate
term.

If discovery requires a build tool, implement
`boundaries.discover(path, root, context, done, options)`. ArchLens passes the
matching `providers.<language>` configuration as `options`. The source symbol
remains usable until `done(boundaries, outcome)` completes.

Discovery must return a cancellation function. ArchLens cancels it after
`boundaries.timeout_ms`. Implement `boundaries.clear_cache()` when manual
refresh should invalidate adapter state.

ArchLens uses these identities for progressive focus, navigation, and
boundary-level aggregation. It does not infer architecture from directory
layout.

### Presentation hooks

`presentation.section(context, relation, row)` can return `key`, `label`,
`order`, or `show_kind`. `presentation.row(context, relation, row)` can return
`name` or `kind_name`.

A presentation key creates a separately collapsible section. It does not
change the canonical relationship ID, direction, evidence, filtering, or
details. Treat all hook inputs as read-only.

If a hook fails or returns an invalid value, ArchLens reports the failure and
falls back to canonical presentation.

## Project-analysis providers

Register custom providers through the shared registry:

```lua
local graph = require("archlens.graph")

require("archlens.providers").register("ownership", {
  order = 35,
  label = "Ownership",
  queued = false,
  enabled = function(_, _, config)
    local options = config.providers.ownership or {}
    return options.enabled == true
  end,
  start = function(context, bufnr, config, done, report)
    local result = graph.delta()
    -- Optional: report("retrying", { retry_delay_ms = 1000 })
    -- Add canonical graph edges, then complete the provider.
    done(result)
    return function() end
  end,
})
```

A provider determines whether it applies, starts bounded work, calls `done`
once, and returns a cancellation function. Store provider-specific settings
under `providers.<id>`.

Register relationship types through
`require("archlens.relations").register()` before returning edges.

### Executable requirements

Expose required tools to `:checkhealth archlens` with
`tools(buffer, config)`. Return requirements only for relevant buffers:

```lua
tools = function(buffer, config)
  if buffer.language ~= "rust" then
    return {}
  end
  local options = config.providers.workspace or {}
  return {
    {
      id = "cargo",
      label = "Cargo",
      command = options.command or "cargo",
      enabled = options.enabled ~= false,
      version_args = { "--version" },
      unavailable_message = "Workspace relationships are unavailable.",
      version_label = "Cargo",
    },
  }
end
```

Tool IDs are scoped to their provider. ArchLens validates declarations, runs a
bounded version check, and reports declaration failures without breaking other
health checks.

### Replacing fallback providers

A build-aware provider can conditionally replace later fallback providers by
returning their IDs from `replaces(context, bufnr, config)`:

```lua
replaces = function(context)
  return context.boundary_level == "package" and { "imports", "importers" } or {}
end
```

Replacement applies only while the provider is enabled. The replacing
provider must have a lower `order` than each fallback and then owns the
complete behavior for that focus.

### Progress and terminal outcomes

The optional `report` callback accepts `"running"` or `"retrying"`. Retry
metadata can include `retry_delay_ms` and a short `message`.

`done(result)` completes normally. Exceptional terminal outcomes can be
reported with a state and message:

```lua
done(result, {
  state = "timed_out",
  message = "Ownership analysis exceeded 1000 ms.",
})
```

Terminal states are `completed`, `failed`, `timed_out`, `unavailable`, and
`cancelled`. ArchLens retains valid partial graph results for every state. Use
`unavailable` only when the provider applies but a required dependency or
capability is absent.

When multiple attached language servers support location-based relationships,
ArchLens queries each server and retains their evidence separately.

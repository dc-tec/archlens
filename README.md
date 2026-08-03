# archlens.nvim

ArchLens is a Neovim side pane for exploring the code around the symbol under
your cursor. It combines local structure with project-level relationships in a
bounded, navigable view.

No LLM, hosted service, or persistent project index is required.

> [!NOTE]
> ArchLens is experimental. Its interface and language support may change.

![ArchLens showing relationships around a Go function](docs/assets/overview.png)

## Approach

ArchLens follows the current symbol instead of building a permanent model of
the repository. Tree-sitter provides immediate file structure, an attached LSP
adds semantic relationships, and ast-grep finds structural candidates across
the project. Results appear as each provider completes. Each relationship is
labeled with its source.

Module dependencies and dependents come from a bounded in-memory scan. The scan
is cached while you navigate and rebuilt when ArchLens is refreshed. It does
not write an index to disk or start language servers for scanned files.

Test and configuration references are grouped by their enclosing function or
module. Each exact use remains available when a group is expanded. Filtered and
truncated relationships are reported instead of silently disappearing.

Press `?` on a relationship to inspect its direction, anchor, provider methods,
evidence classes, and retained occurrence sites without changing navigation
state. Contributions from multiple providers remain independently visible.

![ArchLens relationship evidence for a Rust reference](docs/assets/relationship-details.png)

## Requirements

ArchLens requires Neovim 0.12 or newer. It uses whichever of these sources are
available:

- A Tree-sitter parser provides local structure and language-specific module
  analysis.
- An attached LSP provides semantic definitions, references, implementations,
  and call or type hierarchies when supported by the server.
- [ast-grep](https://ast-grep.github.io/) provides project-wide structural
  candidates.
- [ripgrep](https://github.com/BurntSushi/ripgrep) provides reverse module
  lookup.

If a source is unavailable, ArchLens leaves out those relationships and
continues with the rest. Run `:checkhealth archlens` from a source buffer to see
what is available for that file.

## Installation

With lazy.nvim:

```lua
{
  "dc-tec/archlens",
  config = function()
    require("archlens").setup()

    vim.keymap.set("n", "<leader>cm", "<cmd>ArchLensHere<cr>", {
      desc = "Explore code relationships",
    })
  end,
}
```

Install `ast-grep` and `rg` on Neovim's `PATH` to enable structural search and
reverse module lookup.

With Nixvim, add the flake input:

```nix
inputs.archlens.url = "github:dc-tec/archlens";
```

Then add the plugin and optional tools to your Nixvim module:

```nix
{
  extraPlugins = [ inputs.archlens.packages.${pkgs.system}.default ];
  extraPackages = [ pkgs.ast-grep pkgs.ripgrep ];
}
```

## Usage

ArchLens does not install a global key mapping. It provides three commands:

- `:ArchLensHere` opens or refreshes the pane for the symbol under the cursor.
- `:ArchLensRefresh` refreshes the open pane.
- `:ArchLensClose` closes it.

Use `:help archlens` for the complete command, mapping, and configuration
reference.

Inside the pane:

- `<CR>` opens a relationship, or toggles the selected section or context group.
- `f` focuses a relationship and adds the previous symbol to navigation history.
- `<BS>` or `h` returns to the previous focus.
- `<Tab>` and `<S-Tab>` move between actionable rows.
- `]s` and `[s` move between sections.
- `<Space>` or `za` toggles a section or context group.
- `zM` and `zR` collapse or expand the complete view.
- `?` explains the selected relationship, section, or context group.
- `r` refreshes the view; `q` closes it.

Result sets are bounded, and external relationships are hidden by default. The
pane reports pending providers, omissions, timeouts, and unavailable analysis.

## Configuration

`require("archlens").setup()` works without options. The configuration API is
still evolving; current options and defaults live in
[`lua/archlens/config.lua`](lua/archlens/config.lua).

Vendored and generated relationships are hidden by default. They can be
included, and additional project-relative path prefixes can be excluded:

```lua
require("archlens").setup({
  sections = {
    default_collapsed = { "siblings" },
    hidden = { "structural" },
    max_items = {
      references = 12,
    },
    order = { "incoming", "outgoing", "references" },
  },
  filters = {
    include_vendored = true,
    include_generated = true,
    exclude = { "third_party/legacy" },
  },
})
```

Nearby definitions are collapsed by default. Section and context expansion is
preserved when the pane is refreshed. Use an empty `default_collapsed` list to
start with every section open; `max_items` at the top level remains the fallback
for sections without an override. `hidden` removes selected relationship kinds
from the model while reporting their count. IDs listed in `order` appear first;
unlisted relationship kinds retain their registry order.

If a newly attached language server returns no semantic relationships,
ArchLens retries once after three seconds. The retry only applies during the
configured cold-start window and can be disabled through
`lsp.cold_start_retry.enabled`.

## Language adapters

[`lua/archlens/adapters.lua`](lua/archlens/adapters.lua) is the source of truth
for language behavior. An adapter maps Neovim filetypes to a canonical language
and can define Tree-sitter symbols and project markers, module analysis, an
ast-grep parser and query, or a combination of them.

Additional adapters can be registered before ArchLens is used:

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

## Provider extensions

Project-analysis providers use the same registry as the built-in LSP,
Tree-sitter module, and ast-grep providers. A provider decides whether it
applies to the current focus, starts its work, calls `done` once with a graph
delta, and returns a cancellation function:

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
  start = function(context, bufnr, config, done)
    local result = graph.delta()
    -- Add canonical graph edges, then complete the provider.
    done(result)
    return function() end
  end,
})
```

Register new relationship kinds through
[`lua/archlens/relations.lua`](lua/archlens/relations.lua). Provider-specific
options belong under `providers.<id>`.

When more than one attached LSP supports location-based relationships,
ArchLens queries each client and keeps their evidence separate. Opaque call
hierarchy items remain with the client that resolved the focused symbol.

## Development

Relationship providers exchange the focused graph defined in
[`lua/archlens/graph.lua`](lua/archlens/graph.lua). Section names, ordering, and
direction live in [`lua/archlens/relations.lua`](lua/archlens/relations.lua), so
new relationship kinds do not require orchestration or renderer branches.

Run the complete package, unit, integration, and formatting checks with:

```sh
nix flake check
```

`nix develop` provides the development toolchain. Individual headless test
entrypoints can also be run directly, for example:

```sh
nvim --headless -u NONE --noplugin -i NONE -l tests/run.lua
```

## License

Licensed under the [Apache License 2.0](LICENSE).

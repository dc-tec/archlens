# archlens.nvim

ArchLens is a Neovim side pane for exploring the code around the symbol under
your cursor. It combines local structure and project-level relationships in a
bounded, navigable view.

It does not require an LLM, a remote service, or a separate project index.

> [!NOTE]
> ArchLens is experimental. Its interface and language support may change.
> Neovim 0.12 or newer is required.

## Approach

ArchLens starts at the symbol under your cursor. Tree-sitter provides local
structure, LSP adds semantic relationships, and ast-grep searches the project
for related patterns. Results are assembled on demand without a separate
project index.

Reverse module relationships use a bounded in-memory import scan. The scan is
cached while you navigate the project and rebuilt when ArchLens is refreshed;
it does not write an index to disk or start language servers for scanned files.

Test and configuration uses are grouped by their enclosing function or module.
Expanding a group keeps each exact use site available for navigation.

Local Tree-sitter structure is rendered immediately. LSP and ast-grep results
are merged into the open pane as they arrive, while the pane identifies any
providers that are still pending.

Each source is optional. ArchLens shows the relationships it can find, labels
their source, and reports missing or truncated results. It provides navigable
context around the current symbol rather than an exhaustive project graph.

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

With Nix or Nixvim, add the flake input:

```nix
inputs.archlens.url = "github:dc-tec/archlens";
```

Then add the package to a Nixvim module:

```nix
{
  extraPlugins = [ inputs.archlens.packages.${pkgs.system}.default ];
}
```

Ripgrep enables the reverse module scan. The rest of ArchLens remains available
without it, and the pane reports when imported-by analysis cannot run.

## Usage

Commands:

- `:ArchLensHere` opens or refreshes the pane for the symbol under the cursor.
- `:ArchLensRefresh` refreshes the open pane.
- `:ArchLensClose` closes it.

ArchLens does not install a global key mapping.

Run `:checkhealth archlens` from a source buffer to inspect the project root
and available analysis providers.

Inside the pane:

- `<CR>` opens a relationship, or toggles the selected section or context group.
- `f` focuses a relationship and adds the previous symbol to navigation history.
- `<BS>` or `h` returns to the previous focus.
- `<Tab>` and `<S-Tab>` move between actionable rows.
- `]s` and `[s` move between sections.
- `<Space>` or `za` toggles a section or context group.
- `r` refreshes the view; `q` closes it.

External relationships are hidden and result sets are bounded by default. The
pane reports omissions.

## Configuration

`require("archlens").setup()` works without options. The configuration API is
still evolving; current options and defaults live in
[`lua/archlens/init.lua`](lua/archlens/init.lua).

Vendored and generated relationships are hidden by default. They can be
included, or additional project-relative path prefixes can be excluded:

```lua
require("archlens").setup({
  filters = {
    include_vendored = true,
    include_generated = true,
    exclude = { "third_party/legacy" },
  },
})
```

## Language adapters

[`lua/archlens/adapters.lua`](lua/archlens/adapters.lua) is the source of truth
for language behavior. An adapter maps Neovim filetypes to a canonical language
and can define Tree-sitter symbols and project markers, an ast-grep parser and
query, or both.

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

Relationship providers exchange a focused graph defined in
[`lua/archlens/graph.lua`](lua/archlens/graph.lua). Section names, ordering, and
direction live in [`lua/archlens/relations.lua`](lua/archlens/relations.lua), so
new relationship types do not need orchestration or renderer branches.

## Development

Run the source tests with Neovim:

```sh
nvim --headless -u NONE --noplugin -i NONE -l tests/run.lua
```

`nix flake check` builds the plugin and runs the integration tests. `nix
develop` provides the development toolchain.

## License

Licensed under the [Apache License 2.0](LICENSE).

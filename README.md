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

## Usage

Commands:

- `:ArchLensHere` opens or refreshes the pane for the symbol under the cursor.
- `:ArchLensRefresh` refreshes the open pane.
- `:ArchLensClose` closes it.

ArchLens does not install a global key mapping.

Inside the pane:

- `<CR>` opens a relationship, or toggles the selected section.
- `f` focuses a relationship and adds the previous symbol to navigation history.
- `<BS>` or `h` returns to the previous focus.
- `<Tab>` and `<S-Tab>` move between actionable rows.
- `]s` and `[s` move between sections.
- `<Space>` or `za` toggles a section.
- `r` refreshes the view; `q` closes it.

External relationships are hidden and result sets are bounded by default. The
pane reports omissions.

## Configuration

`require("archlens").setup()` works without options. The configuration API is
still evolving; current options and defaults live in
[`lua/archlens/init.lua`](lua/archlens/init.lua).

## Development

Run the source tests with Neovim:

```sh
nvim --headless -u NONE --noplugin -i NONE -l tests/run.lua
```

`nix flake check` builds the plugin and runs the integration tests. `nix
develop` provides the development toolchain.

## License

Licensed under the [Apache License 2.0](LICENSE).

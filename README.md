# archlens.nvim

ArchLens displays code relationships for the symbol under your cursor in a
Neovim side pane. It combines local structure, semantic relationships, and
project-wide structural matches in a bounded view next to your source buffer.

ArchLens analyzes code on demand. It does not require an LLM, a hosted service,
or a persistent project index.

> [!NOTE]
> ArchLens is experimental. Its interface and language support may change.

![ArchLens exploring callers and navigating between Go functions](docs/assets/archlens-function-demo.gif)

## How ArchLens works

When you open the pane, ArchLens resolves the symbol under your cursor and
collects relationships from Tree-sitter, attached language servers, ast-grep,
and ripgrep when they are available.

Results appear as each source completes. Each relationship records its source,
method, and evidence class.

ArchLens bounds project searches, provider output, and visible rows. By
default, it filters external, generated, and vendored paths. The pane reports
filtered or omitted results and warns when a limit might make the analysis
incomplete.

Within each section, ArchLens ranks exact and corroborated evidence before
provider-defined and structural candidates. It then prefers nearby files.
Expand a section to view lower-ranked results.

The relationship graph is language-neutral. Language adapters define
language-specific analysis and presentation, such as Go interface roles and
Rust trait implementations.

## Requirements

ArchLens requires Neovim 0.12 or later. Configure any of these optional
analysis sources:

| Source                                           | Requirement                     | Provides                                                          |
| ------------------------------------------------ | ------------------------------- | ----------------------------------------------------------------- |
| Tree-sitter                                      | A parser for the current buffer | Local symbols, members, and module syntax                         |
| LSP                                              | An attached language server     | Semantic calls, references, implementations, and type hierarchies |
| [ast-grep](https://ast-grep.github.io/)          | `ast-grep` on Neovim's `PATH`   | Project-wide structural matches                                   |
| [ripgrep](https://github.com/BurntSushi/ripgrep) | `rg` on Neovim's `PATH`         | Reverse module lookup                                             |

If a source is unavailable, ArchLens omits its relationships and continues with
the remaining sources.

Run `:checkhealth archlens` from a source buffer to inspect the selected
project root, Tree-sitter parser and adapter, attached LSP capabilities,
ast-grep, and ripgrep. To inspect a provider failure, open the pane and press
`?` on the `Analysis` or `Results` line.

### Built-in language support

ArchLens sends the same language-neutral requests to every attached language
server. The available semantic relationships depend on the methods that each
server advertises.

Built-in adapters provide the following additional analysis:

| Language                 | Built-in analysis                                                                                             |
| ------------------------ | ------------------------------------------------------------------------------------------------------------- |
| Go                       | Tree-sitter symbols and modules, ast-grep matches, and Go interface presentation                              |
| Rust                     | Tree-sitter symbols and modules, ast-grep matches, and Rust implementation presentation                       |
| Nix                      | Tree-sitter bindings and module imports, plus ast-grep matches                                                |
| OCaml (`.ml` and `.mli`) | Tree-sitter symbols, module relationships, and member presentation; ast-grep does not provide an OCaml parser |
| JavaScript and JSX       | ast-grep matches                                                                                              |
| TypeScript and TSX       | ast-grep matches                                                                                              |
| Lua                      | ast-grep matches                                                                                              |
| Python                   | ast-grep matches                                                                                              |

For a language without a built-in adapter, an attached language server can
still provide semantic relationships. Register an adapter to add local
structure, module analysis, structural search, or language-specific
presentation.

## Install ArchLens

### lazy.nvim

```lua
{
  "dc-tec/archlens.nvim",
  config = function()
    require("archlens").setup()

    vim.keymap.set("n", "<leader>cm", "<cmd>ArchLensHere<cr>", {
      desc = "Explore code relationships",
    })
  end,
}
```

Install `ast-grep` and `rg` on Neovim's `PATH` if you want structural search
and reverse module lookup.

### Nixvim

Add the ArchLens flake input:

```nix
inputs.archlens = {
  url = "github:dc-tec/archlens.nvim";
  inputs.nixpkgs.follows = "nixpkgs";
  inputs.nixvim.follows = "nixvim";
};
```

The flake publishes packages for `aarch64-darwin`, `aarch64-linux`, and
`x86_64-linux`.

Pass the package to your Nixvim module. For example, with
`makeNixvimWithModule`:

```nix
extraSpecialArgs.archlens = inputs.archlens.packages.${system}.default;
```

ArchLens does not provide a native Nixvim option module. You can keep its
configuration in Nix by converting an attribute set with
`lib.generators.toLua`:

```nix
{
  archlens,
  lib,
  pkgs,
  ...
}:
let
  archlensConfig = {
    width = 64;
    max_items = 8;
    include_external = false;
    cursor_follow = {
      enabled = false;
      debounce_ms = 150;
    };
    ast_grep = {
      command = lib.getExe pkgs.ast-grep;
      timeout_ms = 15000;
      max_results = 80;
    };
    imports.inbound.command = lib.getExe pkgs.ripgrep;
  };
in
{
  extraPlugins = [ archlens ];
  extraPackages = [ pkgs.ast-grep pkgs.ripgrep ];

  extraConfigLua = lib.mkAfter ''
    require("archlens").setup(${lib.generators.toLua { } archlensConfig})
  '';

  keymaps = [
    {
      mode = "n";
      key = "<leader>cm";
      action = "<cmd>ArchLensHere<cr>";
      options = {
        desc = "Explore code relationships";
        silent = true;
      };
    }
  ];
}
```

## Use ArchLens

ArchLens does not define a global key mapping. It provides these commands:

| Command            | Action                                                                  |
| ------------------ | ----------------------------------------------------------------------- |
| `:ArchLensHere`    | Open the pane for the symbol under the cursor, or refresh the open pane |
| `:ArchLensRefresh` | Refresh the current focus                                               |
| `:ArchLensClose`   | Close the pane                                                          |

The following keys are available in the pane:

| Key                   | Action                                                                                                      |
| --------------------- | ----------------------------------------------------------------------------------------------------------- |
| `<CR>`                | Open a relationship, or toggle a section or context group                                                   |
| `f`                   | Focus the selected relationship and add the current symbol to navigation history                            |
| `F`                   | Toggle source-cursor following; pinned exploration is the default                                           |
| `<BS>` or `h`         | Return to the previous focus                                                                                |
| `<Tab>` and `<S-Tab>` | Move between actionable rows                                                                                |
| `]s` and `[s`         | Move between sections                                                                                       |
| `<Space>` or `za`     | Toggle a section or context group                                                                           |
| `zM` and `zR`         | Collapse or expand the complete view                                                                        |
| `?`                   | Explain the selected row, section, status line, or summary; on other lines, show the complete key reference |
| `r`                   | Refresh the current focus                                                                                   |
| `q`                   | Close the pane                                                                                              |

Run `:help archlens` for the complete command, mapping, and configuration
reference.

## Interpret the pane

ArchLens uses four inspectable status lines:

| Line           | Meaning                                                               |
| -------------- | --------------------------------------------------------------------- |
| `Sources [?]`  | Sources that contributed relationships to the current view            |
| `Analysis [?]` | Active providers and providers that ended with an exceptional outcome |
| `Path [?]`     | Previous and current focuses in the bounded navigation history        |
| `Results [?]`  | Filters, search limits, omissions, and partial-analysis warnings      |

Press `?` on a status line to view its complete details. The `Analysis` details
include the time to the first useful relationship and each provider's state,
elapsed time, duration, retry delay, and message. Completed providers do not
leave a persistent status line.

ArchLens keeps one details window open. Opening another details or help view
replaces it. When you close the window, focus returns to the ArchLens pane.

### Navigate between focuses

Press `f` on a relationship to analyze that target. ArchLens adds the current
symbol to a bounded navigation history. The `Path [?]` line appears after the
first focus change, and its details show the complete path. ArchLens retains up
to 32 previous focuses.

Press `F` to follow the symbol under the cursor in the tracked source window.
ArchLens debounces cursor movement, ignores repeated positions within the same
symbol, and does not add automatic changes to navigation history. Press `f`,
`<BS>`, or `h` to return to pinned exploration.

### Evaluate relationship evidence

Language-server calls, references, implementations, and type hierarchies are
semantic relationships. ast-grep results are structural candidates. When
semantic usage is available, ArchLens starts unmatched structural candidates
collapsed. Expand the section to inspect them.

If a semantic reference identifies an incoming call occurrence, ArchLens adds
the reference evidence to the caller row. Press `?` on the row to inspect the
call method, reference method, and retained call sites. Other references remain
in a separate section.

ArchLens groups test and configuration references by their enclosing function
or module. Expand a group to inspect each exact use.

For a type focus, `Members` contains children found by Tree-sitter. Language
adapters can present type hierarchy relationships with language-specific terms.
For example, the Go adapter distinguishes satisfied contracts, extended
interfaces, and concrete implementations.

![ArchLens exploring Go type relationships and following the source cursor](docs/assets/archlens-demo.gif)

Module dependencies come from bounded import sites in the focused file. Module
dependents come from a bounded in-memory project scan. ArchLens caches the scan
while you navigate and rebuilds it when you refresh the pane. The scan does not
write an index to disk or start language servers for scanned files.

![ArchLens relationship evidence for a Rust reference](docs/assets/relationship-details.png)

## Configure ArchLens

`require("archlens").setup()` uses the default configuration. The
configuration API is experimental.

Run `:help archlens-configuration` for every option and its default value.
[`lua/archlens/config.lua`](lua/archlens/config.lua) defines the defaults.

The following example changes cursor following, section policy, and project
filters:

```lua
require("archlens").setup({
  cursor_follow = {
    enabled = false,
    debounce_ms = 150,
  },
  sections = {
    collapse_secondary = true,
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

Set `cursor_follow.enabled` to `true` to start `:ArchLensHere` in follow
mode. The `F` mapping changes the mode for the current pane.

The `sections` table controls initial collapse state, visibility, ordering, and
row limits. ArchLens preserves manual expansion state when it refreshes the
current focus. The top-level `max_items` value applies to any section without
an override.

If a newly attached language server returns no semantic relationships,
ArchLens retries once after the configured delay. This retry applies only
during the cold-start window. Set `lsp.cold_start_retry.enabled` to `false` to
disable it.

Each provider has separate time, input, and output bounds. Use `imports` and
`imports.inbound` to bound module analysis, `lsp.max_results` and
`lsp.max_occurrences` to bound semantic responses, `grouping` to bound context
group detection, and `ast_grep.max_results` and
`ast_grep.max_output_bytes` to bound structural search.

## Add language support

[`lua/archlens/adapters.lua`](lua/archlens/adapters.lua) manages the language
adapter registry. Built-in adapters are in
[`lua/archlens/adapters/`](lua/archlens/adapters/).

An adapter maps Neovim filetypes to a canonical language. It can define
Tree-sitter symbols, project root markers, module analysis, an ast-grep
language and query, and relationship presentation.

Register an adapter before you open ArchLens:

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

The optional `presentation.section(context, relation, row)` and
`presentation.row(context, relation, row)` hooks can adapt labels and concise
row names to language semantics. A section hook can return `key`, `label`,
`order`, or `show_kind`. A row hook can return `name` or `kind_name`.

A presentation key creates a separately collapsible section. The underlying
relationship ID, direction, evidence, filtering, and details remain canonical.
Treat hook inputs as read-only.

If an adapter callback fails or returns an invalid value, ArchLens reports the
failure in `Results` details. Presentation falls back to canonical labels and
rows. Module analysis keeps unaffected relationships and omits results that
depend on the failed callback.

## Add a provider

Custom project-analysis providers use the same registry as the built-in LSP,
module, and ast-grep providers. A provider determines whether it applies to the
current focus, starts bounded work, calls `done` once, and returns a
cancellation function.

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

Register relationship types through
[`lua/archlens/relations.lua`](lua/archlens/relations.lua). Store
provider-specific options under `providers.<id>`.

The optional `report` callback accepts `"running"` or `"retrying"`. A retry
can include `retry_delay_ms` and a short `message`. ArchLens records queued,
completed, and start-failure states around the provider call.

Calling `done(result)` marks the provider as completed. If the provider can
classify another terminal outcome, pass `state` and an optional `message`:

```lua
done(result, {
  state = "timed_out",
  message = "Ownership analysis exceeded 1000 ms.",
})
```

Terminal states are `completed`, `failed`, `timed_out`, `unavailable`, and
`cancelled`. ArchLens retains partial graph results for every terminal state.
Use `unavailable` only when the provider applies but a required dependency or
capability is unavailable. Do not start disabled or inapplicable providers.

When multiple attached language servers support location-based relationships,
ArchLens queries each server and keeps its evidence separate. Opaque call
hierarchy items remain associated with the server that resolved the focused
symbol.

## Develop ArchLens

Relationship providers exchange graph deltas defined in
[`lua/archlens/graph.lua`](lua/archlens/graph.lua). Relationship names,
ordering, and directions are registered in
[`lua/archlens/relations.lua`](lua/archlens/relations.lua).

Run the package, unit, integration, formatting, and Lua static-analysis checks:

```sh
nix flake check
```

`nix develop` provides the development toolchain. You can also run an
individual headless test directly:

```sh
nvim --headless -u NONE --noplugin -i NONE -l tests/run.lua
```

Run the local performance report:

```sh
nix run .#benchmark
```

The report measures the time to the first useful Tree-sitter relationship for
the Go, Rust, Nix, and OCaml fixtures and the cost of rendering a bounded large
result set. Set `ARCHLENS_BENCHMARK_ITERATIONS` to change the default of 50
samples. Compare results on the same machine. The report does not enforce a
timing threshold and does not run in CI.

See [RELEASING.md](RELEASING.md) for the release procedure.

## License

ArchLens is licensed under the [Apache License 2.0](LICENSE).

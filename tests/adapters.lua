local adapters = require("archlens.adapters")
local ast_grep = require("archlens.ast_grep")
local fixture_module = assert(
  vim.api.nvim_get_runtime_file("tests/fixtures/project/go.mod", false)[1],
  "Go fixture module is unavailable"
)
local fixture_root = vim.fs.dirname(fixture_module)

local function equal(actual, expected, message)
  assert(vim.deep_equal(actual, expected), message or vim.inspect({ actual, expected }))
end

equal(adapters.language_for_filetype("go"), "go")
equal(adapters.language_for_filetype("ocamlinterface"), "ocaml_interface")
equal(adapters.language_for_filetype("ocaml", "/workspace/api.mli"), "ocaml_interface")
equal(adapters.language_for_filetype("ocaml", "/workspace/api.ml"), "ocaml")
equal(adapters.for_filetype("ocaml", "/workspace/api.mli").language, "ocaml_interface")
assert(
  adapters
    .imports_for_filetype("ocaml", "/workspace/api.mli").query
    :find("include_module_type", 1, true),
  "path-aware import selection should use the interface adapter"
)
equal(adapters.language_for_filetype("javascriptreact"), "javascript")
equal(adapters.language_for_filetype("typescriptreact"), "tsx")
equal(adapters.language_for_filetype("unknown"), "unknown")
equal(adapters.root_markers("unknown"), {
  ".git",
  "flake.nix",
  "go.mod",
  "Cargo.toml",
  "dune-project",
  "package.json",
  "pyproject.toml",
})

equal(adapters.get("go").treesitter.symbol_types, {
  field_declaration = "Field",
  function_declaration = "Function",
  method_elem = "Method",
  method_declaration = "Method",
  type_spec = "Type",
})
equal(adapters.get("go").treesitter.focus_wrappers, { type_declaration = true })
equal(adapters.get("go").treesitter.name_fields, { "name", "pattern", "attrpath", "type" })
equal(adapters.get("go").treesitter.name_node_types.constructor_name, nil)
local configuration_buffer = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(configuration_buffer, 0, -1, false, {
  '    Enabled bool `json:"enabled"`',
})
local go_configuration = adapters.get("go").configuration
local configuration_context = {
  kind = vim.lsp.protocol.SymbolKind.Field,
  name = "Enabled",
  location = {
    range = {
      start = { line = 0, character = 4 },
      ["end"] = { line = 0, character = 11 },
    },
  },
}
equal(go_configuration(configuration_buffer, configuration_context, { name = "TLSConfig" }), {
  key = "Enabled",
  container = "TLSConfig",
  source = "field",
})
equal(
  go_configuration(configuration_buffer, configuration_context, { name = "APIResponse" }),
  nil,
  "serialized fields outside configuration containers should stay ordinary symbols"
)
vim.api.nvim_buf_delete(configuration_buffer, { force = true })
local rust_configuration_buffer = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_name(rust_configuration_buffer, "/workspace/src/config.rs")
vim.api.nvim_buf_set_lines(rust_configuration_buffer, 0, -1, false, {
  "#[derive(Deserialize)]",
  "pub struct Config {",
  "    pub token: String,",
  "}",
})
local rust_configuration = adapters.get("rust").configuration
local rust_field = {
  kind = vim.lsp.protocol.SymbolKind.Field,
  name = "token",
  location = {
    range = {
      start = { line = 2, character = 8 },
      ["end"] = { line = 2, character = 13 },
    },
  },
}
equal(
  rust_configuration(rust_configuration_buffer, rust_field, {
    name = "Config",
    location = {
      full_range = {
        start = { line = 1, character = 0 },
        ["end"] = { line = 3, character = 1 },
      },
    },
  }),
  {
    key = "token",
    container = "Config",
    source = "field",
  }
)
equal(
  rust_configuration(rust_configuration_buffer, rust_field, { name = "Response" }),
  nil,
  "deserializable Rust fields still require a configuration container"
)
vim.api.nvim_buf_delete(rust_configuration_buffer, { force = true })
local go_imports = adapters.imports_for_filetype("go")
equal(go_imports.capture, "import")
equal(go_imports.normalize(nil, '"internal/storage"'), {
  name = "internal/storage",
  position_offset = 1,
})
go_imports.capture = "mutated"
equal(
  adapters.imports_for_filetype("go").capture,
  "import",
  "import adapter reads should be defensive copies"
)
equal(adapters.imports_for_filetype("unknown"), nil)
equal(adapters.supports_boundaries("go"), true)
equal(adapters.supports_boundaries("rust"), false)
local go_fixture = vim.fs.joinpath(fixture_root, "main.go")
local go_boundaries, go_boundary_error =
  adapters.resolve_boundaries("go", go_fixture, vim.fs.dirname(go_fixture), {})
assert(go_boundaries, "Go boundary resolution failed: " .. tostring(go_boundary_error))
local go_boundary = go_boundaries[1]
equal(go_boundary.id, "go-package:example.com/project")
equal(go_boundary.class, "language")
equal(go_boundary.level, "package")
equal(go_boundary.kind_name, "Go package")
equal(go_boundary.name, "project")
equal(go_boundary.import_keys, { "go-package:example.com/project" })
local go_module = go_boundaries[2]
equal(go_module.id, "go-module:example.com/project")
equal(go_module.class, "build")
equal(go_module.level, "module")
equal(go_module.kind_name, "Go module")
equal(go_module.name, "example.com/project")
equal(go_module.representative_path, vim.fs.joinpath(fixture_root, "go.mod"))

local workspace_root = vim.fn.tempname()
local workspace_module = vim.fs.joinpath(workspace_root, "app")
vim.fn.mkdir(workspace_module, "p")
vim.fn.writefile({ "go 1.26.5", "use ./app" }, vim.fs.joinpath(workspace_root, "go.work"))
vim.fn.writefile({ "module example.test/app" }, vim.fs.joinpath(workspace_module, "go.mod"))
local workspace_source = vim.fs.joinpath(workspace_module, "main.go")
vim.fn.writefile({ "package main" }, workspace_source)
local previous_gowork = vim.env.GOWORK
vim.env.GOWORK = "auto"
local workspace_boundaries =
  assert(adapters.resolve_boundaries("go", workspace_source, workspace_module, {}))
vim.env.GOWORK = previous_gowork
equal(#workspace_boundaries, 3, "a used Go module should expose its explicit workspace")
local go_workspace = workspace_boundaries[3]
equal(go_workspace.level, "workspace")
equal(go_workspace.class, "build")
equal(go_workspace.kind_name, "Go workspace")
equal(go_workspace.path, workspace_root)
equal(go_workspace.representative_path, vim.fs.joinpath(workspace_root, "go.work"))
equal(go_workspace.evidence.method, "go.work/use")
local workspace_contexts = require("archlens.boundaries").contexts({
  language = "go",
  root_dir = workspace_module,
  path = workspace_source,
}, workspace_boundaries)
equal(workspace_contexts[1].boundary_level, "package")
equal(workspace_contexts[1].enclosing_boundaries[1].boundary_level, "module")
equal(workspace_contexts[2].enclosing_boundaries[1].boundary_level, "workspace")
equal(adapters.resolve_boundaries("rust", go_fixture, fixture_root, {}), nil)

local discovered
local discovery_outcome
local discovery_done
local discovery_cancelled = 0
local discovery_cache_cleared = 0
adapters.register("rust_shaped_boundary", {
  boundaries = {
    resolve = function()
      return nil
    end,
    discover = function(_, _, _, done)
      discovery_done = done
      return function()
        discovery_cancelled = discovery_cancelled + 1
      end
    end,
    clear_cache = function()
      discovery_cache_cleared = discovery_cache_cleared + 1
    end,
  },
})
equal(adapters.supports_boundaries("rust_shaped_boundary"), true)
equal(adapters.supports_boundary_discovery("rust_shaped_boundary"), true)
local cancel_discovery = assert(
  adapters.discover_boundaries(
    "rust_shaped_boundary",
    "/workspace/src/lib.rs",
    "/workspace",
    {},
    function(value, outcome)
      discovered = value
      discovery_outcome = outcome
    end
  )
)
assert(discovery_done, "asynchronous adapters should receive a completion callback")
discovery_done({
  {
    id = "cargo-target:fixture/lib",
    class = "build",
    level = "target",
    kind_name = "Rust crate",
    name = "fixture",
    path = "/workspace/src",
    representative_path = "/workspace/src/lib.rs",
    symbol_kind = vim.lsp.protocol.SymbolKind.Module,
  },
  {
    id = "cargo-package:fixture",
    class = "build",
    level = "package",
    kind_name = "Cargo package",
    name = "fixture",
    path = "/workspace",
    representative_path = "/workspace/Cargo.toml",
  },
  {
    id = "cargo-workspace:/workspace",
    class = "build",
    level = "workspace",
    kind_name = "Cargo workspace",
    name = "workspace",
    path = "/workspace",
    representative_path = "/workspace/Cargo.toml",
  },
})
equal(discovery_outcome, nil)
equal(discovered[1].level, "target", "boundary levels should be extension-defined")
equal(discovered[1].symbol_kind, vim.lsp.protocol.SymbolKind.Module)
cancel_discovery()
equal(discovery_cancelled, 0, "completed discovery should not invoke late cancellation")
adapters.clear_cache()
equal(discovery_cache_cleared, 1, "registered boundary caches should clear on refresh")

equal(adapters.get("rust").treesitter.symbol_types.impl_item, "Implementation")
equal(adapters.get("rust").treesitter.symbol_types.field_declaration, "Field")
equal(adapters.get("rust").treesitter.symbol_types.function_signature_item, "Method")
equal(adapters.get("rust").treesitter.symbol_types.enum_variant, "EnumMember")
equal(adapters.get("ocaml_interface").treesitter.symbol_types.value_specification, "Value")
equal(adapters.get("ocaml_interface").treesitter.symbol_types.type_binding, "Type")
equal(adapters.get("ocaml_interface").treesitter.symbol_types.field_declaration, "Field")
equal(adapters.get("ocaml_interface").treesitter.name_node_types.constructor_name, true)
equal(adapters.get("ocaml_interface").treesitter.name_node_types.field_name, true)
equal(adapters.get("ocaml_interface").treesitter.name_node_types.tag, true)
equal(adapters.get("ocaml_interface").filename_extensions, { ".mli" })
equal(adapters.get("nix").treesitter.root_markers, {
  ".git",
  "flake.nix",
  "go.mod",
  "Cargo.toml",
  "dune-project",
  "package.json",
  "pyproject.toml",
})

for _, language in ipairs({
  "go",
  "javascript",
  "lua",
  "nix",
  "python",
  "rust",
  "tsx",
  "typescript",
}) do
  equal(adapters.get(language).ast_grep.language, language)
end

local unsupported = adapters.get("ocaml").ast_grep.unsupported_note
equal(
  unsupported,
  "ast-grep has no OCaml parser; semantic references and Tree-sitter context remain available."
)
equal(adapters.get("ocaml_interface").ast_grep.unsupported_note, unsupported)

local go_interface = {
  kind = vim.lsp.protocol.SymbolKind.Interface,
  language = "go",
  syntax_node_type = "type_spec",
}
equal(adapters.section_presentation(go_interface, { id = "supertypes" }, {}), {
  key = "satisfies",
  label = "Satisfies",
  order = 10,
})
equal(
  adapters.section_presentation(go_interface, { id = "subtypes" }, {
    kind = vim.lsp.protocol.SymbolKind.Interface,
  }),
  { key = "extended", label = "Extended by", order = 10, show_kind = true }
)
equal(
  adapters.section_presentation(go_interface, { id = "subtypes" }, {
    kind = vim.lsp.protocol.SymbolKind.Struct,
  }),
  { key = "implemented", label = "Implemented by", order = 20, show_kind = true }
)
equal(adapters.section_presentation(go_interface, { id = "children" }, {}), {
  label = "Members",
})
local go_package = {
  is_boundary = true,
  boundary_level = "package",
  language = "go",
}
equal(adapters.section_presentation(go_package, { id = "module_imports" }, {}), {
  label = "Package dependencies",
})
equal(adapters.section_presentation(go_package, { id = "module_importers" }, {}), {
  label = "Package dependents",
})
equal(
  adapters.row_presentation(go_interface, { id = "implementations" }, {
    name = "type Client struct {",
  }),
  { name = "Client", kind_name = "Struct" }
)
equal(
  adapters.row_presentation(go_interface, { id = "implementations" }, {
    name = "type Identifier string",
  }),
  { name = "Identifier", kind_name = "Type" }
)
equal(
  adapters.row_presentation(go_interface, { id = "subtypes" }, {
    kind = vim.lsp.protocol.SymbolKind.Class,
    kind_name = "Class",
    name = "Client",
  }),
  { kind_name = "Type" }
)

local rust_trait = {
  kind = vim.lsp.protocol.SymbolKind.Interface,
  language = "rust",
  syntax_node_type = "trait_item",
}
equal(adapters.section_presentation(rust_trait, { id = "implementations" }, {}), {
  label = "Implemented by",
})
equal(
  adapters.row_presentation(rust_trait, { id = "implementations" }, {
    name = "impl Provider for AgeProvider {",
  }),
  { name = "AgeProvider", kind_name = "Implementation" }
)
equal(
  adapters.row_presentation(rust_trait, { id = "implementations" }, {
    name = "impl Provider",
  }),
  nil,
  "multiline implementation headers should retain their source text rather than infer a false target"
)
equal(
  adapters.row_presentation(rust_trait, { id = "implementations" }, {
    name = "impl Provider for Wrapped<T> where T: Send {",
  }),
  { name = "Wrapped<T>", kind_name = "Implementation" }
)

local method_pattern, method_selector = ast_grep._query_for({
  name = "Serve",
  syntax_node_type = "method_declaration",
}, "go")
equal(method_pattern, "var _ = $RECEIVER.Serve")
equal(method_selector, "selector_expression")

local function_pattern, function_selector = ast_grep._query_for({
  name = "serve",
  syntax_node_type = "function_declaration",
}, "go")
equal(function_pattern, "func _() { serve($$$ARGS) }")
equal(function_selector, "call_expression")

local generic_pattern, generic_selector = ast_grep._query_for({ name = "serve" }, "rust")
equal(generic_pattern, "serve")
equal(generic_selector, nil)

local zig = adapters.register("zig", {
  filetypes = { "zig", "zir" },
  treesitter = {
    root_markers = { "build.zig" },
    symbol_types = { function_declaration = "Function" },
  },
  ast_grep = { language = "zig" },
})
equal(adapters.for_filetype("zir"), zig)
equal(adapters.language_for_filetype("zir"), "zig")
equal(zig.treesitter.root_markers, { "build.zig" })
equal(adapters.root_markers("zir"), { "build.zig" })
equal(zig.treesitter.name_fields, { "name", "pattern", "attrpath" })

zig.language = "mutated"
zig.treesitter.root_markers[1] = "mutated.marker"
equal(adapters.get("zig").language, "zig")
equal(adapters.root_markers("zir"), { "build.zig" })

adapters.register("react_component", {
  filetypes = { "reactcomponent" },
  ast_grep = {
    language = "tsx",
    query = function(context)
      return "<" .. context.name .. " />", "jsx_self_closing_element"
    end,
  },
})
local tsx_pattern, tsx_selector = ast_grep._query_for({
  name = "Widget",
  language = "react_component",
}, "tsx")
equal(tsx_pattern, "<Widget />")
equal(tsx_selector, "jsx_self_closing_element")

local duplicate_ok = pcall(adapters.register, "zig", {})
equal(duplicate_ok, false)

local presentation_ok = pcall(adapters.register, "invalid_presentation", {
  presentation = { section = true },
})
equal(presentation_ok, false, "adapter presentation hooks must be functions")
local wrappers_ok = pcall(adapters.register, "invalid_wrappers", {
  treesitter = {
    focus_wrappers = { wrapper = false },
    symbol_types = { declaration = "Type" },
  },
})
equal(wrappers_ok, false, "focus wrappers must be explicit node-type flags")

local invalid_static_specs = {
  {
    id = "invalid_unknown_field",
    spec = { relationship_kinds = {} },
    error = "unsupported adapter field: relationship_kinds",
  },
  {
    id = "invalid_filetypes",
    spec = { filetypes = "zig" },
    error = "adapter filetypes must be a list",
  },
  {
    id = "duplicate_filetypes",
    spec = { filetypes = { "zig", "zig" } },
    error = "adapter filetypes contains duplicate value: zig",
  },
  {
    id = "invalid_filename_extension",
    spec = { filename_extensions = { "zig" } },
    error = "adapter filename_extensions[1] is invalid",
  },
  {
    id = "invalid_treesitter_shape",
    spec = { treesitter = true },
    error = "adapter treesitter must be a table",
  },
  {
    id = "invalid_treesitter_field",
    spec = { treesitter = { symbol_types = {}, query = "(_) @symbol" } },
    error = "unsupported Tree-sitter adapter field: query",
  },
  {
    id = "missing_symbol_types",
    spec = { treesitter = {} },
    error = "Tree-sitter symbol_types must be a map",
  },
  {
    id = "invalid_symbol_types",
    spec = { treesitter = { symbol_types = { declaration = "" } } },
    error = "Tree-sitter symbol_types contains an invalid value for declaration",
  },
  {
    id = "invalid_root_markers",
    spec = { treesitter = { symbol_types = {}, root_markers = { 42 } } },
    error = "Tree-sitter root_markers[1] is invalid",
  },
  {
    id = "invalid_name_fields",
    spec = { treesitter = { symbol_types = {}, name_fields = "name" } },
    error = "Tree-sitter name_fields must be a list",
  },
  {
    id = "invalid_name_node_types",
    spec = { treesitter = { symbol_types = {}, name_node_types = { identifier = false } } },
    error = "Tree-sitter name_node_types contains an invalid value for identifier",
  },
  {
    id = "invalid_synthetic_name",
    spec = { treesitter = { symbol_types = {}, synthetic_name = "name" } },
    error = "Tree-sitter synthetic_name must be a function",
  },
  {
    id = "invalid_import_field",
    spec = { treesitter = { symbol_types = {}, imports = { query = "(_) @import", mode = "all" } } },
    error = "unsupported Tree-sitter import adapter field: mode",
  },
  {
    id = "invalid_import_capture",
    spec = { treesitter = { symbol_types = {}, imports = { query = "(_) @import", capture = 42 } } },
    error = "Tree-sitter import adapters require a capture",
  },
  {
    id = "invalid_import_query",
    spec = { treesitter = { symbol_types = {}, imports = { query = " " } } },
    error = "Tree-sitter import adapters require a query",
  },
  {
    id = "invalid_import_extensions",
    spec = {
      treesitter = { symbol_types = {}, imports = { query = "(_) @import", extensions = { "go" } } },
    },
    error = "Tree-sitter import extensions[1] is invalid",
  },
  {
    id = "invalid_import_hook",
    spec = {
      treesitter = { symbol_types = {}, imports = { query = "(_) @import", target_keys = true } },
    },
    error = "Tree-sitter import adapter target_keys must be a function",
  },
  {
    id = "invalid_ast_grep_field",
    spec = { ast_grep = { language = "zig", max_results = 10 } },
    error = "unsupported ast-grep adapter field: max_results",
  },
  {
    id = "invalid_ast_grep_language",
    spec = { ast_grep = { language = " " } },
    error = "ast-grep adapter language must be a non-empty string",
  },
  {
    id = "invalid_ast_grep_query",
    spec = { ast_grep = { query = function() end } },
    error = "ast-grep adapter query requires a language",
  },
  {
    id = "invalid_ast_grep_note",
    spec = { ast_grep = { unsupported_note = "" } },
    error = "ast-grep adapter unsupported_note must be a non-empty string",
  },
  {
    id = "invalid_boundary_field",
    spec = { boundaries = { resolve = function() end, fallback = "directory" } },
    error = "unsupported boundaries adapter field: fallback",
  },
  {
    id = "invalid_boundary_resolver",
    spec = { boundaries = { resolve = true } },
    error = "boundaries adapters require resolve or discover",
  },
  {
    id = "invalid_boundary_discovery",
    spec = { boundaries = { discover = true } },
    error = "boundaries adapters require resolve or discover",
  },
  {
    id = "invalid_presentation_field",
    spec = { presentation = { group = function() end } },
    error = "unsupported adapter presentation field: group",
  },
  {
    id = "invalid_configuration",
    spec = { configuration = {} },
    error = "adapter configuration must be a function",
  },
}

for _, invalid in ipairs(invalid_static_specs) do
  local ok, err = pcall(adapters.register, invalid.id, invalid.spec)
  assert(not ok, invalid.id .. " should be rejected")
  assert(
    tostring(err):find(invalid.error, 1, true),
    string.format("%s should report %q, got %s", invalid.id, invalid.error, tostring(err))
  )
end

adapters.register("broken_boundary", {
  boundaries = {
    resolve = function()
      return {
        {
          id = "broken:value",
          name = "broken",
          kind_name = "Broken package",
          level = "package",
          path = "/workspace/broken",
          class = "language",
          representative_path = 42,
        },
      }
    end,
  },
})
local _, boundary_error =
  adapters.resolve_boundaries("broken_boundary", "/workspace/broken/source", "/workspace", {})
assert(
  boundary_error
    and boundary_error:find("boundary representative_path must be a non-empty string", 1, true),
  "invalid boundary descriptors should use the adapter diagnostic path"
)

adapters.register("broken_hooks", {
  configuration = function()
    error("configuration exploded")
  end,
  ast_grep = {
    language = "lua",
    query = function()
      error("query exploded")
    end,
  },
  presentation = {
    row = function()
      error("row presentation exploded")
    end,
    section = function()
      return { label = "" }
    end,
  },
})
local _, configuration_error = adapters.configuration("broken_hooks", 0, {}, {})
assert(
  configuration_error
    and configuration_error:find("broken_hooks adapter configuration failed", 1, true),
  "configuration callback failures should identify the adapter and hook"
)
local _, normalization_error = adapters.normalize_import("broken_hooks", {
  normalize = function()
    error("normalization exploded")
  end,
}, nil, '"broken"', 0, {})
assert(
  normalization_error
    and normalization_error:find("broken_hooks adapter import normalization failed", 1, true),
  "import normalization failures should identify the adapter and hook"
)
local _, invalid_normalization_error = adapters.normalize_import("broken_hooks", {
  normalize = function()
    return "invalid"
  end,
}, nil, '"broken"', 0, {})
assert(
  invalid_normalization_error
    and invalid_normalization_error:find("must return a table or nil", 1, true),
  "invalid import normalization values should use the same diagnostic path"
)
local _, _, query_error = adapters.ast_grep_query({ name = "Focus" }, "broken_hooks")
assert(
  query_error and query_error:find("broken_hooks adapter ast-grep query failed", 1, true),
  "structural query failures should identify the adapter and hook"
)
local graph = require("archlens.graph")
local broken_context = {
  adapter_issues = { configuration_error, normalization_error },
  kind = vim.lsp.protocol.SymbolKind.Struct,
  kind_name = "Struct",
  language = "broken_hooks",
  location = {
    uri = "file:///workspace/focus.lua",
    range = {
      start = { line = 0, character = 0 },
      ["end"] = { line = 0, character = 5 },
    },
  },
  name = "Focus",
  position_encoding = "utf-8",
  root_dir = "/workspace",
  supports_calls = false,
}
local broken_snapshot = graph.new(broken_context)
graph.add_edge(
  broken_snapshot,
  graph.edge(
    "references",
    graph.node_from_location({
      uri = "file:///workspace/use.lua",
      range = {
        start = { line = 4, character = 0 },
        ["end"] = { line = 4, character = 5 },
      },
    }, { name = "Focus()", kind_name = "Reference" }),
    broken_snapshot.focus,
    { provider = "test-lsp", method = "textDocument/references", class = "semantic" }
  )
)
local broken_model = require("archlens.model").build(broken_context, broken_snapshot, {
  include_external = true,
})
equal(
  broken_model.sections[1].label,
  "Referenced across project",
  "failed presentation hooks should retain the canonical section"
)
equal(
  broken_model.sections[1].rows[1].name,
  "Focus()",
  "failed presentation hooks should retain the canonical row"
)
equal(
  broken_model.result.parts[1],
  { label = "4 adapter issues", severity = "error" },
  "adapter callback failures should remain inspectable without crashing the model"
)
local broken_query_result
local broken_query_outcome
ast_grep.relationships(broken_context, { command = "true" }, function(result, outcome)
  broken_query_result = result
  broken_query_outcome = outcome
end)
equal(broken_query_result.notes, { query_error })
equal(broken_query_result.note_records, {
  { message = query_error, summary = "adapter query failed", severity = "error" },
})
equal(broken_query_outcome, {
  state = "failed",
  message = query_error,
}, "failed structural query hooks should become provider outcomes")

local ast_only_buffer = vim.api.nvim_create_buf(false, true)
vim.bo[ast_only_buffer].filetype = "lua"
local semantic_context = { name = "resolve_me" }
local propagated = require("archlens.treesitter").resolve(ast_only_buffer, {
  line = 0,
  character = 0,
}, semantic_context)
equal(propagated.language, "lua")
equal(semantic_context.language, nil)
local ast_only_result
local ast_only_outcome
require("archlens.ast_grep").relationships(propagated, {
  command = "archlens-definitely-missing-ast-grep",
}, function(result, outcome)
  ast_only_result = result
  ast_only_outcome = outcome
end)
equal(ast_only_result.notes, {})
equal(ast_only_outcome, {
  state = "unavailable",
  message = "ast-grep is unavailable; structural project matches were skipped.",
}, "an ast-grep-only adapter should publish an unavailable outcome")

local failing_ast_grep = vim.fs.joinpath(vim.fn.tempname(), "failing-ast-grep")
vim.fn.mkdir(vim.fs.dirname(failing_ast_grep), "p")
vim.fn.writefile({ "#!/bin/sh", "echo 'simulated failure' >&2", "exit 2" }, failing_ast_grep)
assert(vim.uv.fs_chmod(failing_ast_grep, 493))
local failed_result
local failed_outcome
local failed_context = vim.deepcopy(propagated)
failed_context.root_dir = vim.fs.dirname(failing_ast_grep)
failed_context.path = vim.fs.joinpath(failed_context.root_dir, "focus.lua")
failed_context.location = {
  uri = vim.uri_from_fname(failed_context.path),
  range = {
    start = { line = 0, character = 0 },
    ["end"] = { line = 0, character = 5 },
  },
}
failed_context.position_encoding = "utf-8"
require("archlens.ast_grep").relationships(failed_context, {
  command = failing_ast_grep,
}, function(result, outcome)
  failed_result = result
  failed_outcome = outcome
end)
assert(vim.wait(1000, function()
  return failed_result ~= nil
end, 10))
equal(failed_outcome, {
  state = "failed",
  message = "ast-grep search failed: simulated failure",
}, "a failed ast-grep process should publish a failed lifecycle outcome")
assert(
  table.concat(failed_result.notes, "\n"):find("simulated failure", 1, true),
  "a failed ast-grep process should remain visible in result details"
)

local noisy_ast_grep = vim.fs.joinpath(vim.fn.tempname(), "noisy-ast-grep")
vim.fn.mkdir(vim.fs.dirname(noisy_ast_grep), "p")
vim.fn.writefile({ "#!/bin/sh", "printf '%064d' 0", "sleep 0.1" }, noisy_ast_grep)
assert(vim.uv.fs_chmod(noisy_ast_grep, 493))
local limited_output
local limited_outcome
local noisy_context = vim.deepcopy(propagated)
noisy_context.root_dir = vim.fs.dirname(noisy_ast_grep)
noisy_context.path = vim.fs.joinpath(noisy_context.root_dir, "focus.lua")
noisy_context.location = vim.deepcopy(failed_context.location)
noisy_context.location.uri = vim.uri_from_fname(noisy_context.path)
noisy_context.position_encoding = "utf-8"
require("archlens.ast_grep").relationships(noisy_context, {
  command = noisy_ast_grep,
  max_output_bytes = 16,
}, function(result, outcome)
  limited_output = result
  limited_outcome = outcome
end)
assert(vim.wait(1000, function()
  return limited_output ~= nil
end, 10))
equal(limited_outcome, nil, "the configured ast-grep output limit should be a bounded completion")
assert(
  table.concat(limited_output.notes, "\n"):find("ast%-grep output reached the 16%-byte limit"),
  "ast-grep should report when subprocess output reaches its memory bound"
)

local noisy_stderr = vim.fs.joinpath(vim.fn.tempname(), "noisy-ast-grep-stderr")
vim.fn.mkdir(vim.fs.dirname(noisy_stderr), "p")
vim.fn.writefile({ "#!/bin/sh", "printf '%064d' 0 >&2", "sleep 0.1", "exit 2" }, noisy_stderr)
assert(vim.uv.fs_chmod(noisy_stderr, 493))
local limited_error
local limited_error_outcome
require("archlens.ast_grep").relationships(noisy_context, {
  command = noisy_stderr,
  max_output_bytes = 16,
}, function(result, outcome)
  limited_error = result
  limited_error_outcome = outcome
end)
assert(vim.wait(1000, function()
  return limited_error ~= nil
end, 10))
equal(limited_error_outcome, {
  state = "failed",
  message = "ast-grep search failed: error output reached the 16-byte limit",
}, "the ast-grep error-output limit should stop a noisy failed process")
assert(
  table.concat(limited_error.notes, "\n"):find("error output reached the 16%-byte limit"),
  "ast-grep should report when error output reaches its memory bound"
)

local timeout_root = vim.fn.tempname()
vim.fn.mkdir(timeout_root, "p")
local slow_ast_grep = vim.fs.joinpath(timeout_root, "slow-ast-grep")
vim.fn.writefile({ "#!/bin/sh", "sleep 0.1" }, slow_ast_grep)
assert(vim.uv.fs_chmod(slow_ast_grep, 493))
local timeout_context = vim.deepcopy(propagated)
timeout_context.root_dir = timeout_root
timeout_context.path = vim.fs.joinpath(timeout_root, "focus.lua")
local graph = require("archlens.graph")
local original_node_from_context = graph.node_from_context
local late_focus_builds = 0
graph.node_from_context = function()
  late_focus_builds = late_focus_builds + 1
  return { id = "focus", scope = "symbol" }
end
local ast_timeout_result
local ast_timeout_outcome
require("archlens.ast_grep").relationships(timeout_context, {
  command = slow_ast_grep,
  timeout_ms = 10,
}, function(result, outcome)
  ast_timeout_result = result
  ast_timeout_outcome = outcome
end)
assert(
  vim.wait(1000, function()
    return ast_timeout_result ~= nil
  end, 10),
  "ast-grep should enforce its search deadline"
)
equal(ast_timeout_result.notes, {})
equal(ast_timeout_outcome, {
  state = "timed_out",
  message = "ast-grep search exceeded 10 ms and was stopped.",
})
vim.wait(500, function()
  return false
end, 10)
equal(late_focus_builds, 0, "a stopped ast-grep process must not materialize late results")
graph.node_from_context = original_node_from_context
vim.api.nvim_buf_delete(ast_only_buffer, { force = true })

local parser_missing_buffer = vim.api.nvim_create_buf(false, true)
vim.bo[parser_missing_buffer].filetype = "zir"
local parser_missing = require("archlens.treesitter").resolve(parser_missing_buffer, {
  line = 0,
  character = 0,
}, semantic_context)
equal(parser_missing.language, "zig")
vim.api.nvim_buf_delete(parser_missing_buffer, { force = true })

print("archlens adapter tests passed")

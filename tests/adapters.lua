local adapters = require("archlens.adapters")
local ast_grep = require("archlens.ast_grep")

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

adapters.register("broken_hooks", {
  configuration = function()
    error("configuration exploded")
  end,
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

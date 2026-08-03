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
require("archlens.ast_grep").relationships(propagated, {
  command = "archlens-definitely-missing-ast-grep",
}, function(result)
  ast_only_result = result
end)
assert(
  ast_only_result
    and ast_only_result.notes[1]
    and ast_only_result.notes[1]:find("unavailable", 1, true),
  "an ast-grep-only adapter should reach provider readiness checks"
)
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

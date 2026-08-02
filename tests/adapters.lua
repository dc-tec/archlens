local adapters = require("archlens.adapters")
local ast_grep = require("archlens.ast_grep")

local function equal(actual, expected, message)
  assert(vim.deep_equal(actual, expected), message or vim.inspect({ actual, expected }))
end

equal(adapters.language_for_filetype("go"), "go")
equal(adapters.language_for_filetype("ocamlinterface"), "ocaml_interface")
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
  function_declaration = "Function",
  method_declaration = "Method",
  type_declaration = "Type",
  type_spec = "Type",
})
equal(adapters.get("rust").treesitter.symbol_types.impl_item, "Implementation")
equal(adapters.get("ocaml_interface").treesitter.symbol_types.value_specification, "Value")
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

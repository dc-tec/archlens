local M = {}

local registry = {}
local filetypes = {}

local default_root_markers = {
  ".git",
  "flake.nix",
  "go.mod",
  "Cargo.toml",
  "dune-project",
  "package.json",
  "pyproject.toml",
}

local default_name_fields = {
  "name",
  "pattern",
  "attrpath",
}

local default_name_node_types = {
  attrpath = true,
  field_identifier = true,
  identifier = true,
  module_name = true,
  type_constructor = true,
  type_identifier = true,
  value_name = true,
}

local function declaration_name(node_type, text)
  if node_type == "impl_item" then
    return text:match("^%s*impl%s+(.+)$")
  end
  return text:match("^%s*module%s+([%w_']+)")
    or text:match("^%s*module%s+type%s+([%w_']+)")
    or text:match("^%s*type%s+([%w_']+)")
end

local function go_query(context)
  if context.syntax_node_type == "method_declaration" then
    return "var _ = $RECEIVER." .. context.name, "selector_expression"
  end
  return "func _() { " .. context.name .. "($$$ARGS) }", "call_expression"
end

local function normalize(language, adapter)
  assert(type(language) == "string" and language ~= "", "adapter language must be a string")
  assert(type(adapter) == "table", "adapter must be a table")

  local normalized = vim.deepcopy(adapter)
  normalized.language = language
  normalized.filetypes = normalized.filetypes or { language }

  if normalized.treesitter then
    assert(
      type(normalized.treesitter.symbol_types) == "table",
      "Tree-sitter adapters require symbol_types"
    )
    normalized.treesitter.root_markers = normalized.treesitter.root_markers
      or vim.deepcopy(default_root_markers)
    normalized.treesitter.name_fields = normalized.treesitter.name_fields
      or vim.deepcopy(default_name_fields)
    normalized.treesitter.name_node_types = normalized.treesitter.name_node_types
      or vim.deepcopy(default_name_node_types)
    normalized.treesitter.synthetic_name = normalized.treesitter.synthetic_name or declaration_name
  end

  return normalized
end

function M.register(language, adapter)
  assert(registry[language] == nil, string.format("adapter already registered: %s", language))
  local normalized = normalize(language, adapter)

  for _, filetype in ipairs(normalized.filetypes) do
    assert(filetypes[filetype] == nil, string.format("filetype already registered: %s", filetype))
  end

  registry[language] = normalized
  for _, filetype in ipairs(normalized.filetypes) do
    filetypes[filetype] = language
  end
  return vim.deepcopy(normalized)
end

function M.get(language)
  return vim.deepcopy(registry[language])
end

function M.for_filetype(filetype)
  return M.get(filetypes[filetype] or filetype)
end

function M.language_for_filetype(filetype)
  return filetypes[filetype] or filetype
end

function M.root_markers(filetype)
  local adapter = M.for_filetype(filetype)
  local treesitter = adapter and adapter.treesitter
  return vim.deepcopy(treesitter and treesitter.root_markers or default_root_markers)
end

function M.ast_grep_query(context, language)
  local adapter = registry[language]
  local provider = adapter and adapter.ast_grep
  if provider and provider.query then
    return provider.query(context)
  end
  return context.name, nil
end

M.register("go", {
  treesitter = {
    symbol_types = {
      function_declaration = "Function",
      method_declaration = "Method",
      type_declaration = "Type",
      type_spec = "Type",
    },
  },
  ast_grep = {
    language = "go",
    query = go_query,
  },
})

M.register("nix", {
  treesitter = {
    symbol_types = {
      binding = "Binding",
      inherit = "Binding",
    },
  },
  ast_grep = { language = "nix" },
})

M.register("ocaml", {
  treesitter = {
    symbol_types = {
      class_definition = "Class",
      let_binding = "Value",
      method_definition = "Method",
      module_definition = "Module",
      module_type_definition = "Module",
      type_definition = "Type",
    },
  },
  ast_grep = {
    unsupported_note = "ast-grep has no OCaml parser; semantic references and Tree-sitter context remain available.",
  },
})

M.register("ocaml_interface", {
  filetypes = { "ocamlinterface" },
  treesitter = {
    symbol_types = {
      class_specification = "Class",
      module_specification = "Module",
      module_type_definition = "Module",
      type_definition = "Type",
      value_specification = "Value",
    },
  },
  ast_grep = {
    unsupported_note = "ast-grep has no OCaml parser; semantic references and Tree-sitter context remain available.",
  },
})

M.register("rust", {
  treesitter = {
    symbol_types = {
      const_item = "Constant",
      enum_item = "Enum",
      function_item = "Function",
      impl_item = "Implementation",
      mod_item = "Module",
      static_item = "Constant",
      struct_item = "Struct",
      trait_item = "Interface",
      type_item = "Type",
    },
  },
  ast_grep = { language = "rust" },
})

M.register("javascript", {
  filetypes = { "javascript", "javascriptreact" },
  ast_grep = { language = "javascript" },
})
M.register("lua", { ast_grep = { language = "lua" } })
M.register("python", { ast_grep = { language = "python" } })
M.register("tsx", {
  filetypes = { "tsx", "typescriptreact" },
  ast_grep = { language = "tsx" },
})
M.register("typescript", { ast_grep = { language = "typescript" } })

return M

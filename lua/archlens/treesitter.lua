local model = require("archlens.model")

local M = {}

local project_markers = {
  ".git",
  "flake.nix",
  "go.mod",
  "Cargo.toml",
  "dune-project",
  "package.json",
  "pyproject.toml",
}

local language_for_filetype = {
  go = "go",
  nix = "nix",
  ocaml = "ocaml",
  ocamlinterface = "ocaml_interface",
  rust = "rust",
}

local symbol_types = {
  go = {
    function_declaration = "Function",
    method_declaration = "Method",
    type_declaration = "Type",
    type_spec = "Type",
  },
  nix = {
    binding = "Binding",
    inherit = "Binding",
  },
  ocaml = {
    class_definition = "Class",
    let_binding = "Value",
    method_definition = "Method",
    module_definition = "Module",
    module_type_definition = "Module",
    type_definition = "Type",
  },
  ocaml_interface = {
    class_specification = "Class",
    module_specification = "Module",
    module_type_definition = "Module",
    type_definition = "Type",
    value_specification = "Value",
  },
  rust = {
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
}

local kind_by_label = {
  Binding = vim.lsp.protocol.SymbolKind.Property,
  Class = vim.lsp.protocol.SymbolKind.Class,
  Constant = vim.lsp.protocol.SymbolKind.Constant,
  Enum = vim.lsp.protocol.SymbolKind.Enum,
  Function = vim.lsp.protocol.SymbolKind.Function,
  Implementation = vim.lsp.protocol.SymbolKind.Namespace,
  Interface = vim.lsp.protocol.SymbolKind.Interface,
  Method = vim.lsp.protocol.SymbolKind.Method,
  Module = vim.lsp.protocol.SymbolKind.Module,
  Struct = vim.lsp.protocol.SymbolKind.Struct,
  Type = vim.lsp.protocol.SymbolKind.TypeParameter,
  Value = vim.lsp.protocol.SymbolKind.Variable,
}

local name_fields = {
  "name",
  "pattern",
  "attrpath",
}

local name_node_types = {
  attrpath = true,
  field_identifier = true,
  identifier = true,
  module_name = true,
  type_constructor = true,
  type_identifier = true,
  value_name = true,
}

local function node_text(node, bufnr)
  if not node then
    return nil
  end
  local ok, text = pcall(vim.treesitter.get_node_text, node, bufnr)
  if not ok or type(text) ~= "string" then
    return nil
  end
  return vim.trim(text:gsub("%s+", " "))
end

local function first_line(text)
  return text and text:match("^[^\n{]+") or nil
end

local function synthetic_name(node, bufnr)
  local text = first_line(node_text(node, bufnr))
  if not text then
    return nil
  end
  if node:type() == "impl_item" then
    return text:match("^%s*impl%s+(.+)$")
  end
  return text:match("^%s*module%s+([%w_']+)")
    or text:match("^%s*module%s+type%s+([%w_']+)")
    or text:match("^%s*type%s+([%w_']+)")
end

local function name_node(node, bufnr)
  for _, field in ipairs(name_fields) do
    local nodes = node:field(field)
    if nodes and nodes[1] then
      return nodes[1], node_text(nodes[1], bufnr)
    end
  end
  for index = 0, node:named_child_count() - 1 do
    local child = node:named_child(index)
    if name_node_types[child:type()] then
      return child, node_text(child, bufnr)
    end
  end
  return nil, synthetic_name(node, bufnr)
end

local function node_range(node)
  local start_row, start_col, end_row, end_col = node:range()
  return {
    start = { line = start_row, character = start_col },
    ["end"] = { line = end_row, character = end_col },
  }
end

local function root_for(bufnr)
  local path = vim.api.nvim_buf_get_name(bufnr)
  if path == "" then
    return nil
  end
  return vim.fs.root(path, project_markers) or vim.fs.dirname(path)
end

local function language_for(bufnr)
  local filetype = vim.bo[bufnr].filetype
  return language_for_filetype[filetype] or filetype
end

local function label_for(language, node)
  local language_types = symbol_types[language] or {}
  return language_types[node:type()]
end

local function is_symbol(language, node, bufnr)
  if not label_for(language, node) then
    return false
  end
  local _, name = name_node(node, bufnr)
  return name ~= nil and name ~= ""
end

local function item_from_node(node, bufnr, language)
  local name_target, name = name_node(node, bufnr)
  local range = node_range(node)
  return {
    name = name,
    kind = kind_by_label[label_for(language, node)] or vim.lsp.protocol.SymbolKind.Variable,
    uri = vim.uri_from_bufnr(bufnr),
    range = range,
    selectionRange = name_target and node_range(name_target) or range,
  }
end

local function context_from_node(node, bufnr, language, provider)
  local context = model.context_from_item(item_from_node(node, bufnr, language), provider)
  context.language = language
  context.syntax_node_type = node:type()
  context.kind_name = label_for(language, node) or context.kind_name
  return context
end

local function direct_symbols(container, current, bufnr, language, provider)
  local rows = {}
  local function visit(node)
    for index = 0, node:named_child_count() - 1 do
      local child = node:named_child(index)
      if child:id() ~= current:id() and is_symbol(language, child, bufnr) then
        rows[#rows + 1] = context_from_node(child, bufnr, language, provider)
      elseif child:id() ~= current:id() then
        visit(child)
      end
    end
  end
  visit(container)
  return rows
end

local function symbol_parent(node, bufnr, language)
  local parent = node:parent()
  while parent do
    if is_symbol(language, parent, bufnr) then
      return parent
    end
    parent = parent:parent()
  end
  return nil
end

local function range_span(range)
  if not range or not range.start or not range["end"] then
    return math.huge
  end
  return (range["end"].line - range.start.line) * 100000
    + range["end"].character
    - range.start.character
end

local function merge_base(syntax_context, base_context)
  if not base_context then
    return syntax_context
  end

  local use_syntax_identity = not base_context.supports_calls
    and range_span(syntax_context.location and syntax_context.location.full_range)
      <= range_span(base_context.location and base_context.location.full_range)
  local merged = use_syntax_identity and syntax_context or vim.deepcopy(base_context)
  merged.client_id = base_context.client_id
  merged.client_name = base_context.client_name
  merged.position_encoding = base_context.position_encoding
  merged.root_dir = base_context.root_dir or syntax_context.root_dir
  merged.supports_calls = base_context.supports_calls
  merged.call_item = base_context.supports_calls and base_context.item or nil
  merged.language = syntax_context.language
  merged.syntax_node_type = syntax_context.syntax_node_type
  return merged
end

function M.resolve(bufnr, position, base_context)
  local language = language_for(bufnr)
  if not symbol_types[language] then
    return base_context
  end

  local ok, parser = pcall(vim.treesitter.get_parser, bufnr, language, { error = false })
  if not ok or not parser then
    return base_context
  end
  local trees = parser:parse()
  local root = trees and trees[1] and trees[1]:root()
  if not root then
    return base_context
  end

  local node = root:named_descendant_for_range(
    position.line,
    position.character,
    position.line,
    position.character
  )
  while node and not is_symbol(language, node, bufnr) do
    node = node:parent()
  end
  if not node then
    return base_context
  end

  local provider = {
    id = base_context and base_context.client_id or nil,
    name = base_context and base_context.client_name or "Tree-sitter",
    offset_encoding = base_context and base_context.position_encoding or "utf-8",
    root_dir = base_context and base_context.root_dir or root_for(bufnr),
    supports_calls = false,
  }
  local syntax_context = context_from_node(node, bufnr, language, provider)
  local context = merge_base(syntax_context, base_context)

  local ancestors = {}
  local parent = symbol_parent(node, bufnr, language)
  while parent do
    table.insert(ancestors, 1, context_from_node(parent, bufnr, language, provider))
    parent = symbol_parent(parent, bufnr, language)
  end

  local child_contexts = direct_symbols(node, node, bufnr, language, provider)
  local container = symbol_parent(node, bufnr, language) or root
  local sibling_contexts = direct_symbols(container, node, bufnr, language, provider)
  local siblings = {}
  for _, sibling in ipairs(sibling_contexts) do
    local same = sibling.location.uri == syntax_context.location.uri
      and sibling.location.range.start.line == syntax_context.location.range.start.line
      and sibling.location.range.start.character == syntax_context.location.range.start.character
    if not same then
      siblings[#siblings + 1] = sibling
    end
  end

  context.syntax = {
    provider = "Tree-sitter",
    ancestors = ancestors,
    children = child_contexts,
    siblings = siblings,
  }
  return context
end

function M.supports(bufnr)
  return symbol_types[language_for(bufnr)] ~= nil
end

return M

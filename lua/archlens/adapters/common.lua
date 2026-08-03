local M = {}

local default_name_node_types = {
  attrpath = true,
  field_identifier = true,
  identifier = true,
  module_name = true,
  type_constructor = true,
  type_identifier = true,
  value_name = true,
}

local type_kinds = {
  [vim.lsp.protocol.SymbolKind.Class] = true,
  [vim.lsp.protocol.SymbolKind.Enum] = true,
  [vim.lsp.protocol.SymbolKind.Interface] = true,
  [vim.lsp.protocol.SymbolKind.Object] = true,
  [vim.lsp.protocol.SymbolKind.Struct] = true,
  [vim.lsp.protocol.SymbolKind.TypeParameter] = true,
}

function M.name_node_types(extra)
  return vim.tbl_extend("force", vim.deepcopy(default_name_node_types), extra or {})
end

function M.member_section(context, relation)
  local type_focus = type_kinds[context.kind] == true
    or context.syntax_node_type == "impl_item"
    or context.syntax_node_type == "type_binding"
    or context.syntax_node_type == "type_spec"
  if type_focus and relation.id == "children" then
    return { label = "Members" }
  end
end

function M.existing_paths(paths)
  local targets = {}
  for _, path in ipairs(paths) do
    local stat = vim.uv.fs_stat(path)
    if stat and stat.type == "file" then
      targets[#targets + 1] = vim.fs.normalize(path)
    end
  end
  return targets
end

function M.node_text(node, source)
  local ok, text = pcall(vim.treesitter.get_node_text, node, source)
  return ok and text or ""
end

function M.source_path(source, metadata)
  if metadata and metadata.path then
    return metadata.path
  end
  if type(source) == "number" then
    return vim.api.nvim_buf_get_name(source)
  end
end

return M

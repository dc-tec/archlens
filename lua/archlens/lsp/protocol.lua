local M = {}

M.methods = {
  symbols = "textDocument/documentSymbol",
  definition = "textDocument/definition",
  prepare = "textDocument/prepareCallHierarchy",
  incoming = "callHierarchy/incomingCalls",
  outgoing = "callHierarchy/outgoingCalls",
  prepare_type = "textDocument/prepareTypeHierarchy",
  supertypes = "typeHierarchy/supertypes",
  subtypes = "typeHierarchy/subtypes",
  references = "textDocument/references",
  implementation = "textDocument/implementation",
}

M.implementation_kinds = {
  [vim.lsp.protocol.SymbolKind.Class] = true,
  [vim.lsp.protocol.SymbolKind.Method] = true,
  [vim.lsp.protocol.SymbolKind.Property] = true,
  [vim.lsp.protocol.SymbolKind.Field] = true,
  [vim.lsp.protocol.SymbolKind.Enum] = true,
  [vim.lsp.protocol.SymbolKind.Interface] = true,
  [vim.lsp.protocol.SymbolKind.Object] = true,
  [vim.lsp.protocol.SymbolKind.Struct] = true,
  [vim.lsp.protocol.SymbolKind.TypeParameter] = true,
}

M.type_hierarchy_kinds = {
  [vim.lsp.protocol.SymbolKind.Class] = true,
  [vim.lsp.protocol.SymbolKind.Enum] = true,
  [vim.lsp.protocol.SymbolKind.Interface] = true,
  [vim.lsp.protocol.SymbolKind.Object] = true,
  [vim.lsp.protocol.SymbolKind.Struct] = true,
  [vim.lsp.protocol.SymbolKind.TypeParameter] = true,
}

function M.supports_symbol_kind(context, kinds)
  return context.kind == nil or kinds[context.kind] == true
end

function M.client_provider(client, supports_calls)
  return {
    id = client.id,
    name = client.name,
    offset_encoding = "utf-8",
    root_dir = client.root_dir or (client.config and client.config.root_dir),
    supports_calls = supports_calls,
  }
end

function M.sorted_clients(bufnr, method)
  local clients = vim.lsp.get_clients({ bufnr = bufnr, method = method })
  table.sort(clients, function(left, right)
    if left.name ~= right.name then
      return left.name < right.name
    end
    return left.id < right.id
  end)
  return clients
end

function M.as_error(err)
  if type(err) == "table" then
    return err.message or vim.inspect(err)
  end
  return tostring(err)
end

return M

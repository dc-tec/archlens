local definition = require("archlens.lsp.definition")
local positions = require("archlens.lsp.positions")
local readiness = require("archlens.lsp.readiness")
local relationships = require("archlens.lsp.relationships")
local resolve = require("archlens.lsp.resolve")
local protocol = require("archlens.lsp.protocol")

local M = {
  resolve = resolve.resolve,
  relationships = relationships.relationships,
  definition_at = definition.definition_at,
  note_attach = readiness.record,
  recently_attached = readiness.recent,
}

-- Kept for focused position-encoding contract tests and downstream compatibility.
M._position_to_client = positions.to_client
M._position_from_client = positions.from_client
M._range_from_client = positions.range_from_client
M._normalize_document_symbols = positions.normalize_document_symbols
M._normalize_call_item = positions.normalize_hierarchy_item

function M.relationship_contexts(context, bufnr)
  local contexts = { context }
  local clients = vim.lsp.get_clients({ bufnr = bufnr })
  table.sort(clients, function(left, right)
    if left.name ~= right.name then
      return left.name < right.name
    end
    return left.id < right.id
  end)

  for _, client in ipairs(clients) do
    if client.id ~= context.client_id and client.initialized and not client:is_stopped() then
      local supports_relationship = false
      for _, method in ipairs({
        protocol.methods.references,
        protocol.methods.implementation,
        protocol.methods.prepare_type,
      }) do
        if client:supports_method(method, bufnr) then
          supports_relationship = true
          break
        end
      end
      if supports_relationship then
        local secondary = vim.deepcopy(context)
        secondary.client_id = client.id
        secondary.client_name = client.name
        secondary.root_dir = client.root_dir
          or (client.config and client.config.root_dir)
          or context.root_dir
        secondary.position_encoding = positions.internal_encoding
        secondary.supports_calls = false
        secondary.call_item = nil
        secondary.wire_call_item = nil
        secondary.wire_type_item = nil
        contexts[#contexts + 1] = secondary
      end
    end
  end
  return contexts
end

return M

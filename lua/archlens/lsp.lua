local definition = require("archlens.lsp.definition")
local positions = require("archlens.lsp.positions")
local relationships = require("archlens.lsp.relationships")
local resolve = require("archlens.lsp.resolve")

local M = {
  resolve = resolve.resolve,
  relationships = relationships.relationships,
  definition_at = definition.definition_at,
}

-- Kept for focused position-encoding contract tests and downstream compatibility.
M._position_to_client = positions.to_client
M._position_from_client = positions.from_client
M._range_from_client = positions.range_from_client
M._normalize_document_symbols = positions.normalize_document_symbols
M._normalize_call_item = positions.normalize_hierarchy_item

return M

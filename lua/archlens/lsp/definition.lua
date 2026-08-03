local positions = require("archlens.lsp.positions")
local protocol = require("archlens.lsp.protocol")

local M = {}

function M.definition_at(context, bufnr, location, position, callback)
  local client = context.client_id and vim.lsp.get_client_by_id(context.client_id) or nil
  if
    not client
    or client:is_stopped()
    or not client:supports_method(protocol.methods.definition, bufnr)
  then
    callback({}, "definition unavailable", 0)
    return function() end
  end
  local client_position =
    positions.to_client_uri(location.uri, position, client.offset_encoding, bufnr)
  if not client_position then
    callback({}, "source text unavailable for position conversion", 0)
    return function() end
  end

  local completed = false
  local request_id
  local ok
  ok, request_id = client:request(protocol.methods.definition, {
    textDocument = { uri = location.uri },
    position = client_position,
  }, function(err, value)
    if completed then
      return
    end
    completed = true
    if err then
      callback({}, protocol.as_error(err), 0)
      return
    end
    local locations = {}
    local skipped = 0
    for _, raw_location in ipairs(positions.location_list(value)) do
      local normalized =
        positions.normalize_location(raw_location, client.offset_encoding, bufnr, location.uri)
      if normalized then
        locations[#locations + 1] = normalized
      else
        skipped = skipped + 1
      end
    end
    callback(locations, nil, skipped)
  end, bufnr)
  if not ok then
    completed = true
    callback({}, "request rejected", 0)
    return function() end
  end

  return function()
    if completed then
      return
    end
    completed = true
    local current = vim.lsp.get_client_by_id(context.client_id)
    if current and request_id and current.requests[request_id] then
      pcall(current.cancel_request, current, request_id)
    end
  end
end

return M

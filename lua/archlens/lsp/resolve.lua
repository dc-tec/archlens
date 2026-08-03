local model = require("archlens.model")
local positions = require("archlens.lsp.positions")
local protocol = require("archlens.lsp.protocol")

local M = {}
local methods = protocol.methods

local function internal_position(source)
  if type(source) == "table" then
    return { line = source.line, character = source.character }
  end
  local cursor = vim.api.nvim_win_get_cursor(source)
  return { line = cursor[1] - 1, character = cursor[2] }
end

local function fallback_file_item(bufnr, position)
  local uri = vim.uri_from_bufnr(bufnr)
  local path = vim.api.nvim_buf_get_name(bufnr)
  return {
    name = path ~= "" and vim.fs.basename(path) or "Current buffer",
    kind = vim.lsp.protocol.SymbolKind.File,
    uri = uri,
    range = { start = position, ["end"] = position },
    selectionRange = { start = position, ["end"] = position },
  }
end

local function context_from_call_item(item, client, fallback_bufnr)
  local normalized =
    positions.normalize_hierarchy_item(item, client.offset_encoding, fallback_bufnr)
  if not normalized then
    return nil
  end
  local context = model.context_from_item(normalized, protocol.client_provider(client, true))
  context.wire_call_item = item
  return context
end

local function resolve_document_symbol(bufnr, position_source, callback)
  local clients = protocol.sorted_clients(bufnr, methods.symbols)
  if #clients == 0 then
    callback(nil, "No attached language server provides document symbols for this buffer.")
    return function() end
  end

  local position = internal_position(position_source)
  local uri = vim.uri_from_bufnr(bufnr)

  local hierarchy_cancel
  local cancelled = false
  local symbols_cancel = vim.lsp.buf_request_all(
    bufnr,
    methods.symbols,
    { textDocument = vim.lsp.util.make_text_document_params(bufnr) },
    function(results)
      if cancelled then
        return
      end
      local candidates = {}
      local fallback_candidates = {}
      local errors = {}
      for client_id, response in pairs(results) do
        local client = vim.lsp.get_client_by_id(client_id)
        if response.err then
          errors[#errors + 1] = protocol.as_error(response.err)
        elseif client then
          local symbols = positions.normalize_document_symbols(
            response.result,
            uri,
            client.offset_encoding,
            bufnr
          )
          local symbol = model.select_document_symbol(symbols, position, uri)
          if symbol then
            if not symbol.uri and not symbol.location then
              symbol.uri = uri
            end
            candidates[#candidates + 1] = {
              client = client,
              symbol = symbol,
            }
          else
            fallback_candidates[#fallback_candidates + 1] = {
              client = client,
              symbol = fallback_file_item(bufnr, position),
              file_fallback = true,
            }
          end
        end
      end

      local function sort_candidates(left, right)
        local left_calls = left.client:supports_method(methods.prepare, bufnr)
        local right_calls = right.client:supports_method(methods.prepare, bufnr)
        if left_calls ~= right_calls then
          return left_calls
        end
        if left.client.name ~= right.client.name then
          return left.client.name < right.client.name
        end
        return left.client.id < right.client.id
      end
      table.sort(candidates, sort_candidates)
      table.sort(fallback_candidates, sort_candidates)

      local candidate = candidates[1] or fallback_candidates[1]
      if candidate then
        local fallback_context = model.context_from_item(
          candidate.symbol,
          protocol.client_provider(candidate.client, false)
        )
        fallback_context.file_fallback = candidate.file_fallback == true
        local location = candidate.symbol.location
        local selection_range = candidate.symbol.selectionRange
          or (location and location.range)
          or candidate.symbol.range
        local symbol_uri = candidate.symbol.uri or (location and location.uri) or uri
        local prepare_position = selection_range
          and positions.to_client_uri(
            symbol_uri,
            selection_range.start,
            candidate.client.offset_encoding,
            bufnr
          )

        if candidate.client:supports_method(methods.prepare, bufnr) and prepare_position then
          local ok, request_id = candidate.client:request(methods.prepare, {
            textDocument = { uri = symbol_uri },
            position = prepare_position,
          }, function(err, items)
            if cancelled then
              return
            end
            if not err and items and items[1] then
              callback(
                context_from_call_item(items[1], candidate.client, bufnr) or fallback_context
              )
            else
              callback(fallback_context)
            end
          end, bufnr)
          if ok and request_id then
            hierarchy_cancel = function()
              if candidate.client.requests[request_id] then
                pcall(candidate.client.cancel_request, candidate.client, request_id)
              end
            end
          elseif not ok then
            callback(fallback_context)
          end
        else
          callback(fallback_context)
        end
      else
        callback(nil, errors[1] or "The language server returned no document symbols.")
      end
    end
  )

  return function()
    cancelled = true
    pcall(symbols_cancel)
    if hierarchy_cancel then
      pcall(hierarchy_cancel)
    end
  end
end

function M.resolve(bufnr, position_source, callback)
  local clients = protocol.sorted_clients(bufnr, methods.prepare)
  if #clients == 0 then
    return resolve_document_symbol(bufnr, position_source, callback)
  end

  local position = internal_position(position_source)
  local client_positions = {}
  for _, client in ipairs(clients) do
    client_positions[client.id] = positions.to_client(bufnr, position, client.offset_encoding)
    if not client_positions[client.id] then
      return resolve_document_symbol(bufnr, position_source, callback)
    end
  end

  local fallback_cancel
  local cancelled = false
  local prepare_cancel = vim.lsp.buf_request_all(bufnr, methods.prepare, function(client)
    return {
      textDocument = vim.lsp.util.make_text_document_params(bufnr),
      position = client_positions[client.id],
    }
  end, function(results)
    if cancelled then
      return
    end
    local candidates = {}
    for client_id, response in pairs(results) do
      local client = vim.lsp.get_client_by_id(client_id)
      if client and not response.err then
        for _, item in ipairs(response.result or {}) do
          local normalized = positions.normalize_hierarchy_item(item, client.offset_encoding, bufnr)
          if normalized then
            candidates[#candidates + 1] = {
              client = client,
              item = normalized,
              wire_call_item = item,
            }
          end
        end
      end
    end

    table.sort(candidates, function(left, right)
      local left_local = left.item.uri == vim.uri_from_bufnr(bufnr)
      local right_local = right.item.uri == vim.uri_from_bufnr(bufnr)
      if left_local ~= right_local then
        return left_local
      end
      if left.client.name ~= right.client.name then
        return left.client.name < right.client.name
      end
      if left.client.id ~= right.client.id then
        return left.client.id < right.client.id
      end
      local left_range = left.item.selectionRange or left.item.range
      local right_range = right.item.selectionRange or right.item.range
      local left_lines = left_range and left_range["end"].line - left_range.start.line or math.huge
      local right_lines = right_range and right_range["end"].line - right_range.start.line
        or math.huge
      if left_lines ~= right_lines then
        return left_lines < right_lines
      end
      if left.item.name ~= right.item.name then
        return left.item.name < right.item.name
      end
      return (left.item.detail or "") < (right.item.detail or "")
    end)

    if candidates[1] then
      local context = model.context_from_item(
        candidates[1].item,
        protocol.client_provider(candidates[1].client, true)
      )
      context.wire_call_item = candidates[1].wire_call_item
      callback(context)
    else
      fallback_cancel = resolve_document_symbol(bufnr, position_source, function(context, err)
        if not cancelled then
          callback(context, err)
        end
      end)
    end
  end)

  return function()
    cancelled = true
    pcall(prepare_cancel)
    if fallback_cancel then
      pcall(fallback_cancel)
    end
  end
end

return M

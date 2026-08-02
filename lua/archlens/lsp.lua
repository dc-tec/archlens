local model = require("archlens.model")

local M = {}

local methods = {
  symbols = "textDocument/documentSymbol",
  prepare = "textDocument/prepareCallHierarchy",
  incoming = "callHierarchy/incomingCalls",
  outgoing = "callHierarchy/outgoingCalls",
  references = "textDocument/references",
}

local function client_provider(client, supports_calls)
  return {
    id = client.id,
    name = client.name,
    offset_encoding = client.offset_encoding,
    root_dir = client.root_dir or (client.config and client.config.root_dir),
    supports_calls = supports_calls,
  }
end

local function sorted_clients(bufnr, method)
  local clients = vim.lsp.get_clients({ bufnr = bufnr, method = method })
  table.sort(clients, function(left, right)
    if left.name ~= right.name then
      return left.name < right.name
    end
    return left.id < right.id
  end)
  return clients
end

local function as_error(err)
  if type(err) == "table" then
    return err.message or vim.inspect(err)
  end
  return tostring(err)
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

local function client_position(source, client)
  if type(source) == "table" then
    return source
  end
  return vim.lsp.util.make_position_params(source, client.offset_encoding).position
end

local function resolve_document_symbol(bufnr, position_source, callback)
  local clients = sorted_clients(bufnr, methods.symbols)
  if #clients == 0 then
    callback(nil, "No attached language server provides document symbols for this buffer.")
    return function() end
  end

  local positions = {}
  for _, client in ipairs(clients) do
    positions[client.id] = client_position(position_source, client)
  end
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
          errors[#errors + 1] = as_error(response.err)
        elseif client then
          local symbol =
            model.select_document_symbol(response.result or {}, positions[client_id], uri)
          if symbol then
            symbol = vim.deepcopy(symbol)
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
              symbol = fallback_file_item(bufnr, positions[client_id]),
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
        local fallback_context =
          model.context_from_item(candidate.symbol, client_provider(candidate.client, false))
        local location = candidate.symbol.location
        local selection_range = candidate.symbol.selectionRange
          or (location and location.range)
          or candidate.symbol.range
        local symbol_uri = candidate.symbol.uri or (location and location.uri) or uri

        if candidate.client:supports_method(methods.prepare, bufnr) and selection_range then
          local ok, request_id = candidate.client:request(methods.prepare, {
            textDocument = { uri = symbol_uri },
            position = selection_range.start,
          }, function(err, items)
            if cancelled then
              return
            end
            if not err and items and items[1] then
              callback(model.context_from_item(items[1], client_provider(candidate.client, true)))
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
  local clients = sorted_clients(bufnr, methods.prepare)
  if #clients == 0 then
    return resolve_document_symbol(bufnr, position_source, callback)
  end

  local fallback_cancel
  local cancelled = false
  local prepare_cancel = vim.lsp.buf_request_all(bufnr, methods.prepare, function(client)
    return {
      textDocument = vim.lsp.util.make_text_document_params(bufnr),
      position = client_position(position_source, client),
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
          candidates[#candidates + 1] = {
            client = client,
            item = item,
          }
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
      callback(
        model.context_from_item(candidates[1].item, client_provider(candidates[1].client, true))
      )
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

function M.relationships(context, bufnr, callback, options)
  options = options or {}
  local client = vim.lsp.get_client_by_id(context.client_id)
  if not client or client:is_stopped() then
    callback({ incoming = {}, outgoing = {}, references = {}, errors = {} })
    return function() end
  end

  local result = { incoming = {}, outgoing = {}, references = {}, errors = {} }
  local pending = 0
  local cancelled = false
  local completed = false
  local request_ids = {}
  local timer

  local function complete()
    if cancelled or completed or pending ~= 0 then
      return
    end
    completed = true
    if timer and not timer:is_closing() then
      timer:stop()
      timer:close()
    end
    callback(result)
  end

  local function finish(spec, err, value)
    if cancelled or completed then
      return
    end
    if err then
      result.errors[#result.errors + 1] = string.format("%s failed: %s", spec.label, as_error(err))
    else
      result[spec.key] = value or {}
    end
    pending = pending - 1
    complete()
  end

  local requests = {}
  local call_item = context.call_item or context.item
  if context.supports_calls and call_item then
    for _, request in ipairs({
      {
        key = "incoming",
        label = "Incoming calls",
        method = methods.incoming,
        params = { item = call_item },
      },
      {
        key = "outgoing",
        label = "Outgoing calls",
        method = methods.outgoing,
        params = { item = call_item },
      },
    }) do
      if client:supports_method(request.method, bufnr) then
        requests[#requests + 1] = request
      end
    end
  end

  local reference_range = context.location and context.location.range
  if reference_range and client:supports_method(methods.references, bufnr) then
    requests[#requests + 1] = {
      key = "references",
      label = "Project references",
      method = methods.references,
      params = {
        textDocument = { uri = context.location.uri },
        position = reference_range.start,
        context = { includeDeclaration = false },
      },
    }
  end
  pending = #requests

  local function request(spec)
    local ok, request_id = client:request(spec.method, spec.params, function(err, value)
      finish(spec, err, value)
    end, bufnr)
    if ok and request_id then
      request_ids[#request_ids + 1] = request_id
    elseif not ok then
      finish(spec, "request rejected", nil)
    end
  end

  if pending == 0 then
    complete()
  else
    for _, spec in ipairs(requests) do
      request(spec)
    end
    local timeout_ms = options.timeout_ms or 8000
    timer = vim.defer_fn(function()
      if cancelled or completed then
        return
      end
      for _, request_id in ipairs(request_ids) do
        if client.requests[request_id] then
          pcall(client.cancel_request, client, request_id)
        end
      end
      result.errors[#result.errors + 1] =
        string.format("LSP relationship requests exceeded %d ms and were stopped.", timeout_ms)
      pending = 0
      complete()
    end, timeout_ms)
  end

  return function()
    cancelled = true
    if timer and not timer:is_closing() then
      timer:stop()
      timer:close()
    end
    local current_client = vim.lsp.get_client_by_id(context.client_id)
    if not current_client then
      return
    end
    for _, request_id in ipairs(request_ids) do
      if current_client.requests[request_id] then
        pcall(current_client.cancel_request, current_client, request_id)
      end
    end
  end
end

return M

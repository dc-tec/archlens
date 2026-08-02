local graph = require("archlens.graph")
local model = require("archlens.model")
local test_paths = require("archlens.test_paths")

local M = {}

local internal_position_encoding = "utf-8"
local methods = {
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

local implementation_kinds = {
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

local type_hierarchy_kinds = {
  [vim.lsp.protocol.SymbolKind.Class] = true,
  [vim.lsp.protocol.SymbolKind.Enum] = true,
  [vim.lsp.protocol.SymbolKind.Interface] = true,
  [vim.lsp.protocol.SymbolKind.Object] = true,
  [vim.lsp.protocol.SymbolKind.Struct] = true,
  [vim.lsp.protocol.SymbolKind.TypeParameter] = true,
}

local function supports_symbol_kind(context, kinds)
  return context.kind == nil or kinds[context.kind] == true
end

local function client_provider(client, supports_calls)
  return {
    id = client.id,
    name = client.name,
    offset_encoding = internal_position_encoding,
    root_dir = client.root_dir or (client.config and client.config.root_dir),
    supports_calls = supports_calls,
  }
end

local function buffer_line(bufnr, line)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) or not vim.api.nvim_buf_is_loaded(bufnr) then
    return nil
  end
  return vim.api.nvim_buf_get_lines(bufnr, line, line + 1, false)[1]
end

local function buffer_matches_uri(bufnr, uri)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return false
  end
  if vim.api.nvim_buf_get_name(bufnr) == uri then
    return true
  end
  local ok, buffer_uri = pcall(vim.uri_from_bufnr, bufnr)
  return ok and buffer_uri == uri
end

local function loaded_buffer_for_uri(uri, fallback_bufnr)
  if buffer_matches_uri(fallback_bufnr, uri) and vim.api.nvim_buf_is_loaded(fallback_bufnr) then
    return fallback_bufnr
  end
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) and buffer_matches_uri(bufnr, uri) then
      return bufnr
    end
  end
  return nil
end

local function uri_line(uri, line, fallback_bufnr)
  local loaded_bufnr = loaded_buffer_for_uri(uri, fallback_bufnr)
  if loaded_bufnr then
    return buffer_line(loaded_bufnr, line)
  end
  if type(uri) ~= "string" or not uri:match("^file:") then
    return nil
  end
  local ok, path = pcall(vim.uri_to_fname, uri)
  if not ok then
    return nil
  end
  local read_ok, lines = pcall(vim.fn.readfile, path, "", line + 1)
  return read_ok and lines[line + 1] or nil
end

local function converted_character(text, character, from_encoding, to_encoding)
  if character == nil then
    return nil
  end
  if character == 0 or from_encoding == to_encoding then
    return character
  end
  if not text then
    return nil
  end

  local byte_character = character
  if from_encoding ~= internal_position_encoding then
    local ok, converted = pcall(vim.str_byteindex, text, from_encoding, character, false)
    if not ok then
      return nil
    end
    byte_character = converted
  end
  if to_encoding == internal_position_encoding then
    return byte_character
  end

  local ok, converted = pcall(vim.str_utfindex, text, to_encoding, byte_character, false)
  return ok and converted or nil
end

local function position_to_client(bufnr, position, encoding)
  if not position then
    return nil
  end
  local text = buffer_line(bufnr, position.line)
  local character =
    converted_character(text, position.character, internal_position_encoding, encoding or "utf-16")
  return character ~= nil and { line = position.line, character = character } or nil
end

local function position_to_client_uri(uri, position, encoding, fallback_bufnr)
  if not position then
    return nil
  end
  local text = uri_line(uri, position.line, fallback_bufnr)
  local character =
    converted_character(text, position.character, internal_position_encoding, encoding or "utf-16")
  return character ~= nil and { line = position.line, character = character } or nil
end

local function position_from_client(uri, position, encoding, fallback_bufnr)
  if not position then
    return nil
  end
  local text = uri_line(uri, position.line, fallback_bufnr)
  local character =
    converted_character(text, position.character, encoding or "utf-16", internal_position_encoding)
  return character ~= nil and { line = position.line, character = character } or nil
end

local function range_from_client(uri, range, encoding, fallback_bufnr)
  if not range then
    return nil
  end
  local start = position_from_client(uri, range.start, encoding, fallback_bufnr)
  local finish = position_from_client(uri, range["end"], encoding, fallback_bufnr)
  return start and finish and { start = start, ["end"] = finish } or nil
end

local function normalize_location(location, encoding, fallback_bufnr, origin_uri)
  if not location then
    return nil
  end
  if location.targetUri then
    local target_range =
      range_from_client(location.targetUri, location.targetRange, encoding, fallback_bufnr)
    local target_selection_range =
      range_from_client(location.targetUri, location.targetSelectionRange, encoding, fallback_bufnr)
    if not target_range or not target_selection_range then
      return nil
    end
    local normalized = {
      uri = location.targetUri,
      range = target_selection_range,
      full_range = target_range,
    }
    if location.originSelectionRange then
      normalized.origin_range = range_from_client(
        origin_uri or location.targetUri,
        location.originSelectionRange,
        encoding,
        fallback_bufnr
      )
    end
    return normalized
  else
    local range = range_from_client(location.uri, location.range, encoding, fallback_bufnr)
    if not range then
      return nil
    end
    return { uri = location.uri, range = range, full_range = range }
  end
end

local function location_list(value)
  if not value then
    return {}
  end
  if value.uri or value.targetUri then
    return { value }
  end
  return value
end

local function normalize_document_symbol(symbol, uri, encoding, fallback_bufnr)
  local normalized = vim.deepcopy(symbol)
  if symbol.location then
    normalized.location = normalize_location(symbol.location, encoding, fallback_bufnr)
    if not normalized.location then
      return nil
    end
  else
    normalized.range = range_from_client(uri, symbol.range, encoding, fallback_bufnr)
    normalized.selectionRange =
      range_from_client(uri, symbol.selectionRange, encoding, fallback_bufnr)
    if not normalized.range or not normalized.selectionRange then
      return nil
    end
  end
  normalized.children = nil
  if symbol.children then
    normalized.children = {}
    for _, child in ipairs(symbol.children) do
      local normalized_child = normalize_document_symbol(child, uri, encoding, fallback_bufnr)
      if normalized_child then
        normalized.children[#normalized.children + 1] = normalized_child
      end
    end
  end
  return normalized
end

local function normalize_document_symbols(symbols, uri, encoding, fallback_bufnr)
  local normalized = {}
  for _, symbol in ipairs(symbols or {}) do
    local normalized_symbol = normalize_document_symbol(symbol, uri, encoding, fallback_bufnr)
    if normalized_symbol then
      normalized[#normalized + 1] = normalized_symbol
    end
  end
  return normalized
end

local function normalize_call_item(item, encoding, fallback_bufnr)
  if not item then
    return nil
  end
  local normalized = vim.deepcopy(item)
  normalized.data = nil
  normalized.range = range_from_client(item.uri, item.range, encoding, fallback_bufnr)
  normalized.selectionRange =
    range_from_client(item.uri, item.selectionRange, encoding, fallback_bufnr)
  if not normalized.range or not normalized.selectionRange then
    return nil
  end
  return normalized
end

local function normalize_type_item(item, encoding, fallback_bufnr)
  return normalize_call_item(item, encoding, fallback_bufnr)
end

local function context_from_call_item(item, client, fallback_bufnr)
  local normalized = normalize_call_item(item, client.offset_encoding, fallback_bufnr)
  if not normalized then
    return nil
  end
  local context = model.context_from_item(normalized, client_provider(client, true))
  context.wire_call_item = item
  return context
end

local function normalize_call(call, direction, encoding, fallback_bufnr, origin_uri)
  local normalized = vim.deepcopy(call)
  local item_key = direction == "incoming" and "from" or "to"
  if not call[item_key] then
    return nil
  end
  normalized[item_key] = normalize_call_item(call[item_key], encoding, fallback_bufnr)
  if not normalized[item_key] then
    return nil
  end
  normalized.wire_call_item = call[item_key]
  if call.fromRanges then
    local range_uri = direction == "incoming" and call.from.uri or origin_uri
    normalized.fromRanges = {}
    for _, range in ipairs(call.fromRanges) do
      local normalized_range = range_from_client(range_uri, range, encoding, fallback_bufnr)
      if normalized_range then
        normalized.fromRanges[#normalized.fromRanges + 1] = normalized_range
      end
    end
  end
  return normalized
end

local function call_edge(call, direction, context)
  local item = direction == "incoming" and call.from or call.to
  if not item then
    return nil
  end
  local row_context = model.context_from_item(item, {
    id = context.client_id,
    name = context.client_name,
    offset_encoding = internal_position_encoding,
    root_dir = context.root_dir,
    supports_calls = true,
  })
  row_context.wire_call_item = call.wire_call_item
  local focus = graph.node_from_context(context)
  local related = graph.node_from_context(row_context)
  local source = direction == "incoming" and related or focus
  local target = direction == "incoming" and focus or related
  local occurrence_uri = direction == "incoming" and item.uri or context.location.uri
  local occurrences = {}
  if call.fromRanges and #call.fromRanges > 0 then
    occurrences[1] = { uri = occurrence_uri, ranges = vim.deepcopy(call.fromRanges) }
  end
  return graph.edge(direction, source, target, {
    provider = context.client_name or "LSP",
    method = direction == "incoming" and methods.incoming or methods.outgoing,
    class = "semantic",
  }, {
    occurrences = occurrences,
    position_encoding = internal_position_encoding,
  })
end

local function type_edge(item, kind, context, client, bufnr)
  local normalized = normalize_type_item(item, client.offset_encoding, bufnr)
  if not normalized then
    return nil
  end
  local row_context = model.context_from_item(normalized, client_provider(client, false))
  row_context.wire_type_item = item
  local focus = graph.node_from_context(context)
  local related = graph.node_from_context(row_context)
  local source = kind == "subtypes" and related or focus
  local target = kind == "subtypes" and focus or related
  return graph.edge(kind, source, target, {
    provider = context.client_name or "LSP",
    method = kind == "supertypes" and methods.supertypes or methods.subtypes,
    class = "semantic",
  }, {
    position_encoding = internal_position_encoding,
  })
end

local function type_item_score(item, context)
  local score = 0
  local context_location = context.location or {}
  local context_position = context_location.range and context_location.range.start
  if item.uri == context_location.uri then
    score = score + 8
  end
  if item.name == context.name then
    score = score + 4
  end
  if context_position and model.range_contains(item.selectionRange, context_position) then
    score = score + 2
  end
  if context_position and model.range_contains(item.range, context_position) then
    score = score + 1
  end
  return score
end

local function select_type_item(items, context, client, bufnr)
  local candidates = {}
  for index, item in ipairs(items or {}) do
    local normalized = normalize_type_item(item, client.offset_encoding, bufnr)
    if normalized then
      candidates[#candidates + 1] = {
        index = index,
        item = item,
        normalized = normalized,
        score = type_item_score(normalized, context),
      }
    end
  end
  table.sort(candidates, function(left, right)
    if left.score ~= right.score then
      return left.score > right.score
    end
    if left.normalized.name ~= right.normalized.name then
      return left.normalized.name < right.normalized.name
    end
    if left.normalized.uri ~= right.normalized.uri then
      return left.normalized.uri < right.normalized.uri
    end
    return left.index < right.index
  end)
  return candidates[1] and candidates[1].item or nil, candidates
end

local function location_edge(location, kind, context)
  local focus = graph.node_from_context(context)
  local related = graph.node_from_location(location, {
    kind_name = kind == "implementations" and "Implementation"
      or kind == "test_references" and "Test reference"
      or kind == "configuration_consumers" and "Configuration use"
      or "Reference",
    position_encoding = internal_position_encoding,
  })
  local reverse = kind == "references"
    or kind == "test_references"
    or kind == "configuration_consumers"
  local source = reverse and related or focus
  local target = reverse and focus or related
  local occurrences = {}
  if location.origin_range then
    occurrences[1] = {
      uri = context.location.uri,
      ranges = { vim.deepcopy(location.origin_range) },
    }
  end
  return graph.edge(kind, source, target, {
    provider = context.client_name or "LSP",
    method = kind == "implementations" and methods.implementation or methods.references,
    class = "semantic",
  }, {
    occurrences = occurrences,
    position_encoding = internal_position_encoding,
  })
end

local function internal_position(source)
  if type(source) == "table" then
    return { line = source.line, character = source.character }
  end
  local cursor = vim.api.nvim_win_get_cursor(source)
  return { line = cursor[1] - 1, character = cursor[2] }
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

local function resolve_document_symbol(bufnr, position_source, callback)
  local clients = sorted_clients(bufnr, methods.symbols)
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
          errors[#errors + 1] = as_error(response.err)
        elseif client then
          local symbols =
            normalize_document_symbols(response.result, uri, client.offset_encoding, bufnr)
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
        local fallback_context =
          model.context_from_item(candidate.symbol, client_provider(candidate.client, false))
        fallback_context.file_fallback = candidate.file_fallback == true
        local location = candidate.symbol.location
        local selection_range = candidate.symbol.selectionRange
          or (location and location.range)
          or candidate.symbol.range
        local symbol_uri = candidate.symbol.uri or (location and location.uri) or uri
        local prepare_position = selection_range
          and position_to_client_uri(
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
  local clients = sorted_clients(bufnr, methods.prepare)
  if #clients == 0 then
    return resolve_document_symbol(bufnr, position_source, callback)
  end

  local position = internal_position(position_source)
  local client_positions = {}
  for _, client in ipairs(clients) do
    client_positions[client.id] = position_to_client(bufnr, position, client.offset_encoding)
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
          local normalized = normalize_call_item(item, client.offset_encoding, bufnr)
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
      local context =
        model.context_from_item(candidates[1].item, client_provider(candidates[1].client, true))
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

function M.relationships(context, bufnr, callback, options)
  options = options or {}
  local result = graph.delta()
  local client = vim.lsp.get_client_by_id(context.client_id)
  if not client or client:is_stopped() then
    if context.configuration then
      graph.add_note(
        result,
        "Configuration uses require an active language server with project reference support."
      )
    end
    callback(result)
    return function() end
  end

  graph.add_contributor(result, "lsp:" .. tostring(client.id), client.name)
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

  local request

  local function type_requests(item)
    return {
      {
        key = "supertypes",
        label = "Supertypes",
        method = methods.supertypes,
        params = { item = item },
      },
      {
        key = "subtypes",
        label = "Subtypes",
        method = methods.subtypes,
        params = { item = item },
      },
    }
  end

  local function enqueue(specs)
    pending = pending + #specs
    for _, spec in ipairs(specs) do
      request(spec)
    end
  end

  local function finish(spec, err, value)
    if cancelled or completed then
      return
    end
    if spec.key == "prepare_type" then
      if err then
        result.errors[#result.errors + 1] =
          string.format("%s failed: %s", spec.label, as_error(err))
      else
        local item, candidates = select_type_item(value, context, client, bufnr)
        if item then
          if #candidates > 1 then
            result.notes[#result.notes + 1] = string.format(
              "Type hierarchy preparation returned %d candidates; using %s.",
              #candidates,
              item.name
            )
          end
          enqueue(type_requests(item))
        elseif value and #value > 0 then
          result.errors[#result.errors + 1] = string.format(
            "Type hierarchy preparation omitted %d result%s because its source text was unavailable for position conversion.",
            #value,
            #value == 1 and "" or "s"
          )
        end
      end
      pending = pending - 1
      complete()
      return
    end
    if err then
      result.errors[#result.errors + 1] = string.format("%s failed: %s", spec.label, as_error(err))
    else
      local normalized = {}
      local skipped = 0
      if spec.key == "implementations" or spec.key == "references" then
        local locations = location_list(value)
        for _, location in ipairs(locations) do
          local normalized_location =
            normalize_location(location, client.offset_encoding, bufnr, spec.origin_uri)
          if normalized_location then
            local kind = spec.key
            local path_ok, path = pcall(vim.uri_to_fname, normalized_location.uri)
            if kind == "references" and context.configuration then
              kind = "configuration_consumers"
            elseif
              kind == "references"
              and path_ok
              and test_paths.is_test(
                context.language,
                path,
                context.root_dir,
                normalized_location.range.start.line
              )
            then
              kind = "test_references"
            end
            normalized[#normalized + 1] = location_edge(normalized_location, kind, context)
          else
            skipped = skipped + 1
          end
        end
        if spec.key == "references" and context.configuration and #locations == 0 then
          result.notes[#result.notes + 1] = string.format(
            "%s returned no configuration uses for this field.",
            context.client_name or "The language server"
          )
        end
      elseif spec.key == "incoming" or spec.key == "outgoing" then
        for _, call in ipairs(value or {}) do
          local normalized_call =
            normalize_call(call, spec.key, client.offset_encoding, bufnr, spec.origin_uri)
          if normalized_call then
            normalized[#normalized + 1] = call_edge(normalized_call, spec.key, context)
          else
            skipped = skipped + 1
          end
        end
      elseif spec.key == "supertypes" or spec.key == "subtypes" then
        for _, item in ipairs(value or {}) do
          local edge = type_edge(item, spec.key, context, client, bufnr)
          if edge then
            normalized[#normalized + 1] = edge
          else
            skipped = skipped + 1
          end
        end
      end
      vim.list_extend(result.edges, normalized)
      if skipped > 0 then
        result.errors[#result.errors + 1] = string.format(
          "%s omitted %d result%s because its source text was unavailable for position conversion.",
          spec.label,
          skipped,
          skipped == 1 and "" or "s"
        )
      end
    end
    pending = pending - 1
    complete()
  end

  local requests = {}
  local call_item = context.wire_call_item or context.call_item
  if context.supports_calls and call_item then
    for _, request in ipairs({
      {
        key = "incoming",
        label = "Incoming calls",
        method = methods.incoming,
        params = { item = call_item },
        origin_uri = call_item.uri,
      },
      {
        key = "outgoing",
        label = "Outgoing calls",
        method = methods.outgoing,
        params = { item = call_item },
        origin_uri = call_item.uri,
      },
    }) do
      if client:supports_method(request.method, bufnr) then
        requests[#requests + 1] = request
      end
    end
  end

  if context.wire_type_item then
    vim.list_extend(requests, type_requests(context.wire_type_item))
  end

  local reference_range = context.location and context.location.range
  local supports_implementation = not context.file_fallback
    and not context.module_context
    and not context.configuration
    and supports_symbol_kind(context, implementation_kinds)
    and client:supports_method(methods.implementation, bufnr)
  local supports_references = not context.file_fallback
    and not context.module_context
    and client:supports_method(methods.references, bufnr)
  if context.configuration and not supports_references then
    graph.add_note(
      result,
      string.format(
        "%s does not support project references for configuration fields.",
        context.client_name or client.name
      )
    )
  end
  local supports_type_hierarchy = not context.file_fallback
    and not context.module_context
    and not context.wire_type_item
    and supports_symbol_kind(context, type_hierarchy_kinds)
    and client:supports_method(methods.prepare_type, bufnr)
  if
    reference_range
    and context.location.uri
    and (supports_implementation or supports_references or supports_type_hierarchy)
  then
    local position = position_to_client_uri(
      context.location.uri,
      reference_range.start,
      client.offset_encoding,
      bufnr
    )
    if position and supports_implementation then
      requests[#requests + 1] = {
        key = "implementations",
        label = "Implementations",
        method = methods.implementation,
        origin_uri = context.location.uri,
        params = {
          textDocument = { uri = context.location.uri },
          position = position,
        },
      }
    end
    if position and supports_references then
      requests[#requests + 1] = {
        key = "references",
        label = "Project references",
        method = methods.references,
        origin_uri = context.location.uri,
        params = {
          textDocument = { uri = context.location.uri },
          position = position,
          context = { includeDeclaration = false },
        },
      }
    end
    if position and supports_type_hierarchy then
      requests[#requests + 1] = {
        key = "prepare_type",
        label = "Type hierarchy preparation",
        method = methods.prepare_type,
        params = {
          textDocument = { uri = context.location.uri },
          position = position,
        },
      }
    end
    if not position then
      result.errors[#result.errors + 1] =
        "LSP locations were skipped because their source text was unavailable for position conversion."
    end
  end
  pending = #requests

  request = function(spec)
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
    if not completed then
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

function M.definition_at(context, bufnr, location, position, callback)
  local client = context.client_id and vim.lsp.get_client_by_id(context.client_id) or nil
  if not client or client:is_stopped() or not client:supports_method(methods.definition, bufnr) then
    callback({}, "definition unavailable", 0)
    return function() end
  end
  local client_position =
    position_to_client_uri(location.uri, position, client.offset_encoding, bufnr)
  if not client_position then
    callback({}, "source text unavailable for position conversion", 0)
    return function() end
  end

  local completed = false
  local request_id
  local ok
  ok, request_id = client:request(methods.definition, {
    textDocument = { uri = location.uri },
    position = client_position,
  }, function(err, value)
    if completed then
      return
    end
    completed = true
    if err then
      callback({}, as_error(err), 0)
      return
    end
    local locations = {}
    local skipped = 0
    for _, raw_location in ipairs(location_list(value)) do
      local normalized =
        normalize_location(raw_location, client.offset_encoding, bufnr, location.uri)
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

M._position_to_client = position_to_client
M._position_from_client = position_from_client
M._range_from_client = range_from_client
M._normalize_document_symbols = normalize_document_symbols
M._normalize_call_item = normalize_call_item

return M

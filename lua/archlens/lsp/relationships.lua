local graph = require("archlens.graph")
local model = require("archlens.model")
local positions = require("archlens.lsp.positions")
local protocol = require("archlens.lsp.protocol")
local scope = require("archlens.scope")
local test_paths = require("archlens.test_paths")

local M = {}
local methods = protocol.methods

local function normalize_call(call, direction, encoding, fallback_bufnr, origin_uri, range_limit)
  local item_key = direction == "incoming" and "from" or "to"
  if not call[item_key] then
    return nil, 0, 0
  end
  local normalized = {
    [item_key] = positions.normalize_hierarchy_item(call[item_key], encoding, fallback_bufnr),
  }
  if not normalized[item_key] then
    return nil, 0, 0
  end
  normalized.wire_call_item = call[item_key]
  if call.fromRanges then
    local range_uri = direction == "incoming" and call.from.uri or origin_uri
    normalized.fromRanges = {}
    local admitted = math.min(#call.fromRanges, range_limit)
    for index = 1, admitted do
      local range = call.fromRanges[index]
      local normalized_range =
        positions.range_from_client(range_uri, range, encoding, fallback_bufnr)
      if normalized_range then
        normalized.fromRanges[#normalized.fromRanges + 1] = normalized_range
      end
    end
    return normalized, math.max(0, #call.fromRanges - admitted), admitted
  end
  return normalized, 0, 0
end

local function call_edge(call, direction, context)
  local item = direction == "incoming" and call.from or call.to
  if not item then
    return nil
  end
  local row_context = model.context_from_item(item, {
    id = context.client_id,
    name = context.client_name,
    offset_encoding = positions.internal_encoding,
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
    position_encoding = positions.internal_encoding,
  })
end

local function type_edge(item, kind, context, client, bufnr)
  local normalized = positions.normalize_hierarchy_item(item, client.offset_encoding, bufnr)
  if not normalized then
    return nil
  end
  local row_context = model.context_from_item(normalized, protocol.client_provider(client, false))
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
    position_encoding = positions.internal_encoding,
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

local function valid_position(position)
  return type(position) == "table"
    and type(position.line) == "number"
    and position.line >= 0
    and position.line <= 4294967295
    and position.line == math.floor(position.line)
    and type(position.character) == "number"
    and position.character >= 0
    and position.character <= 4294967295
    and position.character == math.floor(position.character)
end

local function valid_range(range)
  return type(range) == "table" and valid_position(range.start) and valid_position(range["end"])
end

local function hierarchy_candidate(item)
  if
    type(item) ~= "table"
    or type(item.name) ~= "string"
    or item.name == ""
    or type(item.uri) ~= "string"
    or item.uri == ""
    or not valid_range(item.range)
    or not valid_range(item.selectionRange)
  then
    return nil
  end
  return item.uri, item.selectionRange, item.name
end

local function location_candidate(location)
  if type(location) ~= "table" then
    return nil
  end
  if location.targetUri ~= nil then
    if
      type(location.targetUri) ~= "string"
      or location.targetUri == ""
      or not valid_range(location.targetRange)
      or not valid_range(location.targetSelectionRange)
      or (location.originSelectionRange and not valid_range(location.originSelectionRange))
    then
      return nil
    end
    return location.targetUri, location.targetSelectionRange
  end
  if type(location.uri) ~= "string" or location.uri == "" or not valid_range(location.range) then
    return nil
  end
  return location.uri, location.range
end

local function call_candidate(call, direction)
  if type(call) ~= "table" then
    return nil
  end
  return hierarchy_candidate(call[direction == "incoming" and "from" or "to"])
end

local function candidate_key(uri, range, name)
  local start = range and range.start or {}
  local finish = range and range["end"] or {}
  return table.concat({
    uri or "",
    string.format("%010d", start.line or 0),
    string.format("%010d", start.character or 0),
    string.format("%010d", finish.line or 0),
    string.format("%010d", finish.character or 0),
    name or "",
  }, "\0")
end

local function select_type_item(items, context, client, bufnr)
  local candidates = {}
  for index, item in ipairs(items or {}) do
    local normalized = positions.normalize_hierarchy_item(item, client.offset_encoding, bufnr)
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
    position_encoding = positions.internal_encoding,
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
    position_encoding = positions.internal_encoding,
  })
end

function M.relationships(context, bufnr, callback, options)
  options = options or {}
  local max_results = math.max(1, math.floor(tonumber(options.max_results) or 256))
  local max_occurrences = math.max(1, math.floor(tonumber(options.max_occurrences) or 256))
  local filters = options.filters
    or { include_external = true, include_generated = true, include_vendored = true }
  local scope_cache = {}
  local result = graph.delta()
  local client = vim.lsp.get_client_by_id(context.client_id)
  if not client or client:is_stopped() then
    callback(result, {
      request_count = 0,
      request_labels = {},
      outcome = {
        state = "unavailable",
        message = context.configuration
            and "Configuration uses require an active language server with project reference support."
          or "The language server is no longer available for relationship analysis.",
      },
    })
    return function() end
  end

  graph.add_contributor(result, "lsp:" .. tostring(client.id), client.name)
  local pending = 0
  local cancelled = false
  local completed = false
  local request_ids = {}
  local request_count = 0
  local request_labels = {}
  local configuration_unavailable
  local terminal_outcome
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
    callback(result, {
      request_count = request_count,
      request_labels = vim.deepcopy(request_labels),
      outcome = terminal_outcome,
    })
  end

  local request

  local function candidate_scope(uri)
    if type(uri) ~= "string" or not uri:match("^file:") then
      return "external"
    end
    local path_ok, path = pcall(vim.uri_to_fname, uri)
    if not path_ok then
      return "external"
    end
    return scope.classify(context.root_dir, path, filters, scope_cache)
  end

  local scope_scores = {
    project = 4,
    generated = 3,
    vendored = 2,
    external = 1,
  }

  local function admitted_values(values, spec, describe)
    values = type(values) == "table" and values or {}
    local candidates = {}
    local rejected = 0
    local scan_limit = math.min(#values, max_results * 4)
    for index = 1, scan_limit do
      local value = values[index]
      local uri, range, name = describe(value)
      local kind = uri and candidate_scope(uri) or nil
      if kind and scope.visible(kind, filters) then
        local score = (scope_scores[kind] or 0) * 100
        if uri == (context.location and context.location.uri) then
          score = score + 10
        end
        if name and name == context.name then
          score = score + 5
        end
        candidates[#candidates + 1] = {
          index = index,
          key = candidate_key(uri, range, name),
          score = score,
          value = value,
        }
      else
        rejected = rejected + 1
      end
    end
    table.sort(candidates, function(left, right)
      if left.score ~= right.score then
        return left.score > right.score
      end
      if left.key ~= right.key then
        return left.key < right.key
      end
      return left.index < right.index
    end)
    local admitted = {}
    for index = 1, math.min(#candidates, max_results) do
      admitted[index] = candidates[index].value
    end
    local limited = math.max(0, #candidates - #admitted)
    local unexamined = math.max(0, #values - scan_limit)
    local omitted = rejected + limited + unexamined
    if omitted > 0 then
      local message
      if rejected == 0 and unexamined == 0 then
        message = string.format(
          "%s returned %d results; %d were omitted by the %d-result LSP limit.",
          spec.label,
          #values,
          omitted,
          max_results
        )
      else
        message = string.format(
          "%s returned %d results; %d were omitted before normalization (%d hidden or malformed; %d above the %d-result LSP limit; %d outside the %d-candidate scan limit).",
          spec.label,
          #values,
          omitted,
          rejected,
          limited,
          max_results,
          unexamined,
          max_results * 4
        )
      end
      graph.add_note(result, message, { summary = "semantic results limited", severity = "warn" })
    end
    return admitted
  end

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
    if cancelled or completed or spec.settled then
      return
    end
    spec.settled = true
    if spec.key == "prepare_type" then
      if err then
        result.errors[#result.errors + 1] =
          string.format("%s failed: %s", spec.label, protocol.as_error(err))
      else
        local candidates_input = admitted_values(value, spec, hierarchy_candidate)
        local item, candidates = select_type_item(candidates_input, context, client, bufnr)
        if item then
          if #candidates > 1 then
            graph.add_note(
              result,
              string.format(
                "Type hierarchy preparation returned %d candidates; using %s.",
                #candidates,
                item.name
              ),
              { summary = "type hierarchy ambiguous", severity = "info" }
            )
          end
          enqueue(type_requests(item))
        elseif #candidates_input > 0 then
          result.errors[#result.errors + 1] = string.format(
            "Type hierarchy preparation omitted %d result%s because its source text was unavailable for position conversion.",
            #candidates_input,
            #candidates_input == 1 and "" or "s"
          )
        end
      end
      pending = pending - 1
      complete()
      return
    end
    if err then
      result.errors[#result.errors + 1] =
        string.format("%s failed: %s", spec.label, protocol.as_error(err))
    else
      local normalized = {}
      local skipped = 0
      if spec.key == "implementations" or spec.key == "references" then
        local locations = positions.location_list(value)
        local admitted = admitted_values(locations, spec, location_candidate)
        for _, location in ipairs(admitted) do
          local normalized_location =
            positions.normalize_location(location, client.offset_encoding, bufnr, spec.origin_uri)
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
          graph.add_note(
            result,
            string.format(
              "%s returned no configuration uses for this field.",
              context.client_name or "The language server"
            ),
            { summary = "no configuration uses", severity = "info" }
          )
        end
      elseif spec.key == "incoming" or spec.key == "outgoing" then
        local admitted = admitted_values(value, spec, function(call)
          return call_candidate(call, spec.key)
        end)
        local remaining_occurrences = max_occurrences
        local omitted_occurrences = 0
        for _, call in ipairs(admitted) do
          local normalized_call, range_omitted, range_admitted = normalize_call(
            call,
            spec.key,
            client.offset_encoding,
            bufnr,
            spec.origin_uri,
            remaining_occurrences
          )
          remaining_occurrences = math.max(0, remaining_occurrences - range_admitted)
          omitted_occurrences = omitted_occurrences + range_omitted
          if normalized_call then
            normalized[#normalized + 1] = call_edge(normalized_call, spec.key, context)
          else
            skipped = skipped + 1
          end
        end
        if omitted_occurrences > 0 then
          graph.add_note(
            result,
            string.format(
              "%s omitted %d call occurrence%s by the %d-occurrence LSP limit.",
              spec.label,
              omitted_occurrences,
              omitted_occurrences == 1 and "" or "s",
              max_occurrences
            ),
            { summary = "semantic occurrences limited", severity = "warn" }
          )
        end
      elseif spec.key == "supertypes" or spec.key == "subtypes" then
        local admitted = admitted_values(value, spec, hierarchy_candidate)
        for _, item in ipairs(admitted) do
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
    and protocol.supports_symbol_kind(context, protocol.implementation_kinds)
    and client:supports_method(methods.implementation, bufnr)
  local supports_references = not context.file_fallback
    and not context.module_context
    and client:supports_method(methods.references, bufnr)
  if context.configuration and not supports_references then
    configuration_unavailable = string.format(
      "%s does not support project references for configuration fields.",
      context.client_name or client.name
    )
  end
  local supports_type_hierarchy = not context.file_fallback
    and not context.module_context
    and not context.wire_type_item
    and protocol.supports_symbol_kind(context, protocol.type_hierarchy_kinds)
    and client:supports_method(methods.prepare_type, bufnr)
  if
    reference_range
    and context.location.uri
    and (supports_implementation or supports_references or supports_type_hierarchy)
  then
    local position = positions.to_client_uri(
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
  if configuration_unavailable then
    if #requests == 0 then
      terminal_outcome = { state = "unavailable", message = configuration_unavailable }
    else
      graph.add_note(result, configuration_unavailable, {
        summary = "configuration uses unavailable",
        severity = "warn",
      })
    end
  end
  pending = #requests

  request = function(spec)
    request_count = request_count + 1
    request_labels[#request_labels + 1] = spec.label
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
        terminal_outcome = {
          state = "timed_out",
          message = string.format(
            "LSP relationship requests exceeded %d ms and were stopped.",
            timeout_ms
          ),
        }
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

return M

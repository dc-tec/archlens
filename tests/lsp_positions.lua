local source = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(source, ":p:h:h")
vim.opt.runtimepath:prepend(root)

local function assert_equal(actual, expected, message)
  if not vim.deep_equal(actual, expected) then
    error(
      string.format(
        "%s\nexpected: %s\nactual:   %s",
        message or "values differ",
        vim.inspect(expected),
        vim.inspect(actual)
      )
    )
  end
end

local function run()
  local graph = require("archlens.graph")
  local lsp = require("archlens.lsp")
  local model = require("archlens.model")
  local function edges_for(result, kind)
    local edges = {}
    for _, edge in ipairs(result.edges or {}) do
      if edge.kind == kind then
        edges[#edges + 1] = edge
      end
    end
    return edges
  end
  local position_buffer = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(position_buffer, "/tmp/archlens-lsp-position.go")
  vim.api.nvim_buf_set_lines(position_buffer, 0, -1, false, { "éé target", "😀 target" })
  local position_uri = vim.uri_from_bufnr(position_buffer)
  local byte_position = { line = 0, character = 5 }

  assert_equal(
    lsp._position_to_client(position_buffer, byte_position, "utf-16"),
    { line = 0, character = 3 },
    "Go and Nix LSP requests should convert byte columns to UTF-16 code units"
  )
  assert_equal(
    lsp._position_to_client(position_buffer, byte_position, "utf-8"),
    byte_position,
    "UTF-8 LSP requests should preserve byte columns"
  )
  assert_equal(
    lsp._range_from_client(position_uri, {
      start = { line = 0, character = 3 },
      ["end"] = { line = 0, character = 9 },
    }, "utf-16", position_buffer),
    {
      start = { line = 0, character = 5 },
      ["end"] = { line = 0, character = 11 },
    },
    "UTF-16 LSP result ranges should be normalized back to byte columns"
  )
  assert_equal(
    lsp._range_from_client(position_uri, {
      start = { line = 0, character = 5 },
      ["end"] = { line = 0, character = 11 },
    }, "utf-8", position_buffer),
    {
      start = { line = 0, character = 5 },
      ["end"] = { line = 0, character = 11 },
    },
    "UTF-8 LSP result ranges should remain byte-oriented"
  )
  assert_equal(
    lsp._position_to_client(position_buffer, { line = 1, character = 5 }, "utf-16"),
    { line = 1, character = 3 },
    "UTF-16 requests should count an astral character as two code units"
  )
  assert_equal(
    lsp._position_to_client(position_buffer, { line = 1, character = 5 }, "utf-32"),
    { line = 1, character = 2 },
    "UTF-32 requests should count an astral character as one code point"
  )
  assert_equal(
    lsp._range_from_client(position_uri, {
      start = { line = 1, character = 3 },
      ["end"] = { line = 1, character = 9 },
    }, "utf-16", position_buffer).start.character,
    5,
    "astral UTF-16 result ranges should normalize to byte columns"
  )
  assert_equal(
    lsp._range_from_client(position_uri, {
      start = { line = 1, character = 2 },
      ["end"] = { line = 1, character = 8 },
    }, "utf-32", position_buffer).start.character,
    5,
    "astral UTF-32 result ranges should normalize to byte columns"
  )

  local virtual_uri = "jdt://contents/archlens/Contract.class"
  local virtual_buffer = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(virtual_buffer, virtual_uri)
  vim.api.nvim_buf_set_lines(virtual_buffer, 0, -1, false, { "😀 target" })
  assert_equal(
    lsp._range_from_client(virtual_uri, {
      start = { line = 0, character = 3 },
      ["end"] = { line = 0, character = 9 },
    }, "utf-16").start.character,
    5,
    "loaded virtual documents should provide source text for strict conversion"
  )
  vim.api.nvim_buf_delete(virtual_buffer, { force = true })

  local unavailable_uri = "jdt://contents/archlens/Missing.class"
  assert_equal(
    lsp._range_from_client(unavailable_uri, {
      start = { line = 0, character = 3 },
      ["end"] = { line = 0, character = 9 },
    }, "utf-16"),
    nil,
    "encoded ranges without source text must not be mislabeled as byte-oriented"
  )
  assert_equal(
    lsp._range_from_client(unavailable_uri, {
      start = { line = 0, character = 0 },
      ["end"] = { line = 0, character = 0 },
    }, "utf-16"),
    {
      start = { line = 0, character = 0 },
      ["end"] = { line = 0, character = 0 },
    },
    "zero columns are encoding-independent even when source text is unavailable"
  )
  assert_equal(
    lsp._range_from_client(unavailable_uri, {
      start = { line = 0, character = 3 },
      ["end"] = { line = 0, character = 9 },
    }, "utf-8"),
    {
      start = { line = 0, character = 3 },
      ["end"] = { line = 0, character = 9 },
    },
    "UTF-8 ranges remain safe without source text because their units are bytes"
  )

  local original_get_client_by_id = vim.lsp.get_client_by_id
  local definition_params
  local definition_client = {
    id = 98,
    name = "definition-lsp",
    offset_encoding = "utf-16",
    requests = {},
    is_stopped = function()
      return false
    end,
    supports_method = function(_, method)
      return method == "textDocument/definition"
    end,
    request = function(_, _, params, handler)
      definition_params = params
      vim.schedule(function()
        handler(nil, {
          {
            targetUri = position_uri,
            targetRange = {
              start = { line = 0, character = 0 },
              ["end"] = { line = 0, character = 9 },
            },
            targetSelectionRange = {
              start = { line = 0, character = 3 },
              ["end"] = { line = 0, character = 9 },
            },
          },
        })
      end)
      return true, 1
    end,
  }
  vim.lsp.get_client_by_id = function(client_id)
    return client_id == definition_client.id and definition_client
      or original_get_client_by_id(client_id)
  end
  local definition_result
  lsp.definition_at(
    { client_id = definition_client.id },
    position_buffer,
    {
      uri = position_uri,
    },
    byte_position,
    function(locations, err, skipped)
      definition_result = { locations = locations, err = err, skipped = skipped }
    end
  )
  assert(
    vim.wait(1000, function()
      return definition_result ~= nil
    end),
    "definition requests should complete"
  )
  assert_equal(
    definition_params.position.character,
    3,
    "definition requests should convert import positions to the client encoding"
  )
  assert_equal(
    definition_result.locations[1].range.start.character,
    5,
    "definition targets should normalize back to byte columns"
  )
  assert_equal(definition_result.err, nil)
  assert_equal(definition_result.skipped, 0)
  vim.lsp.get_client_by_id = original_get_client_by_id

  local symbols = lsp._normalize_document_symbols({
    {
      name = "target",
      kind = vim.lsp.protocol.SymbolKind.Function,
      range = {
        start = { line = 0, character = 3 },
        ["end"] = { line = 0, character = 9 },
      },
      selectionRange = {
        start = { line = 0, character = 3 },
        ["end"] = { line = 0, character = 9 },
      },
    },
  }, position_uri, "utf-16", position_buffer)
  assert_equal(
    model.select_document_symbol(symbols, byte_position, position_uri).name,
    "target",
    "document symbol selection should compare byte-oriented cursor and result ranges"
  )
  assert_equal(
    lsp._normalize_document_symbols({
      {
        name = "missing",
        kind = vim.lsp.protocol.SymbolKind.Function,
        range = {
          start = { line = 0, character = 3 },
          ["end"] = { line = 0, character = 9 },
        },
        selectionRange = {
          start = { line = 0, character = 3 },
          ["end"] = { line = 0, character = 9 },
        },
      },
    }, unavailable_uri, "utf-16"),
    {},
    "document symbols with unavailable source text should be skipped without crashing"
  )

  local raw_call_item = {
    name = "target",
    kind = vim.lsp.protocol.SymbolKind.Function,
    uri = position_uri,
    range = {
      start = { line = 0, character = 3 },
      ["end"] = { line = 0, character = 9 },
    },
    selectionRange = {
      start = { line = 0, character = 3 },
      ["end"] = { line = 0, character = 9 },
    },
    data = { targetUri = "opaque-call-state" },
  }
  local normalized_call_item = lsp._normalize_call_item(raw_call_item, "utf-16", position_buffer)
  assert_equal(
    normalized_call_item.selectionRange.start.character,
    5,
    "call hierarchy items should expose byte-oriented ranges internally"
  )
  assert_equal(
    normalized_call_item._archlens_lsp_item,
    nil,
    "normalized public items should not contain transport-only LSP payloads"
  )
  assert_equal(
    normalized_call_item.data,
    nil,
    "normalized hierarchy items should keep opaque server data outside the graph"
  )
  assert_equal(
    lsp._normalize_call_item(
      vim.tbl_extend("force", vim.deepcopy(raw_call_item), {
        uri = unavailable_uri,
      }),
      "utf-16",
      position_buffer
    ),
    nil,
    "call items without convertible source ranges should be omitted"
  )
  local call_context = {
    client_id = 99,
    client_name = "gopls",
    position_encoding = "utf-8",
    root_dir = "/tmp",
    name = "caller",
    location = {
      uri = position_uri,
      range = { start = { line = 0, character = 0 }, ["end"] = byte_position },
    },
  }
  local call_graph = graph.new(call_context)
  local related_context = model.context_from_item(normalized_call_item, {
    id = 99,
    name = "gopls",
    offset_encoding = "utf-8",
    root_dir = "/tmp",
    supports_calls = true,
  })
  related_context.wire_call_item = raw_call_item
  graph.add_edge(
    call_graph,
    graph.edge("outgoing", call_graph.focus, graph.node_from_context(related_context), {
      provider = "gopls",
      method = "callHierarchy/outgoingCalls",
      class = "semantic",
    })
  )
  local call_model = model.build(call_context, call_graph, { include_external = true })
  assert(
    call_model.sections[1].rows[1].context.wire_call_item == raw_call_item,
    "relationship contexts should own the original item needed by follow-up call requests"
  )

  local relationship_context = {
    supports_calls = false,
    name = "Contract",
    location = {
      uri = position_uri,
      range = { start = byte_position, ["end"] = { line = 0, character = 11 } },
    },
  }
  local function run_relationships(fake_client, context_overrides)
    local result
    local metadata
    vim.lsp.get_client_by_id = function(client_id)
      return client_id == fake_client.id and fake_client or original_get_client_by_id(client_id)
    end
    local context = vim.tbl_extend("force", vim.deepcopy(relationship_context), {
      client_id = fake_client.id,
      client_name = fake_client.name,
      position_encoding = "utf-8",
      root_dir = "/tmp",
    }, context_overrides or {})
    local cancel = lsp.relationships(context, position_buffer, function(value, details)
      result = value
      metadata = details
    end, { timeout_ms = 1000 })
    assert(
      vim.wait(1000, function()
        return result ~= nil
      end),
      "the mocked relationship batch should complete"
    )
    cancel()
    vim.lsp.get_client_by_id = original_get_client_by_id
    return result, metadata
  end

  local captured_params = {}
  local next_request_id = 0
  local prepared_type_item = {
    name = "Contract",
    kind = vim.lsp.protocol.SymbolKind.Interface,
    uri = position_uri,
    range = {
      start = { line = 0, character = 0 },
      ["end"] = { line = 0, character = 9 },
    },
    selectionRange = {
      start = { line = 0, character = 3 },
      ["end"] = { line = 0, character = 9 },
    },
    data = { opaque = "prepared-type" },
  }
  local function related_type_item(name)
    return {
      name = name,
      kind = vim.lsp.protocol.SymbolKind.Interface,
      uri = position_uri,
      range = {
        start = { line = 1, character = 0 },
        ["end"] = { line = 1, character = 9 },
      },
      selectionRange = {
        start = { line = 1, character = 3 },
        ["end"] = { line = 1, character = 9 },
      },
      data = { opaque = name },
    }
  end
  local supertype_item = related_type_item("Base")
  local subtype_item = related_type_item("Derived")
  local supported_client = {
    id = 99,
    name = "gopls",
    offset_encoding = "utf-16",
    requests = {},
    is_stopped = function()
      return false
    end,
    supports_method = function(_, method)
      return method == "textDocument/implementation"
        or method == "textDocument/references"
        or method == "textDocument/prepareTypeHierarchy"
    end,
    request = function(_, method, params, handler)
      captured_params[method] = params
      next_request_id = next_request_id + 1
      vim.schedule(function()
        if method == "textDocument/implementation" then
          handler(nil, {
            {
              targetUri = position_uri,
              targetRange = {
                start = { line = 0, character = 0 },
                ["end"] = { line = 0, character = 9 },
              },
              targetSelectionRange = {
                start = { line = 0, character = 4 },
                ["end"] = { line = 0, character = 9 },
              },
              originSelectionRange = {
                start = { line = 0, character = 3 },
                ["end"] = { line = 0, character = 9 },
              },
            },
          })
        elseif method == "textDocument/references" then
          handler(nil, {
            {
              uri = position_uri,
              range = {
                start = { line = 0, character = 3 },
                ["end"] = { line = 0, character = 9 },
              },
            },
          })
        elseif method == "textDocument/prepareTypeHierarchy" then
          handler(nil, { prepared_type_item })
        elseif method == "typeHierarchy/supertypes" then
          handler(nil, { supertype_item })
        elseif method == "typeHierarchy/subtypes" then
          handler(nil, { subtype_item })
        end
      end)
      return true, next_request_id
    end,
  }
  local supported_result = run_relationships(supported_client)
  local supported_references = edges_for(supported_result, "references")
  local supported_implementations = edges_for(supported_result, "implementations")
  local supported_supertypes = edges_for(supported_result, "supertypes")
  local supported_subtypes = edges_for(supported_result, "subtypes")
  assert_equal(
    captured_params["textDocument/references"].position.character,
    3,
    "reference requests should convert internal byte columns to the client encoding"
  )
  assert_equal(
    captured_params["textDocument/implementation"].position.character,
    3,
    "implementation requests should use the same client-position boundary"
  )
  assert_equal(
    captured_params["textDocument/prepareTypeHierarchy"].position.character,
    3,
    "type hierarchy preparation should use the client position encoding"
  )
  assert(
    captured_params["typeHierarchy/supertypes"].item == prepared_type_item,
    "supertype requests should retain the raw prepared item"
  )
  assert(
    captured_params["typeHierarchy/subtypes"].item == prepared_type_item,
    "subtype requests should retain the raw prepared item"
  )
  assert_equal(
    supported_references[1].source.location.range.start.character,
    5,
    "reference responses should be normalized to byte columns"
  )
  assert_equal(
    supported_implementations[1].target.location.range.start.character,
    6,
    "LocationLink selection ranges should be normalized to byte columns"
  )
  assert_equal(
    supported_implementations[1].target.location.full_range.start.character,
    0,
    "LocationLink target ranges should remain distinct from selection ranges"
  )
  assert_equal(
    supported_implementations[1].occurrences[1].ranges[1].start.character,
    5,
    "LocationLink origin ranges should remain normalized edge occurrences"
  )
  assert_equal(supported_supertypes[1].target.name, "Base", "supertypes should point upward")
  assert_equal(supported_subtypes[1].source.name, "Derived", "subtypes should point downward")
  assert_equal(
    supported_supertypes[1].target.location.range.start.character,
    5,
    "supertype ranges should normalize to byte columns"
  )
  assert_equal(
    supported_subtypes[1].source.location.range.start.character,
    5,
    "subtype ranges should normalize to byte columns"
  )
  assert(
    supported_supertypes[1].target.context.wire_type_item == supertype_item,
    "supertype contexts should retain opaque server data"
  )
  assert(
    supported_subtypes[1].source.context.wire_type_item == subtype_item,
    "subtype contexts should retain opaque server data"
  )
  assert_equal(
    supported_supertypes[1].evidence.method,
    "typeHierarchy/supertypes",
    "supertype edges should retain request evidence"
  )
  assert_equal(
    supported_subtypes[1].evidence.method,
    "typeHierarchy/subtypes",
    "subtype edges should retain request evidence"
  )
  for _, edge in ipairs(supported_result.edges) do
    for _, raw_key in ipairs({
      "from",
      "to",
      "fromRanges",
      "targetUri",
      "targetRange",
      "targetSelectionRange",
      "originSelectionRange",
    }) do
      assert_equal(edge[raw_key], nil, "canonical edges must not expose LSP key " .. raw_key)
      assert_equal(
        edge.source.location and edge.source.location[raw_key],
        nil,
        "canonical source nodes must not expose LSP key " .. raw_key
      )
      assert_equal(
        edge.target.location and edge.target.location[raw_key],
        nil,
        "canonical target nodes must not expose LSP key " .. raw_key
      )
    end
    assert_equal(edge.position_encoding, "utf-8", "canonical edges must declare byte columns")
  end

  local function_methods = {}
  local function_client = {
    id = 110,
    name = "function-lsp",
    offset_encoding = "utf-16",
    requests = {},
    is_stopped = function()
      return false
    end,
    supports_method = function(_, method)
      return method == "textDocument/implementation"
        or method == "textDocument/references"
        or method == "textDocument/prepareTypeHierarchy"
    end,
    request = function(_, method, _, handler)
      function_methods[#function_methods + 1] = method
      vim.schedule(function()
        handler(nil, {})
      end)
      return true, #function_methods
    end,
  }
  run_relationships(function_client, {
    kind = vim.lsp.protocol.SymbolKind.Function,
  })
  assert_equal(
    function_methods,
    { "textDocument/references" },
    "ordinary functions should skip inapplicable implementation and type hierarchy requests"
  )

  local direct_type_methods = {}
  local direct_type_client = {
    id = 107,
    name = "type-lsp",
    offset_encoding = "utf-16",
    requests = {},
    is_stopped = function()
      return false
    end,
    supports_method = function()
      return false
    end,
    request = function(_, method, params, handler)
      direct_type_methods[#direct_type_methods + 1] = method
      assert(params.item == prepared_type_item, "focused types should reuse their opaque item")
      vim.schedule(function()
        if method == "typeHierarchy/supertypes" then
          handler(nil, { supertype_item })
        else
          handler({ message = "subtypes unavailable" }, nil)
        end
      end)
      return true, #direct_type_methods
    end,
  }
  local direct_type_result = run_relationships(direct_type_client, {
    wire_type_item = prepared_type_item,
  })
  assert_equal(direct_type_methods, {
    "typeHierarchy/supertypes",
    "typeHierarchy/subtypes",
  }, "focusing a hierarchy row should bypass preparation and query both directions")
  assert_equal(
    #edges_for(direct_type_result, "supertypes"),
    1,
    "one failed hierarchy direction should retain the successful direction"
  )
  assert_equal(edges_for(direct_type_result, "subtypes"), {}, "failed subtype results stay empty")
  assert_equal(
    direct_type_result.errors,
    { "Subtypes failed: subtypes unavailable" },
    "hierarchy direction errors should be reported independently"
  )

  local empty_type_client = {
    id = 108,
    name = "empty-type-lsp",
    offset_encoding = "utf-16",
    requests = {},
    is_stopped = function()
      return false
    end,
    supports_method = function(_, method)
      return method == "textDocument/prepareTypeHierarchy"
    end,
    request = function(_, _, _, handler)
      vim.schedule(function()
        handler(nil, nil)
      end)
      return true, 1
    end,
  }
  local empty_type_result = run_relationships(empty_type_client)
  assert_equal(
    empty_type_result.edges,
    {},
    "a non-type symbol should not synthesize hierarchy rows"
  )
  assert_equal(empty_type_result.errors, {}, "an empty prepare result should remain silent")

  local selected_type_item
  local ambiguous_type_client = {
    id = 109,
    name = "ambiguous-type-lsp",
    offset_encoding = "utf-16",
    requests = {},
    is_stopped = function()
      return false
    end,
    supports_method = function(_, method)
      return method == "textDocument/prepareTypeHierarchy"
    end,
    request = function(_, method, params, handler)
      vim.schedule(function()
        if method == "textDocument/prepareTypeHierarchy" then
          local other = vim.deepcopy(prepared_type_item)
          other.name = "Other"
          handler(nil, { other, prepared_type_item })
        else
          selected_type_item = params.item
          handler(nil, {})
        end
      end)
      return true, method
    end,
  }
  local ambiguous_type_result = run_relationships(ambiguous_type_client)
  assert(
    selected_type_item == prepared_type_item,
    "multiple prepare results should prefer the item matching the focused symbol"
  )
  assert(
    table
      .concat(ambiguous_type_result.notes, "\n")
      :find("Type hierarchy preparation returned 2 candidates; using Contract.", 1, true),
    "ambiguous type preparation should be visible without blocking the pane"
  )

  local incoming_wire = vim.deepcopy(raw_call_item)
  incoming_wire.name = "caller"
  local outgoing_wire = vim.deepcopy(raw_call_item)
  outgoing_wire.name = "callee"
  local call_client = {
    id = 106,
    name = "call-lsp",
    offset_encoding = "utf-16",
    requests = {},
    is_stopped = function()
      return false
    end,
    supports_method = function(_, method)
      return method == "callHierarchy/incomingCalls" or method == "callHierarchy/outgoingCalls"
    end,
    request = function(_, method, _, handler)
      vim.schedule(function()
        if method == "callHierarchy/incomingCalls" then
          handler(nil, { { from = incoming_wire, fromRanges = { incoming_wire.selectionRange } } })
        else
          handler(nil, { { to = outgoing_wire, fromRanges = { outgoing_wire.selectionRange } } })
        end
      end)
      return true, method == "callHierarchy/incomingCalls" and 1 or 2
    end,
  }
  local call_result = run_relationships(call_client, {
    supports_calls = true,
    wire_call_item = raw_call_item,
  })
  local incoming_edges = edges_for(call_result, "incoming")
  local outgoing_edges = edges_for(call_result, "outgoing")
  assert_equal(#incoming_edges, 1, "incoming calls should become canonical graph edges")
  assert_equal(#outgoing_edges, 1, "outgoing calls should become canonical graph edges")
  assert(
    incoming_edges[1].source.context.wire_call_item == incoming_wire,
    "incoming edge contexts should retain their opaque call hierarchy item"
  )
  assert(
    outgoing_edges[1].target.context.wire_call_item == outgoing_wire,
    "outgoing edge contexts should retain their opaque call hierarchy item"
  )
  assert_equal(
    incoming_edges[1].occurrences[1].ranges[1].start.character,
    5,
    "incoming call occurrences should use internal byte columns"
  )

  local captured_incoming_item
  local unavailable_client = {
    id = 103,
    name = "virtual-lsp",
    offset_encoding = "utf-16",
    requests = {},
    is_stopped = function()
      return false
    end,
    supports_method = function(_, method)
      return method == "callHierarchy/incomingCalls"
        or method == "textDocument/implementation"
        or method == "textDocument/references"
    end,
    request = function(_, method, params, handler)
      if method == "callHierarchy/incomingCalls" then
        captured_incoming_item = params.item
      end
      vim.schedule(function()
        if method == "callHierarchy/incomingCalls" then
          local missing_item = vim.tbl_extend("force", vim.deepcopy(raw_call_item), {
            uri = unavailable_uri,
          })
          handler(nil, { { from = missing_item, fromRanges = { missing_item.selectionRange } } })
        elseif method == "textDocument/implementation" then
          handler(nil, {
            {
              targetUri = unavailable_uri,
              targetRange = raw_call_item.range,
              targetSelectionRange = raw_call_item.selectionRange,
            },
          })
        else
          handler(nil, {
            { uri = unavailable_uri, range = raw_call_item.selectionRange },
          })
        end
      end)
      return true, 1
    end,
  }
  local unavailable_result = run_relationships(unavailable_client, {
    supports_calls = true,
    wire_call_item = raw_call_item,
  })
  assert(
    captured_incoming_item == raw_call_item,
    "call hierarchy transport should use the context-owned original item"
  )
  assert_equal(#unavailable_result.edges, 0, "unconvertible relationship results should be omitted")
  local unavailable_errors = table.concat(unavailable_result.errors, "\n")
  for _, label in ipairs({ "Incoming calls", "Implementations", "Project references" }) do
    assert(
      unavailable_errors:find(label .. " omitted 1 result", 1, true),
      label .. " should report its unavailable position conversion"
    )
  end

  local singleton_client = {
    id = 102,
    name = "singleton-lsp",
    offset_encoding = "utf-16",
    requests = {},
    is_stopped = function()
      return false
    end,
    supports_method = function(_, method)
      return method == "textDocument/implementation"
    end,
    request = function(_, _, _, handler)
      vim.schedule(function()
        handler(nil, {
          uri = position_uri,
          range = {
            start = { line = 0, character = 3 },
            ["end"] = { line = 0, character = 9 },
          },
        })
      end)
      return true, 1
    end,
  }
  local singleton_result = run_relationships(singleton_client)
  local singleton_implementations = edges_for(singleton_result, "implementations")
  assert_equal(
    #singleton_implementations,
    1,
    "a singleton Location implementation response should be normalized as one result"
  )
  assert_equal(
    singleton_implementations[1].target.location.range.start.character,
    5,
    "singleton Location ranges should use internal byte columns"
  )

  local unsupported_requests = {}
  local unsupported_client = {
    id = 100,
    name = "references-only",
    offset_encoding = "utf-16",
    requests = {},
    is_stopped = function()
      return false
    end,
    supports_method = function(_, method)
      return method == "textDocument/references"
    end,
    request = function(_, method, _, handler)
      unsupported_requests[#unsupported_requests + 1] = method
      vim.schedule(function()
        handler(nil, {})
      end)
      return true, 1
    end,
  }
  local unsupported_result, unsupported_metadata = run_relationships(unsupported_client)
  assert_equal(
    unsupported_requests,
    { "textDocument/references" },
    "clients without implementation support should not receive that request"
  )
  assert_equal(unsupported_metadata, {
    request_count = 1,
    request_labels = { "Project references" },
  }, "relationship completion should describe the semantic requests that ran")
  assert_equal(
    edges_for(unsupported_result, "implementations"),
    {},
    "unsupported implementation capability should remain an empty relationship"
  )
  local empty_configuration_result = run_relationships(unsupported_client, {
    language = "rust",
    kind = vim.lsp.protocol.SymbolKind.Field,
    configuration = { key = "token", container = "Config", source = "field" },
  })
  assert(
    table
      .concat(empty_configuration_result.notes, "\n")
      :find("references-only returned no configuration uses for this field.", 1, true),
    "an empty semantic configuration result should be visible instead of silently blank"
  )
  local no_reference_client = {
    id = 112,
    name = "symbols-only",
    offset_encoding = "utf-8",
    requests = {},
    is_stopped = function()
      return false
    end,
    supports_method = function()
      return false
    end,
    request = function()
      error("an unsupported reference request must not be sent")
    end,
  }
  local unavailable_configuration_result, unavailable_configuration_metadata =
    run_relationships(no_reference_client, {
      language = "rust",
      kind = vim.lsp.protocol.SymbolKind.Field,
      configuration = { key = "token", container = "Config", source = "field" },
    })
  assert_equal(unavailable_configuration_result.notes, {})
  assert_equal(unavailable_configuration_metadata.outcome, {
    state = "unavailable",
    message = "symbols-only does not support project references for configuration fields.",
  }, "configuration focus should classify unsupported references as unavailable")

  local stopped_client = vim.tbl_extend("force", {}, no_reference_client, {
    id = 113,
    name = "stopped-lsp",
    is_stopped = function()
      return true
    end,
  })
  local stopped_result, stopped_metadata = run_relationships(stopped_client)
  assert_equal(stopped_result.edges, {})
  assert_equal(stopped_metadata.outcome, {
    state = "unavailable",
    message = "The language server is no longer available for relationship analysis.",
  }, "a stopped language server should publish an unavailable outcome")

  local test_reference_client = {
    id = 111,
    name = "test-reference-lsp",
    offset_encoding = "utf-8",
    requests = {},
    is_stopped = function()
      return false
    end,
    supports_method = function(_, method)
      return method == "textDocument/references"
    end,
    request = function(_, _, _, handler)
      vim.schedule(function()
        handler(nil, {
          {
            uri = "file:///tmp/service_test.go",
            range = {
              start = { line = 4, character = 2 },
              ["end"] = { line = 4, character = 8 },
            },
          },
        })
      end)
      return true, 1
    end,
  }
  local test_reference_result = run_relationships(test_reference_client, {
    language = "go",
  })
  assert_equal(
    #edges_for(test_reference_result, "test_references"),
    1,
    "Go references in _test.go files should become explicit test relationships"
  )
  assert_equal(
    graph.focus_node(edges_for(test_reference_result, "test_references")[1]).name,
    relationship_context.name,
    "test reference edges should point back to the focused symbol"
  )
  assert_equal(
    edges_for(test_reference_result, "references"),
    {},
    "classified test references should not remain duplicated as generic references"
  )
  local configuration_result = run_relationships(test_reference_client, {
    language = "go",
    kind = vim.lsp.protocol.SymbolKind.Field,
    configuration = { key = "Enabled", container = "TLSConfig", source = "field" },
  })
  assert_equal(
    #edges_for(configuration_result, "configuration_consumers"),
    1,
    "configuration references should become explicit use relationships"
  )
  assert_equal(
    edges_for(configuration_result, "test_references"),
    {},
    "configuration use should take precedence over the test-file presentation"
  )

  local file_fallback_requests = 0
  local file_fallback_client = {
    id = 105,
    name = "file-fallback-lsp",
    offset_encoding = "utf-16",
    requests = {},
    is_stopped = function()
      return false
    end,
    supports_method = function(_, method)
      return method == "textDocument/implementation" or method == "textDocument/references"
    end,
    request = function()
      file_fallback_requests = file_fallback_requests + 1
      return false
    end,
  }
  local file_fallback_result = run_relationships(file_fallback_client, {
    file_fallback = true,
  })
  assert_equal(
    file_fallback_requests,
    0,
    "a file fallback should not issue identifier-based semantic requests"
  )
  assert_equal(file_fallback_result.errors, {}, "a file fallback should not report an LSP error")

  local unavailable_request_count = 0
  local unavailable_source_client = {
    id = 104,
    name = "unavailable-source-lsp",
    offset_encoding = "utf-16",
    requests = {},
    is_stopped = function()
      return false
    end,
    supports_method = function(_, method)
      return method == "textDocument/references"
    end,
    request = function()
      unavailable_request_count = unavailable_request_count + 1
      return true, unavailable_request_count
    end,
  }
  local unavailable_source_result = run_relationships(unavailable_source_client, {
    location = {
      uri = unavailable_uri,
      range = {
        start = { line = 0, character = 3 },
        ["end"] = { line = 0, character = 9 },
      },
    },
  })
  assert_equal(
    unavailable_request_count,
    0,
    "requests requiring an unavailable cross-encoding position should not be sent"
  )
  assert_equal(unavailable_source_result.errors, {
    "LSP locations were skipped because their source text was unavailable for position conversion.",
  }, "skipped outbound location requests should explain the conversion boundary")

  local rejected_client = {
    id = 101,
    name = "rejecting-lsp",
    offset_encoding = "utf-16",
    requests = {},
    is_stopped = function()
      return false
    end,
    supports_method = function(_, method)
      return method == "textDocument/implementation"
    end,
    request = function()
      return false
    end,
  }
  local rejected_result = run_relationships(rejected_client)
  assert_equal(
    rejected_result.errors,
    { "Implementations failed: request rejected" },
    "a rejected implementation request should be reported without aborting the batch"
  )
  assert_equal(
    edges_for(rejected_result, "implementations"),
    {},
    "rejected implementation requests should not synthesize structural fallback rows"
  )

  local duplicate_handlers = {}
  local duplicate_client = {
    id = 114,
    name = "duplicate-callback-lsp",
    offset_encoding = "utf-8",
    requests = {},
    is_stopped = function()
      return false
    end,
    supports_method = function(_, method)
      return method == "callHierarchy/incomingCalls" or method == "callHierarchy/outgoingCalls"
    end,
    request = function(_, _, _, handler)
      duplicate_handlers[#duplicate_handlers + 1] = handler
      return true, #duplicate_handlers
    end,
  }
  vim.lsp.get_client_by_id = function(client_id)
    return client_id == duplicate_client.id and duplicate_client
      or original_get_client_by_id(client_id)
  end
  local duplicate_result
  local cancel_duplicate = lsp.relationships(
    vim.tbl_extend("force", vim.deepcopy(relationship_context), {
      client_id = duplicate_client.id,
      client_name = duplicate_client.name,
      position_encoding = "utf-8",
      root_dir = "/tmp",
      supports_calls = true,
      wire_call_item = {
        name = "Contract",
        uri = position_uri,
        range = relationship_context.location.range,
        selectionRange = relationship_context.location.range,
      },
    }),
    position_buffer,
    function(value)
      duplicate_result = value
    end,
    { timeout_ms = 1000 }
  )
  assert_equal(#duplicate_handlers, 2, "both call hierarchy requests should start")
  duplicate_handlers[1](nil, {})
  duplicate_handlers[1](nil, {})
  assert_equal(
    duplicate_result,
    nil,
    "a duplicate LSP response must not complete an outstanding relationship batch"
  )
  duplicate_handlers[2](nil, {})
  assert(duplicate_result, "the relationship batch should complete after each request settles")
  cancel_duplicate()
  vim.lsp.get_client_by_id = original_get_client_by_id

  local cancelled_type_requests = {}
  local hanging_type_handlers = {}
  local hanging_type_client = {
    id = 110,
    name = "hanging-type-lsp",
    offset_encoding = "utf-16",
    requests = {},
    is_stopped = function()
      return false
    end,
    supports_method = function(_, method)
      return method == "textDocument/prepareTypeHierarchy"
    end,
    request = function(self, method, _, handler)
      local request_id = #hanging_type_handlers + 1
      if method == "textDocument/prepareTypeHierarchy" then
        request_id = 1
        self.requests[request_id] = {}
        vim.schedule(function()
          self.requests[request_id] = nil
          handler(nil, { prepared_type_item })
        end)
      else
        request_id = method == "typeHierarchy/supertypes" and 2 or 3
        self.requests[request_id] = {}
        hanging_type_handlers[#hanging_type_handlers + 1] = handler
      end
      return true, request_id
    end,
    cancel_request = function(self, request_id)
      cancelled_type_requests[#cancelled_type_requests + 1] = request_id
      self.requests[request_id] = nil
      return true
    end,
  }
  vim.lsp.get_client_by_id = function(client_id)
    return client_id == hanging_type_client.id and hanging_type_client
      or original_get_client_by_id(client_id)
  end
  local hanging_context = vim.tbl_extend("force", vim.deepcopy(relationship_context), {
    client_id = hanging_type_client.id,
    client_name = hanging_type_client.name,
    position_encoding = "utf-8",
    root_dir = "/tmp",
  })
  local timeout_result
  local timeout_metadata
  local timeout_callbacks = 0
  local cancel_hanging = lsp.relationships(
    hanging_context,
    position_buffer,
    function(value, details)
      timeout_callbacks = timeout_callbacks + 1
      timeout_result = value
      timeout_metadata = details
    end,
    { timeout_ms = 20 }
  )
  assert(
    vim.wait(1000, function()
      return timeout_result ~= nil
    end),
    "a hanging type hierarchy fan-out should obey the shared timeout"
  )
  table.sort(cancelled_type_requests)
  assert_equal(
    cancelled_type_requests,
    { 2, 3 },
    "the hierarchy timeout should cancel both outstanding follow-up requests"
  )
  assert_equal(timeout_result.errors, {})
  assert_equal(timeout_metadata.outcome, {
    state = "timed_out",
    message = "LSP relationship requests exceeded 20 ms and were stopped.",
  }, "the hierarchy timeout should publish a typed terminal outcome")
  for _, handler in ipairs(hanging_type_handlers) do
    handler(nil, {})
  end
  vim.wait(20)
  assert_equal(timeout_callbacks, 1, "late hierarchy responses must not complete the batch twice")
  cancel_hanging()
  vim.lsp.get_client_by_id = original_get_client_by_id

  local navigation_context = {
    client_name = "gopls",
    position_encoding = "utf-8",
    root_dir = vim.fs.dirname(vim.uri_to_fname(position_uri)),
    supports_calls = true,
    name = "Contract",
    location = {
      uri = position_uri,
      range = {
        start = byte_position,
        ["end"] = { line = 0, character = 11 },
      },
    },
  }
  local navigation_graph = graph.new(navigation_context)
  graph.merge(navigation_graph, supported_result)
  local navigation_model = model.build(navigation_context, navigation_graph, {
    include_external = false,
  })
  local navigation_row
  for _, section in ipairs(navigation_model.sections) do
    if section.id == "implementations" then
      navigation_row = section.rows[1]
      break
    end
  end
  assert(navigation_row, "the implementation relationship should remain navigable")
  local original_show_document = vim.lsp.util.show_document
  local opened_location
  local opened_encoding
  vim.lsp.util.show_document = function(location, encoding)
    opened_location = location
    opened_encoding = encoding
    return true
  end
  require("archlens").open(navigation_row)
  vim.lsp.util.show_document = original_show_document
  assert_equal(
    opened_location.range.start.character,
    6,
    "opening a normalized implementation should retain its byte-oriented target column"
  )
  assert_equal(
    opened_encoding,
    "utf-8",
    "opening a location-only relationship should declare the internal UTF-8 encoding"
  )
  vim.api.nvim_buf_delete(position_buffer, { force = true })
end

local ok, err = xpcall(run, debug.traceback)
if not ok then
  vim.api.nvim_err_writeln(err)
  vim.cmd("cquit 1")
end

print("archlens.nvim LSP position tests passed")
vim.cmd("quitall")

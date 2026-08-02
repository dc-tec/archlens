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
  local lsp = require("archlens.lsp")
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
    require("archlens.model").select_document_symbol(symbols, byte_position, position_uri).name,
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
  local call_model = require("archlens.model").build({
    client_id = 99,
    client_name = "gopls",
    position_encoding = "utf-8",
    root_dir = "/tmp",
    name = "caller",
    location = {
      uri = position_uri,
      range = { start = { line = 0, character = 0 }, ["end"] = byte_position },
    },
  }, {
    outgoing = {
      { to = normalized_call_item, wire_call_item = raw_call_item },
    },
  }, { include_external = true })
  assert(
    call_model.sections[1].rows[1].context.wire_call_item == raw_call_item,
    "relationship contexts should own the original item needed by follow-up call requests"
  )

  local original_get_client_by_id = vim.lsp.get_client_by_id
  local relationship_context = {
    supports_calls = false,
    location = {
      uri = position_uri,
      range = { start = byte_position, ["end"] = { line = 0, character = 11 } },
    },
  }
  local function run_relationships(fake_client, context_overrides)
    local result
    vim.lsp.get_client_by_id = function(client_id)
      return client_id == fake_client.id and fake_client or original_get_client_by_id(client_id)
    end
    local context = vim.tbl_extend("force", vim.deepcopy(relationship_context), {
      client_id = fake_client.id,
    }, context_overrides or {})
    local cancel = lsp.relationships(context, position_buffer, function(value)
      result = value
    end, { timeout_ms = 1000 })
    assert(
      vim.wait(1000, function()
        return result ~= nil
      end),
      "the mocked relationship batch should complete"
    )
    cancel()
    vim.lsp.get_client_by_id = original_get_client_by_id
    return result
  end

  local captured_params = {}
  local next_request_id = 0
  local supported_client = {
    id = 99,
    name = "gopls",
    offset_encoding = "utf-16",
    requests = {},
    is_stopped = function()
      return false
    end,
    supports_method = function(_, method)
      return method == "textDocument/implementation" or method == "textDocument/references"
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
                start = { line = 0, character = 3 },
                ["end"] = { line = 0, character = 9 },
              },
            },
          })
        else
          handler(nil, {
            {
              uri = position_uri,
              range = {
                start = { line = 0, character = 3 },
                ["end"] = { line = 0, character = 9 },
              },
            },
          })
        end
      end)
      return true, next_request_id
    end,
  }
  local supported_result = run_relationships(supported_client)
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
    supported_result.references[1].range.start.character,
    5,
    "reference responses should be normalized to byte columns"
  )
  assert_equal(
    supported_result.implementations[1].targetSelectionRange.start.character,
    5,
    "LocationLink selection ranges should be normalized to byte columns"
  )
  assert_equal(
    supported_result.implementations[1].targetRange.start.character,
    0,
    "LocationLink target ranges should remain distinct from selection ranges"
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
  assert_equal(
    {
      incoming = unavailable_result.incoming,
      implementations = unavailable_result.implementations,
      references = unavailable_result.references,
    },
    { incoming = {}, implementations = {}, references = {} },
    "unconvertible call, implementation, and reference results should all be omitted"
  )
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
  assert_equal(
    #singleton_result.implementations,
    1,
    "a singleton Location implementation response should be normalized as one result"
  )
  assert_equal(
    singleton_result.implementations[1].range.start.character,
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
  local unsupported_result = run_relationships(unsupported_client)
  assert_equal(
    unsupported_requests,
    { "textDocument/references" },
    "clients without implementation support should not receive that request"
  )
  assert_equal(
    unsupported_result.implementations,
    {},
    "unsupported implementation capability should remain an empty relationship"
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
    rejected_result.implementations,
    {},
    "rejected implementation requests should not synthesize structural fallback rows"
  )

  local navigation_model = require("archlens.model").build({
    client_name = "gopls",
    position_encoding = "utf-8",
    root_dir = vim.fs.dirname(vim.uri_to_fname(position_uri)),
    supports_calls = true,
    name = "Contract",
    location = {
      uri = position_uri,
      range = {
        start = { line = 0, character = 0 },
        ["end"] = { line = 0, character = 1 },
      },
    },
  }, {
    implementations = supported_result.implementations,
  }, { include_external = false })
  local navigation_row = navigation_model.sections[1].rows[1]
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
    5,
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

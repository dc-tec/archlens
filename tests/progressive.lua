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

local function section(model, id)
  for _, value in ipairs(model.sections or {}) do
    if value.id == id then
      return value
    end
  end
end

local function run()
  local graph = require("archlens.graph")
  local source_buffer = vim.api.nvim_get_current_buf()
  local source_window = vim.api.nvim_get_current_win()
  local source_path = vim.fn.tempname() .. ".lua"
  vim.api.nvim_buf_set_name(source_buffer, source_path)
  vim.bo[source_buffer].filetype = "lua"
  vim.api.nvim_buf_set_lines(source_buffer, 0, -1, false, {
    "local function Current()",
    "  Child()",
    "end",
    "Current()",
  })

  local uri = vim.uri_from_bufnr(source_buffer)
  local function location(line)
    return {
      uri = uri,
      range = {
        start = { line = line, character = 0 },
        ["end"] = { line = line, character = 7 },
      },
    }
  end

  local base_context = {
    item = {
      name = "Current",
      kind = vim.lsp.protocol.SymbolKind.Function,
      uri = uri,
      range = location(0).range,
      selectionRange = location(0).range,
    },
    call_item = {},
    client_id = 1,
    client_name = "gopls",
    position_encoding = "utf-16",
    root_dir = vim.fs.dirname(source_path),
    supports_calls = true,
    name = "Current",
    kind = vim.lsp.protocol.SymbolKind.Function,
    kind_name = "Function",
    component = vim.fs.basename(vim.fs.dirname(source_path)),
    location = location(0),
    path = source_path,
    path_label = vim.fs.basename(source_path),
    line = 1,
    language = "lua",
    syntax = {
      provider = "Tree-sitter",
      ancestors = {},
      children = {
        {
          name = "Child",
          kind_name = "Function",
          location = location(1),
          path_label = vim.fs.basename(source_path),
          line = 2,
        },
      },
      siblings = {},
    },
  }
  local syntax_context = vim.deepcopy(base_context)
  syntax_context.client_id = nil
  syntax_context.client_name = "Tree-sitter"
  syntax_context.item = nil
  syntax_context.call_item = nil
  syntax_context.supports_calls = false

  local function semantic_delta(current, implementations, outgoing)
    local delta = graph.delta()
    local focus = graph.node_from_context(current)
    for _, value in ipairs(implementations or {}) do
      local related = graph.node_from_location(value, {
        kind_name = "Implementation",
        position_encoding = "utf-8",
      })
      graph.add_edge(
        delta,
        graph.edge("implementations", focus, related, {
          provider = current.client_name,
          method = "textDocument/implementation",
          class = "semantic",
        })
      )
    end
    for _, item in ipairs(outgoing or {}) do
      local related_context = require("archlens.model").context_from_item(item, {
        id = current.client_id,
        name = current.client_name,
        offset_encoding = "utf-8",
        root_dir = current.root_dir,
        supports_calls = true,
      })
      graph.add_edge(
        delta,
        graph.edge("outgoing", focus, graph.node_from_context(related_context), {
          provider = current.client_name,
          method = "callHierarchy/outgoingCalls",
          class = "semantic",
        })
      )
    end
    return delta
  end

  local function structural_delta(current, values, ran)
    local delta = graph.delta()
    local focus = graph.node_from_context(current)
    for _, value in ipairs(values or {}) do
      local related = graph.node_from_location(value, {
        name = value.text,
        kind_name = "Structural match",
        position_encoding = "utf-8",
      })
      graph.add_edge(
        delta,
        graph.edge("structural", related, focus, {
          provider = "ast-grep",
          method = "structural",
          class = "structural",
        })
      )
    end
    if ran then
      graph.add_contributor(delta, "ast_grep", "ast-grep")
    end
    return delta
  end

  local relationship_callbacks = {}
  local relationship_contexts = {}
  local import_callbacks = {}
  local importer_callbacks = {}
  local structural_callbacks = {}
  local resolve_callbacks = {}
  local cancellation_count = 0
  local rendered = {}
  local active_session
  local selected_row_id

  package.loaded["archlens.lsp"] = {
    resolve = function(_, _, callback)
      resolve_callbacks[#resolve_callbacks + 1] = callback
      return function()
        cancellation_count = cancellation_count + 1
      end
    end,
    relationships = function(context, _, callback)
      relationship_contexts[#relationship_contexts + 1] = vim.deepcopy(context)
      relationship_callbacks[#relationship_callbacks + 1] = callback
      return function()
        cancellation_count = cancellation_count + 1
      end
    end,
  }
  package.loaded["archlens.ast_grep"] = {
    default_globs = {},
    relationships = function(_, _, callback)
      structural_callbacks[#structural_callbacks + 1] = callback
      return function()
        cancellation_count = cancellation_count + 1
      end
    end,
  }
  package.loaded["archlens.imports"] = {
    clear_cache = function() end,
    relationships = function(_, _, _, callback)
      import_callbacks[#import_callbacks + 1] = callback
      return function()
        cancellation_count = cancellation_count + 1
      end
    end,
  }
  package.loaded["archlens.import_index"] = {
    relationships = function(_, _, _, callback)
      importer_callbacks[#importer_callbacks + 1] = callback
      return function()
        cancellation_count = cancellation_count + 1
      end
    end,
  }
  package.loaded["archlens.treesitter"] = {
    supports_imports = function()
      return true
    end,
    resolve = function(_, _, semantic_context)
      local context = vim.deepcopy(semantic_context or syntax_context)
      context.syntax = vim.deepcopy(base_context.syntax)
      context.language = "lua"
      return context
    end,
  }
  package.loaded["archlens.view"] = {
    ensure = function(session)
      active_session = session
    end,
    render = function(session, value)
      active_session = session
      rendered[#rendered + 1] = vim.deepcopy(value)
    end,
    is_map_window = function()
      return false
    end,
    selected_row_id = function()
      return selected_row_id
    end,
    close = function() end,
  }
  package.loaded["archlens"] = nil

  local archlens = require("archlens")
  archlens.setup({
    ast_grep = { enabled = true },
    lsp = { resolve_timeout_ms = 60000 },
  })
  archlens.show_here()

  assert_equal(#resolve_callbacks, 1, "the first LSP resolution should start")
  assert_equal(#relationship_callbacks, 0, "relationships must wait for LSP resolution")
  assert_equal(#structural_callbacks, 0, "project search must wait for symbol resolution")
  local immediate_model = rendered[#rendered]
  assert(
    section(immediate_model, "children"),
    "Tree-sitter structure should render before LSP resolution"
  )
  assert_equal(
    immediate_model.pending_providers,
    { "LSP", "ast-grep" },
    "the immediate local view should expose queued providers"
  )

  resolve_callbacks[1](vim.deepcopy(base_context))
  assert_equal(#relationship_callbacks, 1, "the first LSP provider should start")
  assert_equal(#import_callbacks, 1, "the file import provider should start")
  assert_equal(#importer_callbacks, 1, "the project import index should start independently")
  assert_equal(#structural_callbacks, 1, "the first ast-grep provider should start")
  local local_model = rendered[#rendered]
  assert(section(local_model, "children"), "Tree-sitter structure should render immediately")
  assert_equal(
    local_model.pending_providers,
    { "gopls", "Imports", "Project imports", "ast-grep" },
    "the initial local view should name all pending providers"
  )
  local local_lines = require("archlens.render").build(local_model, { width = 80 }).lines
  assert(
    vim.tbl_contains(local_lines, "Pending: gopls · Imports · Project imports · ast-grep"),
    "the rendered pane should expose pending providers"
  )

  structural_callbacks[1](structural_delta(base_context, {
    vim.tbl_extend("force", location(3), { provider = "ast-grep", text = "Current()" }),
  }, true))
  local structural_model = rendered[#rendered]
  assert(section(structural_model, "structural"), "ast-grep results should render on arrival")
  assert_equal(
    structural_model.pending_providers,
    { "gopls", "Imports", "Project imports" },
    "out-of-order ast-grep completion should leave semantic providers pending"
  )

  relationship_callbacks[1](semantic_delta(base_context, { location(2) }, {
    {
      name = "Child",
      kind = vim.lsp.protocol.SymbolKind.Function,
      uri = uri,
      range = location(1).range,
      selectionRange = location(1).range,
    },
  }))
  local complete_model = rendered[#rendered]
  assert(
    section(complete_model, "implementations"),
    "semantic implementations should merge through the existing LSP provider"
  )
  assert(section(complete_model, "outgoing"), "LSP results should merge after ast-grep")
  assert(section(complete_model, "structural"), "earlier ast-grep results should remain merged")
  assert_equal(
    complete_model.pending_providers,
    { "Imports", "Project imports" },
    "LSP completion should not hide the pending import provider"
  )
  import_callbacks[1](graph.delta())
  assert_equal(
    rendered[#rendered].pending_providers,
    { "Project imports" },
    "outbound imports should render without waiting for the cold project index"
  )
  importer_callbacks[1](graph.delta())
  complete_model = rendered[#rendered]
  assert_equal(
    complete_model.pending_providers,
    {},
    "the completed view should have no pending providers"
  )

  archlens.show_here()
  resolve_callbacks[2](vim.deepcopy(base_context))
  local stale_lsp = relationship_callbacks[2]
  local stale_imports = import_callbacks[2]
  local stale_importers = importer_callbacks[2]
  local stale_structural = structural_callbacks[2]
  archlens.show_here()
  assert(cancellation_count >= 4, "starting a new generation should cancel previous provider work")
  local renders_before_stale = #rendered

  stale_lsp(semantic_delta(base_context, {}, {}))
  stale_imports(graph.delta())
  stale_importers(graph.delta())
  stale_structural(structural_delta(base_context, {
    vim.tbl_extend("force", location(2), { provider = "ast-grep", text = "StaleAstGrep()" }),
  }, true))
  assert_equal(
    #rendered,
    renders_before_stale,
    "late callbacks from a stale generation must not redraw the view"
  )

  resolve_callbacks[3](vim.deepcopy(base_context))
  structural_callbacks[3](structural_delta(base_context, {}, true))
  import_callbacks[3](graph.delta())
  importer_callbacks[3](graph.delta())
  assert_equal(
    rendered[#rendered].pending_providers,
    { "gopls" },
    "the current generation should continue after stale callbacks are ignored"
  )
  relationship_callbacks[3](semantic_delta(base_context, {}, {}))
  assert_equal(
    rendered[#rendered].pending_providers,
    {},
    "the current generation should still complete normally"
  )

  local semantic_item = {
    name = "Implementation",
    kind = vim.lsp.protocol.SymbolKind.Function,
    uri = uri,
    range = location(2).range,
    selectionRange = location(2).range,
  }
  local semantic_implementation = vim.deepcopy(base_context)
  semantic_implementation.item = semantic_item
  semantic_implementation.call_item = semantic_item
  semantic_implementation.wire_call_item = { data = "wire-item" }
  semantic_implementation.name = semantic_item.name
  semantic_implementation.location = location(2)
  archlens.focus({
    id = "implementation-focus",
    location = location(2),
    resolve_on_focus = true,
  })
  assert_equal(#resolve_callbacks, 4, "focusing a location row should start semantic resolution")
  resolve_callbacks[4](semantic_implementation)
  assert_equal(
    relationship_contexts[4].supports_calls,
    true,
    "focused location resolution should preserve call hierarchy capability"
  )
  assert_equal(
    relationship_contexts[4].item,
    semantic_item,
    "focused location resolution should preserve the normalized semantic item"
  )
  assert_equal(
    relationship_contexts[4].wire_call_item,
    { data = "wire-item" },
    "focused location resolution should preserve the context-owned transport item"
  )
  relationship_callbacks[4](semantic_delta(semantic_implementation, {}, {}))
  import_callbacks[4](graph.delta())
  importer_callbacks[4](graph.delta())
  structural_callbacks[4](structural_delta(semantic_implementation, {}, true))

  active_session.expanded = { subtypes = true }
  active_session.expanded_groups = { ["test_references:group:test"] = true }
  active_session.group_limits = { ["test_references:group:test"] = 16 }
  active_session.collapsed = { references = true }
  selected_row_id = "subtypes:selected"
  local focused_type = vim.deepcopy(base_context)
  focused_type.name = "Derived"
  focused_type.supports_calls = false
  focused_type.location = location(3)
  focused_type.wire_type_item = { data = { opaque = "focused-type" } }
  archlens.focus({
    id = "subtypes:derived",
    context = focused_type,
    location = focused_type.location,
  })
  assert_equal(
    relationship_contexts[5].wire_type_item,
    focused_type.wire_type_item,
    "direct type focus should preserve the opaque hierarchy item"
  )
  relationship_callbacks[5](semantic_delta(focused_type, {}, {}))
  import_callbacks[5](graph.delta())
  importer_callbacks[5](graph.delta())
  structural_callbacks[5](structural_delta(focused_type, {}, true))

  archlens.back()
  assert_equal(
    active_session.expanded,
    { subtypes = true },
    "back navigation should restore expanded sections"
  )
  assert_equal(
    active_session.collapsed,
    { references = true },
    "back navigation should restore collapsed sections"
  )
  assert_equal(
    active_session.expanded_groups,
    { ["test_references:group:test"] = true },
    "back navigation should restore expanded context groups"
  )
  assert_equal(
    active_session.group_limits,
    { ["test_references:group:test"] = 16 },
    "back navigation should restore progressive group limits"
  )
  assert_equal(
    active_session.restore_row_id,
    "subtypes:selected",
    "back navigation should restore a selected row from an expanded section"
  )
  relationship_callbacks[6](semantic_delta(semantic_implementation, {}, {}))
  import_callbacks[6](graph.delta())
  importer_callbacks[6](graph.delta())
  structural_callbacks[6](structural_delta(semantic_implementation, {}, true))

  local module_context = vim.deepcopy(base_context)
  module_context.name = "example.module"
  module_context.module_context = true
  module_context.location = location(3)
  module_context.supports_calls = false
  archlens.focus({ context = module_context, location = module_context.location })
  assert_equal(
    #relationship_callbacks,
    6,
    "module focus should skip symbol-level LSP relationships"
  )
  assert_equal(#structural_callbacks, 6, "module focus should skip symbol-name project search")
  assert_equal(#import_callbacks, 7, "module focus should continue file-level dependency analysis")
  assert_equal(
    #importer_callbacks,
    7,
    "module focus should continue project-level dependency analysis"
  )
  import_callbacks[7](graph.delta())
  importer_callbacks[7](graph.delta())

  archlens.close()
  assert(vim.api.nvim_win_is_valid(source_window), "the source window should remain valid")
end

local ok, err = xpcall(run, debug.traceback)
if not ok then
  vim.api.nvim_err_writeln(err)
  vim.cmd("cquit 1")
end

print("archlens.nvim progressive provider tests passed")
vim.cmd("quitall!")

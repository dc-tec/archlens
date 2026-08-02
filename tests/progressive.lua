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

  local relationship_callbacks = {}
  local structural_callbacks = {}
  local resolve_callbacks = {}
  local cancellation_count = 0
  local rendered = {}

  package.loaded["archlens.lsp"] = {
    resolve = function(_, _, callback)
      resolve_callbacks[#resolve_callbacks + 1] = callback
      return function()
        cancellation_count = cancellation_count + 1
      end
    end,
    relationships = function(_, _, callback)
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
  package.loaded["archlens.treesitter"] = {
    resolve = function(_, _, semantic_context)
      local context = vim.deepcopy(semantic_context or syntax_context)
      context.syntax = vim.deepcopy(base_context.syntax)
      context.language = "lua"
      return context
    end,
  }
  package.loaded["archlens.view"] = {
    ensure = function() end,
    render = function(_, value)
      rendered[#rendered + 1] = vim.deepcopy(value)
    end,
    is_map_window = function()
      return false
    end,
    selected_row_id = function()
      return nil
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
  assert_equal(#structural_callbacks, 1, "the first ast-grep provider should start")
  local local_model = rendered[#rendered]
  assert(section(local_model, "children"), "Tree-sitter structure should render immediately")
  assert_equal(
    local_model.pending_providers,
    { "gopls", "ast-grep" },
    "the initial local view should name both pending providers"
  )
  local local_lines = require("archlens.render").build(local_model, { width = 80 }).lines
  assert(
    vim.tbl_contains(local_lines, "Pending: gopls · ast-grep"),
    "the rendered pane should expose pending providers"
  )

  structural_callbacks[1]({
    structural = {
      vim.tbl_extend("force", location(3), { provider = "ast-grep", text = "Current()" }),
    },
    ast_grep_ran = true,
  })
  local structural_model = rendered[#rendered]
  assert(section(structural_model, "structural"), "ast-grep results should render on arrival")
  assert_equal(
    structural_model.pending_providers,
    { "gopls" },
    "out-of-order ast-grep completion should leave only LSP pending"
  )

  relationship_callbacks[1]({
    outgoing = {
      {
        to = {
          name = "Child",
          kind = vim.lsp.protocol.SymbolKind.Function,
          uri = uri,
          range = location(1).range,
          selectionRange = location(1).range,
        },
      },
    },
  })
  local complete_model = rendered[#rendered]
  assert(section(complete_model, "outgoing"), "LSP results should merge after ast-grep")
  assert(section(complete_model, "structural"), "earlier ast-grep results should remain merged")
  assert_equal(
    complete_model.pending_providers,
    {},
    "the completed view should have no pending providers"
  )

  archlens.show_here()
  resolve_callbacks[2](vim.deepcopy(base_context))
  local stale_lsp = relationship_callbacks[2]
  local stale_structural = structural_callbacks[2]
  archlens.show_here()
  assert(cancellation_count >= 3, "starting a new generation should cancel previous provider work")
  local renders_before_stale = #rendered

  stale_lsp({ outgoing = { { to = { name = "StaleLsp" } } } })
  stale_structural({
    structural = {
      vim.tbl_extend("force", location(2), { provider = "ast-grep", text = "StaleAstGrep()" }),
    },
    ast_grep_ran = true,
  })
  assert_equal(
    #rendered,
    renders_before_stale,
    "late callbacks from a stale generation must not redraw the view"
  )

  resolve_callbacks[3](vim.deepcopy(base_context))
  structural_callbacks[3]({ structural = {}, ast_grep_ran = true })
  assert_equal(
    rendered[#rendered].pending_providers,
    { "gopls" },
    "the current generation should continue after stale callbacks are ignored"
  )
  relationship_callbacks[3]({ outgoing = {} })
  assert_equal(
    rendered[#rendered].pending_providers,
    {},
    "the current generation should still complete normally"
  )

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

local source = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(source, ":p:h:h")
vim.opt.runtimepath:prepend(root)

local function equal(actual, expected, message)
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
  local source_window = vim.api.nvim_get_current_win()
  local source_buffer = vim.api.nvim_get_current_buf()
  local path = vim.fn.tempname() .. ".lua"
  vim.api.nvim_buf_set_name(source_buffer, path)
  vim.bo[source_buffer].filetype = "lua"
  vim.api.nvim_buf_set_lines(source_buffer, 0, -1, false, {
    "local function Alpha()",
    "  return 1",
    "end",
    "local function Beta()",
    "  return 2",
    "end",
  })
  local uri = vim.uri_from_bufnr(source_buffer)

  local function context(name, line, client_id)
    local location = {
      uri = uri,
      range = {
        start = { line = line, character = 0 },
        ["end"] = { line = line + 2, character = 3 },
      },
    }
    return {
      name = name,
      kind = vim.lsp.protocol.SymbolKind.Function,
      kind_name = "Function",
      client_id = client_id,
      client_name = client_id and "lua_ls" or "Tree-sitter",
      root_dir = vim.fs.dirname(path),
      path = path,
      path_label = vim.fs.basename(path),
      line = line + 1,
      location = location,
      supports_calls = client_id ~= nil,
      syntax = { provider = "Tree-sitter", ancestors = {}, children = {}, siblings = {} },
    }
  end

  local alpha_syntax = context("Alpha", 0, nil)
  local beta_syntax = context("Beta", 3, nil)
  local alpha_semantic = context("Alpha", 0, 1)
  local beta_semantic = context("Beta", 3, 1)
  local resolve_calls = {}
  local cancellations = 0
  local rendered = {}
  local active_session

  package.loaded["archlens.lsp"] = {
    note_attach = function() end,
    resolve = function(buffer, position, callback)
      resolve_calls[#resolve_calls + 1] = {
        buffer = buffer,
        position = vim.deepcopy(position),
        callback = callback,
      }
      return function()
        cancellations = cancellations + 1
      end
    end,
  }
  package.loaded["archlens.treesitter"] = {
    resolve = function(_, position, semantic)
      if semantic then
        return vim.deepcopy(semantic)
      end
      return vim.deepcopy(position.line < 3 and alpha_syntax or beta_syntax)
    end,
  }
  package.loaded["archlens.providers"] = {
    clear_cache = function() end,
    local_pending = function()
      return {}
    end,
    run = function(current, _, _, hooks)
      hooks.on_update(graph.new(current))
    end,
  }
  package.loaded["archlens.view"] = {
    ensure = function(session)
      active_session = session
    end,
    render = function(session, value)
      active_session = session
      session.model = value
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
    cursor_follow = { debounce_ms = 5 },
    lsp = { resolve_timeout_ms = 60000 },
  })
  archlens.show_here()
  equal(#resolve_calls, 1, "ArchLensHere should resolve the initial cursor")
  resolve_calls[1].callback(vim.deepcopy(alpha_semantic))
  equal(rendered[#rendered].cursor_follow, false, "cursor following should default to pinned")

  vim.api.nvim_win_set_cursor(source_window, { 2, 2 })
  vim.api.nvim_exec_autocmds("CursorMoved", { buffer = source_buffer })
  vim.wait(20)
  equal(#resolve_calls, 1, "pinned mode should ignore cursor events")

  for index = 1, 35 do
    local next_context = context("Focus" .. index, index + 10, 1)
    archlens.focus({ context = next_context, location = next_context.location })
  end
  equal(active_session.model.navigation.back_count, 32, "back history should remain bounded")
  equal(active_session.model.navigation.omitted, 3, "bounded history should report discarded roots")
  equal(#active_session.model.navigation.entries, 33, "the path should include history and focus")

  vim.api.nvim_win_set_cursor(source_window, { 1, 0 })
  archlens.show_here()
  equal(active_session.model.navigation.back_count, 0, "ArchLensHere should reset back history")
  resolve_calls[#resolve_calls].callback(vim.deepcopy(alpha_semantic))

  local before_follow = #resolve_calls
  archlens.toggle_follow()
  vim.wait(20)
  equal(active_session.cursor_follow, true, "the follow toggle should activate cursor tracking")
  equal(rendered[#rendered].cursor_follow, true, "the model should expose active cursor tracking")
  assert(
    vim.tbl_contains(
      require("archlens.render").build(rendered[#rendered], { width = 56 }).lines,
      "Following source cursor"
    ),
    "the pane should identify cursor-follow mode"
  )
  equal(
    #resolve_calls,
    before_follow,
    "enabling follow on the current symbol should not reanalyze it"
  )

  vim.api.nvim_win_set_cursor(source_window, { 4, 1 })
  vim.api.nvim_exec_autocmds("CursorMoved", { buffer = source_buffer })
  vim.api.nvim_win_set_cursor(source_window, { 5, 2 })
  vim.api.nvim_exec_autocmds("CursorMoved", { buffer = source_buffer })
  vim.wait(30)
  equal(#resolve_calls, before_follow + 1, "rapid cursor movement should start one debounced run")
  equal(
    resolve_calls[#resolve_calls].position,
    { line = 4, character = 2 },
    "the debounced run should use the latest cursor position"
  )
  equal(active_session.current.name, "Beta", "Tree-sitter should update followed focus immediately")
  equal(
    active_session.model.navigation.back_count,
    0,
    "automatic focus changes must not add history"
  )

  vim.api.nvim_win_set_cursor(source_window, { 4, 2 })
  vim.api.nvim_exec_autocmds("CursorMoved", { buffer = source_buffer })
  vim.wait(20)
  equal(#resolve_calls, before_follow + 1, "movement within one symbol should not restart analysis")

  local stale_callback = resolve_calls[#resolve_calls].callback
  vim.api.nvim_buf_set_lines(source_buffer, 4, 5, false, { "  return 3" })
  vim.api.nvim_exec_autocmds("CursorMoved", { buffer = source_buffer })
  vim.wait(20)
  equal(#resolve_calls, before_follow + 2, "editing should permit same-symbol reanalysis")
  local renders_before_stale = #rendered
  stale_callback(vim.deepcopy(beta_semantic))
  equal(#rendered, renders_before_stale, "a stale follow resolver must not redraw the pane")
  resolve_calls[#resolve_calls].callback(vim.deepcopy(beta_semantic))

  local other_buffer = vim.api.nvim_create_buf(false, true)
  vim.cmd("vsplit")
  local other_window = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(other_window, other_buffer)
  vim.api.nvim_exec_autocmds("CursorMoved", { buffer = other_buffer })
  vim.wait(20)
  equal(#resolve_calls, before_follow + 2, "cursor events from another window should be ignored")
  vim.api.nvim_win_close(other_window, true)
  vim.api.nvim_set_current_win(source_window)

  vim.api.nvim_win_set_cursor(source_window, { 1, 0 })
  vim.api.nvim_exec_autocmds("CursorMoved", { buffer = source_buffer })
  archlens.focus({ context = beta_semantic, location = beta_semantic.location })
  vim.wait(20)
  equal(active_session.cursor_follow, false, "manual focus should return to pinned mode")
  equal(#resolve_calls, before_follow + 2, "manual focus should cancel a pending cursor update")
  assert(cancellations > 0, "new generations should cancel pending resolution work")

  archlens.toggle_follow()
  archlens.back()
  equal(active_session.cursor_follow, false, "back should return to pinned mode")

  archlens.toggle_follow()
  vim.cmd("vsplit")
  local replacement_window = vim.api.nvim_get_current_win()
  vim.api.nvim_win_close(source_window, true)
  vim.wait(20)
  equal(
    active_session.cursor_follow,
    false,
    "closing the tracked source window should stop following"
  )

  archlens.show_here()
  resolve_calls[#resolve_calls].callback(vim.deepcopy(alpha_semantic))
  archlens.toggle_follow()
  local before_close = #resolve_calls
  vim.api.nvim_win_set_cursor(replacement_window, { 5, 0 })
  vim.api.nvim_exec_autocmds("CursorMoved", { buffer = source_buffer })
  archlens.close()
  vim.wait(20)
  equal(#resolve_calls, before_close, "closing should cancel pending cursor work")
  equal(active_session.cursor_follow, false, "closing should disable cursor following")
end

local ok, err = xpcall(run, debug.traceback)
if not ok then
  vim.api.nvim_err_writeln(err)
  vim.cmd("cquit 1")
end

print("archlens.nvim navigation tests passed")
vim.cmd("quitall!")

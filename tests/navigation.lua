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
  local function package_context(name, id, buffer)
    local package_uri = vim.uri_from_bufnr(buffer)
    return {
      name = name,
      kind = vim.lsp.protocol.SymbolKind.Package,
      kind_name = "Lua package",
      root_dir = vim.fs.dirname(vim.api.nvim_buf_get_name(buffer)),
      path = vim.api.nvim_buf_get_name(buffer),
      path_label = name,
      line = 1,
      location = {
        uri = package_uri,
        range = {
          start = { line = 0, character = 0 },
          ["end"] = { line = 0, character = 0 },
        },
      },
      language = "lua",
      is_boundary = true,
      boundary_id = id,
      boundary_class = "language",
      boundary_level = "package",
      enclosing_boundaries = {},
    }
  end
  local packages_by_buffer = {
    [source_buffer] = package_context("package-a", "lua-package:a", source_buffer),
  }
  local resolve_calls = {}
  local cancellations = 0
  local provider_cancellations = 0
  local provider_contexts = {}
  local rendered = {}
  local active_session
  local sessions_by_tab = {}
  local provider_hooks
  local hold_provider = false
  local boundary_discovery_enabled = false
  local boundary_discovery_requests = {}

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
  local function boundary_for_buffer(buffer, level)
    equal(level, "package", "package follow should request its original boundary level")
    return vim.deepcopy(packages_by_buffer[buffer])
  end
  package.loaded["archlens.boundaries"] = {
    supports_discovery = function()
      return boundary_discovery_enabled
    end,
    discover = function(current, _, callback)
      local request = {
        context = vim.deepcopy(current),
        callback = callback,
        cancelled = false,
      }
      boundary_discovery_requests[#boundary_discovery_requests + 1] = request
      return function()
        request.cancelled = true
      end
    end,
    for_buffer = boundary_for_buffer,
    resolve_buffer = function(buffer, level, _, callback)
      callback(boundary_for_buffer(buffer, level))
      return function() end
    end,
  }
  package.loaded["archlens.providers"] = {
    clear_cache = function() end,
    local_pending = function()
      return {}
    end,
    run = function(current, _, _, hooks)
      provider_contexts[#provider_contexts + 1] = vim.deepcopy(current)
      provider_hooks = hooks
      local snapshot = graph.new(current)
      if hold_provider then
        graph.set_provider_runs(snapshot, {
          { id = "slow", label = "Slow provider", state = "running", elapsed_ms = 1 },
        })
        hooks.register_cancel(function()
          provider_cancellations = provider_cancellations + 1
        end)
      end
      hooks.on_update(snapshot)
    end,
  }
  package.loaded["archlens.view"] = {
    ensure = function(session)
      active_session = session
      sessions_by_tab[session.tabpage] = session
    end,
    render = function(session, value)
      active_session = session
      sessions_by_tab[session.tabpage] = session
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
  local primary_tab = vim.api.nvim_get_current_tabpage()
  archlens.show_here()
  equal(#resolve_calls, 1, "ArchLensHere should resolve the initial cursor")
  resolve_calls[1].callback(vim.deepcopy(alpha_semantic))
  equal(rendered[#rendered].cursor_follow, false, "cursor following should default to pinned")

  vim.api.nvim_win_set_cursor(source_window, { 2, 2 })
  vim.api.nvim_exec_autocmds("CursorMoved", { buffer = source_buffer })
  vim.wait(20)
  equal(#resolve_calls, 1, "pinned mode should ignore cursor events")

  boundary_discovery_enabled = true
  local providers_before_discovery = #provider_contexts
  archlens.show_here()
  resolve_calls[#resolve_calls].callback(vim.deepcopy(alpha_semantic))
  equal(#boundary_discovery_requests, 1, "symbol resolution should start boundary discovery")
  equal(
    #provider_contexts,
    providers_before_discovery + 1,
    "symbol analysis should remain available while boundaries are discovered"
  )
  local enriched_alpha = vim.deepcopy(alpha_semantic)
  enriched_alpha.enclosing_boundaries = { vim.deepcopy(packages_by_buffer[source_buffer]) }
  boundary_discovery_requests[1].callback(enriched_alpha)
  equal(
    active_session.current.enclosing_boundaries[1].boundary_id,
    packages_by_buffer[source_buffer].boundary_id,
    "completed boundary discovery should refresh the active symbol context"
  )
  equal(
    #provider_contexts,
    providers_before_discovery + 2,
    "discovered boundaries should restart analysis for the enriched context"
  )
  boundary_discovery_enabled = false

  hold_provider = true
  archlens.show_here()
  resolve_calls[#resolve_calls].callback(vim.deepcopy(alpha_semantic))
  equal(
    active_session.model.provider_runs[1].state,
    "running",
    "the pinned invalidation fixture should begin with active analysis"
  )
  vim.api.nvim_buf_set_lines(source_buffer, 1, 2, false, { "  return 10" })
  vim.api.nvim_exec_autocmds("TextChanged", { buffer = source_buffer })
  equal(active_session.invalidated, true, "source edits should invalidate pinned analysis")
  equal(
    active_session.model.provider_runs[1].state,
    "cancelled",
    "invalidated providers should not remain displayed as running"
  )
  assert(provider_cancellations > 0, "source edits should cancel active provider work")
  assert(
    table.concat(active_session.model.notes, "\n"):find("press r", 1, true),
    "pinned invalidation should explain how to resolve the source cursor again"
  )
  local resolves_before_invalidated_refresh = #resolve_calls
  hold_provider = false
  archlens.refresh()
  equal(
    #resolve_calls,
    resolves_before_invalidated_refresh + 1,
    "refreshing an invalidated pane should resolve the source cursor again"
  )
  resolve_calls[#resolve_calls].callback(vim.deepcopy(alpha_semantic))
  equal(active_session.invalidated, false, "a new resolution should clear source invalidation")

  hold_provider = true
  archlens.show_here()
  resolve_calls[#resolve_calls].callback(vim.deepcopy(alpha_semantic))
  local primary_session = sessions_by_tab[primary_tab]

  vim.cmd("tabnew")
  local secondary_tab = vim.api.nvim_get_current_tabpage()
  local secondary_window = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(secondary_window, source_buffer)
  archlens.show_here()
  resolve_calls[#resolve_calls].callback(vim.deepcopy(alpha_semantic))
  local secondary_session = sessions_by_tab[secondary_tab]
  equal(
    secondary_session.model.provider_runs[1].state,
    "running",
    "the secondary tab should track active analysis for the shared source buffer"
  )

  local cancellations_before_shared_edit = provider_cancellations
  vim.api.nvim_set_current_tabpage(primary_tab)
  vim.api.nvim_set_current_win(source_window)
  vim.api.nvim_buf_set_lines(source_buffer, 1, 2, false, { "  return 11" })
  vim.api.nvim_exec_autocmds("TextChangedP", { buffer = source_buffer })
  for label, session in pairs({ primary = primary_session, secondary = secondary_session }) do
    equal(session.invalidated, true, label .. " session should be invalidated by the shared edit")
    equal(
      session.model.provider_runs[1].state,
      "cancelled",
      label .. " session should not leave providers displayed as running"
    )
  end
  equal(
    provider_cancellations,
    cancellations_before_shared_edit + 2,
    "TextChangedP should cancel every active analysis tracking the changed buffer"
  )

  vim.api.nvim_set_current_tabpage(secondary_tab)
  archlens.close()
  vim.cmd("tabclose")
  vim.api.nvim_set_current_tabpage(primary_tab)
  vim.api.nvim_set_current_win(source_window)
  hold_provider = false
  archlens.refresh()
  resolve_calls[#resolve_calls].callback(vim.deepcopy(alpha_semantic))
  equal(primary_session.invalidated, false, "refresh should clear shared-buffer invalidation")

  hold_provider = true
  archlens.show_here()
  resolve_calls[#resolve_calls].callback(vim.deepcopy(alpha_semantic))
  local replacement_buffer = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(replacement_buffer, 0, -1, false, { "local replacement = true" })
  vim.api.nvim_win_set_buf(source_window, replacement_buffer)
  local completed_after_replacement = graph.new(alpha_semantic)
  graph.set_provider_runs(completed_after_replacement, {
    { id = "slow", label = "Slow provider", state = "completed", duration_ms = 2 },
  })
  provider_hooks.on_update(completed_after_replacement)
  equal(
    active_session.model.provider_runs[1].state,
    "completed",
    "pinned analysis should finish after the source window displays another buffer"
  )
  vim.api.nvim_win_set_buf(source_window, source_buffer)
  hold_provider = false
  archlens.show_here()
  resolve_calls[#resolve_calls].callback(vim.deepcopy(alpha_semantic))

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

  local package_a = packages_by_buffer[source_buffer]
  archlens.focus({ context = package_a, location = package_a.location })
  equal(active_session.current.boundary_id, package_a.boundary_id, "package focus should activate")
  local history_before_package_follow = active_session.model.navigation.back_count
  local resolves_before_package_follow = #resolve_calls
  local providers_before_package_follow = #provider_contexts
  archlens.toggle_follow()
  vim.wait(20)
  equal(active_session.follow_scope, "package", "following should preserve package focus")
  equal(
    active_session.model.navigation.back_count,
    history_before_package_follow,
    "enabling follow should preserve navigation history"
  )
  equal(
    #resolve_calls,
    resolves_before_package_follow,
    "package follow should not start symbol resolution"
  )
  equal(
    #provider_contexts,
    providers_before_package_follow,
    "enabling follow within the focused package should not restart analysis"
  )
  assert(
    vim.tbl_contains(
      require("archlens.render").build(rendered[#rendered], { width = 56 }).lines,
      "Following source package · gs symbol"
    ),
    "the pane should identify package-follow mode"
  )

  vim.api.nvim_win_set_cursor(source_window, { 4, 1 })
  vim.api.nvim_exec_autocmds("CursorMoved", { buffer = source_buffer })
  vim.wait(20)
  equal(
    #provider_contexts,
    providers_before_package_follow,
    "movement inside one package should not restart package analysis"
  )

  archlens.focus_source_symbol()
  equal(active_session.follow_scope, "symbol", "source-symbol focus should change follow scope")
  equal(active_session.cursor_follow, true, "source-symbol focus should keep active following")
  equal(#resolve_calls, resolves_before_package_follow + 1, "source-symbol focus should resolve")
  equal(active_session.current.name, "Beta", "source-symbol focus should update immediately")
  equal(
    active_session.model.navigation.back_count,
    history_before_package_follow + 1,
    "source-symbol focus should retain the boundary in history"
  )
  resolve_calls[#resolve_calls].callback(vim.deepcopy(beta_semantic))
  archlens.back()
  equal(active_session.cursor_follow, false, "back should pin the restored package")
  equal(
    active_session.current.boundary_id,
    package_a.boundary_id,
    "back should restore the package followed before source-symbol focus"
  )

  local resolves_before_pinned_symbol = #resolve_calls
  archlens.focus_source_symbol()
  equal(active_session.cursor_follow, false, "source-symbol focus should preserve pinned mode")
  equal(
    #resolve_calls,
    resolves_before_pinned_symbol + 1,
    "pinned source-symbol focus should resolve"
  )
  equal(active_session.current.name, "Beta", "pinned source-symbol focus should update immediately")
  resolve_calls[#resolve_calls].callback(vim.deepcopy(beta_semantic))
  archlens.back()
  equal(
    active_session.current.boundary_id,
    package_a.boundary_id,
    "back should restore the package after pinned source-symbol focus"
  )

  archlens.toggle_follow()
  vim.wait(20)
  equal(active_session.follow_scope, "package", "restored package should resume package following")
  local resolves_before_cross_package = #resolve_calls
  local providers_before_cross_package = #provider_contexts

  local package_b_buffer = vim.api.nvim_create_buf(false, true)
  local package_b_path = vim.fn.tempname() .. ".lua"
  vim.api.nvim_buf_set_name(package_b_buffer, package_b_path)
  vim.bo[package_b_buffer].filetype = "lua"
  vim.api.nvim_buf_set_lines(package_b_buffer, 0, -1, false, { "local package_b = true" })
  local package_b = package_context("package-b", "lua-package:b", package_b_buffer)
  packages_by_buffer[package_b_buffer] = package_b
  vim.api.nvim_win_set_buf(source_window, package_b_buffer)
  vim.api.nvim_exec_autocmds("BufEnter", { buffer = package_b_buffer })
  vim.wait(20)
  equal(
    #provider_contexts,
    providers_before_cross_package + 1,
    "crossing a package boundary should start one package analysis"
  )
  equal(
    active_session.current.boundary_id,
    package_b.boundary_id,
    "package follow should refresh navigation to the source package"
  )
  equal(
    #resolve_calls,
    resolves_before_cross_package,
    "cross-package follow should remain independent from symbol resolution"
  )
  vim.api.nvim_buf_set_lines(package_b_buffer, 0, -1, false, { "local package_b = false" })
  vim.api.nvim_exec_autocmds("TextChanged", { buffer = package_b_buffer })
  vim.wait(20)
  equal(
    #provider_contexts,
    providers_before_cross_package + 2,
    "editing the followed package should refresh its analysis"
  )
  archlens.toggle_follow()
  vim.api.nvim_win_set_buf(source_window, source_buffer)

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

  archlens.setup({ lsp = { resolve_timeout_ms = 5 } })
  vim.api.nvim_set_current_win(replacement_window)
  archlens.show_here()
  local cancellations_after_start = cancellations
  vim.wait(20)
  equal(
    cancellations,
    cancellations_after_start + 1,
    "a symbol-resolution timeout should cancel its LSP request"
  )
  archlens.close()

  local closed_source = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(closed_source, 0, -1, false, { "local closed_source = true" })
  vim.api.nvim_win_set_buf(replacement_window, closed_source)
  vim.api.nvim_set_current_win(replacement_window)
  hold_provider = true
  archlens.show_here()
  resolve_calls[#resolve_calls].callback(vim.deepcopy(alpha_semantic))
  vim.api.nvim_buf_delete(closed_source, { force = true })
  equal(active_session.invalidated, true, "closing the source buffer should invalidate analysis")
  equal(
    active_session.model.provider_runs[1].state,
    "cancelled",
    "closing the source buffer should not leave providers displayed as running"
  )
  archlens.close()
end

local ok, err = xpcall(run, debug.traceback)
if not ok then
  vim.api.nvim_err_writeln(err)
  vim.cmd("cquit 1")
end

print("archlens.nvim navigation tests passed")
vim.cmd("quitall!")

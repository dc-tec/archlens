local config_module = require("archlens.config")
local boundaries = require("archlens.boundaries")
local graph = require("archlens.graph")
local lsp = require("archlens.lsp")
local model = require("archlens.model")
local navigation = require("archlens.navigation")
local performance = require("archlens.performance")
local providers = require("archlens.providers")
local treesitter = require("archlens.treesitter")
local view = require("archlens.view")

local M = {}

local config = config_module.new()

---@class ArchLensSession
---@field tabpage integer
---@field generation integer
---@field history table[]
---@field history_omitted integer
---@field cancellations function[]
---@field expanded table<string, boolean>
---@field expanded_groups table<string, boolean>
---@field group_limits table<string, integer>
---@field collapsed table<string, boolean>
---@field active boolean
---@field window? integer
---@field buffer? integer
---@field source_window? integer
---@field source_buffer? integer
---@field origin_window? integer
---@field origin_buffer? integer
---@field origin_view? table
---@field run_source_buffer? integer
---@field run_changedtick? integer
---@field current? table
---@field snapshot? ArchLensGraphDelta
---@field model? table
---@field rendered? table
---@field options? table
---@field detail? table
---@field did_jump? boolean
---@field restore_row_id? string
---@field performance? ArchLensPerformanceRun
---@field cursor_follow boolean
---@field follow_timer? any
---@field follow_token integer
---@field follow_identity? string
---@field follow_scope? string
---@field follow_dirty? boolean
---@field invalidated? boolean

---@type table<integer, ArchLensSession>
local sessions = {}
local lifecycle_initialized = false

local function valid_window(winid)
  return winid and vim.api.nvim_win_is_valid(winid)
end

local function valid_buffer(bufnr)
  return bufnr and vim.api.nvim_buf_is_valid(bufnr)
end

---@param tabpage? integer
---@return ArchLensSession
local function session_for(tabpage)
  tabpage = tabpage or vim.api.nvim_get_current_tabpage()
  local session = sessions[tabpage]
  if session then
    return session
  end

  session = {
    tabpage = tabpage,
    generation = 0,
    history = {},
    history_omitted = 0,
    cancellations = {},
    expanded = {},
    expanded_groups = {},
    group_limits = {},
    collapsed = {},
    active = false,
    cursor_follow = false,
    follow_token = 0,
  }
  sessions[tabpage] = session
  return session
end

local function cancel_follow_timer(session)
  session.follow_token = (session.follow_token or 0) + 1
  local timer = session.follow_timer
  session.follow_timer = nil
  if timer and not timer:is_closing() then
    timer:stop()
    timer:close()
  end
end

local function cancel_requests(session)
  for _, cancel in ipairs(session.cancellations or {}) do
    pcall(cancel)
  end
  session.cancellations = {}
end

local function reset_view_state(session)
  session.expanded = {}
  session.expanded_groups = {}
  session.group_limits = {}
  session.collapsed = {}
  for _, section_id in ipairs(config.sections.default_collapsed or {}) do
    session.collapsed[section_id] = true
  end
end

local function begin_run(session, preserve_view_state)
  session.generation = session.generation + 1
  cancel_requests(session)
  if not preserve_view_state then
    reset_view_state(session)
  end
  session.run_source_buffer = session.source_buffer
  session.run_changedtick = valid_buffer(session.source_buffer)
      and vim.api.nvim_buf_get_changedtick(session.source_buffer)
    or nil
  session.snapshot = nil
  session.invalidated = false
  session.performance = performance.start()
  return session.generation
end

local function is_current(session, generation)
  if
    not session.active
    or session.generation ~= generation
    or not vim.api.nvim_tabpage_is_valid(session.tabpage)
    or not valid_buffer(session.run_source_buffer)
  then
    return false
  end

  if
    session.run_changedtick
    and vim.api.nvim_buf_get_changedtick(session.run_source_buffer) ~= session.run_changedtick
  then
    return false
  end

  return true
end

local function register_cancel(session, cancel)
  if type(cancel) == "function" then
    session.cancellations[#session.cancellations + 1] = cancel
  end
end

local function actions_for(session)
  return {
    open = function(row)
      M.open(row, session.tabpage)
    end,
    focus = function(row, navigation_metadata)
      M.focus(row, session.tabpage, navigation_metadata)
    end,
    back = function()
      M.back(session.tabpage)
    end,
    refresh = function()
      M.refresh(session.tabpage)
    end,
    close = function()
      M.close(session.tabpage)
    end,
    dismiss = function()
      M.dismiss(session.tabpage)
    end,
    toggle_follow = function()
      M.toggle_follow(session.tabpage)
    end,
  }
end

local function ensure_view(session)
  view.ensure(session, config, actions_for(session))
end

local function render(session, rendered_model)
  if not session.active then
    return
  end
  performance.observe(session.performance, rendered_model)
  rendered_model.performance = performance.snapshot(session.performance)
  rendered_model.cursor_follow = session.cursor_follow == true
  rendered_model.cursor_follow_scope = session.cursor_follow and session.follow_scope or nil
  rendered_model.navigation = navigation.snapshot(session, rendered_model.focus)
  ensure_view(session)
  view.render(session, rendered_model, config)
end

local function render_local_context(session, context)
  session.current = context
  local snapshot = graph.new(context)
  graph.set_pending(snapshot, providers.local_pending(config))
  session.snapshot = snapshot
  render(session, model.build(context, snapshot, config))
end

local function load_context(session, context, generation)
  if not is_current(session, generation) then
    return
  end

  session.current = context

  providers.run(context, session.source_buffer, config, {
    is_current = function()
      return is_current(session, generation)
    end,
    register_cancel = function(cancel)
      register_cancel(session, cancel)
    end,
    on_update = function(relationships)
      session.snapshot = relationships
      render(session, model.build(context, relationships, config))
    end,
  })
end

local function capture_source(session)
  local window = vim.api.nvim_get_current_win()
  if view.is_map_window(session, window) then
    if not valid_window(session.source_window) then
      return false
    end
    session.source_buffer = vim.api.nvim_win_get_buf(session.source_window)
    return true
  end

  session.source_window = window
  session.source_buffer = vim.api.nvim_win_get_buf(window)
  session.origin_window = window
  session.origin_buffer = session.source_buffer
  session.origin_view = vim.fn.winsaveview()
  session.did_jump = false
  return true
end

local function resolve_at(session, buffer, position, opts)
  opts = opts or {}
  session.source_buffer = buffer
  local generation = begin_run(session)
  local syntax_context = opts.syntax_context or treesitter.resolve(buffer, position, nil)
  if syntax_context then
    render_local_context(session, syntax_context)
  else
    render(session, model.error(opts.loading_message or "Resolving the symbol…"))
  end
  local resolved = false

  local function finish(context, err)
    if resolved or not is_current(session, generation) then
      return
    end
    resolved = true
    context = treesitter.resolve(buffer, position, context) or syntax_context
    if not context then
      if opts.on_failure then
        opts.on_failure()
      end
      render(session, model.error(err or opts.failure_message or "No symbol could be resolved."))
      return
    end
    load_context(session, context, generation)
  end

  local cancel_resolve = function() end
  local resolve_settled = false
  local resolve_cancelled = false
  local timer
  local function stop_timer()
    if timer and not timer:is_closing() then
      timer:stop()
      timer:close()
    end
    timer = nil
  end

  local function cancel_resolution()
    if resolve_settled or resolve_cancelled then
      return
    end
    resolve_cancelled = true
    pcall(cancel_resolve)
  end

  local cancel = lsp.resolve(buffer, position, function(context, err)
    resolve_settled = true
    stop_timer()
    finish(context, err)
  end)
  cancel_resolve = type(cancel) == "function" and cancel or cancel_resolve
  if not resolved then
    timer = vim.defer_fn(function()
      cancel_resolution()
      resolve_settled = true
      finish(syntax_context, syntax_context and nil or opts.timeout_message)
    end, config.lsp.resolve_timeout_ms)
  end
  register_cancel(session, function()
    stop_timer()
    cancel_resolution()
  end)
  return syntax_context
end

local invalidated_provider_states = {
  queued = true,
  retrying = true,
  running = true,
}

local function invalidate_analysis(session, message)
  if not session.active or session.invalidated then
    return false
  end

  session.generation = session.generation + 1
  cancel_requests(session)
  session.invalidated = true

  if not session.current or not session.snapshot then
    render(session, model.error(message))
    return true
  end

  local snapshot = vim.deepcopy(session.snapshot)
  local runs = vim.deepcopy(snapshot.provider_runs or {})
  for _, run in ipairs(runs) do
    if invalidated_provider_states[run.state] then
      run.state = "cancelled"
      run.duration_ms = run.elapsed_ms
      run.elapsed_ms = nil
      run.retry_delay_ms = nil
      run.message = message
    end
  end
  graph.set_provider_runs(snapshot, runs)
  graph.add_note(snapshot, message, { summary = "source changed", severity = "warn" })
  session.snapshot = snapshot
  render(session, model.build(session.current, snapshot, config))
  return true
end

function M.show_here(tabpage)
  local session = session_for(tabpage)
  if not capture_source(session) then
    vim.notify("ArchLens could not find a source window.", vim.log.levels.WARN)
    return
  end

  navigation.reset(session)
  cancel_follow_timer(session)
  session.cursor_follow = config.cursor_follow.enabled == true
  session.follow_identity = nil
  session.follow_scope = session.cursor_follow and "symbol" or nil
  session.follow_dirty = false
  session.active = true

  local cursor = vim.api.nvim_win_get_cursor(session.source_window)
  local position = { line = cursor[1] - 1, character = cursor[2] }
  local syntax_context = resolve_at(session, session.source_buffer, position, {
    loading_message = "Resolving the symbol under the cursor…",
    failure_message = "No symbol could be resolved at the cursor.",
    timeout_message = "Symbol resolution timed out.",
  })
  if session.cursor_follow and syntax_context then
    session.follow_identity = navigation.context_identity(
      syntax_context,
      vim.api.nvim_buf_get_changedtick(session.source_buffer)
    )
  end
end

local function same_context(left, right)
  if (left and left.is_boundary) or (right and right.is_boundary) then
    return left
      and right
      and left.is_boundary == true
      and right.is_boundary == true
      and left.boundary_id == right.boundary_id
  end
  if not left or not right or left.client_id ~= right.client_id then
    return false
  end
  local left_location = left.location or {}
  local right_location = right.location or {}
  local left_start = left_location.range and left_location.range.start or {}
  local right_start = right_location.range and right_location.range.start or {}
  return left_location.uri == right_location.uri
    and left_start.line == right_start.line
    and left_start.character == right_start.character
end

local function buffer_for_uri(uri)
  local buffer = vim.uri_to_bufnr(uri)
  vim.fn.bufload(buffer)
  if not valid_buffer(buffer) then
    return nil
  end
  if vim.bo[buffer].filetype == "" and vim.filetype and vim.filetype.match then
    local ok, filetype = pcall(vim.filetype.match, { buf = buffer })
    if ok and filetype and filetype ~= "" then
      vim.bo[buffer].filetype = filetype
    end
  end
  return buffer
end

local function repair_source_buffer(session, context)
  if not context or not context.location or not context.location.uri then
    return valid_buffer(session.source_buffer)
  end
  local buffer = buffer_for_uri(context.location.uri)
  if not buffer then
    return false
  end
  session.source_buffer = buffer
  return true
end

local function focus_location(session, row, navigation_metadata)
  if not row.location or not row.location.uri or not row.location.range then
    return
  end
  local buffer = buffer_for_uri(row.location.uri)
  if not buffer then
    return
  end
  local entry = navigation.push(session, navigation_metadata, view.selected_row_id(session))
  session.restore_row_id = nil
  local position = row.location.range.start
  resolve_at(session, buffer, position, {
    loading_message = "Resolving the focused relationship…",
    failure_message = "No symbol could be resolved at this relationship.",
    timeout_message = "Focused symbol resolution timed out.",
    on_failure = function()
      navigation.rollback(session, entry)
    end,
  })
end

local function disable_cursor_follow(session)
  cancel_follow_timer(session)
  session.cursor_follow = false
  session.follow_identity = nil
  session.follow_scope = nil
  session.follow_dirty = false
end

local function follow_boundary(session, buffer, scope)
  session.source_buffer = buffer
  local context = boundaries.for_buffer(buffer, scope)
  local identity = context and context.boundary_id
    or table.concat({ "missing", scope, vim.uri_from_bufnr(buffer) }, "\0")
  local force = session.follow_dirty == true
  session.follow_dirty = false
  if identity == session.follow_identity and not force then
    return
  end
  if
    session.follow_identity == nil
    and not force
    and context
    and same_context(context, session.current)
  then
    session.follow_identity = identity
    return
  end

  session.follow_identity = identity
  local generation = begin_run(session)
  if not context then
    render(
      session,
      model.error(string.format("No %s boundary could be resolved at the source cursor.", scope))
    )
    return
  end
  load_context(session, context, generation)
end

local function follow_source_cursor(session, allow_background)
  if
    not session.active
    or not session.cursor_follow
    or not vim.api.nvim_tabpage_is_valid(session.tabpage)
    or vim.api.nvim_get_current_tabpage() ~= session.tabpage
    or not valid_window(session.source_window)
    or (not allow_background and vim.api.nvim_get_current_win() ~= session.source_window)
  then
    return
  end

  local buffer = vim.api.nvim_win_get_buf(session.source_window)
  if not valid_buffer(buffer) then
    return
  end
  if session.follow_scope and session.follow_scope ~= "symbol" then
    follow_boundary(session, buffer, session.follow_scope)
    return
  end

  local cursor = vim.api.nvim_win_get_cursor(session.source_window)
  local position = { line = cursor[1] - 1, character = cursor[2] }
  local changedtick = vim.api.nvim_buf_get_changedtick(buffer)
  local syntax_context = treesitter.resolve(buffer, position, nil)
  local identity = navigation.context_identity(syntax_context, changedtick)
    or table.concat(
      { vim.uri_from_bufnr(buffer), position.line, position.character, changedtick },
      "\0"
    )
  local force = session.follow_dirty == true
  session.follow_dirty = false
  if identity == session.follow_identity and not force then
    return
  end
  if
    session.follow_identity == nil
    and not force
    and syntax_context
    and navigation.same_symbol(syntax_context, session.current)
  then
    session.follow_identity = identity
    return
  end

  session.follow_identity = identity
  resolve_at(session, buffer, position, {
    syntax_context = syntax_context,
    loading_message = "Resolving the source cursor…",
    failure_message = "No symbol could be resolved at the source cursor.",
    timeout_message = "Source cursor resolution timed out.",
  })
end

local function schedule_cursor_follow(session, delay, allow_background)
  cancel_follow_timer(session)
  if not session.active or not session.cursor_follow then
    return
  end
  local token = session.follow_token
  local timer
  timer = vim.defer_fn(function()
    if session.follow_token ~= token then
      return
    end
    session.follow_timer = nil
    follow_source_cursor(session, allow_background)
  end, delay == nil and config.cursor_follow.debounce_ms or delay)
  session.follow_timer = timer
end

function M.toggle_follow(tabpage)
  local session = session_for(tabpage)
  if not session.active then
    return
  end
  if session.cursor_follow then
    disable_cursor_follow(session)
  else
    cancel_follow_timer(session)
    session.cursor_follow = true
    session.follow_identity = nil
    session.follow_scope = session.current
        and session.current.is_boundary
        and session.current.boundary_level
      or "symbol"
    session.follow_dirty = false
    navigation.reset(session)
  end
  if session.model then
    render(session, session.model)
  end
  if session.cursor_follow then
    schedule_cursor_follow(session, 0, true)
  end
end

function M.focus(target, tabpage, navigation_metadata)
  local session = session_for(tabpage)
  local was_following = session.cursor_follow
  disable_cursor_follow(session)
  if target and target.resolve_on_focus then
    if session.active and session.current then
      focus_location(session, target, navigation_metadata)
    elseif was_following and session.model then
      render(session, session.model)
    end
    return
  end
  local context = target and (target.context or target)
  if
    not session.active
    or not context
    or not session.current
    or same_context(context, session.current)
  then
    if was_following and session.active and session.model then
      render(session, session.model)
    end
    return
  end
  if not repair_source_buffer(session, context) then
    if was_following and session.model then
      render(session, session.model)
    end
    return
  end
  context = treesitter.resolve(session.source_buffer, context.location.range.start, context)
    or context
  navigation.push(session, navigation_metadata, view.selected_row_id(session))
  session.restore_row_id = nil
  local generation = begin_run(session)
  load_context(session, context, generation)
end

function M.back(tabpage)
  local session = session_for(tabpage)
  local was_following = session.cursor_follow
  disable_cursor_follow(session)
  if not session.active then
    return
  end
  local entry = table.remove(session.history)
  if not entry then
    if was_following and session.model then
      render(session, session.model)
    end
    return
  end
  if not repair_source_buffer(session, entry.context) then
    session.history[#session.history + 1] = entry
    if was_following and session.model then
      render(session, session.model)
    end
    return
  end
  session.restore_row_id = entry.selected_row_id
  local generation = begin_run(session)
  session.expanded = entry.expanded or {}
  session.expanded_groups = entry.expanded_groups or {}
  session.group_limits = entry.group_limits or {}
  session.collapsed = entry.collapsed or {}
  load_context(session, entry.context, generation)
end

function M.refresh(tabpage)
  local session = session_for(tabpage)
  if not session.active or not session.current then
    M.show_here(tabpage)
    return
  end
  if session.invalidated then
    M.show_here(tabpage)
    return
  end
  if not repair_source_buffer(session, session.current) then
    render(session, model.error("ArchLens could not recover its source buffer."))
    return
  end
  session.restore_row_id = view.selected_row_id(session)
  local generation = begin_run(session, true)
  providers.clear_cache(session.current.root_dir)
  load_context(session, session.current, generation)
end

local function source_window(session)
  if valid_window(session.source_window) then
    return session.source_window
  end
  for _, window in ipairs(vim.api.nvim_tabpage_list_wins(session.tabpage)) do
    if not view.is_map_window(session, window) then
      session.source_window = window
      return window
    end
  end
  if
    not vim.api.nvim_tabpage_is_valid(session.tabpage)
    or vim.api.nvim_get_current_tabpage() ~= session.tabpage
    or not valid_window(session.window)
  then
    return nil
  end
  vim.api.nvim_set_current_win(session.window)
  vim.cmd("leftabove vsplit")
  session.source_window = vim.api.nvim_get_current_win()
  return session.source_window
end

function M.open(row, tabpage)
  local session = session_for(tabpage)
  if not row or not row.location or not row.location.uri or not row.location.range then
    return
  end

  local window = source_window(session)
  if not window then
    vim.notify("ArchLens could not find a window for the source location.", vim.log.levels.WARN)
    return
  end

  vim.api.nvim_set_current_win(window)
  local opened = vim.lsp.util.show_document(
    { uri = row.location.uri, range = row.location.range },
    row.position_encoding or (row.context and row.context.position_encoding) or "utf-8",
    { focus = true, reuse_win = true }
  )
  if opened then
    session.did_jump = true
    session.source_window = vim.api.nvim_get_current_win()
    session.source_buffer = vim.api.nvim_get_current_buf()
  end
end

local function restore_origin(session)
  if
    session.did_jump
    or not valid_window(session.origin_window)
    or not valid_buffer(session.origin_buffer)
    or vim.api.nvim_win_get_buf(session.origin_window) ~= session.origin_buffer
    or not session.origin_view
  then
    return
  end
  vim.api.nvim_win_call(session.origin_window, function()
    vim.fn.winrestview(session.origin_view)
  end)
end

local function deactivate(session)
  if not session.active then
    return false
  end
  session.active = false
  session.generation = session.generation + 1
  disable_cursor_follow(session)
  cancel_requests(session)
  return true
end

function M.dismiss(tabpage)
  local session = session_for(tabpage)
  if deactivate(session) then
    restore_origin(session)
  end
end

function M.close(tabpage)
  local session = session_for(tabpage)
  deactivate(session)
  view.close(session)
  restore_origin(session)
  if valid_window(session.source_window) then
    vim.api.nvim_set_current_win(session.source_window)
  end
end

function M.setup(options)
  config = config_module.merge(config, options)
  if lifecycle_initialized then
    return
  end
  lifecycle_initialized = true
  local group = vim.api.nvim_create_augroup("archlens_lifecycle", { clear = true })
  vim.api.nvim_create_autocmd("TabClosed", {
    group = group,
    callback = function()
      for tabpage, session in pairs(sessions) do
        if not vim.api.nvim_tabpage_is_valid(tabpage) then
          cancel_follow_timer(session)
          cancel_requests(session)
          sessions[tabpage] = nil
        end
      end
    end,
  })
  vim.api.nvim_create_autocmd("LspAttach", {
    group = group,
    callback = function(event)
      if event.data and event.data.client_id then
        lsp.note_attach(event.data.client_id)
      end
    end,
  })
  vim.api.nvim_create_autocmd({ "CursorMoved", "BufEnter" }, {
    group = group,
    callback = function(event)
      local tabpage = vim.api.nvim_get_current_tabpage()
      local session = sessions[tabpage]
      if
        session
        and session.active
        and session.cursor_follow
        and valid_window(session.source_window)
        and vim.api.nvim_get_current_win() == session.source_window
        and event.buf == vim.api.nvim_win_get_buf(session.source_window)
      then
        schedule_cursor_follow(session)
      end
    end,
  })
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "TextChangedP" }, {
    group = group,
    callback = function(event)
      if not valid_buffer(event.buf) then
        return
      end
      local changedtick = vim.api.nvim_buf_get_changedtick(event.buf)
      for _, session in pairs(sessions) do
        local run_source_changed = event.buf == session.run_source_buffer
          and session.run_changedtick
          and changedtick ~= session.run_changedtick
        local followed_source_changed = session.cursor_follow and event.buf == session.source_buffer
        if session.active and (run_source_changed or followed_source_changed) then
          local following = session.cursor_follow
          session.follow_dirty = following
          invalidate_analysis(
            session,
            following and "Source changed; ArchLens is resolving the source cursor again."
              or "Source changed; press r to resolve the symbol at the source cursor again."
          )
          if following then
            schedule_cursor_follow(session)
          end
        end
      end
    end,
  })
  vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
    group = group,
    callback = function(event)
      for _, session in pairs(sessions) do
        if session.active and event.buf == session.run_source_buffer then
          invalidate_analysis(
            session,
            "Source buffer closed; press r to resolve the symbol in the tracked source window."
          )
        end
      end
    end,
  })
  vim.api.nvim_create_autocmd("WinClosed", {
    group = group,
    callback = function(event)
      local closed = tonumber(event.match)
      for _, session in pairs(sessions) do
        if session.source_window == closed then
          local was_following = session.cursor_follow
          disable_cursor_follow(session)
          if was_following and session.active and session.model then
            vim.schedule(function()
              if session.active and session.model then
                render(session, session.model)
              end
            end)
          end
        end
      end
    end,
  })
end

function M.get_config()
  return vim.deepcopy(config)
end

return M

local ast_grep = require("archlens.ast_grep")
local lsp = require("archlens.lsp")
local model = require("archlens.model")
local treesitter = require("archlens.treesitter")
local view = require("archlens.view")

local M = {}

local config = {
  width = 56,
  max_items = 8,
  include_external = false,
  lsp = {
    resolve_timeout_ms = 5000,
    relationship_timeout_ms = 8000,
  },
  ast_grep = {
    enabled = true,
    command = "ast-grep",
    timeout_ms = 15000,
    max_results = 80,
    min_name_length = 5,
    threads = 1,
    globs = vim.deepcopy(ast_grep.default_globs),
  },
}

local sessions = {}
local lifecycle_initialized = false

local function valid_window(winid)
  return winid and vim.api.nvim_win_is_valid(winid)
end

local function valid_buffer(bufnr)
  return bufnr and vim.api.nvim_buf_is_valid(bufnr)
end

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
    cancellations = {},
    expanded = {},
    collapsed = {},
    active = false,
  }
  sessions[tabpage] = session
  return session
end

local function cancel_requests(session)
  for _, cancel in ipairs(session.cancellations or {}) do
    pcall(cancel)
  end
  session.cancellations = {}
end

local function begin_run(session, require_source_window)
  cancel_requests(session)
  session.generation = session.generation + 1
  session.expanded = {}
  session.collapsed = {}
  session.run_source_buffer = session.source_buffer
  session.run_source_window = require_source_window and session.source_window or nil
  session.run_changedtick = valid_buffer(session.source_buffer)
      and vim.api.nvim_buf_get_changedtick(session.source_buffer)
    or nil
  session.require_source_window = require_source_window == true
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

  if valid_window(session.run_source_window) then
    return vim.api.nvim_win_get_buf(session.run_source_window) == session.run_source_buffer
  end
  return not session.require_source_window
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
    focus = function(row)
      M.focus(row, session.tabpage)
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
  }
end

local function ensure_view(session)
  view.ensure(session, config, actions_for(session))
end

local function render(session, rendered_model)
  if not session.active then
    return
  end
  ensure_view(session)
  view.render(session, rendered_model, config)
end

local function render_local_context(session, context)
  local pending_providers = { "LSP" }
  if config.ast_grep.enabled then
    pending_providers[#pending_providers + 1] = "ast-grep"
  end
  render(
    session,
    model.build(context, {
      pending_providers = pending_providers,
    }, config)
  )
end

local function load_context(session, context, generation)
  if not is_current(session, generation) then
    return
  end

  session.current = context

  local relationships = {
    incoming = {},
    outgoing = {},
    references = {},
    structural = {},
    errors = {},
    notes = {},
    structural_omitted = 0,
    ast_grep_ran = false,
  }
  local tasks = {}

  local function merge(result)
    result = result or {}
    for _, key in ipairs({ "incoming", "outgoing", "references", "structural", "errors", "notes" }) do
      vim.list_extend(relationships[key], result[key] or {})
    end
    relationships.structural_omitted = relationships.structural_omitted
      + (result.structural_omitted or 0)
    relationships.ast_grep_ran = relationships.ast_grep_ran or result.ast_grep_ran == true
  end

  if context.client_id then
    tasks[#tasks + 1] = {
      id = "lsp",
      label = context.client_name or "LSP",
      start = function(done)
        return lsp.relationships(context, session.source_buffer, done, {
          timeout_ms = config.lsp.relationship_timeout_ms,
        })
      end,
    }
  end
  if config.ast_grep.enabled then
    tasks[#tasks + 1] = {
      id = "ast_grep",
      label = "ast-grep",
      start = function(done)
        return ast_grep.relationships(context, config.ast_grep, done)
      end,
    }
  end

  local pending = {}
  for _, task in ipairs(tasks) do
    pending[task.id] = true
  end

  local function render_progress()
    if not is_current(session, generation) then
      return
    end
    local pending_providers = {}
    for _, task in ipairs(tasks) do
      if pending[task.id] then
        pending_providers[#pending_providers + 1] = task.label
      end
    end
    relationships.pending_providers = pending_providers
    render(session, model.build(context, relationships, config))
  end

  -- Tree-sitter context is already available, so show it before starting any
  -- project-wide work. Later provider results enrich this same bounded view.
  render_progress()

  for _, task in ipairs(tasks) do
    local completed = false
    local function done(result)
      if completed or not is_current(session, generation) then
        return
      end
      completed = true
      merge(result)
      pending[task.id] = nil
      render_progress()
    end

    local ok, cancel_or_error = pcall(task.start, done)
    if ok then
      register_cancel(session, cancel_or_error)
    elseif not completed and is_current(session, generation) then
      completed = true
      pending[task.id] = nil
      relationships.errors[#relationships.errors + 1] =
        string.format("%s failed to start: %s", task.label, tostring(cancel_or_error))
      render_progress()
    end
  end
end

local function capture_source(session)
  local window = vim.api.nvim_get_current_win()
  if view.is_map_window(session, window) then
    return valid_window(session.source_window)
  end

  session.source_window = window
  session.source_buffer = vim.api.nvim_win_get_buf(window)
  session.origin_window = window
  session.origin_buffer = session.source_buffer
  session.origin_view = vim.fn.winsaveview()
  session.did_jump = false
  return true
end

function M.show_here(tabpage)
  local session = session_for(tabpage)
  if not capture_source(session) then
    vim.notify("ArchLens could not find a source window.", vim.log.levels.WARN)
    return
  end

  session.history = {}
  session.restore_row_id = nil
  session.active = true
  local generation = begin_run(session, true)

  local cursor = vim.api.nvim_win_get_cursor(session.source_window)
  local position = { line = cursor[1] - 1, character = cursor[2] }
  local syntax_context = treesitter.resolve(session.source_buffer, position, nil)
  if syntax_context then
    render_local_context(session, syntax_context)
  else
    render(session, model.error("Resolving the symbol under the cursor…"))
  end
  local resolved = false

  local function finish(context, err)
    if resolved or not is_current(session, generation) then
      return
    end
    resolved = true
    context = treesitter.resolve(session.source_buffer, position, context) or syntax_context
    if not context then
      render(session, model.error(err or "No symbol could be resolved at the cursor."))
      return
    end
    load_context(session, context, generation)
  end

  local cancel = lsp.resolve(session.source_buffer, session.source_window, function(context, err)
    finish(context, err)
  end)
  register_cancel(session, cancel)
  local timer = vim.defer_fn(function()
    finish(syntax_context, syntax_context and nil or "Symbol resolution timed out.")
  end, config.lsp.resolve_timeout_ms)
  register_cancel(session, function()
    if timer and not timer:is_closing() then
      timer:stop()
      timer:close()
    end
  end)
end

local function same_context(left, right)
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

local function repair_source_buffer(session, context)
  if not context or not context.location or not context.location.uri then
    return valid_buffer(session.source_buffer)
  end
  local buffer = vim.uri_to_bufnr(context.location.uri)
  vim.fn.bufload(buffer)
  if not valid_buffer(buffer) then
    return false
  end
  session.source_buffer = buffer
  if
    valid_window(session.source_window)
    and vim.api.nvim_win_get_buf(session.source_window) ~= buffer
  then
    session.source_window = nil
  end
  return true
end

local function focus_location(session, row)
  if not row.location or not row.location.uri or not row.location.range then
    return
  end
  session.history[#session.history + 1] = {
    context = session.current,
    selected_row_id = view.selected_row_id(session),
  }
  session.restore_row_id = nil

  local buffer = vim.uri_to_bufnr(row.location.uri)
  vim.fn.bufload(buffer)
  if not valid_buffer(buffer) then
    table.remove(session.history)
    return
  end
  session.source_buffer = buffer
  session.source_window = nil
  local generation = begin_run(session, false)
  local position = row.location.range.start
  local syntax_context = treesitter.resolve(buffer, position, nil)
  local resolved = false

  local function finish(context, err)
    if resolved or not is_current(session, generation) then
      return
    end
    resolved = true
    if syntax_context then
      if context then
        syntax_context.client_id = context.client_id
        syntax_context.client_name = context.client_name
        syntax_context.position_encoding = context.position_encoding
        syntax_context.root_dir = context.root_dir or syntax_context.root_dir
      end
      context = syntax_context
    end
    if not context then
      render(session, model.error(err or "No symbol could be resolved at this relationship."))
      return
    end
    load_context(session, context, generation)
  end

  if syntax_context then
    render_local_context(session, syntax_context)
  else
    render(session, model.error("Resolving the focused relationship…"))
  end
  local cancel = lsp.resolve(buffer, position, finish)
  register_cancel(session, cancel)
  local timer = vim.defer_fn(function()
    finish(syntax_context, syntax_context and nil or "Focused symbol resolution timed out.")
  end, config.lsp.resolve_timeout_ms)
  register_cancel(session, function()
    if timer and not timer:is_closing() then
      timer:stop()
      timer:close()
    end
  end)
end

function M.focus(target, tabpage)
  local session = session_for(tabpage)
  if target and target.resolve_on_focus then
    if session.active and session.current then
      focus_location(session, target)
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
    return
  end
  if not repair_source_buffer(session, context) then
    return
  end
  context = treesitter.resolve(session.source_buffer, context.location.range.start, context)
    or context
  session.history[#session.history + 1] = {
    context = session.current,
    selected_row_id = view.selected_row_id(session),
  }
  session.restore_row_id = nil
  local generation = begin_run(session, false)
  load_context(session, context, generation)
end

function M.back(tabpage)
  local session = session_for(tabpage)
  local entry = table.remove(session.history)
  if not session.active or not entry or not repair_source_buffer(session, entry.context) then
    return
  end
  session.restore_row_id = entry.selected_row_id
  local generation = begin_run(session, false)
  load_context(session, entry.context, generation)
end

function M.refresh(tabpage)
  local session = session_for(tabpage)
  if not session.active or not session.current then
    M.show_here(tabpage)
    return
  end
  if not repair_source_buffer(session, session.current) then
    render(session, model.error("ArchLens could not recover its source buffer."))
    return
  end
  session.restore_row_id = view.selected_row_id(session)
  local generation = begin_run(session, false)
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
    (row.context and row.context.position_encoding) or "utf-16",
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
  config = vim.tbl_deep_extend("force", config, options or {})
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
          cancel_requests(session)
          sessions[tabpage] = nil
        end
      end
    end,
  })
end

function M.get_config()
  return vim.deepcopy(config)
end

return M

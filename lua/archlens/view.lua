local renderer = require("archlens.render")

local M = {}
local namespace = vim.api.nvim_create_namespace("archlens")

local function valid_window(winid)
  return winid and vim.api.nvim_win_is_valid(winid)
end

local function valid_buffer(bufnr)
  return bufnr and vim.api.nvim_buf_is_valid(bufnr)
end

local function target_at_cursor(session)
  if not valid_window(session.window) or not session.rendered then
    return nil
  end
  local line = vim.api.nvim_win_get_cursor(session.window)[1]
  return session.rendered.targets[line]
end

local function selected_row_id(session)
  local target = target_at_cursor(session)
  return target and target.row and target.row.id or nil
end

local function move_to_target(session, direction, predicate)
  if not valid_window(session.window) or not session.rendered then
    return
  end

  local lines = {}
  for line, target in pairs(session.rendered.targets) do
    if not predicate or predicate(target) then
      lines[#lines + 1] = line
    end
  end
  table.sort(lines)
  if #lines == 0 then
    return
  end

  local current = vim.api.nvim_win_get_cursor(session.window)[1]
  if direction > 0 then
    for _, line in ipairs(lines) do
      if line > current then
        vim.api.nvim_win_set_cursor(session.window, { line, 0 })
        return
      end
    end
    vim.api.nvim_win_set_cursor(session.window, { lines[1], 0 })
  else
    for index = #lines, 1, -1 do
      if lines[index] < current then
        vim.api.nvim_win_set_cursor(session.window, { lines[index], 0 })
        return
      end
    end
    vim.api.nvim_win_set_cursor(session.window, { lines[#lines], 0 })
  end
end

local function map(buffer, lhs, callback, desc)
  vim.keymap.set("n", lhs, callback, {
    buffer = buffer,
    silent = true,
    nowait = true,
    desc = desc,
  })
end

local function configure_buffer(session, actions)
  local buffer = session.buffer
  vim.bo[buffer].buftype = "nofile"
  vim.bo[buffer].bufhidden = "wipe"
  vim.bo[buffer].swapfile = false
  vim.bo[buffer].modifiable = false
  vim.bo[buffer].filetype = "archlens"

  local function expand_section(section_id)
    session.expanded[section_id] = true
    session.collapsed[section_id] = false
    M.render(session, session.model, session.options)
  end

  map(buffer, "<CR>", function()
    local target = target_at_cursor(session)
    if not target then
      return
    end
    if target.action == "expand" then
      expand_section(target.section_id)
    elseif target.action == "toggle" then
      session.collapsed[target.section_id] = not session.collapsed[target.section_id]
      M.render(session, session.model, session.options)
    elseif target.row then
      actions.open(target.row)
    end
  end, "ArchLens open")

  map(buffer, "f", function()
    local target = target_at_cursor(session)
    if target and target.row and target.row.id then
      actions.focus(target.row)
    end
  end, "ArchLens focus")
  map(buffer, "<BS>", actions.back, "ArchLens back")
  map(buffer, "h", actions.back, "ArchLens back")
  map(buffer, "r", actions.refresh, "ArchLens refresh")
  map(buffer, "q", actions.close, "ArchLens close")
  local function toggle_section()
    local target = target_at_cursor(session)
    if target and target.action == "expand" then
      expand_section(target.section_id)
    elseif target and target.action == "toggle" then
      session.collapsed[target.section_id] = not session.collapsed[target.section_id]
      M.render(session, session.model, session.options)
    end
  end
  map(buffer, "<Space>", toggle_section, "ArchLens toggle section")
  map(buffer, "za", toggle_section, "ArchLens toggle section")
  map(buffer, "<Tab>", function()
    move_to_target(session, 1)
  end, "ArchLens next item")
  map(buffer, "<S-Tab>", function()
    move_to_target(session, -1)
  end, "ArchLens previous item")
  map(buffer, "]s", function()
    move_to_target(session, 1, function(target)
      return target.action == "toggle"
    end)
  end, "ArchLens next section")
  map(buffer, "[s", function()
    move_to_target(session, -1, function(target)
      return target.action == "toggle"
    end)
  end, "ArchLens previous section")
end

local function configure_window(session)
  local window = session.window
  vim.wo[window].number = false
  vim.wo[window].relativenumber = false
  vim.wo[window].signcolumn = "no"
  vim.wo[window].foldcolumn = "0"
  vim.wo[window].wrap = false
  vim.wo[window].cursorline = true
  vim.wo[window].winfixwidth = true
end

function M.ensure(session, options, actions)
  session.options = options
  session.expanded = session.expanded or {}
  session.collapsed = session.collapsed or {}

  if valid_window(session.window) and valid_buffer(session.buffer) then
    return session.window
  end

  session.buffer = vim.api.nvim_create_buf(false, true)
  pcall(
    vim.api.nvim_buf_set_name,
    session.buffer,
    string.format("archlens://tab/%d", vim.api.nvim_tabpage_get_number(0))
  )
  configure_buffer(session, actions)

  vim.cmd("botright vsplit")
  session.window = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(session.window, session.buffer)
  local available = math.max(vim.o.columns - 20, 30)
  vim.api.nvim_win_set_width(session.window, math.min(options.width, available))
  configure_window(session)

  local window = session.window
  local buffer = session.buffer
  vim.api.nvim_create_autocmd("WinClosed", {
    pattern = tostring(window),
    once = true,
    callback = function()
      if session.window == window then
        session.window = nil
        session.buffer = nil
        session.rendered = nil
        session.model = nil
        actions.dismiss()
      end
    end,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = buffer,
    once = true,
    callback = function()
      if session.buffer == buffer then
        session.window = nil
        session.buffer = nil
        session.rendered = nil
        session.model = nil
        actions.dismiss()
      end
    end,
  })
  return session.window
end

function M.render(session, model, options)
  if not valid_buffer(session.buffer) or not valid_window(session.window) then
    return
  end

  session.model = model
  session.options = options
  local selected_id = session.restore_row_id or selected_row_id(session)
  local width = vim.api.nvim_win_get_width(session.window) - 2
  local rendered = renderer.build(model, {
    width = width,
    max_items = options.max_items,
    expanded = session.expanded,
    collapsed = session.collapsed,
  })
  session.rendered = rendered

  vim.bo[session.buffer].modifiable = true
  vim.api.nvim_buf_set_lines(session.buffer, 0, -1, false, rendered.lines)
  vim.api.nvim_buf_clear_namespace(session.buffer, namespace, 0, -1)
  for _, highlight in ipairs(rendered.highlights) do
    vim.api.nvim_buf_add_highlight(
      session.buffer,
      namespace,
      highlight.group,
      highlight.line,
      0,
      -1
    )
  end
  vim.bo[session.buffer].modifiable = false

  local selected_line
  if selected_id then
    for line, target in pairs(rendered.targets) do
      if target.row and target.row.id == selected_id then
        selected_line = line
        break
      end
    end
  end
  if selected_line then
    vim.api.nvim_win_set_cursor(session.window, { selected_line, 0 })
    session.restore_row_id = nil
  end
end

function M.close(session)
  if valid_window(session.window) then
    vim.api.nvim_win_close(session.window, true)
  end
  session.window = nil
  session.buffer = nil
  session.rendered = nil
  session.model = nil
end

function M.is_map_window(session, winid)
  return valid_window(session.window) and session.window == winid
end

function M.selected_row_id(session)
  return selected_row_id(session)
end

return M

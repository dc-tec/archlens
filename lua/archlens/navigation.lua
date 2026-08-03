local M = {}
local history_limit = 32

function M.reset(session)
  session.history = {}
  session.history_omitted = 0
  session.restore_row_id = nil
end

function M.push(session, via, selected_row_id)
  local entry = {
    context = session.current,
    via = via,
    selected_row_id = selected_row_id,
    expanded = vim.deepcopy(session.expanded),
    expanded_groups = vim.deepcopy(session.expanded_groups),
    group_limits = vim.deepcopy(session.group_limits),
    collapsed = vim.deepcopy(session.collapsed),
  }
  session.history[#session.history + 1] = entry
  if #session.history > history_limit then
    table.remove(session.history, 1)
    session.history_omitted = (session.history_omitted or 0) + 1
  end
  return entry
end

function M.rollback(session, entry)
  if session.history[#session.history] == entry then
    table.remove(session.history)
  end
end

function M.snapshot(session, focus)
  local entries = {}
  for _, entry in ipairs(session.history) do
    local context = entry.context or {}
    entries[#entries + 1] = {
      name = context.name or "Unknown focus",
      kind_name = context.kind_name,
      path_label = context.path_label,
      location = context.location,
      via = vim.deepcopy(entry.via),
    }
  end
  if focus then
    entries[#entries + 1] = {
      name = focus.name or "Unknown focus",
      kind_name = focus.kind_name,
      path_label = focus.path_label,
      location = focus.location,
    }
  end
  return {
    back_count = #session.history,
    omitted = session.history_omitted or 0,
    entries = entries,
  }
end

function M.context_identity(context, changedtick)
  if not context or not context.location or not context.location.uri then
    return nil
  end
  local start = context.location.range and context.location.range.start or {}
  return table.concat({
    context.location.uri,
    context.name or "",
    tostring(context.kind or context.kind_name or ""),
    tostring(start.line or 0),
    tostring(start.character or 0),
    tostring(changedtick or 0),
  }, "\0")
end

function M.same_symbol(left, right)
  if not left or not right or not left.location or not right.location then
    return false
  end
  local left_start = left.location.range and left.location.range.start or {}
  local right_start = right.location.range and right.location.range.start or {}
  return left.location.uri == right.location.uri
    and left.name == right.name
    and (left.kind or left.kind_name) == (right.kind or right.kind_name)
    and left_start.line == right_start.line
    and left_start.character == right_start.character
end

return M

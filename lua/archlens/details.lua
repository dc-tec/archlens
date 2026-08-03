local graph = require("archlens.graph")
local relations = require("archlens.relations")

local M = {}

local function append(lines, label, value)
  if value and value ~= "" then
    lines[#lines + 1] = string.format("%-12s%s", label, value)
  end
end

local function relative_path(root, uri)
  if not uri or uri == "" then
    return nil
  end
  if not uri:match("^file:") then
    return uri
  end

  local path = vim.uri_to_fname(uri)
  if root then
    return vim.fs.relpath(vim.fs.normalize(root), vim.fs.normalize(path)) or path
  end
  return path
end

local function location_label(location, root, fallback)
  if not location or not location.uri then
    return fallback
  end

  local path = fallback or relative_path(root, location.uri)
  local position = location.range and location.range.start
  if not position then
    return path
  end
  return string.format("%s:%d:%d", path, position.line + 1, position.character + 1)
end

local function evidence_rows(selection)
  if selection.row then
    return { selection.row }
  end
  if selection.group then
    return selection.group.rows or {}
  end
  return selection.section and selection.section.rows or {}
end

local function evidence_records(rows)
  local result = {}
  local seen = {}
  for _, row in ipairs(rows) do
    for _, evidence in ipairs(graph.evidence_records(row)) do
      local key = table.concat({ evidence.provider, evidence.method, evidence.class }, "\0")
      if not seen[key] then
        result[#result + 1] = evidence
        seen[key] = true
      end
    end
  end
  table.sort(result, function(left, right)
    if left.provider ~= right.provider then
      return left.provider < right.provider
    end
    if left.method ~= right.method then
      return left.method < right.method
    end
    return left.class < right.class
  end)
  return result
end

local function confidence(records)
  local classes = {}
  for _, evidence in ipairs(records) do
    classes[evidence.class] = true
  end
  if classes.semantic and classes.structural and not classes.syntax then
    return "Exact semantic relationship, structurally corroborated"
  end
  if classes.semantic and classes.syntax and not classes.structural then
    return "Exact semantic relationship, syntax corroborated"
  end
  if classes.syntax and classes.structural and not classes.semantic then
    return "Exact syntax relationship, structurally corroborated"
  end
  local count = vim.tbl_count(classes)
  if count > 1 then
    return "Mixed evidence"
  end
  if classes.structural then
    return "Structural candidate"
  end
  if classes.semantic then
    return "Exact semantic relationship"
  end
  if classes.syntax then
    return "Exact syntax relationship"
  end
  local only = next(classes)
  if only then
    return "Provider-defined (" .. only .. ")"
  end
  return nil
end

local function occurrence_locations(rows, root)
  local locations = {}
  for _, row in ipairs(rows) do
    for _, occurrence in ipairs(row.occurrences or {}) do
      for _, range in ipairs(occurrence.ranges or {}) do
        locations[#locations + 1] = location_label({
          uri = occurrence.uri,
          range = range,
        }, root)
      end
    end
  end
  table.sort(locations)
  return locations
end

local provider_state_labels = {
  cancelled = "Cancelled",
  completed = "Completed",
  failed = "Failed",
  queued = "Queued",
  retrying = "Retrying",
  running = "Running",
  timed_out = "Timed out",
  unavailable = "Unavailable",
}

local function duration_label(milliseconds)
  if milliseconds == nil then
    return nil
  end
  if milliseconds < 1000 then
    return string.format("%d ms", math.floor(milliseconds + 0.5))
  end
  return string.format("%.1f s", milliseconds / 1000)
end

local function provider_lines(runs)
  local lines = { "Analysis", "────────" }
  for index, run in ipairs(runs) do
    if index > 1 then
      lines[#lines + 1] = ""
    end
    lines[#lines + 1] = run.label
    append(lines, "State", provider_state_labels[run.state] or run.state)
    if run.duration_ms ~= nil then
      append(lines, "Duration", duration_label(run.duration_ms))
    elseif run.elapsed_ms ~= nil and run.state ~= "queued" then
      append(lines, "Elapsed", duration_label(run.elapsed_ms))
    end
    if run.retry_delay_ms ~= nil then
      append(lines, "Retry", "in " .. duration_label(run.retry_delay_ms))
    end
    append(lines, "Message", run.message)
  end
  return lines
end

local function result_lines(result)
  local lines = { "Results", "───────" }
  if result.parts and #result.parts > 0 then
    local labels = vim.tbl_map(function(part)
      return type(part) == "table" and part.label or part
    end, result.parts)
    append(lines, "Summary", table.concat(labels, " · "))
  end
  if result.notes and #result.notes > 0 then
    lines[#lines + 1] = ""
    lines[#lines + 1] = "Details"
    for _, note in ipairs(result.notes) do
      lines[#lines + 1] = "  • " .. note
    end
  end
  return lines
end

local function help_lines()
  return {
    "ArchLens keys",
    "─────────────",
    "<CR>            Open an item or toggle a section or context group",
    "f               Focus an item and retain the previous focus in history",
    "<BS>, h         Return to the previous focus",
    "<Tab>, <S-Tab>  Move to the next or previous actionable row",
    "]s, [s          Move to the next or previous section",
    "<Space>, za     Toggle a section or context group",
    "zM, zR          Collapse or expand the complete view",
    "?               Inspect the current line, or show this help",
    "r               Refresh the current focus",
    "q               Close ArchLens",
  }
end

function M.lines(selection, model)
  if selection and selection.help then
    return help_lines()
  end
  if selection and selection.provider_runs then
    return provider_lines(selection.provider_runs)
  end
  if selection and selection.result then
    return result_lines(selection.result)
  end
  local section = selection and selection.section
  if not section then
    return nil
  end

  local relation = relations.get(section.id)
  local root = model and model.focus and model.focus.root_dir
  local rows = evidence_rows(selection)
  local records = evidence_records(rows)
  local lines = { section.label, string.rep("─", math.min(vim.fn.strchars(section.label), 24)) }

  if relation then
    if relation.endpoint == "source" then
      append(lines, "Direction", "Incoming — related item → focus")
    else
      append(lines, "Direction", "Outgoing — focus → related item")
    end
  end

  if section.anchor then
    local kind = relation and relation.anchor == "file" and "File" or "Context"
    append(
      lines,
      "Anchor",
      string.format("%s — %s %s", kind, section.anchor.prefix, section.anchor.label)
    )
  elseif model and model.focus then
    append(lines, "Anchor", "Focus — " .. (model.focus.name or "current item"))
  end

  if selection.row then
    append(lines, "Item", selection.row.name)
    append(
      lines,
      "Location",
      location_label(selection.row.location, root, selection.row.path_label)
    )
  elseif selection.group then
    append(lines, "Context", selection.group.name)
    append(lines, "Location", location_label(selection.group.location, root))
    append(lines, "Items", tostring(#rows))
  else
    append(lines, "Items", tostring(#rows))
  end

  if #records > 0 then
    lines[#lines + 1] = ""
    lines[#lines + 1] = "Evidence"
    if #records == 1 then
      append(lines, "Provider", records[1].provider)
      append(lines, "Method", records[1].method)
      append(lines, "Class", records[1].class)
    else
      append(lines, "Records", tostring(#records))
      for _, evidence in ipairs(records) do
        lines[#lines + 1] =
          string.format("  %s · %s · %s", evidence.provider, evidence.method, evidence.class)
      end
    end
    append(lines, "Confidence", confidence(records))
  end

  local occurrences = occurrence_locations(rows, root)
  if #occurrences > 0 then
    lines[#lines + 1] = ""
    append(lines, "Occurrences", tostring(#occurrences) .. " retained")
    local shown = math.min(#occurrences, 12)
    for index = 1, shown do
      lines[#lines + 1] = "  " .. occurrences[index]
    end
    if shown < #occurrences then
      lines[#lines + 1] = string.format("  … %d more", #occurrences - shown)
    end
  end

  return lines
end

local function valid_window(window)
  return window and vim.api.nvim_win_is_valid(window)
end

local function restore_focus(instance)
  if
    not instance.tabpage
    or not vim.api.nvim_tabpage_is_valid(instance.tabpage)
    or vim.api.nvim_get_current_tabpage() ~= instance.tabpage
  then
    return
  end
  for _, field in ipairs({ "return_window", "fallback_window" }) do
    local window = instance[field]
    if valid_window(window) then
      local restored = pcall(vim.api.nvim_set_current_win, window)
      if restored then
        return
      end
    end
  end
end

local function notify_closed(instance)
  if instance.on_close then
    pcall(instance.on_close, instance)
  end
end

function M.close(instance, opts)
  if not instance or instance.closed then
    return true
  end
  opts = opts or {}
  instance.closed = true
  if valid_window(instance.window) then
    local closed = pcall(vim.api.nvim_win_close, instance.window, true)
    if not closed and valid_window(instance.window) then
      instance.closed = false
      return false
    end
  end
  notify_closed(instance)
  if opts.restore_focus ~= false then
    restore_focus(instance)
  end
  return true
end

function M.open(selection, model, opts)
  local lines = M.lines(selection, model)
  if not lines then
    return nil
  end
  opts = opts or {}

  local max_width = math.max(1, vim.o.columns - 4)
  local width = 1
  for _, line in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(line))
  end
  width = math.min(width, 72, max_width)
  local height = math.min(#lines, math.max(1, vim.o.lines - 4))
  local buffer = vim.api.nvim_create_buf(false, true)
  vim.bo[buffer].buftype = "nofile"
  vim.bo[buffer].bufhidden = "wipe"
  vim.bo[buffer].swapfile = false
  vim.bo[buffer].filetype = "archlensdetails"
  vim.api.nvim_buf_set_lines(buffer, 0, -1, false, lines)
  vim.bo[buffer].modifiable = false

  local window = vim.api.nvim_open_win(buffer, true, {
    relative = "editor",
    row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1),
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
    width = width,
    height = height,
    border = "rounded",
    style = "minimal",
    title = selection and selection.help and " ArchLens help " or " ArchLens details ",
    title_pos = "center",
  })
  vim.wo[window].wrap = true
  vim.wo[window].cursorline = false

  local instance = {
    buffer = buffer,
    window = window,
    lines = lines,
    return_window = opts.return_window,
    fallback_window = opts.fallback_window,
    on_close = opts.on_close,
    tabpage = vim.api.nvim_win_get_tabpage(window),
    closed = false,
  }

  vim.api.nvim_create_autocmd("WinClosed", {
    pattern = tostring(window),
    once = true,
    callback = function()
      if instance.closed then
        return
      end
      instance.closed = true
      notify_closed(instance)
      restore_focus(instance)
    end,
  })

  local function close_details()
    M.close(instance)
  end
  for _, key in ipairs({ "q", "<Esc>", "?" }) do
    vim.keymap.set("n", key, close_details, {
      buffer = buffer,
      silent = true,
      nowait = true,
      desc = "Close ArchLens details",
    })
  end

  return instance
end

return M

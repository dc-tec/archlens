local relations = require("archlens.relations")

local M = {}

local function append(lines, label, value)
  if value and value ~= "" then
    lines[#lines + 1] = string.format("%-12s%s", label, value)
  end
end

local function sorted_values(values)
  local result = {}
  for value in pairs(values) do
    result[#result + 1] = value
  end
  table.sort(result)
  return result
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

local function evidence_summary(rows)
  local result = {
    providers = {},
    methods = {},
    classes = {},
  }
  for _, row in ipairs(rows) do
    local evidence = row.evidence or {}
    if evidence.provider then
      result.providers[evidence.provider] = true
    end
    if evidence.method then
      result.methods[evidence.method] = true
    end
    if evidence.class then
      result.classes[evidence.class] = true
    end
  end
  return result
end

local function confidence(classes)
  local count = 0
  local only
  for class in pairs(classes) do
    count = count + 1
    only = class
  end
  if count > 1 then
    return "Mixed evidence"
  end
  if only == "structural" then
    return "Structural candidate"
  end
  if only == "semantic" then
    return "Exact semantic relationship"
  end
  if only == "syntax" then
    return "Exact syntax relationship"
  end
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

function M.lines(selection, model)
  local section = selection and selection.section
  if not section then
    return nil
  end

  local relation = relations.get(section.id)
  local root = model and model.focus and model.focus.root_dir
  local rows = evidence_rows(selection)
  local evidence = evidence_summary(rows)
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

  local providers = sorted_values(evidence.providers)
  local methods = sorted_values(evidence.methods)
  local classes = sorted_values(evidence.classes)
  if #providers > 0 or #methods > 0 or #classes > 0 then
    lines[#lines + 1] = ""
    lines[#lines + 1] = "Evidence"
    append(lines, #providers == 1 and "Provider" or "Providers", table.concat(providers, ", "))
    append(lines, #methods == 1 and "Method" or "Methods", table.concat(methods, ", "))
    append(lines, #classes == 1 and "Class" or "Classes", table.concat(classes, ", "))
    append(lines, "Confidence", confidence(evidence.classes))
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

local function close(window)
  if window and vim.api.nvim_win_is_valid(window) then
    vim.api.nvim_win_close(window, true)
  end
end

function M.open(selection, model)
  local lines = M.lines(selection, model)
  if not lines then
    return nil
  end

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
    title = " ArchLens details ",
    title_pos = "center",
  })
  vim.wo[window].wrap = true
  vim.wo[window].cursorline = false

  local function close_details()
    close(window)
  end
  for _, key in ipairs({ "q", "<Esc>", "?" }) do
    vim.keymap.set("n", key, close_details, {
      buffer = buffer,
      silent = true,
      nowait = true,
      desc = "Close ArchLens details",
    })
  end

  return { buffer = buffer, window = window, lines = lines }
end

return M

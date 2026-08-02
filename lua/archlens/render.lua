local M = {}

local function truncate(text, width)
  text = text or ""
  if width <= 0 then
    return ""
  end
  if vim.fn.strdisplaywidth(text) <= width then
    return text
  end
  if width == 1 then
    return "…"
  end

  local characters = vim.fn.strchars(text)
  while characters > 0 do
    local prefix = vim.fn.strcharpart(text, 0, characters)
    if vim.fn.strdisplaywidth(prefix .. "…") <= width then
      return prefix .. "…"
    end
    characters = characters - 1
  end
  return "…"
end

local function location_label(row)
  if not row.path_label or row.path_label == "" then
    return ""
  end
  if row.line then
    return string.format("%s:%d", row.path_label, row.line)
  end
  return row.path_label
end

function M.build(model, opts)
  opts = opts or {}
  local width = math.max(opts.width or 56, 30)
  local max_items = opts.max_items or 8
  local expanded = opts.expanded or {}
  local collapsed = opts.collapsed or {}
  local lines = {}
  local targets = {}
  local highlights = {}

  local function add(text, target, highlight)
    lines[#lines + 1] = truncate(text, width)
    if target then
      targets[#lines] = target
    end
    if highlight then
      highlights[#highlights + 1] = { line = #lines - 1, group = highlight }
    end
  end

  add(model.title or "ArchLens", nil, "Title")
  add(string.rep("─", math.min(width, 24)), nil, "Comment")

  if model.providers and #model.providers > 0 then
    add(table.concat(model.providers, " · "), nil, "DiagnosticHint")
  end

  if model.pending_providers and #model.pending_providers > 0 then
    add("Pending: " .. table.concat(model.pending_providers, " · "), nil, "DiagnosticInfo")
  end

  if model.focus then
    local focus = model.focus
    add("")
    local root_label = focus.root_dir and vim.fs.basename(focus.root_dir) or "workspace"
    add(root_label, nil, "Directory")
    local depth = 0
    if focus.path_label and focus.path_label ~= "" then
      add("└─ " .. focus.path_label, nil, "Directory")
      depth = 1
    end

    local trail = focus.syntax and focus.syntax.ancestors or {}
    for _, ancestor in ipairs(trail) do
      local prefix = string.rep("   ", depth) .. "└─ "
      add(prefix .. ancestor.name, {
        action = "open",
        row = {
          id = "trail:" .. (ancestor.location.uri or "") .. ":" .. ancestor.name,
          location = ancestor.location,
          context = ancestor,
        },
      }, "Identifier")
      depth = depth + 1
    end

    local focus_label = string.format("%s  %s", focus.name, focus.kind_name or "Symbol")
    add(string.rep("   ", depth) .. "└─ " .. focus_label, {
      action = "open",
      row = {
        id = "focus:" .. (focus.location.uri or "") .. ":" .. focus.name,
        location = focus.location,
        context = focus,
      },
    }, "Identifier")
    local detail = location_label(focus)
    if detail ~= "" then
      add(string.rep("   ", depth + 1) .. detail, nil, "Comment")
    end
  end

  if model.status then
    add("")
    add(model.status, nil, "DiagnosticInfo")
  end

  for _, section in ipairs(model.sections or {}) do
    add("")
    local is_collapsed = collapsed[section.id] == true
    add(
      string.format("%s %s  %d", is_collapsed and "▸" or "▾", section.label, #section.rows),
      { action = "toggle", section_id = section.id },
      "Special"
    )
    local limit = is_collapsed and 0
      or (expanded[section.id] and #section.rows or math.min(#section.rows, max_items))
    for index = 1, limit do
      local row = section.rows[index]
      add(
        string.format("  %s %s", section.marker, row.name),
        { action = "open", row = row },
        "Normal"
      )
      local badge = row.evidence and row.evidence.provider or "lsp"
      local detail = location_label(row)
      if detail ~= "" then
        add(string.format("    %s · %s", detail, badge), nil, "Comment")
      else
        add(string.format("    %s", badge), nil, "Comment")
      end
    end
    if not is_collapsed and limit < #section.rows then
      add(
        string.format("  … %d more", #section.rows - limit),
        { action = "expand", section_id = section.id },
        "MoreMsg"
      )
    end
  end

  for _, note in ipairs(model.notes or {}) do
    add("")
    add(note, nil, "DiagnosticHint")
  end

  add("")
  add("<CR> open  f focus  <BS> back  <Tab> next", nil, "Comment")
  add("<Space> section  [s/]s sections  r refresh  q close", nil, "Comment")

  return {
    lines = lines,
    targets = targets,
    highlights = highlights,
  }
end

return M

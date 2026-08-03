local M = {}

local provider_state_labels = {
  cancelled = "cancelled",
  failed = "failed",
  queued = "queued",
  retrying = "retrying",
  running = "running",
  timed_out = "timed out",
  unavailable = "unavailable",
}

local provider_state_order = {
  "failed",
  "timed_out",
  "unavailable",
  "cancelled",
  "retrying",
  "running",
  "queued",
}

local exceptional_provider_states = {
  cancelled = true,
  failed = true,
  retrying = true,
  timed_out = true,
  unavailable = true,
}

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

local function active_provider_runs(runs)
  local grouped = {}
  for _, state in ipairs(provider_state_order) do
    grouped[state] = {}
  end
  for _, run in ipairs(runs or {}) do
    if grouped[run.state] then
      grouped[run.state][#grouped[run.state] + 1] = run
    end
  end

  local active = {}
  for _, state in ipairs(provider_state_order) do
    vim.list_extend(active, grouped[state])
  end
  return active, grouped
end

local function analysis_line(model, width, inspectable)
  local prefix = inspectable and "Analysis [?]: " or "Analysis: "
  local active, grouped = active_provider_runs(model.provider_runs)
  if #active == 0 then
    return prefix .. table.concat(model.provider_activity or {}, " · ")
  end

  local full = vim.tbl_map(function(run)
    return string.format("%s %s", run.label, provider_state_labels[run.state])
  end, active)
  local full_line = prefix .. table.concat(full, " · ")
  if vim.fn.strdisplaywidth(full_line) <= width then
    return full_line
  end

  local compact = {}
  for _, state in ipairs(provider_state_order) do
    local state_runs = grouped[state]
    if #state_runs > 0 then
      if #state_runs == 1 and (exceptional_provider_states[state] or #active == 1) then
        compact[#compact + 1] =
          string.format("%s %s", state_runs[1].label, provider_state_labels[state])
      else
        compact[#compact + 1] = string.format("%d %s", #state_runs, provider_state_labels[state])
      end
    end
  end
  return prefix .. table.concat(compact, " · ")
end

function M.build(model, opts)
  opts = opts or {}
  local width = math.max(opts.width or 56, 30)
  local max_items = opts.max_items or 8
  local section_max_items = opts.section_max_items or {}
  local expanded = opts.expanded or {}
  local expanded_groups = opts.expanded_groups or {}
  local group_limits = opts.group_limits or {}
  local collapsed = opts.collapsed or {}
  local lines = {}
  local targets = {}
  local details = {}
  local highlights = {}

  local function add(text, target, highlight, detail)
    lines[#lines + 1] = truncate(text, width)
    if target then
      targets[#lines] = target
    end
    if detail then
      details[#lines] = detail
    end
    if highlight then
      highlights[#highlights + 1] = { line = #lines - 1, group = highlight }
    end
  end

  add(model.title or "ArchLens", nil, "Title")
  add(string.rep("─", math.min(width, 24)), nil, "Comment")

  local analysis_detail = model.provider_runs
      and #model.provider_runs > 0
      and { provider_runs = model.provider_runs }
    or nil

  if model.providers and #model.providers > 0 then
    add(
      (analysis_detail and "Sources [?]: " or "Sources: ") .. table.concat(model.providers, " · "),
      nil,
      "DiagnosticHint",
      analysis_detail
    )
  end

  if model.provider_activity and #model.provider_activity > 0 then
    add(analysis_line(model, width, analysis_detail ~= nil), nil, "DiagnosticInfo", analysis_detail)
  elseif model.pending_providers and #model.pending_providers > 0 then
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
    local section_detail = { section = section }
    add(
      string.format("%s %s  %d", is_collapsed and "▸" or "▾", section.label, #section.rows),
      { action = "toggle", section_id = section.id },
      "Special",
      section_detail
    )
    if not is_collapsed and section.anchor then
      add(
        string.format("  %s %s", section.anchor.prefix, section.anchor.label),
        nil,
        "Comment",
        section_detail
      )
    end
    local function add_row(row, indent)
      local row_detail = { section = section, row = row }
      add(
        string.format("%s%s %s", indent, section.marker, row.name),
        { action = "open", row = row },
        "Normal",
        row_detail
      )
      local badge = row.evidence and row.evidence.provider or "lsp"
      local detail = location_label(row)
      if detail ~= "" then
        add(string.format("%s  %s · %s", indent, detail, badge), nil, "Comment", row_detail)
      else
        add(string.format("%s  %s", indent, badge), nil, "Comment", row_detail)
      end
    end

    local items = section.groups or section.rows
    local item_limit = section_max_items[section.id] or max_items
    local limit = is_collapsed and 0
      or (expanded[section.id] and #items or math.min(#items, item_limit))
    if section.groups then
      for index = 1, limit do
        local group = section.groups[index]
        local is_group_expanded = expanded_groups[group.id] == true
        local group_detail = { section = section, group = group }
        add(
          string.format(
            "  %s %s  %d",
            is_group_expanded and "▾" or "▸",
            group.name,
            #group.rows
          ),
          {
            action = "toggle_group",
            group_id = group.id,
            section_id = section.id,
            row = {
              id = group.id,
              name = group.name,
              kind_name = group.kind_name,
              location = group.location,
              context = group.context,
              resolve_on_focus = group.resolve_on_focus,
            },
          },
          "Identifier",
          group_detail
        )
        if is_group_expanded then
          local group_limit = math.min(#group.rows, group_limits[group.id] or item_limit)
          for row_index = 1, group_limit do
            add_row(group.rows[row_index], "    ")
          end
          if group_limit < #group.rows then
            add(string.format("    … %d more uses", #group.rows - group_limit), {
              action = "expand_group",
              group_id = group.id,
              section_id = section.id,
            }, "MoreMsg", group_detail)
          end
        end
      end
    else
      for index = 1, limit do
        add_row(section.rows[index], "  ")
      end
    end
    if not is_collapsed and limit < #items then
      local suffix = section.groups and " contexts" or ""
      add(string.format("  … %d more%s", #items - limit, suffix), {
        action = "expand",
        section_id = section.id,
      }, "MoreMsg", section_detail)
    end
  end

  for _, note in ipairs(model.notes or {}) do
    add("")
    add(note, nil, "DiagnosticHint")
  end

  add("")
  add("<CR> open  f focus  <BS> back  <Tab> next", nil, "Comment")
  add("<Space> toggle  [s/]s sections  ? details", nil, "Comment")
  add("zM/zR collapse/expand all  r refresh  q close", nil, "Comment")

  return {
    lines = lines,
    targets = targets,
    details = details,
    highlights = highlights,
  }
end

return M

local adapters = require("archlens.adapters")
local graph = require("archlens.graph")
local relations = require("archlens.relations")
local scope = require("archlens.scope")

local M = {}

local function position_lte(left, right)
  return left.line < right.line or (left.line == right.line and left.character <= right.character)
end

local function position_lt(left, right)
  return left.line < right.line or (left.line == right.line and left.character < right.character)
end

function M.range_contains(range, position)
  if not range or not range.start or not range["end"] then
    return false
  end

  local empty = range.start.line == range["end"].line
    and range.start.character == range["end"].character
  return position_lte(range.start, position)
    and (position_lt(position, range["end"]) or (empty and position_lte(position, range.start)))
end

local function range_size(range)
  local lines = range["end"].line - range.start.line
  local characters = range["end"].character - range.start.character
  return lines, characters
end

local function prefer_symbol(candidate, current)
  if not current then
    return true
  end

  if candidate.depth ~= current.depth then
    return candidate.depth > current.depth
  end

  local candidate_lines, candidate_characters = range_size(candidate.range)
  local current_lines, current_characters = range_size(current.range)
  if candidate_lines ~= current_lines then
    return candidate_lines < current_lines
  end
  return candidate_characters < current_characters
end

local function visit_document_symbols(symbols, position, uri, depth, best)
  for _, symbol in ipairs(symbols or {}) do
    local range = symbol.range or (symbol.location and symbol.location.range)
    local symbol_uri = symbol.location and symbol.location.uri or uri
    if symbol_uri == uri and M.range_contains(range, position) then
      local candidate = {
        raw = symbol,
        range = range,
        uri = symbol_uri,
        depth = depth,
      }
      if prefer_symbol(candidate, best) then
        best = candidate
      end
      if symbol.children then
        best = visit_document_symbols(symbol.children, position, uri, depth + 1, best)
      end
    end
  end
  return best
end

function M.select_document_symbol(symbols, position, uri)
  local best = visit_document_symbols(symbols, position, uri, 0, nil)
  return best and best.raw or nil
end

local function normalized_path(path)
  return path and vim.fs.normalize(path) or nil
end

local function relative_path(root, path)
  root = normalized_path(root)
  path = normalized_path(path)
  if not path then
    return ""
  end
  if not root then
    return path
  end
  return vim.fs.relpath(root, path) or path
end

local function location_from_item(item)
  local location = item.location
  if location then
    if location.targetUri then
      return {
        uri = location.targetUri,
        range = location.targetSelectionRange or location.targetRange,
        full_range = location.targetRange,
      }
    end
    return {
      uri = location.uri,
      range = location.range,
      full_range = location.full_range or location.range,
    }
  end

  return {
    uri = item.uri,
    range = item.selectionRange or item.range,
    full_range = item.range,
  }
end

local function kind_name(kind)
  return (vim.lsp.protocol.SymbolKind or {})[kind] or "Symbol"
end

local function component_for(root, path)
  local relative = relative_path(root, path)
  local directory = vim.fs.dirname(relative)
  if not directory or directory == "." then
    return vim.fs.basename(root or path or "workspace")
  end
  return directory
end

function M.context_from_item(item, provider)
  local location = location_from_item(item)
  local path = location.uri and vim.uri_to_fname(location.uri) or nil
  local root = provider.root_dir
  local line = location.range and location.range.start.line + 1 or nil

  return {
    item = item,
    client_id = provider.id,
    client_name = provider.name,
    position_encoding = provider.offset_encoding or "utf-16",
    root_dir = root,
    supports_calls = provider.supports_calls == true,
    name = item.name or (path and vim.fs.basename(path)) or "Current file",
    detail = item.detail,
    kind = item.kind,
    kind_name = kind_name(item.kind),
    component = component_for(root, path),
    location = location,
    path = path,
    path_label = relative_path(root, path),
    line = line,
  }
end

local function source_line(location, cache)
  if not location or not location.uri or not location.range then
    return nil
  end
  local uri = location.uri
  local line = location.range.start.line
  cache[uri] = cache[uri] or {}
  if cache[uri][line] ~= nil then
    return cache[uri][line] or nil
  end

  local text
  local path = vim.uri_to_fname(uri)
  local buffer = vim.fn.bufnr(path, false)
  if buffer ~= -1 and vim.api.nvim_buf_is_loaded(buffer) then
    text = vim.api.nvim_buf_get_lines(buffer, line, line + 1, false)[1]
  else
    local ok, lines = pcall(vim.fn.readfile, path, "", line + 1)
    text = ok and lines[line + 1] or nil
  end
  text = text and vim.trim(text:gsub("%s+", " ")) or nil
  cache[uri][line] = text or false
  return text
end

local function row_from_edge(edge, relation, context, cache)
  local node = graph.related_node(edge)
  local location = node and node.location
  if not location or not location.uri or not location.range then
    return nil
  end
  local path = vim.uri_to_fname(location.uri)
  local line = location.range.start.line + 1
  local name = node.name
  if not node.context then
    name = source_line(location, cache) or name or context.name
  end
  local row = {
    name = name,
    detail = node.detail,
    kind = node.kind,
    kind_name = node.kind_name or relation.kind_name,
    path_label = node.path_label or relative_path(context.root_dir, path),
    line = node.line or line,
    location = location,
    context = node.context,
    position_encoding = node.position_encoding or edge.position_encoding or "utf-8",
    resolve_on_focus = node.resolve_on_focus == true,
    evidence = vim.deepcopy(edge.evidence),
    evidence_records = graph.evidence_records(edge),
    occurrences = vim.deepcopy(edge.occurrences or {}),
    presentation = vim.deepcopy(edge.presentation),
  }
  local projected = adapters.row_presentation(context, relation, row)
  if projected then
    row.name = projected.name or row.name
    row.kind_name = projected.kind_name or row.kind_name
  end
  local id
  if edge.evidence.class == "syntax" then
    id = table.concat({ edge.kind, graph.location_key(location), row.name or "" }, ":")
  elseif relation.sort == "name" then
    id = table.concat({ edge.kind, graph.location_key(location), row.name or "" }, ":")
  else
    id = table.concat({ edge.kind, edge.evidence.method, graph.location_key(location) }, ":")
  end
  row.id = id
  return row
end

local function occurrence_key(occurrence)
  local parts = { occurrence.uri or "" }
  for _, range in ipairs(occurrence.ranges or {}) do
    parts[#parts + 1] = table.concat({
      range.start.line,
      range.start.character,
      range["end"].line,
      range["end"].character,
    }, ":")
  end
  return table.concat(parts, ":")
end

local function merge_row(target, source)
  target.evidence_records =
    graph.merge_evidence(graph.evidence_records(target), graph.evidence_records(source))
  target.evidence = graph.evidence_summary(target.evidence_records)
  local seen = {}
  for _, occurrence in ipairs(target.occurrences or {}) do
    seen[occurrence_key(occurrence)] = true
  end
  for _, occurrence in ipairs(source.occurrences or {}) do
    local key = occurrence_key(occurrence)
    if not seen[key] then
      seen[key] = true
      target.occurrences[#target.occurrences + 1] = occurrence
    end
  end
  if source.presentation then
    target.presentation = target.presentation or {}
    for key, value in pairs(source.presentation) do
      if target.presentation[key] == nil then
        target.presentation[key] = vim.deepcopy(value)
      end
    end
  end
end

local function ranges_overlap(left, right)
  if
    not left
    or not right
    or not left.start
    or not left["end"]
    or not right.start
    or not right["end"]
  then
    return false
  end
  local left_empty = not position_lt(left.start, left["end"])
  local right_empty = not position_lt(right.start, right["end"])
  if left_empty then
    return M.range_contains(right, left.start)
  end
  if right_empty then
    return M.range_contains(left, right.start)
  end
  return position_lt(left.start, right["end"]) and position_lt(right.start, left["end"])
end

local function occurrence_line_key(uri, line)
  return table.concat({ uri or "", tostring(line or 0) }, "\0")
end

local function incoming_occurrence_index(rows)
  local exact = {}
  local by_line = {}
  for _, row in ipairs(rows or {}) do
    for _, occurrence in ipairs(row.occurrences or {}) do
      if occurrence.uri then
        for _, range in ipairs(occurrence.ranges or {}) do
          if range.start and range["end"] and range.start.line and range["end"].line then
            local location = { uri = occurrence.uri, range = range }
            local location_key = graph.location_key(location)
            exact[location_key] = exact[location_key] or row
            for line = range.start.line, range["end"].line do
              local key = occurrence_line_key(occurrence.uri, line)
              by_line[key] = by_line[key] or {}
              by_line[key][#by_line[key] + 1] = { row = row, range = range }
            end
          end
        end
      end
    end
  end
  return exact, by_line
end

local function covering_incoming(row, exact, by_line)
  local location = row.location
  local direct = exact[graph.location_key(location)]
  if direct then
    return direct
  end
  local candidates = by_line[occurrence_line_key(location.uri, location.range.start.line)] or {}
  for _, candidate in ipairs(candidates) do
    if ranges_overlap(candidate.range, location.range) then
      return candidate.row
    end
  end
end

local function coalesce_call_references(grouped)
  local exact, by_line = incoming_occurrence_index(grouped.incoming)
  if vim.tbl_isempty(exact) then
    return
  end
  for _, relation_id in ipairs({ "test_references", "references" }) do
    local remaining = {}
    for _, row in ipairs(grouped[relation_id] or {}) do
      local incoming = covering_incoming(row, exact, by_line)
      if incoming then
        merge_row(incoming, row)
      else
        remaining[#remaining + 1] = row
      end
    end
    grouped[relation_id] = remaining
  end
end

local function section_anchor(rows)
  local anchor
  for _, row in ipairs(rows) do
    local candidate = row.presentation and row.presentation.section_anchor
    if candidate then
      if anchor and not vim.deep_equal(anchor, candidate) then
        return nil
      end
      anchor = vim.deepcopy(candidate)
    end
  end
  return anchor
end

local function container_groups(relation, rows)
  if relation.group_by ~= "container" then
    return nil
  end
  local groups = {}
  local by_id = {}
  for _, row in ipairs(rows) do
    local container = row.presentation and row.presentation.container
    if not container or not container.id then
      return nil
    end
    local group = by_id[container.id]
    if not group then
      local labels = vim.deepcopy(container.trail or {})
      labels[#labels + 1] = container.name
      group = {
        id = relation.id .. ":group:" .. container.id,
        name = table.concat(labels, " › "),
        kind_name = container.kind_name,
        location = vim.deepcopy(container.location),
        context = vim.deepcopy(container.context),
        rows = {},
        resolve_on_focus = container.kind_name ~= "File",
      }
      groups[#groups + 1] = group
      by_id[container.id] = group
    end
    group.rows[#group.rows + 1] = row
  end
  return groups
end

local function sort_rows(rows, style)
  table.sort(rows, function(left, right)
    if style == "name" and left.name ~= right.name then
      return (left.name or "") < (right.name or "")
    end
    if left.path_label ~= right.path_label then
      return (left.path_label or "") < (right.path_label or "")
    end
    if left.line ~= right.line then
      return (left.line or 0) < (right.line or 0)
    end
    return (left.name or "") < (right.name or "")
  end)
  return rows
end

local function normalize_edges(snapshot, context, filters)
  local cache = {}
  local scope_cache = {}
  local grouped = {}
  local seen = {}
  local hidden_locations = {}
  local hidden = {
    excluded = 0,
    external = 0,
    generated = 0,
    vendored = 0,
  }
  local self_key = graph.location_key(context.location)

  for _, relation in ipairs(relations.ordered()) do
    grouped[relation.id] = {}
    seen[relation.id] = {}
    hidden_locations[relation.id] = {}
  end

  for _, edge in ipairs(snapshot.edges or {}) do
    local relation = relations.get(edge.kind)
    local node = relation and graph.related_node(edge)
    local location = node and node.location
    if relation and location and location.uri and location.range then
      local key = graph.location_key(location)
      local dedupe_key = relation.sort == "name" and table.concat({ key, node.name or "" }, ":")
        or key
      local suppress_overlapping_self = relation.id == "configuration_consumers"
        or relation.id == "references"
        or relation.id == "test_references"
      local suppress_self = relation.suppress_self == true
        and (
          key == self_key
          or (
            suppress_overlapping_self
            and context.location
            and location.uri == context.location.uri
            and ranges_overlap(location.range, context.location.range)
          )
        )
      if not suppress_self and not seen[relation.id][dedupe_key] then
        local row = row_from_edge(edge, relation, context, cache)
        if row then
          local path = vim.uri_to_fname(row.location.uri)
          row.scope = scope.classify(context.root_dir, path, filters, scope_cache)
          row.internal = row.scope ~= "external"
          if scope.visible(row.scope, filters) then
            grouped[relation.id][#grouped[relation.id] + 1] = row
            seen[relation.id][dedupe_key] = row
          else
            hidden[row.scope] = hidden[row.scope] + 1
            seen[relation.id][dedupe_key] = true
            hidden_locations[relation.id][#hidden_locations[relation.id] + 1] = {
              location = location,
              scope = row.scope,
            }
          end
        end
      elseif type(seen[relation.id][dedupe_key]) == "table" then
        local row = row_from_edge(edge, relation, context, cache)
        if row then
          merge_row(seen[relation.id][dedupe_key], row)
        end
      end
    end
  end

  for _, relation in ipairs(relations.ordered()) do
    sort_rows(grouped[relation.id], relation.sort)
  end

  for _, relation in ipairs(relations.ordered()) do
    if relation.corroborates then
      local corroborated = {}
      for _, row in ipairs(grouped[relation.corroborates] or {}) do
        corroborated[graph.location_key(row.location)] = row
        if relation.corroborates_by == "line" then
          corroborated[graph.line_key(row.location)] = corroborated[graph.line_key(row.location)]
            or row
        end
      end
      local remaining = {}
      for _, row in ipairs(grouped[relation.id]) do
        local semantic = corroborated[graph.location_key(row.location)]
        if not semantic and relation.corroborates_by == "line" then
          semantic = corroborated[graph.line_key(row.location)]
        end
        if semantic then
          merge_row(semantic, row)
        else
          remaining[#remaining + 1] = row
        end
      end
      grouped[relation.id] = remaining

      local hidden_corroborated = {}
      for _, entry in ipairs(hidden_locations[relation.corroborates] or {}) do
        hidden_corroborated[graph.location_key(entry.location)] = true
        if relation.corroborates_by == "line" then
          hidden_corroborated[graph.line_key(entry.location)] = true
        end
      end
      for _, entry in ipairs(hidden_locations[relation.id]) do
        local corroborated_location = hidden_corroborated[graph.location_key(entry.location)]
        if not corroborated_location and relation.corroborates_by == "line" then
          corroborated_location = hidden_corroborated[graph.line_key(entry.location)]
        end
        if corroborated_location then
          hidden[entry.scope] = hidden[entry.scope] - 1
        end
      end
    end
  end

  coalesce_call_references(grouped)

  return grouped, hidden
end

local function projected_sections(context, relation, rows)
  local sections = {}
  local by_key = {}
  for index, row in ipairs(rows) do
    local projection = adapters.section_presentation(context, relation, row) or {}
    local key = projection.key or "default"
    local section = by_key[key]
    if not section then
      section = {
        key = key,
        label = projection.label or relation.label,
        order = projection.order or 0,
        first = index,
        rows = {},
        show_kind = projection.show_kind == true,
      }
      sections[#sections + 1] = section
      by_key[key] = section
    end
    section.rows[#section.rows + 1] = row
    section.show_kind = section.show_kind or projection.show_kind == true
  end
  table.sort(sections, function(left, right)
    if left.order ~= right.order then
      return left.order < right.order
    end
    return left.first < right.first
  end)
  return sections
end

function M.loading(context, message)
  return {
    title = "ArchLens",
    focus = context,
    status = message or "Loading relationships…",
    sections = {},
    notes = {},
  }
end

function M.error(message)
  return {
    title = "ArchLens",
    status = message,
    sections = {},
    notes = {},
  }
end

local function section_relations(policy)
  local ordered = relations.ordered()
  if not policy or not policy.order or #policy.order == 0 then
    return ordered
  end

  local by_id = {}
  for _, relation in ipairs(ordered) do
    by_id[relation.id] = relation
  end
  local result = {}
  local added = {}
  for _, section_id in ipairs(policy.order) do
    if by_id[section_id] and not added[section_id] then
      result[#result + 1] = by_id[section_id]
      added[section_id] = true
    end
  end
  for _, relation in ipairs(ordered) do
    if not added[relation.id] then
      result[#result + 1] = relation
    end
  end
  return result
end

local provider_state_labels = {
  cancelled = "cancelled",
  failed = "failed",
  queued = "queued",
  retrying = "retrying",
  running = "running",
  timed_out = "timed out",
  unavailable = "unavailable",
}

local function provider_runs(snapshot)
  if snapshot.provider_runs and #snapshot.provider_runs > 0 then
    return vim.deepcopy(snapshot.provider_runs)
  end
  return vim.tbl_map(function(provider)
    return {
      id = provider.id,
      label = provider.label,
      state = "queued",
    }
  end, snapshot.pending or {})
end

local function provider_activity(runs)
  local activity = {}
  for _, run in ipairs(runs) do
    local state = provider_state_labels[run.state]
    if state then
      activity[#activity + 1] = string.format("%s %s", run.label, state)
    end
  end
  return activity
end

function M.build(context, snapshot, opts)
  opts = opts or {}
  snapshot = snapshot or graph.new(context)
  assert(snapshot.version == 1, "unsupported relationship graph version")
  local pending_providers = vim.tbl_map(function(provider)
    return provider.label
  end, snapshot.pending or {})
  local resolving_lsp = false
  for _, provider in ipairs(snapshot.pending or {}) do
    if provider.id == "lsp" then
      resolving_lsp = true
      break
    end
  end
  local filters = vim.deepcopy(opts.filters or {})
  if filters.include_external == nil then
    filters.include_external = opts.include_external == true
  end
  local grouped, hidden = normalize_edges(snapshot, context, filters)
  local has_semantic_usage = #grouped.incoming > 0
    or #grouped.test_references > 0
    or #grouped.references > 0
    or #grouped.implementations > 0
    or #grouped.supertypes > 0
    or #grouped.subtypes > 0

  local notes = {}
  if context.configuration and not context.client_id and not resolving_lsp then
    notes[#notes + 1] =
      "Configuration uses require an active language server with project reference support."
  elseif context.file_fallback and not resolving_lsp then
    notes[#notes + 1] =
      "No symbol could be resolved at this position; semantic relationships were skipped."
  elseif
    not context.module_context
    and not context.configuration
    and not context.supports_calls
    and (context.kind == vim.lsp.protocol.SymbolKind.Constructor or context.kind == vim.lsp.protocol.SymbolKind.Function or context.kind == vim.lsp.protocol.SymbolKind.Method)
    and not resolving_lsp
  then
    notes[#notes + 1] = string.format(
      "%s has no call hierarchy here; other semantic and syntax relationships are used instead.",
      context.client_name or "The attached language server"
    )
  end
  for _, hidden_kind in ipairs({ "vendored", "generated", "excluded", "external" }) do
    local count = hidden[hidden_kind]
    if count > 0 then
      notes[#notes + 1] =
        string.format("%d %s relationship%s hidden.", count, hidden_kind, count == 1 and "" or "s")
    end
  end
  local structural_omitted = (snapshot.omitted or {}).structural or 0
  if structural_omitted > 0 then
    notes[#notes + 1] = string.format(
      "%d additional structural match%s omitted by the project-search limit.",
      structural_omitted,
      structural_omitted == 1 and " was" or "es were"
    )
  end
  for _, error_message in ipairs(snapshot.errors or {}) do
    notes[#notes + 1] = error_message
  end
  for _, note in ipairs(snapshot.notes or {}) do
    notes[#notes + 1] = note
  end

  local sections = {}
  local section_policy = opts.sections or {}
  local hidden_sections = {}
  for _, section_id in ipairs(section_policy.hidden or {}) do
    hidden_sections[section_id] = true
  end
  local section_hidden_count = 0
  for _, relation in ipairs(section_relations(section_policy)) do
    local rows = grouped[relation.id]
    if rows and #rows > 0 then
      if hidden_sections[relation.id] then
        section_hidden_count = section_hidden_count + #rows
      else
        for _, projection in ipairs(projected_sections(context, relation, rows)) do
          sections[#sections + 1] = {
            id = relation.id,
            view_id = projection.key == "default" and relation.id
              or relation.id .. ":" .. projection.key,
            label = projection.label,
            marker = relation.marker,
            rows = projection.rows,
            groups = container_groups(relation, projection.rows),
            anchor = section_anchor(projection.rows),
            show_kind = projection.show_kind,
            default_collapsed = section_policy.collapse_secondary ~= false
              and relation.source == "structural"
              and has_semantic_usage,
          }
        end
      end
    end
  end
  if section_hidden_count > 0 then
    notes[#notes + 1] = string.format(
      "%d relationship%s hidden by section policy.",
      section_hidden_count,
      section_hidden_count == 1 and "" or "s"
    )
  end
  if #sections == 0 and #notes == 0 and #pending_providers == 0 then
    notes[#notes + 1] = "No local or project relationships were returned."
  end

  local providers = vim.tbl_map(function(contributor)
    return contributor.label
  end, snapshot.contributors or {})
  local runs = provider_runs(snapshot)

  return {
    title = "ArchLens",
    focus = context,
    sections = sections,
    notes = notes,
    providers = providers,
    provider_activity = provider_activity(runs),
    provider_runs = runs,
    pending_providers = pending_providers,
  }
end

M.location_key = graph.location_key

return M

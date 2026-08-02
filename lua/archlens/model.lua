local graph = require("archlens.graph")
local relations = require("archlens.relations")

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

local function is_within(root, path)
  root = normalized_path(root)
  path = normalized_path(path)
  if not root or not path then
    return true
  end
  return path == root or path:sub(1, #root + 1) == root .. "/"
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
  local id
  if edge.evidence.class == "syntax" then
    id = table.concat({ edge.kind, graph.location_key(location), name or "" }, ":")
  elseif relation.sort == "name" then
    id = table.concat({ edge.kind, graph.location_key(location), name or "" }, ":")
  else
    id = table.concat({ edge.kind, edge.evidence.method, graph.location_key(location) }, ":")
  end
  return {
    id = id,
    name = name,
    detail = node.detail,
    kind_name = node.kind_name or relation.kind_name,
    path_label = node.path_label or relative_path(context.root_dir, path),
    line = node.line or line,
    location = location,
    context = node.context,
    position_encoding = node.position_encoding or edge.position_encoding or "utf-8",
    internal = is_within(context.root_dir, path),
    resolve_on_focus = node.resolve_on_focus == true,
    evidence = vim.deepcopy(edge.evidence),
    occurrences = vim.deepcopy(edge.occurrences or {}),
  }
end

local function add_provider(evidence, provider)
  local present = {}
  for value in evidence.provider:gmatch("[^+]+") do
    present[value] = true
  end
  for value in provider:gmatch("[^+]+") do
    if not present[value] then
      evidence.provider = evidence.provider .. "+" .. value
      present[value] = true
    end
  end
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
  add_provider(target.evidence, source.evidence.provider)
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

local function normalize_edges(snapshot, context, include_external)
  local cache = {}
  local grouped = {}
  local seen = {}
  local hidden_locations = {}
  local hidden = 0
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
      local suppress_self = relation.suppress_self == true and key == self_key
      if not suppress_self and not seen[relation.id][dedupe_key] then
        local row = row_from_edge(edge, relation, context, cache)
        if row then
          if row.internal or include_external then
            grouped[relation.id][#grouped[relation.id] + 1] = row
            seen[relation.id][dedupe_key] = row
          else
            hidden = hidden + 1
            seen[relation.id][dedupe_key] = true
            hidden_locations[relation.id][#hidden_locations[relation.id] + 1] = location
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
        corroborated[graph.line_key(row.location)] = corroborated[graph.line_key(row.location)]
          or row
      end
      local remaining = {}
      for _, row in ipairs(grouped[relation.id]) do
        local semantic = corroborated[graph.location_key(row.location)]
          or corroborated[graph.line_key(row.location)]
        if semantic then
          add_provider(semantic.evidence, row.evidence.provider)
        else
          remaining[#remaining + 1] = row
        end
      end
      grouped[relation.id] = remaining

      local hidden_corroborated = {}
      for _, location in ipairs(hidden_locations[relation.corroborates] or {}) do
        hidden_corroborated[graph.location_key(location)] = true
        hidden_corroborated[graph.line_key(location)] = true
      end
      for _, location in ipairs(hidden_locations[relation.id]) do
        if
          hidden_corroborated[graph.location_key(location)]
          or hidden_corroborated[graph.line_key(location)]
        then
          hidden = hidden - 1
        end
      end
    end
  end

  return grouped, hidden
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
  local grouped, hidden = normalize_edges(snapshot, context, opts.include_external)

  local notes = {}
  if context.file_fallback and not resolving_lsp then
    notes[#notes + 1] =
      "No symbol could be resolved at this position; semantic relationships were skipped."
  elseif not context.supports_calls and not resolving_lsp then
    notes[#notes + 1] = string.format(
      "%s has no call hierarchy here; project references and syntax structure are used instead.",
      context.client_name or "The attached language server"
    )
  end
  if hidden > 0 then
    notes[#notes + 1] =
      string.format("%d external relationship%s hidden.", hidden, hidden == 1 and "" or "s")
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
  for _, relation in ipairs(relations.ordered()) do
    local rows = grouped[relation.id]
    if rows and #rows > 0 then
      sections[#sections + 1] = {
        id = relation.id,
        label = relation.label,
        marker = relation.marker,
        rows = rows,
      }
    end
  end
  if #sections == 0 and #notes == 0 and #pending_providers == 0 then
    notes[#notes + 1] = "No local or project relationships were returned."
  end

  local providers = vim.tbl_map(function(contributor)
    return contributor.label
  end, snapshot.contributors or {})

  return {
    title = "ArchLens",
    focus = context,
    sections = sections,
    notes = notes,
    providers = providers,
    pending_providers = pending_providers,
  }
end

M.location_key = graph.location_key

return M

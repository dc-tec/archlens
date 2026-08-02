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
      full_range = location.range,
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

local function location_key(location)
  local range = location and location.range
  local start = range and range.start or {}
  return table.concat({
    location and location.uri or "",
    tostring(start.line or 0),
    tostring(start.character or 0),
  }, ":")
end

local function location_line_key(location)
  local range = location and location.range
  return table.concat({
    "line",
    location and location.uri or "",
    tostring(range and range.start and range.start.line or 0),
  }, ":")
end

local function row_from_call(call, direction, context)
  local item = direction == "incoming" and call.from or call.to
  if not item then
    return nil
  end

  local row_context = M.context_from_item(item, {
    id = context.client_id,
    name = context.client_name,
    offset_encoding = context.position_encoding,
    root_dir = context.root_dir,
    supports_calls = true,
  })
  local range = row_context.location.range
  local start = range and range.start or { line = 0, character = 0 }

  return {
    id = table.concat({
      direction,
      row_context.location.uri or "",
      tostring(start.line),
      tostring(start.character),
      row_context.name,
    }, ":"),
    name = row_context.name,
    detail = row_context.detail,
    kind_name = row_context.kind_name,
    path_label = row_context.path_label,
    line = row_context.line,
    location = row_context.location,
    context = row_context,
    internal = is_within(context.root_dir, row_context.path),
    evidence = {
      provider = context.client_name,
      method = direction == "incoming" and "callHierarchy/incomingCalls"
        or "callHierarchy/outgoingCalls",
    },
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

local function row_from_location(location, context, evidence, cache, fallback_name)
  if not location or not location.uri or not location.range then
    return nil
  end
  local path = vim.uri_to_fname(location.uri)
  local line = location.range.start.line + 1
  return {
    id = table.concat({ evidence.method, location_key(location) }, ":"),
    name = source_line(location, cache) or fallback_name or context.name,
    kind_name = "Reference",
    path_label = relative_path(context.root_dir, path),
    line = line,
    location = { uri = location.uri, range = location.range, full_range = location.range },
    internal = is_within(context.root_dir, path),
    resolve_on_focus = true,
    evidence = vim.deepcopy(evidence),
  }
end

local function row_from_syntax(syntax_context, relation)
  return {
    id = table.concat(
      { relation, location_key(syntax_context.location), syntax_context.name },
      ":"
    ),
    name = syntax_context.name,
    detail = syntax_context.detail,
    kind_name = syntax_context.kind_name,
    path_label = syntax_context.path_label,
    line = syntax_context.line,
    location = syntax_context.location,
    context = syntax_context,
    internal = true,
    evidence = { provider = "Tree-sitter", method = relation },
  }
end

local function normalize_calls(calls, direction, context, include_external)
  local rows = {}
  local seen = {}
  local hidden = 0

  for _, call in ipairs(calls or {}) do
    local row = row_from_call(call, direction, context)
    if row and not seen[row.id] then
      seen[row.id] = true
      if row.internal or include_external then
        rows[#rows + 1] = row
      else
        hidden = hidden + 1
      end
    end
  end

  table.sort(rows, function(left, right)
    if left.name ~= right.name then
      return left.name < right.name
    end
    if left.path_label ~= right.path_label then
      return left.path_label < right.path_label
    end
    return (left.line or 0) < (right.line or 0)
  end)

  return rows, hidden
end

local function normalize_locations(locations, context, include_external, evidence, cache)
  local rows = {}
  local hidden = 0
  local seen = {}
  local self_key = location_key(context.location)
  for _, location in ipairs(locations or {}) do
    if location.targetUri then
      location = {
        uri = location.targetUri,
        range = location.targetSelectionRange or location.targetRange,
      }
    end
    local key = location_key(location)
    if key ~= self_key and not seen[key] then
      local row = row_from_location(location, context, evidence, cache)
      if row then
        if row.internal or include_external then
          rows[#rows + 1] = row
          seen[key] = row
          seen[location_line_key(location)] = seen[location_line_key(location)] or row
        else
          hidden = hidden + 1
          seen[key] = true
        end
      end
    end
  end
  return rows, hidden, seen
end

local function normalize_structural(matches, context, include_external, cache, excluded)
  local rows = {}
  local hidden = 0
  local seen = {}
  local self_key = location_key(context.location)
  for _, match in ipairs(matches or {}) do
    local location = { uri = match.uri, range = match.range }
    local key = location_key(location)
    local semantic_row = excluded[key] or excluded[location_line_key(location)]
    if key ~= self_key and semantic_row then
      if type(semantic_row) == "table" and semantic_row.evidence then
        semantic_row.evidence.provider = semantic_row.evidence.provider .. "+ast-grep"
      end
    elseif key ~= self_key and not seen[key] then
      seen[key] = true
      local row = row_from_location(location, context, {
        provider = match.provider or "ast-grep",
        method = "structural",
      }, cache, match.text)
      if row then
        if row.internal or include_external then
          rows[#rows + 1] = row
        else
          hidden = hidden + 1
        end
      end
    end
  end
  return rows, hidden
end

local function sort_rows(rows)
  table.sort(rows, function(left, right)
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

local function syntax_rows(context, key)
  local rows = {}
  for _, syntax_context in ipairs((context.syntax and context.syntax[key]) or {}) do
    rows[#rows + 1] = row_from_syntax(syntax_context, key)
  end
  return sort_rows(rows)
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

function M.build(context, relationships, opts)
  opts = opts or {}
  relationships = relationships or {}
  local pending_providers = vim.deepcopy(relationships.pending_providers or {})
  local resolving_lsp = vim.tbl_contains(pending_providers, "LSP")

  local cache = {}
  local incoming, incoming_hidden =
    normalize_calls(relationships.incoming, "incoming", context, opts.include_external)
  local outgoing, outgoing_hidden =
    normalize_calls(relationships.outgoing, "outgoing", context, opts.include_external)
  local references, references_hidden, reference_keys = normalize_locations(
    relationships.references,
    context,
    opts.include_external,
    { provider = context.client_name or "LSP", method = "textDocument/references" },
    cache
  )
  local structural, structural_hidden = normalize_structural(
    relationships.structural,
    context,
    opts.include_external,
    cache,
    reference_keys
  )
  sort_rows(references)
  sort_rows(structural)
  local children = syntax_rows(context, "children")
  local siblings = syntax_rows(context, "siblings")

  local notes = {}
  if not context.supports_calls and not resolving_lsp then
    notes[#notes + 1] = string.format(
      "%s has no call hierarchy here; project references and syntax structure are used instead.",
      context.client_name or "The attached language server"
    )
  end
  local hidden = incoming_hidden + outgoing_hidden + references_hidden + structural_hidden
  if hidden > 0 then
    notes[#notes + 1] =
      string.format("%d external relationship%s hidden.", hidden, hidden == 1 and "" or "s")
  end
  if (relationships.structural_omitted or 0) > 0 then
    notes[#notes + 1] = string.format(
      "%d additional structural match%s omitted by the project-search limit.",
      relationships.structural_omitted,
      relationships.structural_omitted == 1 and " was" or "es were"
    )
  end
  for _, error_message in ipairs(relationships.errors or {}) do
    notes[#notes + 1] = error_message
  end
  for _, note in ipairs(relationships.notes or {}) do
    notes[#notes + 1] = note
  end

  local sections = {}
  if #children > 0 then
    sections[#sections + 1] = {
      id = "children",
      label = "Contains",
      marker = "└",
      rows = children,
    }
  end
  if #incoming > 0 then
    sections[#sections + 1] = {
      id = "incoming",
      label = "Entered through",
      marker = "←",
      rows = incoming,
    }
  end
  if #outgoing > 0 then
    sections[#sections + 1] = {
      id = "outgoing",
      label = "Touches",
      marker = "→",
      rows = outgoing,
    }
  end
  if #references > 0 then
    sections[#sections + 1] = {
      id = "references",
      label = "Referenced across project",
      marker = "◆",
      rows = references,
    }
  end
  if #structural > 0 then
    sections[#sections + 1] = {
      id = "structural",
      label = "Structural matches",
      marker = "≈",
      rows = structural,
    }
  end
  if #siblings > 0 then
    sections[#sections + 1] = {
      id = "siblings",
      label = "Nearby definitions",
      marker = "·",
      rows = siblings,
    }
  end
  if #sections == 0 and #notes == 0 and #pending_providers == 0 then
    notes[#notes + 1] = "No local or project relationships were returned."
  end

  local providers = {}
  local provider_seen = {}
  local function add_provider(provider)
    if provider and not provider_seen[provider] then
      provider_seen[provider] = true
      providers[#providers + 1] = provider
    end
  end
  add_provider(context.client_name)
  add_provider(context.syntax and context.syntax.provider)
  if relationships.ast_grep_ran then
    add_provider("ast-grep")
  end

  return {
    title = "ArchLens",
    focus = context,
    sections = sections,
    notes = notes,
    providers = providers,
    pending_providers = pending_providers,
  }
end

M.location_key = location_key

return M

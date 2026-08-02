local relations = require("archlens.relations")

local M = {}

---@class ArchLensGraphNode
---@field id string
---@field name? string
---@field kind? integer
---@field kind_name? string
---@field scope "symbol"|"file"|"module"|"configuration"
---@field location? { uri: string, range: table, full_range: table }
---@field context? table
---@field resolve_on_focus? boolean

---@class ArchLensGraphEdge
---@field id string
---@field kind string
---@field source ArchLensGraphNode
---@field target ArchLensGraphNode
---@field evidence { provider: string, method: string, class: string }
---@field occurrences table[]
---@field position_encoding "utf-8"

---@class ArchLensGraphDelta
---@field version 1
---@field edges ArchLensGraphEdge[]
---@field errors string[]
---@field notes string[]
---@field omitted table<string, integer>
---@field contributors { id: string, label: string }[]
---@field pending { id: string, label: string }[]

local valid_scopes = {
  configuration = true,
  file = true,
  module = true,
  symbol = true,
}

local raw_provider_fields = {
  from = true,
  fromRanges = true,
  originSelectionRange = true,
  targetRange = true,
  targetSelectionRange = true,
  targetUri = true,
  to = true,
}

local function validate_canonical(value, path, seen, allow_wire_call_item)
  if type(value) ~= "table" then
    return
  end
  seen = seen or {}
  if seen[value] then
    return
  end
  seen[value] = true

  for key, nested in pairs(value) do
    assert(
      not raw_provider_fields[key],
      string.format("graph values cannot expose provider field %s at %s", tostring(key), path)
    )
    if not (allow_wire_call_item and key == "wire_call_item") then
      validate_canonical(nested, path .. "." .. tostring(key), seen, key == "context")
    end
  end
end

local function normalized_location(location)
  if not location then
    return nil
  end
  validate_canonical(location, "location")
  return {
    uri = location.uri,
    range = location.range,
    full_range = location.full_range or location.range,
  }
end

function M.location_key(location)
  location = normalized_location(location)
  local range = location and location.range
  local start = range and range.start or {}
  return table.concat({
    location and location.uri or "",
    tostring(start.line or 0),
    tostring(start.character or 0),
  }, ":")
end

function M.line_key(location)
  location = normalized_location(location)
  local range = location and location.range
  return table.concat({
    "line",
    location and location.uri or "",
    tostring(range and range.start and range.start.line or 0),
  }, ":")
end

local function scope_for(fields)
  if fields.scope then
    return fields.scope
  end
  if fields.kind == vim.lsp.protocol.SymbolKind.File or fields.kind_name == "File" then
    return "file"
  end
  if
    fields.kind == vim.lsp.protocol.SymbolKind.Module
    or fields.kind == vim.lsp.protocol.SymbolKind.Package
    or fields.kind_name == "Module"
    or fields.kind_name == "Package"
  then
    return "module"
  end
  return "symbol"
end

function M.node(fields)
  assert(type(fields) == "table", "graph nodes require a table")
  local node = vim.tbl_extend("force", {}, fields)
  node.location = normalized_location(node.location)
  node.scope = scope_for(node)
  assert(valid_scopes[node.scope], "unsupported graph node scope: " .. tostring(node.scope))
  assert(
    node.location or (type(node.id) == "string" and node.id ~= ""),
    "graph nodes require a location or id"
  )
  node.id = node.id
    or table.concat(
      { node.scope, M.location_key(node.location), node.name or node.kind_name or "" },
      ":"
    )
  return node
end

function M.node_from_context(context, overrides)
  assert(type(context) == "table", "graph context nodes require a context")
  return M.node(vim.tbl_extend("force", {
    name = context.name,
    detail = context.detail,
    kind = context.kind,
    kind_name = context.kind_name,
    scope = context.scope,
    location = context.location,
    path = context.path,
    path_label = context.path_label,
    line = context.line,
    position_encoding = context.position_encoding,
    context = context,
  }, overrides or {}))
end

function M.node_from_location(location, fields)
  fields = vim.tbl_extend("force", {
    location = location,
    resolve_on_focus = true,
  }, fields or {})
  return M.node(fields)
end

local function validate_evidence(evidence)
  assert(type(evidence) == "table", "graph edges require evidence")
  for _, key in ipairs({ "provider", "method", "class" }) do
    assert(
      type(evidence[key]) == "string" and evidence[key] ~= "",
      "graph edge evidence requires " .. key
    )
  end
end

function M.edge(kind, source, target, evidence, fields)
  assert(relations.get(kind), "unknown relationship kind: " .. tostring(kind))
  source = M.node(source)
  target = M.node(target)
  validate_evidence(evidence)
  local edge = vim.tbl_extend("force", fields or {}, {
    id = table.concat({ kind, source.id, target.id }, ":"),
    kind = kind,
    source = source,
    target = target,
    evidence = vim.deepcopy(evidence),
  })
  edge.position_encoding = edge.position_encoding or "utf-8"
  assert(edge.position_encoding == "utf-8", "graph edges must use UTF-8 byte columns")
  return edge
end

function M.related_node(edge)
  local relation = edge and relations.get(edge.kind)
  if not relation then
    return nil
  end
  return edge[relation.endpoint]
end

function M.focus_node(edge)
  local relation = edge and relations.get(edge.kind)
  if not relation then
    return nil
  end
  return edge[relation.endpoint == "source" and "target" or "source"]
end

local function contributor_key(contributor)
  return contributor.id or contributor.label
end

function M.delta()
  return {
    version = 1,
    edges = {},
    errors = {},
    notes = {},
    omitted = {},
    contributors = {},
    pending = {},
  }
end

function M.add_edge(target, edge)
  assert(type(target) == "table" and target.version == 1, "invalid graph delta")
  assert(type(edge) == "table" and relations.get(edge.kind), "invalid graph edge")
  assert(type(edge.source) == "table" and type(edge.target) == "table", "graph edges require nodes")
  assert(edge.position_encoding == "utf-8", "graph edges must use UTF-8 byte columns")
  validate_evidence(edge.evidence)
  validate_canonical(edge, "edge")
  if target.focus then
    local focus = M.focus_node(edge)
    assert(focus and focus.id == target.focus.id, "graph edge does not belong to the focused node")
  end
  target.edges[#target.edges + 1] = edge
  return edge
end

function M.add_error(target, message)
  if type(message) == "string" and message ~= "" then
    target.errors[#target.errors + 1] = message
  end
end

function M.add_note(target, message)
  if type(message) == "string" and message ~= "" then
    target.notes[#target.notes + 1] = message
  end
end

function M.add_omitted(target, kind, count)
  assert(relations.get(kind), "unknown omitted relationship kind: " .. tostring(kind))
  if count and count > 0 then
    target.omitted[kind] = (target.omitted[kind] or 0) + count
  end
end

function M.add_contributor(target, id, label)
  assert(type(id) == "string" and id ~= "", "contributors require an id")
  label = label or id
  for _, contributor in ipairs(target.contributors) do
    if contributor_key(contributor) == id then
      return
    end
  end
  target.contributors[#target.contributors + 1] = { id = id, label = label }
end

function M.set_pending(target, providers)
  target.pending = {}
  for _, provider in ipairs(providers or {}) do
    target.pending[#target.pending + 1] = {
      id = assert(provider.id, "pending providers require an id"),
      label = provider.label or provider.id,
    }
  end
end

function M.merge(target, delta)
  assert(type(target) == "table" and target.version == 1, "invalid graph snapshot")
  assert(type(delta) == "table" and delta.version == 1, "invalid graph delta")
  for _, edge in ipairs(delta.edges or {}) do
    M.add_edge(target, edge)
  end
  vim.list_extend(target.errors, delta.errors or {})
  vim.list_extend(target.notes, delta.notes or {})
  for kind, count in pairs(delta.omitted or {}) do
    M.add_omitted(target, kind, count)
  end
  for _, contributor in ipairs(delta.contributors or {}) do
    M.add_contributor(target, contributor.id, contributor.label)
  end
  return target
end

local function add_syntax_edges(snapshot, context, kind)
  local focus = snapshot.focus
  for _, syntax_context in ipairs((context.syntax and context.syntax[kind]) or {}) do
    local related = M.node_from_context(syntax_context)
    M.add_edge(
      snapshot,
      M.edge(kind, focus, related, {
        provider = context.syntax.provider or "Tree-sitter",
        method = kind,
        class = "syntax",
      })
    )
  end
end

function M.new(context)
  local snapshot = M.delta()
  snapshot.focus = M.node_from_context(context)
  if context.client_id and context.client_name then
    M.add_contributor(snapshot, "lsp:" .. tostring(context.client_id), context.client_name)
  end
  if context.syntax and context.syntax.provider then
    M.add_contributor(snapshot, "syntax", context.syntax.provider)
  end
  add_syntax_edges(snapshot, context, "children")
  add_syntax_edges(snapshot, context, "siblings")
  return snapshot
end

return M

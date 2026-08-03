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
---@field evidence_records { provider: string, method: string, class: string }[]
--- Compatibility summary derived from evidence_records. Mixed methods or classes are reported as "mixed".
---@field evidence { provider: string, method: string, class: string }
---@field occurrences table[]
---@field position_encoding "utf-8"
---@field presentation? { container?: { id: string, name: string, kind_name: string, location: table }, section_anchor?: { prefix: string, label: string } }

---@class ArchLensGraphDelta
---@field version 1
---@field edges ArchLensGraphEdge[]
---@field errors string[]
---@field notes string[]
---@field note_records { message: string, summary?: string, severity?: "info"|"warn"|"error" }[]
---@field omitted table<string, integer>
---@field contributors { id: string, label: string }[]
---@field pending { id: string, label: string }[]
---@field provider_runs { id: string, label: string, state: string, elapsed_ms?: integer, duration_ms?: integer, retry_delay_ms?: integer, message?: string }[]

local valid_scopes = {
  configuration = true,
  file = true,
  module = true,
  symbol = true,
}

local valid_provider_states = {
  cancelled = true,
  completed = true,
  failed = true,
  queued = true,
  retrying = true,
  running = true,
  timed_out = true,
  unavailable = true,
}

local valid_note_severities = {
  error = true,
  info = true,
  warn = true,
}

local pending_provider_states = {
  queued = true,
  retrying = true,
  running = true,
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

local opaque_context_fields = {
  wire_call_item = true,
  wire_type_item = true,
}

local function validate_canonical(value, path, seen, allow_wire_items)
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
    if not (allow_wire_items and opaque_context_fields[key]) then
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

local function evidence_key(evidence)
  return table.concat({ evidence.provider, evidence.method, evidence.class }, "\0")
end

local function validate_evidence_records(records)
  assert(type(records) == "table" and #records > 0, "graph edges require evidence records")
  for _, evidence in ipairs(records) do
    validate_evidence(evidence)
  end
end

---Return independent evidence records, falling back to the compatibility summary for older values.
---@param value table
---@return table[]
function M.evidence_records(value)
  if type(value) ~= "table" then
    return {}
  end
  if type(value.evidence_records) == "table" and #value.evidence_records > 0 then
    return vim.deepcopy(value.evidence_records)
  end
  if type(value.evidence) == "table" then
    return { vim.deepcopy(value.evidence) }
  end
  return {}
end

---Build the compact evidence value used by existing row badges and consumers.
---@param records table[]
---@return table
function M.evidence_summary(records)
  validate_evidence_records(records)
  local providers = {}
  local provider_seen = {}
  local methods = {}
  local classes = {}
  for _, evidence in ipairs(records) do
    for provider in evidence.provider:gmatch("[^+]+") do
      if not provider_seen[provider] then
        providers[#providers + 1] = provider
        provider_seen[provider] = true
      end
    end
    methods[evidence.method] = true
    classes[evidence.class] = true
  end
  local method = next(methods)
  if next(methods, method) then
    method = "mixed"
  end
  local class = next(classes)
  if next(classes, class) then
    class = "mixed"
  end
  return {
    provider = table.concat(providers, "+"),
    method = method,
    class = class,
  }
end

---Merge unique evidence contributions while preserving first-seen provider order for badges.
---@param target table[]
---@param source table[]
function M.merge_evidence(target, source)
  validate_evidence_records(target)
  validate_evidence_records(source)
  local seen = {}
  for _, evidence in ipairs(target) do
    seen[evidence_key(evidence)] = true
  end
  for _, evidence in ipairs(source) do
    local key = evidence_key(evidence)
    if not seen[key] then
      target[#target + 1] = vim.deepcopy(evidence)
      seen[key] = true
    end
  end
  return target
end

local function validate_presentation(presentation)
  if presentation == nil then
    return
  end
  assert(type(presentation) == "table", "graph edge presentation must be a table")
  local container = presentation.container
  if container ~= nil then
    assert(type(container) == "table", "graph edge container presentation must be a table")
    for _, field in ipairs({ "id", "name", "kind_name" }) do
      assert(
        type(container[field]) == "string" and container[field] ~= "",
        "graph edge container presentation requires " .. field
      )
    end
    assert(
      container.location and container.location.uri and container.location.range,
      "graph edge container presentation requires a location"
    )
  end
  local section_anchor = presentation.section_anchor
  if section_anchor ~= nil then
    assert(type(section_anchor) == "table", "graph edge section anchor must be a table")
    for _, field in ipairs({ "prefix", "label" }) do
      assert(
        type(section_anchor[field]) == "string" and section_anchor[field] ~= "",
        "graph edge section anchor requires " .. field
      )
    end
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
    evidence_records = { vim.deepcopy(evidence) },
  })
  edge.occurrences = edge.occurrences or {}
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
    note_records = {},
    omitted = {},
    contributors = {},
    pending = {},
    provider_runs = {},
  }
end

function M.add_edge(target, edge)
  assert(type(target) == "table" and target.version == 1, "invalid graph delta")
  assert(type(edge) == "table" and relations.get(edge.kind), "invalid graph edge")
  assert(type(edge.source) == "table" and type(edge.target) == "table", "graph edges require nodes")
  assert(edge.position_encoding == "utf-8", "graph edges must use UTF-8 byte columns")
  edge.evidence_records = M.evidence_records(edge)
  validate_evidence_records(edge.evidence_records)
  edge.evidence = M.evidence_summary(edge.evidence_records)
  validate_presentation(edge.presentation)
  validate_canonical(edge, "edge")
  if target.focus then
    local focus = M.focus_node(edge)
    local relation = relations.get(edge.kind)
    if relation.anchor == "file" then
      assert(
        focus
          and focus.scope == "file"
          and focus.location
          and target.focus.location
          and focus.location.uri == target.focus.location.uri,
        "file-context graph edge does not belong to the focused file"
      )
    else
      assert(
        focus and focus.id == target.focus.id,
        "graph edge does not belong to the focused node"
      )
    end
  end
  target.edges[#target.edges + 1] = edge
  return edge
end

function M.add_error(target, message)
  if type(message) == "string" and message ~= "" then
    target.errors[#target.errors + 1] = message
  end
end

function M.add_note(target, message, metadata)
  if type(message) == "string" and message ~= "" then
    if metadata then
      assert(type(metadata) == "table", "note metadata must be a table")
      assert(
        metadata.summary == nil or (type(metadata.summary) == "string" and metadata.summary ~= ""),
        "note summary must be a non-empty string"
      )
      assert(
        metadata.severity == nil or valid_note_severities[metadata.severity],
        "unsupported note severity: " .. tostring(metadata.severity)
      )
      assert(
        metadata.severity == nil or metadata.summary ~= nil,
        "note severity requires a summary"
      )
    end
    local index = #target.notes + 1
    target.notes[index] = message
    target.note_records = target.note_records or {}
    target.note_records[index] = {
      message = message,
      summary = metadata and metadata.summary or nil,
      severity = metadata and metadata.severity or nil,
    }
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

function M.set_provider_runs(target, runs)
  assert(type(target) == "table" and target.version == 1, "invalid graph snapshot")
  target.provider_runs = {}
  target.pending = {}
  for _, run in ipairs(runs or {}) do
    assert(type(run.id) == "string" and run.id ~= "", "provider runs require an id")
    assert(type(run.label) == "string" and run.label ~= "", "provider runs require a label")
    assert(valid_provider_states[run.state], "unsupported provider state: " .. tostring(run.state))
    for _, field in ipairs({ "elapsed_ms", "duration_ms", "retry_delay_ms" }) do
      local value = run[field]
      assert(
        value == nil or (type(value) == "number" and value >= 0),
        "provider run " .. field .. " must be a non-negative number"
      )
    end
    assert(
      run.message == nil or type(run.message) == "string",
      "provider run message must be a string"
    )
    local normalized = {
      id = run.id,
      label = run.label,
      state = run.state,
      elapsed_ms = run.elapsed_ms,
      duration_ms = run.duration_ms,
      retry_delay_ms = run.retry_delay_ms,
      message = run.message,
    }
    target.provider_runs[#target.provider_runs + 1] = normalized
    if pending_provider_states[normalized.state] then
      target.pending[#target.pending + 1] = { id = normalized.id, label = normalized.label }
    end
  end
end

function M.set_pending(target, providers)
  local runs = {}
  for _, provider in ipairs(providers or {}) do
    runs[#runs + 1] = {
      id = assert(provider.id, "pending providers require an id"),
      label = provider.label or provider.id,
      state = "queued",
    }
  end
  M.set_provider_runs(target, runs)
end

function M.merge(target, delta)
  assert(type(target) == "table" and target.version == 1, "invalid graph snapshot")
  assert(type(delta) == "table" and delta.version == 1, "invalid graph delta")
  for _, edge in ipairs(delta.edges or {}) do
    M.add_edge(target, edge)
  end
  vim.list_extend(target.errors, delta.errors or {})
  for index, note in ipairs(delta.notes or {}) do
    local record = delta.note_records and delta.note_records[index]
    local metadata = record and record.message == note and record or nil
    M.add_note(target, note, metadata)
  end
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

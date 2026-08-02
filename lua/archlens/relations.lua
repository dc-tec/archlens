local M = {}

local registry = {}
local allowed_fields = {
  corroborates = true,
  endpoint = true,
  id = true,
  kind_name = true,
  label = true,
  marker = true,
  order = true,
  sort = true,
  source = true,
  suppress_self = true,
}

local function nonempty_string(value)
  return type(value) == "string" and value:match("%S") ~= nil
end

local function validate(spec)
  assert(type(spec) == "table", "relation kind must be a table")
  for key in pairs(spec) do
    assert(allowed_fields[key], "unsupported relation kind field: " .. tostring(key))
  end
  assert(
    nonempty_string(spec.id) and spec.id:match("^[%l][%l%d_%-]*$"),
    "relation kind id must be a lowercase identifier"
  )
  assert(nonempty_string(spec.label), "relation kind label must be a non-empty string")
  assert(nonempty_string(spec.marker), "relation kind marker must be a non-empty string")
  assert(
    type(spec.order) == "number"
      and spec.order >= 0
      and spec.order < math.huge
      and spec.order == math.floor(spec.order),
    "relation kind order must be a non-negative integer"
  )
  assert(nonempty_string(spec.source), "relation kind source must be a non-empty string")
  assert(
    spec.endpoint == "source" or spec.endpoint == "target",
    "relation kind endpoint must be source or target"
  )
  assert(
    spec.sort == "location" or spec.sort == "name",
    "relation kind sort must be location or name"
  )
  if spec.kind_name ~= nil then
    assert(nonempty_string(spec.kind_name), "relation kind kind_name must be a non-empty string")
  end
  if spec.corroborates ~= nil then
    assert(nonempty_string(spec.corroborates), "relation kind corroborates must be an identifier")
  end
  if spec.suppress_self ~= nil then
    assert(type(spec.suppress_self) == "boolean", "relation kind suppress_self must be boolean")
  end

  return vim.deepcopy(spec)
end

function M.register(id_or_spec, maybe_spec)
  local candidate = id_or_spec
  if maybe_spec ~= nil then
    assert(nonempty_string(id_or_spec), "relation kind id must be a non-empty string")
    candidate = vim.deepcopy(maybe_spec)
    assert(type(candidate) == "table", "relation kind must be a table")
    assert(
      candidate.id == nil or candidate.id == id_or_spec,
      "relation kind id does not match registration id"
    )
    candidate.id = id_or_spec
  end

  local normalized = validate(candidate)
  if normalized.corroborates then
    assert(
      normalized.corroborates ~= normalized.id,
      "relation kind cannot corroborate itself: " .. normalized.id
    )
    assert(
      registry[normalized.corroborates] ~= nil,
      "unknown corroborated relation kind: " .. normalized.corroborates
    )
  end
  assert(
    registry[normalized.id] == nil,
    string.format("relation kind already registered: %s", normalized.id)
  )
  registry[normalized.id] = normalized
  return vim.deepcopy(normalized)
end

function M.get(id)
  return vim.deepcopy(registry[id])
end

function M.ordered()
  local kinds = {}
  for _, kind in pairs(registry) do
    kinds[#kinds + 1] = vim.deepcopy(kind)
  end
  table.sort(kinds, function(left, right)
    if left.order ~= right.order then
      return left.order < right.order
    end
    return left.id < right.id
  end)
  return kinds
end

for _, kind in ipairs({
  {
    id = "children",
    label = "Contains",
    marker = "└",
    order = 10,
    source = "syntax",
    endpoint = "target",
    sort = "location",
    suppress_self = true,
  },
  {
    id = "implementations",
    label = "Implementations",
    marker = "↳",
    order = 20,
    source = "semantic",
    endpoint = "target",
    sort = "location",
    kind_name = "Implementation",
    suppress_self = true,
  },
  {
    id = "incoming",
    label = "Entered through",
    marker = "←",
    order = 30,
    source = "semantic",
    endpoint = "source",
    sort = "name",
  },
  {
    id = "outgoing",
    label = "Touches",
    marker = "→",
    order = 40,
    source = "semantic",
    endpoint = "target",
    sort = "name",
  },
  {
    id = "references",
    label = "Referenced across project",
    marker = "◆",
    order = 50,
    source = "semantic",
    endpoint = "source",
    sort = "location",
    kind_name = "Reference",
    suppress_self = true,
  },
  {
    id = "structural",
    label = "Structural matches",
    marker = "≈",
    order = 60,
    source = "structural",
    endpoint = "source",
    sort = "location",
    kind_name = "Structural match",
    corroborates = "references",
    suppress_self = true,
  },
  {
    id = "siblings",
    label = "Nearby definitions",
    marker = "·",
    order = 70,
    source = "syntax",
    endpoint = "target",
    sort = "location",
    suppress_self = true,
  },
}) do
  M.register(kind)
end

return M

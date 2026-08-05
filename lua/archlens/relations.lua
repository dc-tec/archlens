local M = {}

local registry = {}
local allowed_fields = {
  anchor = true,
  corroborates = true,
  corroborates_by = true,
  endpoint = true,
  group_by = true,
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
  if spec.group_by ~= nil then
    assert(spec.group_by == "container", "relation kind group_by must be container")
  end
  if spec.corroborates ~= nil then
    assert(nonempty_string(spec.corroborates), "relation kind corroborates must be an identifier")
  end
  if spec.corroborates_by ~= nil then
    assert(spec.corroborates ~= nil, "relation kind corroborates_by requires corroborates")
    assert(
      spec.corroborates_by == "location" or spec.corroborates_by == "line",
      "relation kind corroborates_by must be location or line"
    )
  end
  if spec.suppress_self ~= nil then
    assert(type(spec.suppress_self) == "boolean", "relation kind suppress_self must be boolean")
  end
  if spec.anchor ~= nil then
    assert(spec.anchor == "file", "relation kind anchor must be file")
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
    id = "supertypes",
    label = "Supertypes",
    marker = "↑",
    order = 15,
    source = "semantic",
    endpoint = "target",
    sort = "name",
    suppress_self = true,
  },
  {
    id = "subtypes",
    label = "Subtypes",
    marker = "↓",
    order = 16,
    source = "semantic",
    endpoint = "source",
    sort = "name",
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
    corroborates = "subtypes",
    corroborates_by = "location",
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
    id = "workspace_members",
    label = "Workspace members",
    marker = "└",
    order = 44,
    source = "semantic",
    endpoint = "target",
    sort = "name",
    suppress_self = true,
  },
  {
    id = "module_imports",
    label = "Module dependencies",
    marker = "⇢",
    order = 45,
    source = "semantic",
    endpoint = "target",
    sort = "name",
    kind_name = "Module",
    anchor = "file",
    suppress_self = true,
  },
  {
    id = "module_importers",
    label = "Module dependents",
    marker = "⇠",
    order = 46,
    source = "semantic",
    endpoint = "source",
    sort = "name",
    kind_name = "Importer",
    anchor = "file",
    suppress_self = true,
  },
  {
    id = "build_dependencies",
    label = "Build dependencies",
    marker = "⇢",
    order = 47,
    source = "semantic",
    endpoint = "target",
    sort = "name",
    kind_name = "Build dependency",
    anchor = "file",
    suppress_self = true,
  },
  {
    id = "build_dependents",
    label = "Build dependents",
    marker = "⇠",
    order = 48,
    source = "semantic",
    endpoint = "source",
    sort = "name",
    kind_name = "Build dependent",
    anchor = "file",
    suppress_self = true,
  },
  {
    id = "test_dependencies",
    label = "Test dependencies",
    marker = "⇢",
    order = 47,
    source = "semantic",
    endpoint = "target",
    sort = "name",
    kind_name = "Test dependency",
    anchor = "file",
    suppress_self = true,
  },
  {
    id = "test_dependents",
    label = "Test dependents",
    marker = "⇠",
    order = 48,
    source = "semantic",
    endpoint = "source",
    sort = "name",
    kind_name = "Test dependent",
    anchor = "file",
    suppress_self = true,
  },
  {
    id = "configuration_consumers",
    label = "Configuration used at",
    marker = "↤",
    order = 49,
    source = "semantic",
    endpoint = "source",
    sort = "location",
    kind_name = "Configuration use",
    group_by = "container",
    suppress_self = true,
  },
  {
    id = "test_references",
    label = "Referenced from tests",
    marker = "◇",
    order = 50,
    source = "semantic",
    endpoint = "source",
    sort = "location",
    kind_name = "Test reference",
    group_by = "container",
    suppress_self = true,
  },
  {
    id = "references",
    label = "Referenced across project",
    marker = "◆",
    order = 51,
    source = "semantic",
    endpoint = "source",
    sort = "location",
    kind_name = "Reference",
    suppress_self = true,
  },
  {
    id = "test_structural",
    label = "Potential test matches",
    marker = "⋄",
    order = 59,
    source = "structural",
    endpoint = "source",
    sort = "location",
    kind_name = "Test match",
    corroborates = "test_references",
    corroborates_by = "line",
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
    corroborates_by = "line",
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

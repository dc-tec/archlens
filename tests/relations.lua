local source = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(source, ":p:h:h")
vim.opt.runtimepath:prepend(root)

local function equal(actual, expected, message)
  assert(vim.deep_equal(actual, expected), message or vim.inspect({ actual, expected }))
end

local relations = require("archlens.relations")

equal(relations.ordered(), {
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
})

local children = relations.get("children")
children.label = "mutated"
equal(relations.get("children").label, "Contains", "get should return an immutable copy")

local ordered = relations.ordered()
ordered[1].marker = "mutated"
table.remove(ordered, 2)
equal(relations.ordered()[1].marker, "└", "ordered should return deep copies")
equal(#relations.ordered(), 7, "mutating an ordered result must not mutate the registry")

local custom_input = {
  id = "dependencies",
  label = "Depends on",
  marker = "◇",
  order = 45,
  source = "semantic",
  endpoint = "target",
  sort = "location",
}
local custom = relations.register(custom_input)
custom_input.label = "mutated input"
custom.label = "mutated result"
equal(relations.get("dependencies"), {
  id = "dependencies",
  label = "Depends on",
  marker = "◇",
  order = 45,
  source = "semantic",
  endpoint = "target",
  sort = "location",
})
equal(relations.ordered()[5].id, "dependencies", "custom kinds should follow declared order")

local alias = relations.register("owns", {
  label = "Owns",
  marker = "+",
  order = 45,
  source = "custom",
  endpoint = "target",
  sort = "location",
})
equal(alias.id, "owns", "registration should accept an explicit id")
equal(
  vim.tbl_map(function(kind)
    return kind.id
  end, relations.ordered()),
  {
    "children",
    "implementations",
    "incoming",
    "outgoing",
    "dependencies",
    "owns",
    "references",
    "structural",
    "siblings",
  },
  "equal order values should be deterministic by id"
)

for _, kind in ipairs(relations.ordered()) do
  equal(kind.provider, nil, "relation metadata must not register provider behavior")
  equal(kind.render, nil, "relation metadata must not register render behavior")
end

local invalid = {
  { label = "Missing id", marker = "!", order = 80, source = "custom" },
  { id = "Invalid id", label = "Invalid id", marker = "!", order = 80, source = "custom" },
  { id = "missing_label", marker = "!", order = 80, source = "custom" },
  { id = "missing_marker", label = "Missing marker", order = 80, source = "custom" },
  { id = "bad_order", label = "Bad order", marker = "!", order = 1.5, source = "custom" },
  { id = "bad_source", label = "Bad source", marker = "!", order = 80, source = {} },
  {
    id = "bad_endpoint",
    label = "Bad endpoint",
    marker = "!",
    order = 80,
    source = "custom",
    endpoint = "related",
  },
  {
    id = "bad_sort",
    label = "Bad sort",
    marker = "!",
    order = 80,
    source = "custom",
    sort = "random",
  },
  {
    id = "bad_suppression",
    label = "Bad suppression",
    marker = "!",
    order = 80,
    source = "custom",
    suppress_self = "yes",
  },
  {
    id = "provider_behavior",
    label = "Provider behavior",
    marker = "!",
    order = 80,
    source = "custom",
    provider = function() end,
  },
  {
    id = "render_behavior",
    label = "Render behavior",
    marker = "!",
    order = 80,
    source = "custom",
    render = function() end,
  },
  {
    id = "self_corroboration",
    label = "Self corroboration",
    marker = "!",
    order = 80,
    source = "custom",
    corroborates = "self_corroboration",
  },
  {
    id = "unknown_corroboration",
    label = "Unknown corroboration",
    marker = "!",
    order = 80,
    source = "custom",
    corroborates = "missing_relation",
  },
}
for _, kind in ipairs(invalid) do
  kind.endpoint = kind.endpoint or "target"
  kind.sort = kind.sort or "location"
end
for _, kind in ipairs(invalid) do
  local ok = pcall(relations.register, kind)
  equal(ok, false, "invalid relation metadata should be rejected: " .. vim.inspect(kind))
end

local duplicate_ok = pcall(relations.register, {
  id = "children",
  label = "Duplicate",
  marker = "!",
  order = 80,
  source = "custom",
  endpoint = "target",
  sort = "location",
})
equal(duplicate_ok, false, "registered relation ids must remain immutable")
equal(relations.get("missing"), nil, "unknown relation ids should return nil")

print("archlens relation registry tests passed")
vim.cmd("quitall")

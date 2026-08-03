local source = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(source, ":p:h:h")
vim.opt.runtimepath:prepend(root)

local function equal(actual, expected, message)
  if not vim.deep_equal(actual, expected) then
    error(
      string.format(
        "%s\nexpected: %s\nactual:   %s",
        message,
        vim.inspect(expected),
        vim.inspect(actual)
      )
    )
  end
end

local graph = require("archlens.graph")
local model = require("archlens.model")
local uri = "file:///workspace/main.lua"
local function location(line)
  return {
    uri = uri,
    range = {
      start = { line = line, character = 0 },
      ["end"] = { line = line, character = 4 },
    },
  }
end

local context = {
  name = "focus",
  kind_name = "Function",
  position_encoding = "utf-8",
  root_dir = "/workspace",
  location = location(0),
  syntax = { provider = "Tree-sitter", ancestors = {}, children = {}, siblings = {} },
}
local snapshot = graph.new(context)
local focus = snapshot.focus
local function related(name, line)
  return graph.node_from_location(location(line), { name = name, kind_name = "Function" })
end
local function add(kind, source_node, target_node)
  graph.add_edge(
    snapshot,
    graph.edge(kind, source_node, target_node, {
      provider = "test-lsp",
      method = "test/" .. kind,
      class = "semantic",
    })
  )
end

add("incoming", related("caller", 1), focus)
add("outgoing", focus, related("callee", 2))
add("references", related("reference", 3), focus)
add("siblings", focus, related("sibling", 4))

local mapped = model.build(context, snapshot, {
  include_external = true,
  sections = {
    hidden = { "references" },
    order = { "outgoing", "incoming", "unknown_relation" },
  },
})
local ids = vim.tbl_map(function(section)
  return section.id
end, mapped.sections)
equal(
  ids,
  { "outgoing", "incoming", "siblings" },
  "explicit section order should lead while unspecified relations retain registry order"
)
assert(
  table.concat(mapped.notes, "\n"):find("1 relationship hidden by section policy.", 1, true),
  "model-level hiding should remain visible as an exact omission note"
)

local all_hidden = model.build(context, snapshot, {
  include_external = true,
  sections = { hidden = { "incoming", "outgoing", "references", "siblings" } },
})
equal(all_hidden.sections, {}, "hidden sections should leave navigation and details with no rows")
assert(
  table.concat(all_hidden.notes, "\n"):find("4 relationships hidden by section policy.", 1, true),
  "hiding every section should not fall back to an inaccurate empty-result message"
)

print("archlens.nvim section policy tests passed")
vim.cmd("quitall!")

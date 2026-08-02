local source = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(source, ":p:h:h")
vim.opt.runtimepath:prepend(root)

local function equal(actual, expected, message)
  assert(vim.deep_equal(actual, expected), message or vim.inspect({ actual, expected }))
end

local graph = require("archlens.graph")

local uri = "file:///workspace/main.go"
local function location(line, character, finish)
  return {
    uri = uri,
    range = {
      start = { line = line, character = character or 0 },
      ["end"] = { line = line, character = finish or (character or 0) + 1 },
    },
  }
end

local child = {
  name = "Child",
  kind_name = "Function",
  location = location(1),
  path = "/workspace/main.go",
  path_label = "main.go",
  line = 2,
}
local context = {
  client_id = 7,
  client_name = "gopls",
  name = "Current",
  kind = vim.lsp.protocol.SymbolKind.Function,
  kind_name = "Function",
  location = location(0),
  path = "/workspace/main.go",
  path_label = "main.go",
  line = 1,
  position_encoding = "utf-8",
  syntax = {
    provider = "Tree-sitter",
    children = { child },
    siblings = {},
  },
}

local snapshot = graph.new(context)
equal(snapshot.version, 1)
equal(#snapshot.edges, 1, "syntax relationships should seed the focused snapshot")
equal(snapshot.edges[1].kind, "children")
equal(snapshot.edges[1].source.name, "Current")
equal(snapshot.edges[1].target.name, "Child")
equal(snapshot.edges[1].evidence, {
  provider = "Tree-sitter",
  method = "children",
  class = "syntax",
})
equal(snapshot.contributors, {
  { id = "lsp:7", label = "gopls" },
  { id = "syntax", label = "Tree-sitter" },
})

local delta = graph.delta()
local implementation = graph.node_from_location({
  uri = uri,
  range = location(4, 5, 12).range,
  full_range = location(4).range,
}, {
  kind_name = "Implementation",
})
graph.add_edge(
  delta,
  graph.edge("implementations", snapshot.focus, implementation, {
    provider = "gopls",
    method = "textDocument/implementation",
    class = "semantic",
  })
)
graph.add_error(delta, "provider error")
graph.add_note(delta, "provider note")
graph.add_omitted(delta, "structural", 2)
graph.add_contributor(delta, "lsp:7", "gopls")
graph.add_contributor(delta, "ast_grep", "ast-grep")
graph.merge(snapshot, delta)
equal(#snapshot.edges, 2)
equal(snapshot.edges[2].target.location.range, location(4, 5, 12).range)
equal(snapshot.edges[2].target.location.full_range, location(4).range)
equal(snapshot.errors, { "provider error" })
equal(snapshot.notes, { "provider note" })
equal(snapshot.omitted, { structural = 2 })
equal(snapshot.contributors, {
  { id = "lsp:7", label = "gopls" },
  { id = "syntax", label = "Tree-sitter" },
  { id = "ast_grep", label = "ast-grep" },
})

local second_delta = graph.delta()
graph.add_omitted(second_delta, "structural", 3)
graph.merge(snapshot, second_delta)
equal(snapshot.omitted, { structural = 5 }, "omitted counts should accumulate across providers")

graph.set_pending(snapshot, {
  { id = "lsp", label = "gopls" },
  { id = "ast_grep", label = "ast-grep" },
})
equal(snapshot.pending, {
  { id = "lsp", label = "gopls" },
  { id = "ast_grep", label = "ast-grep" },
})

local returned = graph.related_node(snapshot.edges[2])
returned.kind_name = "mutated"
equal(
  snapshot.edges[2].target.kind_name,
  "mutated",
  "graph navigation should preserve node identity inside a snapshot"
)

for _, invalid in ipairs({
  function()
    graph.node({ scope = "unknown", id = "invalid" })
  end,
  function()
    graph.node_from_location({
      targetUri = uri,
      targetRange = location(4).range,
      targetSelectionRange = location(4, 5, 12).range,
    })
  end,
  function()
    graph.edge("unknown", snapshot.focus, implementation, {
      provider = "test",
      method = "test",
      class = "semantic",
    })
  end,
  function()
    graph.edge("implementations", snapshot.focus, implementation, {
      provider = "test",
      method = "test",
    })
  end,
  function()
    graph.edge("implementations", snapshot.focus, implementation, {
      provider = "test",
      method = "test",
      class = "semantic",
    }, { position_encoding = "utf-16" })
  end,
  function()
    local malformed = graph.edge("implementations", snapshot.focus, implementation, {
      provider = "test",
      method = "test",
      class = "semantic",
    })
    malformed.targetUri = uri
    graph.add_edge(graph.delta(), malformed)
  end,
  function()
    local malformed = graph.edge("implementations", snapshot.focus, implementation, {
      provider = "test",
      method = "test",
      class = "semantic",
    })
    malformed.target.location.targetUri = uri
    graph.add_edge(graph.delta(), malformed)
  end,
  function()
    local malformed = graph.edge("implementations", snapshot.focus, implementation, {
      provider = "test",
      method = "test",
      class = "semantic",
    }, {
      occurrences = { { originSelectionRange = location(4).range } },
    })
    graph.add_edge(graph.delta(), malformed)
  end,
  function()
    local other_focus = graph.node_from_location(location(9), { name = "Other" })
    local mismatched = graph.edge("implementations", other_focus, implementation, {
      provider = "test",
      method = "test",
      class = "semantic",
    })
    graph.add_edge(snapshot, mismatched)
  end,
}) do
  equal(pcall(invalid), false, "invalid graph values should be rejected")
end

local wire_item = {
  name = "Opaque LSP item",
  uri = uri,
  range = location(8).range,
  selectionRange = location(8).range,
  data = { targetUri = "opaque-provider-state" },
}
local wire_focus = graph.node({
  id = "wire-focus",
  scope = "symbol",
  context = { wire_call_item = wire_item },
})
local wire_edge = graph.edge("outgoing", wire_focus, implementation, {
  provider = "test",
  method = "callHierarchy/outgoingCalls",
  class = "semantic",
})
equal(
  pcall(graph.add_edge, graph.delta(), wire_edge),
  true,
  "opaque wire call items should be allowed"
)
assert(
  wire_edge.source.context.wire_call_item == wire_item,
  "opaque wire call items should preserve identity"
)

print("archlens relationship graph tests passed")
vim.cmd("quitall")

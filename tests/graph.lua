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
equal(snapshot.edges[1].occurrences, {}, "graph edges should always expose occurrence arrays")
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

local file_source = graph.node({
  name = "main.go",
  scope = "file",
  location = location(0, 0, 0),
})
local imported_module = graph.node_from_location(location(7), {
  name = "internal/storage",
  scope = "module",
})
local file_import = graph.edge("module_imports", file_source, imported_module, {
  provider = "Tree-sitter",
  method = "adapter/moduleTarget",
  class = "semantic",
})
equal(
  pcall(graph.add_edge, snapshot, file_import),
  true,
  "file-context edges should belong to every symbol focused in the same file"
)

local importing_file = graph.node({
  name = "consumer.go",
  scope = "file",
  location = {
    uri = "file:///workspace/consumer.go",
    range = location(3).range,
  },
})
local focused_file = graph.node({
  name = "source.go",
  scope = "file",
  location = location(0, 0, 0),
})
local imported_by = graph.edge("module_importers", importing_file, focused_file, {
  provider = "Tree-sitter",
  method = "adapter/moduleTarget",
  class = "semantic",
})
equal(
  graph.related_node(imported_by),
  importing_file,
  "module dependents should navigate to the dependent source"
)
equal(
  graph.focus_node(imported_by),
  focused_file,
  "module dependents should remain anchored to the dependency target"
)
equal(
  pcall(graph.add_edge, snapshot, imported_by),
  true,
  "module-dependent edges should be accepted for the focused file"
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
    malformed.presentation = { container = { id = "missing-fields" } }
    graph.add_edge(graph.delta(), malformed)
  end,
  function()
    local malformed = graph.edge("implementations", snapshot.focus, implementation, {
      provider = "test",
      method = "test",
      class = "semantic",
    })
    malformed.presentation = { section_anchor = { prefix = "from" } }
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
  function()
    local foreign_file = graph.node({
      name = "foreign.go",
      scope = "file",
      location = {
        uri = "file:///workspace/foreign.go",
        range = location(0).range,
      },
    })
    graph.add_edge(
      snapshot,
      graph.edge("module_imports", foreign_file, imported_module, {
        provider = "Tree-sitter",
        method = "adapter/moduleTarget",
        class = "semantic",
      })
    )
  end,
  function()
    local foreign_target = graph.node({
      name = "foreign.go",
      scope = "file",
      location = {
        uri = "file:///workspace/foreign.go",
        range = location(0).range,
      },
    })
    graph.add_edge(
      snapshot,
      graph.edge("module_importers", importing_file, foreign_target, {
        provider = "Tree-sitter",
        method = "adapter/moduleTarget",
        class = "semantic",
      })
    )
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

local supertype = graph.node_from_location(location(10), { name = "Base" })
local subtype = graph.node_from_location(location(11), { name = "Derived" })
local supertype_edge = graph.edge("supertypes", snapshot.focus, supertype, {
  provider = "gopls",
  method = "typeHierarchy/supertypes",
  class = "semantic",
})
local subtype_edge = graph.edge("subtypes", subtype, snapshot.focus, {
  provider = "gopls",
  method = "typeHierarchy/subtypes",
  class = "semantic",
})
equal(graph.related_node(supertype_edge).name, "Base", "supertypes should point upward")
equal(graph.focus_node(supertype_edge).name, "Current", "supertype edges should retain focus")
equal(graph.related_node(subtype_edge).name, "Derived", "subtypes should point downward")
equal(graph.focus_node(subtype_edge).name, "Current", "subtype edges should retain focus")

local wire_type_item = vim.tbl_extend("force", vim.deepcopy(wire_item), {
  data = { targetUri = "opaque-type-state" },
})
local type_focus = graph.node({
  id = "type-focus",
  scope = "symbol",
  context = { wire_type_item = wire_type_item },
})
local focused_type_edge = graph.edge("supertypes", type_focus, supertype, {
  provider = "gopls",
  method = "typeHierarchy/supertypes",
  class = "semantic",
})
equal(
  pcall(graph.add_edge, graph.delta(), focused_type_edge),
  true,
  "opaque wire type items should be allowed"
)
assert(
  focused_type_edge.source.context.wire_type_item == wire_type_item,
  "opaque wire type items should preserve identity"
)

print("archlens relationship graph tests passed")
vim.cmd("quitall")

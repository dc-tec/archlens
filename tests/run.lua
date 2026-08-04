local source = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(source, ":p:h:h")
vim.opt.runtimepath:prepend(root)

local function assert_equal(actual, expected, message)
  if not vim.deep_equal(actual, expected) then
    error(
      string.format(
        "%s\nexpected: %s\nactual:   %s",
        message or "values differ",
        vim.inspect(expected),
        vim.inspect(actual)
      )
    )
  end
end

local function contains(lines, expected)
  for _, line in ipairs(lines) do
    if line:find(expected, 1, true) then
      return true
    end
  end
  return false
end

local function run()
  local model = require("archlens.model")
  local graph = require("archlens.graph")
  local render = require("archlens.render")
  local performance = require("archlens.performance")
  local view = require("archlens.view")

  local current_time = 100
  local measurement = performance.start(function()
    return current_time
  end)
  current_time = 112
  performance.observe(measurement, { sections = {} })
  assert_equal(
    performance.snapshot(measurement),
    {},
    "status-only renders should not count as a useful relationship"
  )
  current_time = 125
  performance.observe(measurement, { sections = { { rows = { { id = "first" } } } } })
  assert_equal(
    performance.snapshot(measurement),
    { first_result_ms = 25 },
    "the first relationship should record elapsed monotonic time"
  )
  current_time = 150
  performance.observe(measurement, { sections = { { rows = { { id = "later" } } } } })
  assert_equal(
    performance.snapshot(measurement),
    { first_result_ms = 25 },
    "later renders should not replace the first-result measurement"
  )

  local position = { line = 4, character = 3 }
  local symbols = {
    {
      name = "outer",
      kind = vim.lsp.protocol.SymbolKind.Function,
      range = { start = { line = 0, character = 0 }, ["end"] = { line = 10, character = 0 } },
      selectionRange = {
        start = { line = 0, character = 0 },
        ["end"] = { line = 0, character = 5 },
      },
      children = {
        {
          name = "inner",
          kind = vim.lsp.protocol.SymbolKind.Function,
          range = { start = { line = 3, character = 0 }, ["end"] = { line = 6, character = 0 } },
          selectionRange = {
            start = { line = 3, character = 0 },
            ["end"] = { line = 3, character = 5 },
          },
        },
      },
    },
  }
  assert_equal(
    model.select_document_symbol(symbols, position, "file:///tmp/example.go").name,
    "inner",
    "the innermost document symbol should win"
  )
  assert(
    not model.range_contains(
      { start = { line = 1, character = 0 }, ["end"] = { line = 2, character = 0 } },
      { line = 2, character = 0 }
    ),
    "LSP range ends should be exclusive"
  )

  local context = model.context_from_item({
    name = "Reconcile",
    kind = vim.lsp.protocol.SymbolKind.Method,
    uri = "file:///workspace/internal/controller/reconcile.go",
    range = { start = { line = 10, character = 0 }, ["end"] = { line = 20, character = 0 } },
    selectionRange = {
      start = { line = 10, character = 5 },
      ["end"] = { line = 10, character = 14 },
    },
  }, {
    id = 1,
    name = "gopls",
    offset_encoding = "utf-8",
    root_dir = "/workspace",
    supports_calls = true,
  })
  context.language = "go"

  local function call_context(name, uri, line)
    return model.context_from_item({
      name = name,
      kind = vim.lsp.protocol.SymbolKind.Function,
      uri = uri,
      range = {
        start = { line = line, character = 0 },
        ["end"] = { line = line + 2, character = 0 },
      },
      selectionRange = {
        start = { line = line, character = 0 },
        ["end"] = { line = line, character = 4 },
      },
    }, {
      id = context.client_id,
      name = context.client_name,
      offset_encoding = "utf-8",
      root_dir = context.root_dir,
      supports_calls = true,
    })
  end

  local function add_outgoing(snapshot, name, uri, line)
    graph.add_edge(
      snapshot,
      graph.edge(
        "outgoing",
        snapshot.focus,
        graph.node_from_context(call_context(name, uri, line)),
        {
          provider = "gopls",
          method = "callHierarchy/outgoingCalls",
          class = "semantic",
        }
      )
    )
  end

  local function add_incoming(snapshot, name, uri, line, ranges)
    graph.add_edge(
      snapshot,
      graph.edge(
        "incoming",
        graph.node_from_context(call_context(name, uri, line)),
        snapshot.focus,
        {
          provider = "gopls",
          method = "callHierarchy/incomingCalls",
          class = "semantic",
        },
        { occurrences = { { uri = uri, ranges = ranges } } }
      )
    )
  end

  local function add_location(snapshot, kind, location, fields, provider, edge_fields)
    local related = graph.node_from_location(location, fields)
    local reverse = kind == "references"
      or kind == "structural"
      or kind == "test_references"
      or kind == "test_structural"
    local structural = kind == "structural" or kind == "test_structural"
    local source = reverse and related or snapshot.focus
    local target = reverse and snapshot.focus or related
    graph.add_edge(
      snapshot,
      graph.edge(kind, source, target, {
        provider = provider or (structural and "ast-grep" or "gopls"),
        method = kind == "implementations" and "textDocument/implementation"
          or (kind == "references" or kind == "test_references") and "textDocument/references"
          or "structural",
        class = structural and "structural" or "semantic",
      }, edge_fields)
    )
  end

  local relationships = graph.new(context)
  add_outgoing(relationships, "Read", "file:///workspace/internal/storage/store.go", 8)
  add_outgoing(relationships, "Read", "file:///workspace/internal/storage/store.go", 8)
  add_outgoing(relationships, "Write", "file:///workspace/internal/storage/store.go", 8)
  add_outgoing(relationships, "Println", "file:///usr/local/go/src/fmt/print.go", 20)
  local mapped = model.build(context, relationships, { include_external = false })
  assert_equal(#mapped.sections, 1, "only a non-empty outgoing section should be shown")
  assert_equal(
    #mapped.sections[1].rows,
    2,
    "identical calls should collapse without merging distinct symbols at one location"
  )
  assert(
    contains(mapped.notes, "1 external relationship hidden."),
    "hidden external calls should be explicit"
  )
  assert_equal(mapped.result.parts, { { label = "1 filtered", severity = "info" } })
  assert_equal(mapped.result.severity, "info", "filter-only summaries should stay informational")

  local scoped_graph = graph.new(context)
  add_outgoing(scoped_graph, "Vendored", "file:///workspace/vendor/example/client.go", 2)
  add_outgoing(scoped_graph, "Generated", "file:///workspace/internal/zz_generated.client.go", 3)
  add_outgoing(scoped_graph, "Excluded", "file:///workspace/internal/legacy/client.go", 4)
  add_outgoing(scoped_graph, "Project", "file:///workspace/internal/client.go", 5)
  graph.add_note(
    scoped_graph,
    "Project module discovery reached the 2000-candidate limit; module-dependent results may be incomplete.",
    { summary = "module scan limited", severity = "warn" }
  )
  local scoped = model.build(context, scoped_graph, {
    filters = { exclude = { "internal/legacy" } },
  })
  assert_equal(#scoped.sections[1].rows, 1, "default scope filters should retain project source")
  assert_equal(scoped.sections[1].rows[1].name, "Project")
  assert(contains(scoped.notes, "1 vendored relationship hidden."))
  assert(contains(scoped.notes, "1 generated relationship hidden."))
  assert(contains(scoped.notes, "1 excluded relationship hidden."))
  assert_equal(scoped.result.parts, {
    { label = "module scan limited", severity = "warn" },
    { label = "3 filtered", severity = "info" },
  })
  assert_equal(scoped.result.severity, "warn")

  local duplicate_note_graph = graph.new(context)
  graph.add_note(
    duplicate_note_graph,
    "same provider note",
    { summary = "benign duplicate", severity = "info" }
  )
  graph.add_note(
    duplicate_note_graph,
    "same provider note",
    { summary = "warning retained", severity = "warn" }
  )
  local duplicate_note_model = model.build(context, duplicate_note_graph, {})
  assert_equal(duplicate_note_model.result.parts, {
    { label = "warning retained", severity = "warn" },
    { label = "benign duplicate", severity = "info" },
  }, "duplicate note text should retain warning metadata regardless of arrival order")
  assert_equal(duplicate_note_model.result.severity, "warn")

  local included_scope = model.build(context, scoped_graph, {
    filters = {
      include_generated = true,
      include_vendored = true,
      exclude = { "internal/legacy" },
    },
  })
  assert_equal(
    #included_scope.sections[1].rows,
    3,
    "vendored and generated relationships should be recoverable through configuration"
  )
  assert(contains(included_scope.notes, "1 excluded relationship hidden."))

  local empty = model.build(context, graph.new(context), { include_external = false })
  assert(
    contains(empty.notes, "No local or project relationships were returned."),
    "an empty map should be explained"
  )

  local function type_node(name, line)
    local item = {
      name = name,
      kind = vim.lsp.protocol.SymbolKind.Interface,
      uri = context.location.uri,
      range = {
        start = { line = line, character = 0 },
        ["end"] = { line = line + 1, character = 0 },
      },
      selectionRange = {
        start = { line = line, character = 5 },
        ["end"] = { line = line, character = 5 + #name },
      },
    }
    local related_context = model.context_from_item(item, {
      id = context.client_id,
      name = context.client_name,
      offset_encoding = "utf-8",
      root_dir = context.root_dir,
      supports_calls = false,
    })
    related_context.wire_type_item = item
    return graph.node_from_context(related_context)
  end

  local hierarchy_graph = graph.new(context)
  graph.add_edge(
    hierarchy_graph,
    graph.edge("supertypes", hierarchy_graph.focus, type_node("Base", 2), {
      provider = "gopls",
      method = "typeHierarchy/supertypes",
      class = "semantic",
    })
  )
  local derived_type = type_node("Derived", 24)
  graph.add_edge(
    hierarchy_graph,
    graph.edge("subtypes", derived_type, hierarchy_graph.focus, {
      provider = "gopls",
      method = "typeHierarchy/subtypes",
      class = "semantic",
    })
  )
  add_location(hierarchy_graph, "implementations", vim.deepcopy(derived_type.location))
  graph.add_edge(
    hierarchy_graph,
    graph.edge("supertypes", hierarchy_graph.focus, hierarchy_graph.focus, {
      provider = "gopls",
      method = "typeHierarchy/supertypes",
      class = "semantic",
    })
  )
  add_location(hierarchy_graph, "implementations", {
    uri = context.location.uri,
    range = {
      start = { line = 28, character = 5 },
      ["end"] = { line = 28, character = 12 },
    },
  })
  local hierarchy_map = model.build(context, hierarchy_graph, { include_external = false })
  assert_equal(
    vim.tbl_map(function(section)
      return section.id
    end, hierarchy_map.sections),
    { "supertypes", "subtypes", "implementations" },
    "type hierarchy sections should stay adjacent ahead of implementations"
  )
  assert_equal(#hierarchy_map.sections[1].rows, 1, "self-referential supertypes should be hidden")
  assert_equal(hierarchy_map.sections[1].rows[1].name, "Base")
  assert_equal(hierarchy_map.sections[2].rows[1].name, "Derived")
  assert_equal(
    #hierarchy_map.sections[3].rows,
    1,
    "exact subtype duplicates should be removed from implementations"
  )
  local hierarchy_render = render.build(hierarchy_map, { width = 80 })
  assert(contains(hierarchy_render.lines, "▾ Supertypes  1"), "supertypes should render")
  assert(contains(hierarchy_render.lines, "  ↑ Base"), "supertypes should use the upward marker")
  assert(contains(hierarchy_render.lines, "▾ Subtypes  1"), "subtypes should render")
  assert(
    contains(hierarchy_render.lines, "  ↓ Derived"),
    "subtypes should use the downward marker"
  )

  local go_type_context = vim.deepcopy(context)
  go_type_context.name = "ClusterActions"
  go_type_context.kind = vim.lsp.protocol.SymbolKind.Interface
  go_type_context.kind_name = "Interface"
  go_type_context.language = "go"
  go_type_context.supports_calls = false
  go_type_context.syntax_node_type = "type_spec"
  go_type_context.syntax = {
    provider = "Tree-sitter",
    ancestors = {},
    children = {
      vim.tbl_extend("force", call_context("IsHealthy", context.location.uri, 11), {
        kind = vim.lsp.protocol.SymbolKind.Method,
        kind_name = "Method",
      }),
    },
    siblings = {},
  }
  local go_type_graph = graph.new(go_type_context)
  local function related_type(name, line, kind)
    local item = {
      name = name,
      kind = kind,
      uri = context.location.uri,
      range = {
        start = { line = line, character = 0 },
        ["end"] = { line = line + 1, character = 0 },
      },
      selectionRange = {
        start = { line = line, character = 5 },
        ["end"] = { line = line, character = 5 + #name },
      },
    }
    local related_context = model.context_from_item(item, {
      id = context.client_id,
      name = context.client_name,
      offset_encoding = "utf-8",
      root_dir = context.root_dir,
      supports_calls = false,
    })
    related_context.language = "go"
    related_context.wire_type_item = item
    return graph.node_from_context(related_context)
  end
  local satisfied = related_type("ScaleDownPodClient", 40, vim.lsp.protocol.SymbolKind.Interface)
  local extended = related_type("RaftActions", 50, vim.lsp.protocol.SymbolKind.Interface)
  local implemented = related_type("Client", 60, vim.lsp.protocol.SymbolKind.Struct)
  graph.add_edge(
    go_type_graph,
    graph.edge("supertypes", go_type_graph.focus, satisfied, {
      provider = "gopls",
      method = "typeHierarchy/supertypes",
      class = "semantic",
    })
  )
  for _, related in ipairs({ extended, implemented }) do
    graph.add_edge(
      go_type_graph,
      graph.edge("subtypes", related, go_type_graph.focus, {
        provider = "gopls",
        method = "typeHierarchy/subtypes",
        class = "semantic",
      })
    )
  end
  add_location(go_type_graph, "implementations", vim.deepcopy(implemented.location), {
    name = "type Client struct {",
  })
  add_location(go_type_graph, "implementations", {
    uri = context.location.uri,
    range = {
      start = { line = 70, character = 0 },
      ["end"] = { line = 70, character = 18 },
    },
  }, { name = "type Adapter struct {" })
  add_location(go_type_graph, "structural", {
    uri = context.location.uri,
    range = {
      start = { line = 80, character = 0 },
      ["end"] = { line = 80, character = 14 },
    },
  }, { name = "ClusterActions" })
  local go_type_map = model.build(go_type_context, go_type_graph, {})
  assert_equal(
    vim.tbl_map(function(section)
      return { section.id, section.view_id, section.label }
    end, go_type_map.sections),
    {
      { "children", "children", "Members" },
      { "supertypes", "supertypes:satisfies", "Satisfies" },
      { "subtypes", "subtypes:extended", "Extended by" },
      { "subtypes", "subtypes:implemented", "Implemented by" },
      { "implementations", "implementations", "Implementations" },
      { "structural", "structural", "Structural matches" },
    },
    "Go type roles should project into independently addressable view sections"
  )
  assert_equal(
    go_type_map.sections[5].rows[1].name,
    "Adapter",
    "Go implementation declarations should render as concise type names"
  )
  assert(
    go_type_map.sections[6].default_collapsed,
    "semantic type relationships should make structural matches secondary"
  )
  assert(
    not contains(go_type_map.notes, "has no call hierarchy here"),
    "type focuses should not report an inapplicable call hierarchy"
  )
  local go_type_render = render.build(go_type_map, { width = 100 })
  assert(contains(go_type_render.lines, "▾ Members  1"), "type children should render as members")
  assert(contains(go_type_render.lines, "▾ Satisfies  1"), "Go parent contracts should render")
  assert(
    contains(go_type_render.lines, "▾ Extended by  1"),
    "Go interface extensions should render"
  )
  assert(
    contains(go_type_render.lines, "  ↓ RaftActions  Interface"),
    "projected type rows should retain their related kind"
  )
  assert(
    contains(go_type_render.lines, "▾ Implemented by  1"),
    "Go concrete type-hierarchy results should render as implementations"
  )
  local collapsed_go_types = render.build(go_type_map, {
    width = 100,
    collapsed = { subtypes = true },
  })
  assert(
    contains(collapsed_go_types.lines, "▸ Extended by  1")
      and contains(collapsed_go_types.lines, "▸ Implemented by  1"),
    "canonical collapse policy should apply to every projected relation section"
  )

  local no_call_context = vim.deepcopy(context)
  no_call_context.supports_calls = false
  local no_call_map = model.build(no_call_context, graph.new(no_call_context), {})
  assert(
    contains(no_call_map.notes, "has no call hierarchy here"),
    "callable focuses should still explain unavailable call hierarchy"
  )

  local ocaml_type_context = vim.deepcopy(go_type_context)
  ocaml_type_context.name = "pull"
  ocaml_type_context.kind = vim.lsp.protocol.SymbolKind.TypeParameter
  ocaml_type_context.kind_name = "Type"
  ocaml_type_context.language = "ocaml"
  ocaml_type_context.location.range = {
    start = { line = 10, character = 5 },
    ["end"] = { line = 10, character = 9 },
  }
  local ocaml_type_graph = graph.new(ocaml_type_context)
  add_location(ocaml_type_graph, "references", {
    uri = ocaml_type_context.location.uri,
    range = {
      start = { line = 10, character = 0 },
      ["end"] = { line = 10, character = 11 },
    },
  }, { name = "type pull =" })
  add_location(ocaml_type_graph, "references", {
    uri = ocaml_type_context.location.uri,
    range = {
      start = { line = 20, character = 8 },
      ["end"] = { line = 20, character = 12 },
    },
  }, { name = "pull" })
  local ocaml_type_map = model.build(ocaml_type_context, ocaml_type_graph, {})
  assert_equal(
    #ocaml_type_map.sections[1].rows,
    1,
    "overlapping type declarations should be suppressed while real references remain"
  )

  local implementation_context = vim.deepcopy(context)
  implementation_context.syntax = {
    provider = "Tree-sitter",
    ancestors = {},
    children = {
      {
        name = "nested",
        kind_name = "Function",
        location = {
          uri = context.location.uri,
          range = {
            start = { line = 12, character = 2 },
            ["end"] = { line = 14, character = 2 },
          },
        },
        path_label = context.path_label,
        line = 13,
      },
    },
    siblings = {},
  }
  local implementation_link = {
    uri = "file:///workspace/internal/storage/store.go",
    full_range = {
      start = { line = 7, character = 0 },
      ["end"] = { line = 14, character = 1 },
    },
    range = {
      start = { line = 8, character = 2 },
      ["end"] = { line = 8, character = 10 },
    },
  }
  local implementation_graph = graph.new(implementation_context)
  add_location(implementation_graph, "implementations", implementation_link)
  add_location(
    implementation_graph,
    "implementations",
    vim.deepcopy(implementation_link),
    nil,
    "other-lsp",
    {
      occurrences = { { uri = context.location.uri, ranges = { context.location.range } } },
    }
  )
  graph.add_contributor(implementation_graph, "lsp:2", "other-lsp")
  add_location(implementation_graph, "implementations", vim.deepcopy(context.location))
  add_location(implementation_graph, "implementations", {
    uri = "file:///usr/local/go/src/example/external.go",
    range = {
      start = { line = 3, character = 0 },
      ["end"] = { line = 3, character = 8 },
    },
  })
  add_outgoing(implementation_graph, "Read", "file:///workspace/internal/storage/store.go", 18)
  local implementation_map =
    model.build(implementation_context, implementation_graph, { include_external = false })
  assert_equal(
    vim.tbl_map(function(section)
      return section.id
    end, implementation_map.sections),
    { "children", "implementations", "outgoing" },
    "implementations should appear immediately after local containment"
  )
  local implementation_section = implementation_map.sections[2]
  assert_equal(#implementation_section.rows, 1, "implementation locations should deduplicate")
  assert_equal(
    implementation_section.rows[1].location.range,
    implementation_link.range,
    "LocationLink selection ranges should identify the implementation symbol"
  )
  assert_equal(
    implementation_section.rows[1].kind_name,
    "Implementation",
    "implementation rows should retain their relationship type"
  )
  assert_equal(implementation_section.rows[1].evidence, {
    provider = "gopls+other-lsp",
    method = "textDocument/implementation",
    class = "semantic",
  }, "implementation provenance should remain semantic and provider-specific")
  assert_equal(implementation_section.rows[1].evidence_records, {
    {
      provider = "gopls",
      method = "textDocument/implementation",
      class = "semantic",
    },
    {
      provider = "other-lsp",
      method = "textDocument/implementation",
      class = "semantic",
    },
  }, "duplicate semantic providers should retain independent evidence")
  assert_equal(
    #implementation_section.rows[1].occurrences,
    1,
    "duplicate semantic edges should merge their occurrences"
  )
  assert(
    implementation_section.rows[1].resolve_on_focus,
    "implementation locations should resolve when focused"
  )
  assert(
    contains(implementation_map.notes, "1 external relationship hidden."),
    "external implementations should follow the existing project boundary"
  )
  local implementation_render = render.build(implementation_map, { width = 80 })
  assert(
    contains(implementation_render.lines, "▾ Implementations  1"),
    "the generic renderer should show the implementation section"
  )
  assert(
    contains(implementation_render.lines, "  ↳ Reconcile"),
    "the generic renderer should apply the implementation marker"
  )
  assert(
    contains(implementation_render.lines, "internal/storage/store.go:9 · gopls"),
    "implementation rows should show compact location provenance"
  )

  local reference_location = {
    uri = "file:///workspace/internal/controller/reconcile.go",
    range = {
      start = { line = 30, character = 4 },
      ["end"] = { line = 30, character = 13 },
    },
  }
  local structural_location = {
    uri = "file:///workspace/internal/controller/worker.go",
    range = {
      start = { line = 5, character = 2 },
      ["end"] = { line = 5, character = 11 },
    },
  }
  local corroborating_location = vim.deepcopy(reference_location)
  corroborating_location.range.start.character = 0
  corroborating_location.range["end"].character = 9
  local project_graph = graph.new(context)
  add_location(project_graph, "references", reference_location)
  add_location(project_graph, "structural", corroborating_location, {
    name = "Reconcile(ctx)",
  })
  add_location(project_graph, "structural", structural_location, {
    name = "Reconcile(job)",
  })
  local test_reference = {
    uri = "file:///workspace/internal/controller/reconcile_test.go",
    range = {
      start = { line = 12, character = 4 },
      ["end"] = { line = 12, character = 13 },
    },
  }
  local test_structural = vim.deepcopy(test_reference)
  test_structural.range.start.character = 0
  add_location(project_graph, "test_references", test_reference)
  add_location(project_graph, "test_structural", test_structural, {
    name = "Reconcile(testCase)",
  })
  local external_reference = {
    uri = "file:///usr/local/go/src/example/external.go",
    range = {
      start = { line = 7, character = 4 },
      ["end"] = { line = 7, character = 13 },
    },
  }
  local external_structural = vim.deepcopy(external_reference)
  external_structural.range.start.character = 0
  add_location(project_graph, "references", external_reference)
  add_location(project_graph, "structural", external_structural, {
    name = "Reconcile(external)",
  })
  graph.add_contributor(project_graph, "ast_grep", "ast-grep")
  local project_map = model.build(context, project_graph, { include_external = false })
  local reference_section
  local structural_section
  local test_reference_section
  local test_structural_section
  for _, section in ipairs(project_map.sections) do
    if section.id == "references" then
      reference_section = section
    elseif section.id == "structural" then
      structural_section = section
    elseif section.id == "test_references" then
      test_reference_section = section
    elseif section.id == "test_structural" then
      test_structural_section = section
    end
  end
  assert_equal(#reference_section.rows, 1, "semantic project references should render")
  assert_equal(
    reference_section.rows[1].evidence.provider,
    "gopls+ast-grep",
    "matching structural evidence should corroborate the semantic row"
  )
  assert_equal(reference_section.rows[1].evidence, {
    provider = "gopls+ast-grep",
    method = "mixed",
    class = "mixed",
  }, "compatibility evidence should report mixed corroboration honestly")
  assert_equal(reference_section.rows[1].evidence_records, {
    {
      provider = "gopls",
      method = "textDocument/references",
      class = "semantic",
    },
    {
      provider = "ast-grep",
      method = "structural",
      class = "structural",
    },
  }, "semantic and structural evidence should remain independently inspectable")
  assert_equal(
    reference_section.rows[1].id,
    "references:textDocument/references:" .. graph.location_key(reference_section.rows[1].location),
    "corroboration should not change navigation row ids"
  )
  assert_equal(
    #structural_section.rows,
    1,
    "only additional structural matches should get a section"
  )
  assert_equal(#test_reference_section.rows, 1, "test references should get a distinct section")
  assert_equal(
    test_reference_section.rows[1].evidence.provider,
    "gopls+ast-grep",
    "test structural evidence should corroborate semantic test references"
  )
  assert_equal(
    test_structural_section,
    nil,
    "corroborated test matches should not render a duplicate structural section"
  )
  assert(
    contains(project_map.notes, "1 external relationship hidden."),
    "corroborating external evidence should count as one hidden relationship"
  )

  local caller_uri = "file:///workspace/internal/controller/reconcile_test.go"
  local call_location = {
    uri = caller_uri,
    range = {
      start = { line = 42, character = 4 },
      ["end"] = { line = 42, character = 13 },
    },
  }
  local non_call_location = {
    uri = caller_uri,
    range = {
      start = { line = 43, character = 12 },
      ["end"] = { line = 43, character = 21 },
    },
  }
  local unmatched_structural_location = {
    uri = "file:///workspace/internal/other_test.go",
    range = {
      start = { line = 8, character = 2 },
      ["end"] = { line = 8, character = 20 },
    },
  }
  local usage_graph = graph.new(context)
  add_incoming(usage_graph, "TestReconcile", caller_uri, 40, { call_location.range })
  add_location(usage_graph, "test_references", call_location)
  add_location(usage_graph, "test_references", non_call_location)
  local production_caller_uri = "file:///workspace/internal/controller/worker.go"
  local production_call_location = {
    uri = production_caller_uri,
    range = {
      start = { line = 52, character = 4 },
      ["end"] = { line = 52, character = 13 },
    },
  }
  add_incoming(
    usage_graph,
    "RunWorker",
    production_caller_uri,
    50,
    { production_call_location.range }
  )
  add_location(usage_graph, "references", production_call_location)
  local corroborating_call = vim.deepcopy(call_location)
  corroborating_call.range.start.character = 2
  corroborating_call.range["end"].character = 24
  add_location(usage_graph, "test_structural", corroborating_call, {
    name = "Reconcile(ctx)",
  })
  add_location(usage_graph, "test_structural", unmatched_structural_location, {
    name = "Reconcile(other)",
  })
  local usage_map = model.build(context, usage_graph, {})
  local incoming_section = vim.iter(usage_map.sections):find(function(value)
    return value.id == "incoming"
  end)
  local test_references = vim.iter(usage_map.sections):find(function(value)
    return value.id == "test_references"
  end)
  local remaining_structural = vim.iter(usage_map.sections):find(function(value)
    return value.id == "test_structural"
  end)
  assert_equal(
    #incoming_section.rows,
    1,
    "production callers should remain under the primary incoming relationship"
  )
  assert_equal(
    incoming_section.rows[1].name,
    "RunWorker",
    "production callers should remain under Entered through"
  )
  assert_equal(incoming_section.rows[1].evidence_records, {
    {
      provider = "gopls",
      method = "callHierarchy/incomingCalls",
      class = "semantic",
    },
    {
      provider = "gopls",
      method = "textDocument/references",
      class = "semantic",
    },
  }, "production references should enrich callers without another row")
  assert_equal(test_references.rows[1].evidence_records, {
    {
      provider = "gopls",
      method = "callHierarchy/incomingCalls",
      class = "semantic",
    },
    {
      provider = "gopls",
      method = "textDocument/references",
      class = "semantic",
    },
    {
      provider = "ast-grep",
      method = "structural",
      class = "structural",
    },
  }, "covered test references should enrich test callers without another row")
  assert_equal(
    test_references.rows[1].occurrences,
    { { uri = caller_uri, ranges = { call_location.range } } },
    "consolidated caller details should retain the exact call site"
  )
  assert_equal(
    #test_references.rows,
    2,
    "test callers and non-call references should share the test section without duplicates"
  )
  assert_equal(
    test_references.rows[2].location.uri,
    non_call_location.uri,
    "reference consolidation must retain the non-call source file"
  )
  assert_equal(
    test_references.rows[2].location.range,
    non_call_location.range,
    "reference consolidation must retain uses outside incoming call ranges"
  )
  assert_equal(
    #remaining_structural.rows,
    1,
    "only unmatched structural candidates should remain after corroboration"
  )
  assert_equal(
    remaining_structural.default_collapsed,
    true,
    "unmatched structural candidates should be secondary when semantic usage exists"
  )
  local expanded_usage_map = model.build(context, usage_graph, {
    sections = { collapse_secondary = false },
  })
  local expanded_structural = vim.iter(expanded_usage_map.sections):find(function(value)
    return value.id == "test_structural"
  end)
  assert_equal(
    expanded_structural.default_collapsed,
    false,
    "section policy should be able to keep secondary structural candidates open"
  )

  local structural_only_graph = graph.new(context)
  add_location(structural_only_graph, "test_structural", unmatched_structural_location, {
    name = "Reconcile(other)",
  })
  local structural_only_map = model.build(context, structural_only_graph, {})
  assert_equal(
    structural_only_map.sections[1].default_collapsed,
    false,
    "structural candidates should stay open when semantic usage is unavailable"
  )

  local syntax_configuration = vim.deepcopy(context)
  syntax_configuration.client_id = nil
  syntax_configuration.client_name = "Tree-sitter"
  syntax_configuration.configuration = { key = "Enabled", container = "TLSConfig" }
  local syntax_configuration_map =
    model.build(syntax_configuration, graph.new(syntax_configuration), {})
  assert(
    contains(
      syntax_configuration_map.notes,
      "Configuration uses require an active language server with project reference support."
    ),
    "syntax-only configuration focus should explain the semantic provider requirement"
  )

  local relations = require("archlens.relations")
  relations.register("dependencies", {
    label = "Depends on",
    marker = "◇",
    order = 55,
    source = "semantic",
    endpoint = "source",
    sort = "location",
  })
  local custom_graph = graph.new(context)
  add_location(custom_graph, "references", reference_location)
  local dependency = graph.node_from_location(reference_location, { name = "dependency" })
  graph.add_edge(
    custom_graph,
    graph.edge("dependencies", dependency, custom_graph.focus, {
      provider = "gopls",
      method = "textDocument/references",
      class = "semantic",
    })
  )
  local custom_map = model.build(context, custom_graph, { include_external = false })
  assert(
    custom_map.sections[1].rows[1].id ~= custom_map.sections[2].rows[1].id,
    "row ids should remain unique when relation kinds share a method and location"
  )

  local relevance_specs = {
    {
      name = "structural-near",
      uri = "file:///workspace/internal/controller/candidate.go",
      line = 1,
      evidence = { provider = "ast-grep", method = "structural", class = "structural" },
    },
    {
      name = "provider-defined",
      uri = "file:///workspace/internal/storage/custom.go",
      line = 2,
      evidence = { provider = "custom", method = "first", class = "heuristic" },
      corroboration = { provider = "custom-2", method = "second", class = "heuristic" },
    },
    {
      name = "exact-distant",
      uri = "file:///workspace/internal/storage/read.go",
      line = 3,
      evidence = { provider = "gopls", method = "references", class = "semantic" },
    },
    {
      name = "exact-near",
      uri = "file:///workspace/internal/controller/helper.go",
      line = 4,
      evidence = { provider = "Tree-sitter", method = "syntax", class = "syntax" },
    },
    {
      name = "exact-same-file",
      uri = context.location.uri,
      line = 30,
      evidence = { provider = "gopls", method = "references", class = "semantic" },
    },
    {
      name = "corroborated-exact",
      uri = "file:///workspace/cmd/controller/main.go",
      line = 5,
      evidence = { provider = "gopls", method = "references", class = "semantic" },
      corroboration = { provider = "ast-grep", method = "structural", class = "structural" },
    },
  }
  local function relevance_map(specs)
    local snapshot = graph.new(context)
    for _, spec in ipairs(specs) do
      local location = {
        uri = spec.uri,
        range = {
          start = { line = spec.line, character = 2 },
          ["end"] = { line = spec.line, character = 6 },
        },
      }
      local related = graph.node_from_location(location, { name = spec.name })
      graph.add_edge(snapshot, graph.edge("dependencies", related, snapshot.focus, spec.evidence))
      if spec.corroboration then
        graph.add_edge(
          snapshot,
          graph.edge("dependencies", related, snapshot.focus, spec.corroboration)
        )
      end
    end
    return model.build(context, snapshot, {}).sections[1]
  end
  local relevance = relevance_map(relevance_specs)
  assert_equal(
    vim.tbl_map(function(row)
      return row.name
    end, relevance.rows),
    {
      "corroborated-exact",
      "exact-same-file",
      "exact-near",
      "exact-distant",
      "provider-defined",
      "structural-near",
    },
    "relationships should rank by evidence quality and filesystem locality"
  )
  local reversed_specs = vim.deepcopy(relevance_specs)
  table.sort(reversed_specs, function(left, right)
    return left.name > right.name
  end)
  assert_equal(
    vim.tbl_map(function(row)
      return row.name
    end, relevance_map(reversed_specs).rows),
    vim.tbl_map(function(row)
      return row.name
    end, relevance.rows),
    "relevance ordering should not depend on provider completion order"
  )
  assert_equal(#relevance.rows, #relevance_specs, "relevance ordering must retain every row")

  context.syntax = {
    provider = "Tree-sitter",
    ancestors = {
      vim.tbl_extend("force", vim.deepcopy(context), { name = "Controller" }),
    },
    children = {},
    siblings = {},
  }
  context.enclosing_boundary = {
    name = "internal/controller",
    kind = vim.lsp.protocol.SymbolKind.Package,
    kind_name = "Go package",
    scope = "boundary",
    root_dir = context.root_dir,
    location = {
      uri = context.location.uri,
      range = { start = { line = 0, character = 0 }, ["end"] = { line = 0, character = 0 } },
    },
    path = context.path,
    path_label = context.path_label,
    language = "go",
    is_boundary = true,
    module_context = true,
    preserve_file_identity = true,
    boundary_id = "go-package:example.com/workspace/internal/controller",
    boundary_class = "language",
    boundary_path = "/workspace/internal/controller",
    boundary_keys = { "go-package:example.com/workspace/internal/controller" },
    boundary_evidence = {
      provider = "Go adapter",
      method = "go.mod/package",
      class = "semantic",
    },
  }

  mapped.sections[1].rows[2] = vim.deepcopy(mapped.sections[1].rows[1])
  mapped.sections[1].rows[2].id = "second"
  mapped.sections[1].rows[2].name = "Write"
  local rendered = render.build(mapped, { width = 56, max_items = 1 })
  assert(
    contains(rendered.lines, "└─ internal/controller  Go package"),
    "the immediate language boundary should replace the raw source path"
  )
  assert(contains(rendered.lines, "└─ Reconcile  Method"), "focus hierarchy should render")
  assert(
    contains(rendered.lines, "reconcile.go:11"),
    "boundary context should shorten the file label"
  )
  assert(contains(rendered.lines, "… 1 more"), "bounded sections should expose omitted rows")
  local collapsed = render.build(mapped, {
    width = 56,
    max_items = 2,
    collapsed = { outgoing = true },
  })
  assert(contains(collapsed.lines, "▸ Touches  2"), "collapsed sections should remain visible")
  assert(not contains(collapsed.lines, "  → Read"), "collapsed section rows should be hidden")
  assert(
    not contains(collapsed.lines, "… 2 more"),
    "collapsed sections should not expose a misleading expansion row"
  )

  local ast_grep = require("archlens.ast_grep")
  local decoded, omitted = ast_grep._decode_matches(vim.json.encode({
    file = "main.nix",
    lines = "use target",
    range = {
      start = { line = 2, column = 4 },
      ["end"] = { line = 2, column = 10 },
    },
  }) .. "\n", "/workspace", 10)
  assert_equal(#decoded, 1, "ast-grep stream output should decode")
  assert_equal(decoded[1].uri, "file:///workspace/main.nix", "ast-grep paths should be rooted")
  assert_equal(omitted, 0, "decoded structural matches should track omissions")
  local filtered_stream = table.concat({
    vim.json.encode({
      file = "vendor/example/generated.go",
      lines = "target()",
      range = {
        start = { line = 0, column = 0 },
        ["end"] = { line = 0, column = 6 },
      },
    }),
    vim.json.encode({
      file = "internal/main.go",
      lines = "target()",
      range = {
        start = { line = 1, column = 0 },
        ["end"] = { line = 1, column = 6 },
      },
    }),
  }, "\n")
  local filtered, filtered_omitted = ast_grep._decode_matches(filtered_stream, "/workspace", 1, {})
  assert_equal(
    filtered[1].uri,
    "file:///workspace/internal/main.go",
    "hidden paths must not consume ast-grep's visible result budget"
  )
  assert_equal(filtered_omitted, 0)
  local go_pattern, go_selector = ast_grep._query_for({
    name = "Reconcile",
    syntax_node_type = "method_declaration",
  }, "go")
  assert_equal(go_pattern, "var _ = $RECEIVER.Reconcile", "Go methods need a contextual pattern")
  assert_equal(
    go_selector,
    "selector_expression",
    "Go method matches should select the relationship"
  )
  local args = ast_grep._command_args(
    "ast-grep",
    {
      name = "Reconcile",
      syntax_node_type = "method_declaration",
    },
    "go",
    "/workspace",
    {
      threads = 2,
      globs = { "!vendor/**", "pkg/**" },
    }
  )
  assert(contains(args, "2"), "ast-grep command should include the configured thread count")
  assert(contains(args, "!vendor/**"), "ast-grep command should include exclusion globs")
  assert(contains(args, "pkg/**"), "ast-grep command should include inclusion globs")
  assert(contains(args, "!**/target/**"), "ast-grep should derive generated-path globs")
  assert(contains(args, "!**/zz_generated.*"), "ast-grep should skip generated filenames")
  assert(contains(args, "!**/*_generated_*"), "ast-grep should skip generated variants")
  assert(contains(args, "!**/*.generated_*"), "ast-grep should skip dot-generated variants")
  assert(contains(args, "!**/*.pb.go"), "ast-grep should skip generated protobuf files")
  assert_equal(args[#args], "/workspace", "ast-grep command should end with the project root")

  local source_window = vim.api.nvim_get_current_win()
  local session = { expanded = {} }
  local noop = function() end
  local dismissed = 0
  view.ensure(session, { width = 56, max_items = 1 }, {
    open = noop,
    focus = noop,
    back = noop,
    refresh = noop,
    close = noop,
    dismiss = function()
      dismissed = dismissed + 1
    end,
  })
  view.render(session, mapped, { width = 56, max_items = 1 })
  assert_equal(vim.bo[session.buffer].buftype, "nofile", "the view should use a scratch buffer")
  assert_equal(vim.bo[session.buffer].modifiable, false, "the rendered view should be read-only")
  assert(session.window ~= source_window, "the view should open in a separate window")
  local expand_line
  for line, target in pairs(session.rendered.targets) do
    if target.action == "expand" then
      expand_line = line
      break
    end
  end
  assert(expand_line, "a bounded section should render an expansion action")
  vim.api.nvim_win_set_cursor(session.window, { expand_line, 0 })
  local space_mapping
  for _, mapping in ipairs(vim.api.nvim_buf_get_keymap(session.buffer, "n")) do
    if mapping.lhs == " " then
      space_mapping = mapping
      break
    end
  end
  assert(space_mapping and space_mapping.callback, "the section mapping should be callable")
  space_mapping.callback()
  assert_equal(session.expanded.outgoing, true, "activating the more row should expand its section")
  assert_equal(
    session.collapsed.outgoing,
    false,
    "activating the more row should not collapse its section"
  )
  assert(
    not contains(session.rendered.lines, "… 1 more"),
    "an expanded section should render all remaining rows"
  )
  session.expanded.outgoing = nil
  view.render(session, mapped, { width = 56, max_items = 1 })
  local selected_line
  for line, target in pairs(session.rendered.targets) do
    if target.row and target.row.id == mapped.sections[1].rows[1].id then
      selected_line = line
    end
  end
  assert(selected_line, "the rendered relationship should be actionable")
  vim.api.nvim_win_set_cursor(session.window, { selected_line, 0 })
  mapped.sections[1].rows[1], mapped.sections[1].rows[2] =
    mapped.sections[1].rows[2], mapped.sections[1].rows[1]
  view.render(session, mapped, { width = 56, max_items = 2 })
  assert_equal(
    view.selected_row_id(session),
    mapped.sections[1].rows[2].id,
    "rerendering should preserve the selected relationship"
  )
  vim.api.nvim_win_close(session.window, true)
  vim.wait(50)
  assert_equal(dismissed, 1, "manual window closure should dismiss the session")
  assert_equal(session.window, nil, "manual window closure should clear the view window")

  vim.cmd.runtime("plugin/archlens.lua")
  assert_equal(vim.fn.exists(":ArchLensHere"), 2, "the user command should be registered")
end

local ok, err = xpcall(run, debug.traceback)
if not ok then
  vim.api.nvim_err_writeln(err)
  vim.cmd("cquit 1")
end

print("archlens.nvim headless tests passed")
vim.cmd("quitall")

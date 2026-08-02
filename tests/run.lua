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
  local view = require("archlens.view")

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

  local function add_location(snapshot, kind, location, fields, provider, edge_fields)
    local related = graph.node_from_location(location, fields)
    local reverse = kind == "references" or kind == "structural"
    local source = reverse and related or snapshot.focus
    local target = reverse and snapshot.focus or related
    graph.add_edge(
      snapshot,
      graph.edge(kind, source, target, {
        provider = provider or (kind == "structural" and "ast-grep" or "gopls"),
        method = kind == "implementations" and "textDocument/implementation"
          or kind == "references" and "textDocument/references"
          or "structural",
        class = kind == "structural" and "structural" or "semantic",
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

  local empty = model.build(context, graph.new(context), { include_external = false })
  assert(
    contains(empty.notes, "No local or project relationships were returned."),
    "an empty map should be explained"
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
  for _, section in ipairs(project_map.sections) do
    if section.id == "references" then
      reference_section = section
    elseif section.id == "structural" then
      structural_section = section
    end
  end
  assert_equal(#reference_section.rows, 1, "semantic project references should render")
  assert_equal(
    reference_section.rows[1].evidence.provider,
    "gopls+ast-grep",
    "matching structural evidence should corroborate the semantic row"
  )
  assert_equal(
    #structural_section.rows,
    1,
    "only additional structural matches should get a section"
  )
  assert(
    contains(project_map.notes, "1 external relationship hidden."),
    "corroborating external evidence should count as one hidden relationship"
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

  context.syntax = {
    provider = "Tree-sitter",
    ancestors = {
      vim.tbl_extend("force", vim.deepcopy(context), { name = "Controller" }),
    },
    children = {},
    siblings = {},
  }

  mapped.sections[1].rows[2] = vim.deepcopy(mapped.sections[1].rows[1])
  mapped.sections[1].rows[2].id = "second"
  mapped.sections[1].rows[2].name = "Write"
  local rendered = render.build(mapped, { width = 56, max_items = 1 })
  assert(contains(rendered.lines, "└─ Reconcile  Method"), "focus hierarchy should render")
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

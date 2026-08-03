local source = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(source, ":p:h:h")
vim.opt.runtimepath:prepend(root)

local function equal(actual, expected, message)
  assert(vim.deep_equal(actual, expected), message or vim.inspect({ actual, expected }))
end

local function location(path, line, character)
  return {
    uri = vim.uri_from_fname(path),
    range = {
      start = { line = line, character = character or 0 },
      ["end"] = { line = line, character = (character or 0) + 5 },
    },
  }
end

local parser_calls = 0
package.loaded["archlens.treesitter"] = {
  enclosing_containers = function(path, positions)
    parser_calls = parser_calls + 1
    if path:match("fallback%.go$") then
      return {}
    end
    local values = {}
    for index in ipairs(positions) do
      values[index] = {
        name = "TestLoadConfig",
        kind_name = "Function",
        trail = { "tests" },
        location = location(path, 4, 5),
      }
    end
    return values
  end,
}
package.loaded["archlens.containers"] = nil

local graph = require("archlens.graph")
local model = require("archlens.model")
local containers = require("archlens.containers")
local focus_location = location("/workspace/config.go", 2, 4)
local context = {
  name = "Enabled",
  kind = vim.lsp.protocol.SymbolKind.Field,
  kind_name = "Field",
  root_dir = "/workspace",
  supports_calls = false,
  configuration = { key = "Enabled", container = "Config" },
  location = focus_location,
}
local delta = graph.delta()
local focus = graph.node_from_context(context)
local first_location = location("/workspace/config_test.go", 10, 8)
local second_location = location("/workspace/config_test.go", 12, 8)
for _, use_location in ipairs({ first_location, second_location }) do
  graph.add_edge(
    delta,
    graph.edge(
      "test_references",
      graph.node_from_location(use_location, { kind_name = "Test reference" }),
      focus,
      {
        provider = "gopls",
        method = "textDocument/references",
        class = "semantic",
      }
    )
  )
end

local enriched
containers.enrich(
  delta,
  context,
  { timeout_ms = 1000, batch_size = 1, filters = {} },
  function(value)
    enriched = value
  end
)
assert(
  vim.wait(1500, function()
    return enriched ~= nil
  end, 10),
  "container enrichment timed out"
)
equal(parser_calls, 1, "one source file should be parsed once")
equal(
  enriched.edges[1].source.location.range,
  first_location.range,
  "grouping must not replace the exact reference location"
)
equal(
  enriched.edges[1].presentation.container.id,
  enriched.edges[2].presentation.container.id,
  "uses in one function should share a presentation group"
)

local snapshot = graph.new(context)
graph.merge(snapshot, enriched)
graph.add_edge(
  snapshot,
  graph.edge(
    "test_structural",
    graph.node_from_location(first_location, { name = "Enabled" }),
    snapshot.focus,
    {
      provider = "ast-grep",
      method = "structural",
      class = "structural",
    }
  )
)
local mapped = model.build(context, snapshot, {})
equal(mapped.sections[1].id, "test_references")
equal(#mapped.sections[1].rows, 2, "exact use sites should remain canonical rows")
equal(#mapped.sections[1].groups, 1, "uses in one function should form one group")
equal(mapped.sections[1].groups[1].name, "tests › TestLoadConfig")
equal(#mapped.sections[1].groups[1].rows, 2)
equal(
  mapped.sections[1].groups[1].rows[1].evidence.provider,
  "gopls+ast-grep",
  "structural evidence should merge before presentation grouping"
)

local render = require("archlens.render")
local collapsed_render = render.build(mapped, { width = 80, max_items = 8 })
local group_target
for _, target in pairs(collapsed_render.targets) do
  if target.action == "toggle_group" then
    group_target = target
    break
  end
end
assert(group_target, "a grouped section should expose a group toggle")
equal(group_target.row.resolve_on_focus, true, "group focus should resolve its declaration")
assert(
  vim.tbl_contains(collapsed_render.lines, "  ▸ tests › TestLoadConfig  2"),
  "the collapsed group should summarize its exact uses"
)
local expanded_render = render.build(mapped, {
  width = 80,
  max_items = 1,
  expanded_groups = { [mapped.sections[1].groups[1].id] = true },
})
assert(
  vim.tbl_contains(expanded_render.lines, "    ◇ Enabled"),
  "expanding a group should reveal exact relationship rows"
)
assert(
  vim.tbl_contains(expanded_render.lines, "    … 1 more uses"),
  "expanded groups should retain a bounded child list"
)

local view = require("archlens.view")
local source_window = vim.api.nvim_get_current_win()
local session = { expanded = {}, expanded_groups = {}, group_limits = {}, collapsed = {} }
local noop = function() end
view.ensure(session, { width = 80, max_items = 1 }, {
  open = noop,
  focus = noop,
  back = noop,
  refresh = noop,
  close = noop,
  dismiss = noop,
})
view.render(session, mapped, { width = 80, max_items = 1 })
local group_line
for line, target in pairs(session.rendered.targets) do
  if target.action == "toggle_group" then
    group_line = line
    break
  end
end
assert(group_line, "the grouped view should retain the group action")
vim.api.nvim_win_set_cursor(session.window, { group_line, 0 })
local enter_mapping
for _, mapping in ipairs(vim.api.nvim_buf_get_keymap(session.buffer, "n")) do
  if mapping.lhs == "<CR>" then
    enter_mapping = mapping
    break
  end
end
assert(enter_mapping and enter_mapping.callback)
enter_mapping.callback()
equal(
  session.expanded_groups[mapped.sections[1].groups[1].id],
  true,
  "activating a group should expand it without changing the section"
)
local more_line
for line, target in pairs(session.rendered.targets) do
  if target.action == "expand_group" then
    more_line = line
    break
  end
end
assert(more_line, "a bounded group should expose progressive child expansion")
vim.api.nvim_win_set_cursor(session.window, { more_line, 0 })
enter_mapping.callback()
equal(
  session.group_limits[mapped.sections[1].groups[1].id],
  2,
  "repeated group expansion should increase the child budget"
)
assert(
  not vim.tbl_contains(session.rendered.lines, "    … 1 more uses"),
  "the final group expansion should reveal all exact rows"
)
vim.api.nvim_win_close(session.window, true)
vim.api.nvim_set_current_win(source_window)

local cached
containers.enrich(delta, context, { timeout_ms = 1000, filters = {} }, function(value)
  cached = value
end)
assert(vim.wait(1500, function()
  return cached ~= nil
end, 10))
equal(parser_calls, 1, "unchanged files should reuse enclosing-container results")

local modified_buffer = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_name(modified_buffer, "/workspace/config_test.go")
vim.api.nvim_buf_set_lines(modified_buffer, 0, -1, false, { "func TestLoadConfig() {}" })
local loaded
containers.enrich(delta, context, { timeout_ms = 1000, filters = {} }, function(value)
  loaded = value
end)
assert(vim.wait(1500, function()
  return loaded ~= nil
end, 10))
equal(parser_calls, 2, "loading a file buffer should invalidate disk-backed container results")
vim.api.nvim_buf_set_lines(modified_buffer, 0, -1, false, { "func TestRenamed() {}" })
local modified
containers.enrich(delta, context, { timeout_ms = 1000, filters = {} }, function(value)
  modified = value
end)
assert(vim.wait(1500, function()
  return modified ~= nil
end, 10))
equal(parser_calls, 3, "unsaved buffer changes should invalidate container results")
vim.api.nvim_buf_delete(modified_buffer, { force = true })

local fallback_delta = graph.delta()
local fallback_location = location("/workspace/fallback.go", 8, 2)
graph.add_edge(
  fallback_delta,
  graph.edge(
    "configuration_consumers",
    graph.node_from_location(fallback_location, { kind_name = "Configuration use" }),
    focus,
    {
      provider = "gopls",
      method = "textDocument/references",
      class = "semantic",
    }
  )
)
local fallback
containers.enrich(fallback_delta, context, { timeout_ms = 1000, filters = {} }, function(value)
  fallback = value
end)
assert(vim.wait(1500, function()
  return fallback ~= nil
end, 10))
equal(fallback.edges[1].presentation.container.kind_name, "File")
equal(fallback.edges[1].presentation.container.name, "fallback.go")
local fallback_snapshot = graph.new(context)
graph.merge(fallback_snapshot, fallback)
local fallback_model = model.build(context, fallback_snapshot, {})
equal(
  fallback_model.sections[1].groups[1].resolve_on_focus,
  false,
  "file fallback groups should not resolve an unrelated symbol at line zero"
)
equal(fallback_model.sections[1].groups[1].context.preserve_file_identity, true)

containers.clear_cache()
print("archlens.nvim relationship container tests passed")

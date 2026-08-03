local source = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(source, ":p:h:h")
vim.opt.runtimepath:prepend(root)
vim.bo.filetype = "go"

local function equal(actual, expected, message)
  assert(vim.deep_equal(actual, expected), message or vim.inspect({ actual, expected }))
end

local uri = "file:///workspace/source.go"
local function range(line, character)
  return {
    start = { line = line, character = character or 0 },
    ["end"] = { line = line, character = (character or 0) + 4 },
  }
end

local sites = {
  {
    name = "internal/storage",
    location = { uri = uri, range = range(1, 8) },
    position = { line = 1, character = 9 },
  },
  {
    name = "internal/storage",
    location = { uri = uri, range = range(2, 8) },
    position = { line = 2, character = 9 },
  },
  {
    name = "vendor/helper",
    location = { uri = uri, range = range(3, 8) },
    position = { line = 3, character = 9 },
  },
  {
    name = "missing/module",
    location = { uri = uri, range = range(4, 8) },
    position = { line = 4, character = 9 },
  },
}
local site_error

package.loaded["archlens.treesitter"] = {
  import_sites = function()
    return vim.deepcopy(sites), site_error
  end,
}

local requested = {}
local cancelled = 0
package.loaded["archlens.lsp"] = {
  definition_at = function(_, _, _, position, callback)
    requested[#requested + 1] = vim.deepcopy(position)
    if position.line == 4 then
      callback({}, "not found", 0)
    else
      local target = position.line == 3 and "file:///workspace/vendor/helper/main.go"
        or "file:///workspace/internal/storage/store.go"
      local locations = {
        {
          uri = target,
          range = range(0, 5),
          full_range = range(0, 0),
        },
      }
      if position.line == 1 then
        locations[#locations + 1] = {
          uri = "file:///workspace/internal/storage/a_generated.go",
          range = range(0, 5),
          full_range = range(0, 0),
        }
      end
      callback(locations, nil, 0)
    end
    return function()
      cancelled = cancelled + 1
    end
  end,
}

local fake_client = {
  id = 4,
  name = "gopls",
  is_stopped = function()
    return false
  end,
  supports_method = function(_, method)
    return method == "textDocument/definition"
  end,
}
local original_get_client_by_id = vim.lsp.get_client_by_id
vim.lsp.get_client_by_id = function(id)
  return id == fake_client.id and fake_client or original_get_client_by_id(id)
end

local context = {
  client_id = fake_client.id,
  client_name = fake_client.name,
  name = "Current",
  kind_name = "Function",
  root_dir = "/workspace",
  location = { uri = uri, range = range(8, 0) },
  position_encoding = "utf-8",
}

local imports = require("archlens.imports")
local result
imports.relationships(context, 0, { concurrency = 2 }, function(value)
  result = value
end)
assert(result, "synchronous import resolution should complete")
equal(#requested, 4)
equal(#result.edges, 3, "resolved import targets should become graph edges")
equal(result.edges[1].kind, "module_imports")
equal(result.edges[1].source.scope, "file")
equal(result.edges[1].source.location.uri, uri)
assert(
  result.edges[1].source.name ~= context.name,
  "file import edges should not attribute the dependency to the focused symbol"
)
equal(result.edges[1].target.scope, "module")
equal(result.edges[1].target.resolve_on_focus, nil)
equal(result.edges[1].target.context.module_context, true)
equal(result.edges[1].target.context.import_filetype, "go")
equal(
  result.edges[1].target.location.uri,
  "file:///workspace/internal/storage/store.go",
  "one import should collapse multi-file package definitions to one stable project target"
)
equal(result.edges[1].evidence, {
  provider = "Tree-sitter+gopls",
  method = "textDocument/definition",
  class = "semantic",
})
equal(result.edges[1].presentation.section_anchor, {
  prefix = "from",
  label = "source.go",
})
equal(result.edges[1].occurrences[1].ranges[1], sites[1].location.range)
assert(
  table
    .concat(result.notes, "\n")
    :find("1 module dependency target could not be resolved.", 1, true),
  "unresolved imports should be aggregated"
)

local graph = require("archlens.graph")
local model = require("archlens.model")
local snapshot = graph.new(context)
graph.merge(snapshot, result)
local mapped = model.build(context, snapshot, {})
equal(#mapped.sections, 1)
equal(mapped.sections[1].id, "module_imports")
equal(mapped.sections[1].label, "Module dependencies")
equal(mapped.sections[1].anchor, { prefix = "from", label = "source.go" })
equal(#mapped.sections[1].rows, 1, "duplicate imports should merge by target module")
equal(#mapped.sections[1].rows[1].occurrences, 2, "merged imports should retain source sites")
local rendered = require("archlens.render").build(mapped, { width = 80 })
assert(vim.tbl_contains(rendered.lines, "  from source.go"), "the file anchor should render")
local collapsed = require("archlens.render").build(mapped, {
  width = 80,
  collapsed = { module_imports = true },
})
assert(
  not vim.tbl_contains(collapsed.lines, "  from source.go"),
  "collapsed sections should hide their anchor"
)
assert(
  table.concat(mapped.notes, "\n"):find("1 vendored relationship hidden.", 1, true),
  "module targets should use shared scope filtering"
)

local limited
local requests_before_limited = #requested
imports.relationships(context, 0, { max_imports = 1 }, function(value)
  limited = value
end)
equal(#limited.edges, 3, "hidden imports and duplicate occurrences should survive provider mapping")
equal(
  #requested,
  requests_before_limited + 1,
  "successful targets should be cached while unresolved imports are retried"
)
local limited_snapshot = graph.new(context)
graph.merge(limited_snapshot, limited)
local limited_model = model.build(context, limited_snapshot, {})
equal(#limited_model.sections[1].rows, 1, "the visible limit should apply to unique module rows")

local original_sites = sites
sites = {
  {
    name = "internal/static",
    location = { uri = uri, range = range(1, 8) },
    position = { line = 1, character = 9 },
    target_locations = {
      {
        uri = "file:///workspace/internal/static/mod.rs",
        range = range(0, 0),
      },
    },
  },
}
local requests_before_static = #requested
local static
imports.relationships(context, 0, {}, function(value)
  static = value
end)
equal(#requested, requests_before_static, "static module targets should bypass LSP definition")
equal(static.edges[1].evidence, {
  provider = "Tree-sitter",
  method = "adapter/moduleTarget",
  class = "semantic",
})

local no_lsp_context = vim.deepcopy(context)
no_lsp_context.client_id = nil
no_lsp_context.client_name = nil
local no_lsp_static
imports.relationships(no_lsp_context, 0, {}, function(value)
  no_lsp_static = value
end)
equal(
  #no_lsp_static.edges,
  1,
  "static module targets should remain available without a language server"
)
sites = {
  {
    name = "dynamic/module",
    location = { uri = uri, range = range(1, 8) },
    position = { line = 1, character = 9 },
  },
}
local no_lsp_dynamic
local no_lsp_dynamic_outcome
imports.relationships(no_lsp_context, 0, {}, function(value, outcome)
  no_lsp_dynamic = value
  no_lsp_dynamic_outcome = outcome
end)
equal(#no_lsp_dynamic.edges, 0)
equal(no_lsp_dynamic.notes, {})
equal(no_lsp_dynamic_outcome, {
  state = "unavailable",
  message = "1 module dependency target requires a definition-capable language server.",
})
sites = original_sites

site_error = "query exploded"
local extraction_failure
local extraction_outcome
imports.relationships(context, 0, {}, function(value, outcome)
  extraction_failure = value
  extraction_outcome = outcome
end)
equal(extraction_outcome, {
  state = "failed",
  message = "Module dependency extraction failed: query exploded",
}, "a complete import extraction failure should publish a failed lifecycle outcome")
assert(
  table.concat(extraction_failure.errors, "\n"):find("query exploded", 1, true),
  "import extraction failures should remain visible in result details"
)
site_error = nil

imports.clear_cache()
local requests_before_refresh = #requested
local refreshed
imports.relationships(context, 0, { max_imports = 1 }, function(value)
  refreshed = value
end)
assert(refreshed)
equal(
  #requested,
  requests_before_refresh + #original_sites,
  "clearing the import cache should make refresh query every dynamic import again"
)
local invalid_limit
imports.relationships(context, 0, { max_imports = -10 }, function(value)
  invalid_limit = value
end)
local invalid_snapshot = graph.new(context)
graph.merge(invalid_snapshot, invalid_limit)
local invalid_model = model.build(context, invalid_snapshot, {})
equal(#invalid_model.sections[1].rows, 1, "invalid import limits should clamp instead of looping")

sites = {}
for index = 1, 24 do
  sites[#sites + 1] = {
    name = "external/" .. index,
    location = { uri = uri, range = range(index, 8) },
    position = { line = index, character = 9 },
    target_locations = {
      {
        uri = "file:///sdk/external/" .. index .. "/module.go",
        range = range(0, 0),
      },
    },
  }
end
sites[#sites + 1] = {
  name = "internal/visible",
  location = { uri = uri, range = range(25, 8) },
  position = { line = 25, character = 9 },
  target_locations = {
    {
      uri = "file:///workspace/internal/visible/module.go",
      range = range(0, 0),
    },
  },
}
local external_first
imports.relationships(no_lsp_context, 0, { max_imports = 1, max_sites = 32 }, function(value)
  external_first = value
end)
local external_first_snapshot = graph.new(no_lsp_context)
graph.merge(external_first_snapshot, external_first)
local external_first_model = model.build(no_lsp_context, external_first_snapshot, {})
equal(#external_first_model.sections, 1)
equal(
  external_first_model.sections[1].rows[1].location.uri,
  "file:///workspace/internal/visible/module.go",
  "hidden external imports must not consume the visible relationship budget"
)

local scan_limited
imports.relationships(no_lsp_context, 0, { max_imports = 1, max_sites = 2 }, function(value)
  scan_limited = value
end)
assert(
  table
    .concat(scan_limited.notes, "\n")
    :find("23 module dependency declarations omitted by the scan limit.", 1, true),
  "the hard import scan limit should be reported separately"
)
sites = original_sites

imports.clear_cache()
sites = {
  {
    name = "duplicate/one",
    location = { uri = uri, range = range(10, 8) },
    position = { line = 10, character = 9 },
  },
  {
    name = "duplicate/two",
    location = { uri = uri, range = range(11, 8) },
    position = { line = 11, character = 9 },
  },
}
local duplicate_callbacks = {}
package.loaded["archlens.lsp"].definition_at = function(_, _, _, _, callback)
  duplicate_callbacks[#duplicate_callbacks + 1] = callback
  return function() end
end
package.loaded["archlens.imports"] = nil
imports = require("archlens.imports")
local duplicate_result
imports.relationships(context, 0, { concurrency = 2, timeout_ms = 1000 }, function(value)
  duplicate_result = value
end)
equal(#duplicate_callbacks, 2, "both module definitions should start")
local duplicate_target = {
  {
    uri = "file:///workspace/duplicate/module.go",
    range = range(0, 0),
  },
}
duplicate_callbacks[1](duplicate_target)
duplicate_callbacks[1](duplicate_target)
equal(
  duplicate_result,
  nil,
  "a duplicate definition callback must not complete unresolved module analysis"
)
duplicate_callbacks[2](duplicate_target)
assert(duplicate_result, "module analysis should complete after every definition settles")
sites = original_sites

local hanging_callbacks = {}
local hanging_cancellations = 0
package.loaded["archlens.lsp"].definition_at = function(_, _, _, _, callback)
  hanging_callbacks[#hanging_callbacks + 1] = callback
  return function()
    hanging_cancellations = hanging_cancellations + 1
  end
end
package.loaded["archlens.imports"] = nil
imports = require("archlens.imports")
local timeout_result
local timeout_outcome
local timeout_callbacks = 0
imports.relationships(context, 0, { concurrency = 2, timeout_ms = 10 }, function(value, outcome)
  timeout_callbacks = timeout_callbacks + 1
  timeout_result = value
  timeout_outcome = outcome
end)
assert(
  vim.wait(1000, function()
    return timeout_result ~= nil
  end),
  "hanging import definitions should obey the provider timeout"
)
equal(hanging_cancellations, 2, "the timeout should cancel active definition requests")
equal(timeout_outcome, {
  state = "timed_out",
  message = "Module dependency resolution exceeded 10 ms and was stopped.",
})
for _, callback in ipairs(hanging_callbacks) do
  callback({}, nil, 0)
end
vim.wait(20)
equal(timeout_callbacks, 1, "late definition results must not complete twice")

vim.lsp.get_client_by_id = original_get_client_by_id
print("archlens import relationship tests passed")
vim.cmd("quitall")

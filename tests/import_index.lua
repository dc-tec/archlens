local source = debug.getinfo(1, "S").source:sub(2)
local plugin_root = vim.fn.fnamemodify(source, ":p:h:h")
vim.opt.runtimepath:prepend(plugin_root)

local function equal(actual, expected, message)
  assert(
    vim.deep_equal(actual, expected),
    string.format(
      "%s\nexpected: %s\nactual:   %s",
      message or "values differ",
      vim.inspect(expected),
      vim.inspect(actual)
    )
  )
end

local function range(line, character)
  return {
    start = { line = line, character = character or 0 },
    ["end"] = { line = line, character = (character or 0) + 8 },
  }
end

local project = vim.fn.tempname()
vim.fn.mkdir(vim.fs.joinpath(project, "pkg"), "p")
vim.fn.mkdir(vim.fs.joinpath(project, "other"), "p")
vim.fn.mkdir(vim.fs.joinpath(project, "vendor", "ignored"), "p")
vim.fn.mkdir(vim.fs.joinpath(project, "generated"), "p")
vim.fn.mkdir(vim.fs.joinpath(project, "ignored"), "p")
vim.fn.mkdir(vim.fs.joinpath(project, ".git"), "p")
vim.fn.writefile({ "module example.test/project" }, vim.fs.joinpath(project, "go.mod"))
vim.fn.writefile({ "ignored/", "vendor/" }, vim.fs.joinpath(project, ".gitignore"))

local target = vim.fs.joinpath(project, "pkg", "target.go")
local consumer = vim.fs.joinpath(project, "consumer.go")
local other = vim.fs.joinpath(project, "other", "consumer.go")
local vendored = vim.fs.joinpath(project, "vendor", "ignored", "consumer.go")
local generated = vim.fs.joinpath(project, "generated", "consumer.go")
local ignored = vim.fs.joinpath(project, "ignored", "consumer.go")
for _, path in ipairs({ target, consumer, other, vendored, generated, ignored }) do
  vim.fn.writefile({ "package fixture" }, path)
end

local parsed = {}
local function site(path, line)
  return {
    name = "example.test/project/pkg",
    location = {
      uri = vim.uri_from_fname(path),
      range = range(line, 8),
      full_range = range(line, 8),
    },
    position = { line = line, character = 9 },
  }
end

package.loaded["archlens.treesitter"] = {
  import_sites_from_path = function(path)
    parsed[path] = (parsed[path] or 0) + 1
    if path == consumer then
      return { site(path, 1), site(path, 4) }
    elseif path == other or path == vendored or path == generated or path == ignored then
      return { site(path, 2) }
    elseif path == target then
      return { site(path, 3) }
    end
    return {}
  end,
}
package.loaded["archlens.import_index"] = nil

local bufnr = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_name(bufnr, target)
vim.bo[bufnr].filetype = "go"
local context = {
  name = "target.go",
  kind = vim.lsp.protocol.SymbolKind.File,
  kind_name = "File",
  scope = "file",
  root_dir = project,
  supports_calls = false,
  location = { uri = vim.uri_from_fname(target), range = range(0, 0) },
}

local go_keys, go_error =
  require("archlens.adapters").imports_for_filetype("go").target_keys(target, project)
equal(
  go_keys,
  { "go-package:example.test/project/pkg" },
  "the focused Go file should resolve to its module package key: " .. tostring(go_error)
)

local options = {
  command = "rg",
  timeout_ms = 2000,
  max_index_files = 20,
  max_candidate_files = 40,
  max_file_bytes = 1024,
  batch_size = 2,
  max_importers = 20,
  filters = {},
}
local index = require("archlens.import_index")
local result
index.relationships(context, bufnr, options, function(value)
  result = value
end)
assert(
  vim.wait(2500, function()
    return result ~= nil
  end, 10),
  "the fallback project import index timed out"
)

equal(#result.edges, 2, "visible importers should be grouped by file")
equal(result.edges[1].kind, "module_importers")
equal(result.edges[1].source.scope, "file")
equal(result.edges[1].target.scope, "file")
equal(result.edges[1].target.location.uri, context.location.uri)
equal(result.edges[1].source.location.uri, vim.uri_from_fname(consumer))
equal(
  #result.edges[1].occurrences[1].ranges,
  2,
  "repeat imports in one file should remain exact occurrences on one edge"
)
equal(result.edges[1].source.context.scope, "file")
equal(result.edges[1].source.context.module_context, true)
equal(result.edges[1].source.context.preserve_file_identity, true)
equal(result.edges[1].presentation.section_anchor, { prefix = "for", label = "pkg" })
equal(parsed[vendored], nil, "vendored paths should be excluded before parsing")
equal(parsed[generated], nil, "generated paths should be excluded before parsing")

local included_vendored
local included_options = vim.tbl_deep_extend("force", {}, options, {
  filters = { include_vendored = true },
})
index.relationships(context, bufnr, included_options, function(value)
  included_vendored = value
end)
assert(vim.wait(2500, function()
  return included_vendored ~= nil
end, 10))
assert(parsed[vendored], "explicitly included vendored files should be indexed")
equal(
  parsed[ignored],
  nil,
  "including vendored files must not admit unrelated ignored project paths"
)

local graph = require("archlens.graph")
local snapshot = graph.new(context)
graph.merge(snapshot, result)
local mapped = require("archlens.model").build(context, snapshot, {})
equal(mapped.sections[1].id, "module_importers")
equal(mapped.sections[1].label, "Module dependents")
equal(mapped.sections[1].anchor, { prefix = "for", label = "pkg" })
equal(#mapped.sections[1].rows, 2)
equal(
  mapped.sections[1].rows[1].location.uri,
  vim.uri_from_fname(consumer),
  "the module-dependent row should navigate to the exact declaration"
)
local rendered = require("archlens.render").build(mapped, { width = 80 })
assert(vim.tbl_contains(rendered.lines, "  for pkg"), "the module anchor should render")

local first_parse_count = 0
for _, count in pairs(parsed) do
  first_parse_count = first_parse_count + count
end
local cached
index.relationships(context, bufnr, options, function(value)
  cached = value
end)
assert(cached, "a completed project index should be reusable synchronously")
local cached_parse_count = 0
for _, count in pairs(parsed) do
  cached_parse_count = cached_parse_count + count
end
equal(cached_parse_count, first_parse_count, "repeated navigation should reuse the project index")

local limited_options = vim.tbl_deep_extend("force", {}, options, { max_importers = 1 })
local limited
index.relationships(context, bufnr, limited_options, function(value)
  limited = value
end)
equal(#limited.edges, 1, "the importer budget should count unique files")
assert(
  table.concat(limited.notes, "\n"):find("1 module dependent omitted", 1, true),
  "the importer budget should report partial results"
)

local capped_options = vim.tbl_deep_extend("force", {}, options, {
  max_index_files = 1,
  batch_size = 1,
})
local capped
index.relationships(context, bufnr, capped_options, function(value)
  capped = value
end)
assert(
  vim.wait(2500, function()
    return capped ~= nil
  end, 10),
  "the capped project import index timed out"
)
assert(
  table.concat(capped.notes, "\n"):find("scan limit", 1, true),
  "a candidate cap should report incomplete results"
)

local discovery_options = vim.tbl_deep_extend("force", {}, options, {
  max_candidate_files = 1,
})
local discovery_limited
index.relationships(context, bufnr, discovery_options, function(value)
  discovery_limited = value
end)
assert(vim.wait(2500, function()
  return discovery_limited ~= nil
end, 10))
assert(
  table.concat(discovery_limited.notes, "\n"):find("candidate limit", 1, true),
  "the raw candidate bound should report unexamined files"
)

local cancelled = false
local cancel_options = vim.tbl_deep_extend("force", {}, options, { max_index_files = 7 })
local cancel = index.relationships(context, bufnr, cancel_options, function()
  cancelled = true
end)
cancel()
vim.wait(250, function()
  return false
end, 10)
equal(cancelled, false, "a cancelled subscriber must ignore a late index completion")

local unavailable_options = vim.tbl_deep_extend("force", {}, options, {
  command = "archlens-command-that-does-not-exist",
})
local unavailable
local shared_after_clear
index.relationships(context, bufnr, unavailable_options, function(value)
  unavailable = value
end)
index.clear_cache()
index.relationships(context, bufnr, unavailable_options, function(value)
  shared_after_clear = value
end)
assert(vim.wait(500, function()
  return unavailable ~= nil and shared_after_clear ~= nil
end, 10))
assert(
  table.concat(unavailable.notes, "\n"):find("ripgrep", 1, true),
  "a missing enumerator should be reported explicitly"
)
assert(
  table.concat(shared_after_clear.notes, "\n"):find("ripgrep", 1, true),
  "cache clearing must not strand subscribers sharing an active build"
)

index.clear_cache()
local refreshed
index.relationships(context, bufnr, options, function(value)
  refreshed = value
end)
assert(
  vim.wait(2500, function()
    return refreshed ~= nil
  end, 10),
  "the refreshed project import index timed out"
)
local refreshed_parse_count = 0
for _, count in pairs(parsed) do
  refreshed_parse_count = refreshed_parse_count + count
end
assert(
  refreshed_parse_count > cached_parse_count,
  "refresh should rebuild the project import index"
)

vim.api.nvim_buf_delete(bufnr, { force = true })
vim.fn.delete(project, "rf")
print("archlens.nvim project import index tests passed")

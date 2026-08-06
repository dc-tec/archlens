local source = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(source, ":p:h:h:h:h")
vim.opt.runtimepath:prepend(root)

local function equal(actual, expected, message)
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

local function range(line, character)
  return {
    start = { line = line, character = character or 0 },
    ["end"] = { line = line, character = (character or 0) + 8 },
  }
end

local function occurrence(path, line)
  return { uri = vim.uri_from_fname(path), ranges = { range(line, 8) } }
end

local project = vim.fn.tempname()
local module_path = "example.test/project"
local directories = {
  focus = vim.fs.joinpath(project, "focus"),
  dependency = vim.fs.joinpath(project, "dependency"),
  dependent = vim.fs.joinpath(project, "dependent"),
  source_only = vim.fs.joinpath(project, "source_only"),
  test_dependent = vim.fs.joinpath(project, "test_dependent"),
}
vim.fn.mkdir(project, "p")
vim.fn.writefile({ "module " .. module_path }, vim.fs.joinpath(project, "go.mod"))
for _, directory in pairs(directories) do
  vim.fn.mkdir(directory, "p")
end

local paths = {
  focus = vim.fs.joinpath(directories.focus, "active.go"),
  focus_ignored = vim.fs.joinpath(directories.focus, "ignored.go"),
  focus_test = vim.fs.joinpath(directories.focus, "active_test.go"),
  focus_xtest = vim.fs.joinpath(directories.focus, "external_test.go"),
  dependency = vim.fs.joinpath(directories.dependency, "dependency.go"),
  dependent = vim.fs.joinpath(directories.dependent, "dependent.go"),
  source_only = vim.fs.joinpath(directories.source_only, "source_only.go"),
  test_dependent = vim.fs.joinpath(directories.test_dependent, "base.go"),
  test_dependent_test = vim.fs.joinpath(directories.test_dependent, "base_test.go"),
  test_dependent_xtest = vim.fs.joinpath(directories.test_dependent, "external_test.go"),
}
for _, path in pairs(paths) do
  vim.fn.writefile({ "package fixture" }, path)
end

local function boundary(import_path, path, name)
  return {
    id = "go-package:" .. import_path,
    boundary_id = "go-package:" .. import_path,
    boundary_keys = { "go-package:" .. import_path },
    boundary_level = "package",
    boundary_path = vim.fs.dirname(path),
    is_boundary = true,
    module_context = true,
    language = "go",
    import_filetype = "go",
    name = name,
    kind = vim.lsp.protocol.SymbolKind.Package,
    kind_name = "Go package",
    scope = "boundary",
    root_dir = project,
    path = path,
    path_label = vim.fs.relpath(project, path),
    location = { uri = vim.uri_from_fname(path), range = range(0, 0) },
  }
end

local focus_import = module_path .. "/focus"
local dependency_import = module_path .. "/dependency"
local dependent_import = module_path .. "/dependent"
local source_only_import = module_path .. "/source_only"
local test_dependent_import = module_path .. "/test_dependent"
local module_boundary = {
  boundary_id = "go-module:" .. module_path,
  boundary_level = "module",
  boundary_path = project,
}
local focus = boundary(focus_import, paths.focus, "focus")
focus.enclosing_boundaries = { module_boundary }
local dependency = boundary(dependency_import, paths.dependency, "dependency")
local dependent = boundary(dependent_import, paths.dependent, "dependent")
local source_only = boundary(source_only_import, paths.source_only, "source_only")
local test_dependent = boundary(test_dependent_import, paths.test_dependent_test, "test_dependent")

local graph = require("archlens.graph")
local dependency_syntax = graph.delta()
graph.add_edge(
  dependency_syntax,
  graph.edge(
    "module_imports",
    graph.node_from_context(focus),
    graph.node_from_context(dependency),
    {
      provider = "Tree-sitter",
      method = "adapter/moduleTarget",
      class = "semantic",
    },
    {
      occurrences = {
        occurrence(paths.focus, 2),
        occurrence(paths.focus_ignored, 3),
        occurrence(paths.focus_test, 4),
      },
    }
  )
)
graph.add_edge(
  dependency_syntax,
  graph.edge(
    "module_imports",
    graph.node_from_context(focus),
    graph.node_from_context(source_only),
    {
      provider = "Tree-sitter",
      method = "adapter/moduleTarget",
      class = "semantic",
    },
    {
      occurrences = {
        occurrence(paths.focus_test, 6),
        occurrence(paths.focus_xtest, 8),
      },
    }
  )
)

local dependent_syntax = graph.delta()
graph.add_edge(
  dependent_syntax,
  graph.edge(
    "module_importers",
    graph.node_from_context(dependent),
    graph.node_from_context(focus),
    {
      provider = "Tree-sitter",
      method = "adapter/moduleTarget",
      class = "semantic",
    },
    { occurrences = { occurrence(paths.dependent, 5) } }
  )
)
graph.add_edge(
  dependent_syntax,
  graph.edge(
    "module_importers",
    graph.node_from_context(test_dependent),
    graph.node_from_context(focus),
    {
      provider = "Tree-sitter",
      method = "adapter/moduleTarget",
      class = "semantic",
    },
    {
      occurrences = {
        occurrence(paths.test_dependent_test, 7),
        occurrence(paths.test_dependent_xtest, 9),
      },
    }
  )
)

local import_index_calls = { dependencies = 0, dependents = 0, cancellations = 0 }
package.loaded["archlens.import_index"] = {
  dependencies = function(_, _, _, callback)
    import_index_calls.dependencies = import_index_calls.dependencies + 1
    callback(vim.deepcopy(dependency_syntax))
    return function()
      import_index_calls.cancellations = import_index_calls.cancellations + 1
    end
  end,
  dependents = function(_, _, _, callback)
    import_index_calls.dependents = import_index_calls.dependents + 1
    callback(vim.deepcopy(dependent_syntax))
    return function()
      import_index_calls.cancellations = import_index_calls.cancellations + 1
    end
  end,
}
package.loaded["archlens.languages.go.packages"] = nil
local go_packages = require("archlens.languages.go.packages")

local framed, frame_error = go_packages._decode_json_stream(
  '{"ImportPath":"first","Detail":"a } brace and \\"quote\\""}'
    .. '{"ImportPath":"second","Nested":{"value":2}}'
)
equal(frame_error, nil, "adjacent go list JSON objects should decode")
equal(#framed, 2, "the JSON stream decoder should frame every top-level object")
equal(framed[1].Detail, 'a } brace and "quote"', "quoted braces must not end a JSON frame")
equal(framed[2].Nested.value, 2, "nested JSON objects must remain intact")
local partial, partial_error = go_packages._decode_json_stream('{"ImportPath":"complete"}{')
equal(#partial, 1, "valid objects before an incomplete frame should remain available")
equal(partial_error, "go list returned incomplete JSON")

local module = {
  Path = module_path,
  Main = true,
  Dir = project,
  GoMod = vim.fs.joinpath(project, "go.mod"),
}
local packages = {
  {
    Dir = directories.focus,
    ImportPath = focus_import,
    Name = "focus",
    Module = module,
    GoFiles = { "active.go" },
    IgnoredGoFiles = { "ignored.go" },
    TestGoFiles = { "active_test.go" },
    XTestGoFiles = { "external_test.go" },
    Imports = { dependency_import },
    TestImports = { source_only_import },
    XTestImports = { dependency_import, source_only_import },
  },
  {
    Dir = directories.dependency,
    ImportPath = dependency_import,
    Name = "dependency",
    Module = module,
    GoFiles = { "dependency.go" },
    Imports = {},
  },
  {
    Dir = directories.dependent,
    ImportPath = dependent_import,
    Name = "dependent",
    Module = module,
    GoFiles = { "dependent.go" },
    Imports = { focus_import },
  },
  {
    Dir = directories.source_only,
    ImportPath = source_only_import,
    Name = "source_only",
    Module = module,
    GoFiles = { "source_only.go" },
    Imports = {},
  },
  {
    Dir = directories.test_dependent,
    ImportPath = test_dependent_import,
    Name = "test_dependent",
    Module = module,
    TestGoFiles = { "base_test.go" },
    XTestGoFiles = { "external_test.go" },
    Imports = {},
    TestImports = { focus_import },
    XTestImports = { focus_import },
  },
}

local output_path = vim.fs.joinpath(project, "go-list-output.json")
local encoded = {}
for _, package in ipairs(packages) do
  encoded[#encoded + 1] = vim.json.encode(package)
end
vim.fn.writefile({ table.concat(encoded) }, output_path)
local invocation_path = vim.fs.joinpath(project, "go-invocations")
local fake_go = vim.fs.joinpath(project, "fake-go")
vim.fn.writefile({
  "#!/bin/sh",
  "printf x >> " .. vim.fn.shellescape(invocation_path),
  "exec cat " .. vim.fn.shellescape(output_path),
}, fake_go)
assert(vim.uv.fs_chmod(fake_go, 493))

local default_scan_timeout_ms = 5000

local function run(command, timeout_ms, limits)
  local scan_timeout_ms = timeout_ms or default_scan_timeout_ms
  local result
  local outcome
  go_packages.relationships(focus, 0, {
    build = {
      command = command,
      timeout_ms = scan_timeout_ms,
      max_packages = 20,
      max_output_bytes = 64 * 1024,
    },
    imports = {},
    max_imports = limits and limits.max_imports or 20,
    max_importers = limits and limits.max_importers or 20,
  }, function(value, terminal)
    result = value
    outcome = terminal
  end)
  assert(
    vim.wait(math.max(2000, scan_timeout_ms + 1000), function()
      return result ~= nil
    end, 10),
    "Go package relationships timed out in the test harness"
  )
  return result, outcome
end

local result, outcome = run(fake_go)
equal(outcome, nil, "a successful go list scan should complete normally")
equal(#result.edges, 4, "Go build truth should separate production and test relationships")
local by_kind = {}
for _, edge in ipairs(result.edges) do
  by_kind[edge.kind] = edge
end
local outgoing = assert(by_kind.module_imports, "the build dependency edge is missing")
local incoming = assert(by_kind.module_importers, "the build dependent edge is missing")
local test_outgoing = assert(by_kind.test_dependencies, "the test dependency edge is missing")
local test_incoming = assert(by_kind.test_dependents, "the test dependent edge is missing")
equal(outgoing.target.id, dependency.boundary_id)
equal(incoming.source.id, dependent.boundary_id)
equal(outgoing.evidence_records, {
  { provider = "Go tool", method = "go list/Imports", class = "semantic" },
  { provider = "Tree-sitter", method = "adapter/moduleTarget", class = "semantic" },
}, "active syntax evidence should corroborate the Go build dependency")
equal(outgoing.evidence.provider, "Go tool+Tree-sitter")
equal(
  outgoing.occurrences,
  { occurrence(paths.focus, 2) },
  "test and build-ignored import sites must not leak into production dependencies"
)
equal(incoming.evidence.provider, "Go tool+Tree-sitter")
equal(
  incoming.occurrences,
  { occurrence(paths.dependent, 5) },
  "dependent evidence should retain its active source import site"
)
equal(test_outgoing.target.id, source_only.boundary_id)
equal(test_incoming.source.id, test_dependent.boundary_id)
equal(test_outgoing.evidence_records, {
  { provider = "Go tool", method = "go list/TestImports", class = "semantic" },
  { provider = "Go tool", method = "go list/XTestImports", class = "semantic" },
  { provider = "Tree-sitter", method = "adapter/moduleTarget", class = "semantic" },
}, "internal and external test imports should contribute distinct evidence")
equal(test_outgoing.occurrences, {
  occurrence(paths.focus_test, 6),
  occurrence(paths.focus_xtest, 8),
}, "test dependencies should retain only their test import sites")
equal(test_incoming.evidence_records, {
  { provider = "Go tool", method = "go list/TestImports", class = "semantic" },
  { provider = "Go tool", method = "go list/XTestImports", class = "semantic" },
  { provider = "Tree-sitter", method = "adapter/moduleTarget", class = "semantic" },
}, "test dependents should retain both Go test import classes")
equal(test_incoming.occurrences, {
  occurrence(paths.test_dependent_test, 7),
  occurrence(paths.test_dependent_xtest, 9),
}, "test dependents should retain only their test import sites")
assert(not vim.iter(result.edges):any(function(edge)
  return edge.kind == "test_dependencies" and graph.related_node(edge).id == dependency.boundary_id
end), "a production dependency must not be duplicated as a test dependency")
equal(result.contributors, {
  { id = "go_build", label = "Go tool" },
  { id = "syntax", label = "Tree-sitter" },
})
local snapshot = graph.new(focus)
graph.merge(snapshot, result)
local mapped = require("archlens.model").build(focus, snapshot, {})
equal(
  vim.tbl_map(function(section)
    return { id = section.id, label = section.label, rows = #section.rows }
  end, mapped.sections),
  {
    { id = "module_imports", label = "Package dependencies", rows = 1 },
    { id = "module_importers", label = "Package dependents", rows = 1 },
    { id = "test_dependencies", label = "Test dependencies", rows = 1 },
    { id = "test_dependents", label = "Test dependents", rows = 1 },
  },
  "package models should render production and test-only relationships separately"
)

local first_invocations = vim.fn.readfile(invocation_path)[1]
equal(first_invocations, "x", "the initial relationship run should execute go list once")
local cached = run(fake_go)
equal(#cached.edges, 4, "cached build results should remain materializable")
equal(
  vim.fn.readfile(invocation_path)[1],
  "x",
  "repeated package navigation should reuse the Go package scan"
)
local limited = run(fake_go, nil, { max_imports = 1, max_importers = 1 })
equal(#limited.edges, 2, "production relationships should consume shared limits first")
assert(
  vim.iter(limited.edges):all(function(edge)
    return edge.kind == "module_imports" or edge.kind == "module_importers"
  end),
  "test-only relationships should not expand the existing package result bounds"
)
equal(
  vim
    .iter(limited.note_records)
    :filter(function(note)
      return note.summary == "package results limited"
    end)
    :fold(0, function(count)
      return count + 1
    end),
  2,
  "dependency and dependent limits should report omitted test-only rows"
)
go_packages.clear_cache(project)
run(fake_go)
equal(
  vim.fn.readfile(invocation_path)[1],
  "xx",
  "clearing the project cache should force a fresh Go package scan"
)

local fallback, unavailable = run(vim.fs.joinpath(project, "missing-go"))
equal(unavailable.state, "unavailable", "a missing Go command should use a typed outcome")
equal(#fallback.edges, 4, "unavailable Go analysis should retain all Tree-sitter relationships")
local fallback_by_kind = {}
for _, edge in ipairs(fallback.edges) do
  fallback_by_kind[edge.kind] = edge
end
equal(
  fallback_by_kind.module_imports.occurrences,
  { occurrence(paths.focus, 2), occurrence(paths.focus_ignored, 3) },
  "fallback production dependencies should exclude test import sites"
)
equal(
  fallback_by_kind.test_dependencies.occurrences,
  { occurrence(paths.focus_test, 6), occurrence(paths.focus_xtest, 8) },
  "fallback dependencies should classify Go test files"
)
equal(
  fallback_by_kind.test_dependents.occurrences,
  { occurrence(paths.test_dependent_test, 7), occurrence(paths.test_dependent_xtest, 9) },
  "fallback dependents should classify Go test files"
)
assert(
  table.concat(fallback.notes, "\n"):find("Go build-aware package analysis was skipped", 1, true),
  "fallback results should explain why build-aware filtering was unavailable"
)

local slow_go = vim.fs.joinpath(project, "slow-go")
vim.fn.writefile(
  { "#!/bin/sh", "sleep 1", "exec cat " .. vim.fn.shellescape(output_path) },
  slow_go
)
assert(vim.uv.fs_chmod(slow_go, 493))
local timed_out, timeout_outcome = run(slow_go, 20)
equal(timeout_outcome.state, "timed_out", "slow Go analysis should retain its timeout outcome")
equal(#timed_out.edges, 4, "a Go timeout should fall back to Tree-sitter relationships")

local cancelled_result
local cancel = go_packages.relationships(focus, 0, {
  build = {
    command = slow_go,
    timeout_ms = 100,
    max_packages = 20,
    max_output_bytes = 64 * 1024,
  },
  imports = {},
  max_imports = 20,
  max_importers = 20,
}, function(value)
  cancelled_result = value
end)
cancel()
vim.wait(250, function()
  return false
end, 10)
equal(cancelled_result, nil, "cancelled subscribers must ignore late provider completion")
assert(import_index_calls.cancellations >= 2, "cancellation should propagate to import-index work")

print("archlens.nvim Go package provider tests passed")

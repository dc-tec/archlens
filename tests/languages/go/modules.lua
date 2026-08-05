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

local function zero_range()
  return {
    start = { line = 0, character = 0 },
    ["end"] = { line = 0, character = 0 },
  }
end

local project = vim.fn.tempname()
local module_specs = {
  plugin = {
    path = "example.test/plugin",
    dir = vim.fs.joinpath(project, "plugin"),
  },
  sdk = {
    path = "example.test/sdk/v2",
    dir = vim.fs.joinpath(project, "sdk"),
  },
  shared = {
    path = "example.test/shared",
    dir = vim.fs.joinpath(project, "shared"),
  },
}
vim.fn.mkdir(project, "p")
vim.fn.writefile(
  { "go 1.26.5", "use ./plugin", "use ./sdk", "use ./shared" },
  vim.fs.joinpath(project, "go.work")
)
for _, spec in pairs(module_specs) do
  vim.fn.mkdir(spec.dir, "p")
  spec.go_mod = vim.fs.joinpath(spec.dir, "go.mod")
  vim.fn.writefile({ "module " .. spec.path }, spec.go_mod)
end

local function module_context(spec)
  return {
    id = "go-module:" .. spec.path,
    name = spec.path,
    kind = vim.lsp.protocol.SymbolKind.Module,
    kind_name = "Go module",
    scope = "boundary",
    root_dir = spec.dir,
    location = { uri = vim.uri_from_fname(spec.go_mod), range = zero_range() },
    path = spec.go_mod,
    path_label = "go.mod",
    language = "go",
    import_filetype = "go",
    is_boundary = true,
    module_context = true,
    preserve_file_identity = true,
    enclosing_boundaries = {},
    boundary_id = "go-module:" .. spec.path,
    boundary_class = "build",
    boundary_level = "module",
    boundary_path = spec.dir,
    boundary_keys = {},
  }
end

local modules = {}
for _, name in ipairs({ "plugin", "sdk", "shared" }) do
  local spec = module_specs[name]
  modules[#modules + 1] = {
    Path = spec.path,
    Main = true,
    Dir = spec.dir,
    GoMod = spec.go_mod,
  }
end

local packages = {
  {
    Dir = vim.fs.joinpath(module_specs.plugin.dir, "backend"),
    ImportPath = module_specs.plugin.path .. "/backend",
    Module = modules[1],
    Imports = {
      module_specs.sdk.path .. "/framework",
      module_specs.sdk.path .. "/logical",
      module_specs.shared.path .. "/identity",
    },
  },
  {
    Dir = vim.fs.joinpath(module_specs.plugin.dir, "cmd"),
    ImportPath = module_specs.plugin.path .. "/cmd",
    Module = modules[1],
    Imports = { module_specs.plugin.path .. "/backend" },
  },
  {
    Dir = vim.fs.joinpath(module_specs.sdk.dir, "framework"),
    ImportPath = module_specs.sdk.path .. "/framework",
    Module = modules[2],
    Imports = { module_specs.plugin.path .. "/backend" },
  },
  {
    Dir = vim.fs.joinpath(module_specs.sdk.dir, "logical"),
    ImportPath = module_specs.sdk.path .. "/logical",
    Module = modules[2],
    Imports = {},
  },
  {
    Dir = vim.fs.joinpath(module_specs.shared.dir, "identity"),
    ImportPath = module_specs.shared.path .. "/identity",
    Module = modules[3],
    Imports = {},
  },
}

local module_output = vim.fs.joinpath(project, "modules.json")
local package_output = vim.fs.joinpath(project, "packages.json")
local function write_stream(path, values)
  local encoded = {}
  for _, value in ipairs(values) do
    encoded[#encoded + 1] = vim.json.encode(value)
  end
  vim.fn.writefile({ table.concat(encoded) }, path)
end
write_stream(module_output, modules)
write_stream(package_output, packages)

local invocations = vim.fs.joinpath(project, "invocations")
local fake_go = vim.fs.joinpath(project, "fake-go")
vim.fn.writefile({
  "#!/bin/sh",
  "printf x >> " .. vim.fn.shellescape(invocations),
  'if [ "$2" = "-m" ]; then',
  "  exec /bin/cat " .. vim.fn.shellescape(module_output),
  "fi",
  "exec /bin/cat " .. vim.fn.shellescape(package_output),
}, fake_go)
assert(vim.uv.fs_chmod(fake_go, 493))

local go_modules = require("archlens.languages.go.modules")
local boundaries = require("archlens.boundaries")
local go_workspace = require("archlens.languages.go.workspace")
local graph = require("archlens.graph")
local model = require("archlens.model")

local function run(context, command, include_dependents, timeout_ms)
  local result
  local outcome
  go_modules.relationships(context, 0, {
    build = {
      command = command or fake_go,
      timeout_ms = timeout_ms or 1000,
      max_modules = 10,
      max_packages = 20,
      max_output_bytes = 64 * 1024,
    },
    include_dependents = include_dependents ~= false,
    max_imports = 10,
    max_importers = 10,
  }, function(value, terminal)
    result = value
    outcome = terminal
  end)
  assert(
    vim.wait(2000, function()
      return result ~= nil
    end, 10),
    "Go module relationships timed out in the test harness"
  )
  return result, outcome
end

local focus = module_context(module_specs.plugin)
equal(go_modules.supports(focus), true, "Go module boundaries should enable aggregation")
local result, outcome = run(focus)
equal(outcome, nil, "a successful workspace scan should complete normally")
equal(#result.edges, 3, "module focus should aggregate two dependencies and one dependent")
local rows = {}
for _, edge in ipairs(result.edges) do
  local related = assert(graph.related_node(edge))
  rows[edge.kind .. "\0" .. related.id] = edge
  equal(related.visibility_scope, "project", "workspace modules should remain project-visible")
end
equal(
  rows["module_imports\0go-module:" .. module_specs.sdk.path].target.detail,
  "2 package edges",
  "multiple package imports should aggregate into one module dependency"
)
equal(
  rows["module_imports\0go-module:" .. module_specs.shared.path].target.detail,
  "1 package edge"
)
equal(rows["module_importers\0go-module:" .. module_specs.sdk.path].source.detail, "1 package edge")
local mapped = model.build(
  focus,
  vim.tbl_extend("force", result, {
    focus = graph.node_from_context(focus),
  }),
  { include_external = false }
)
equal(#mapped.sections, 2, "workspace modules outside the focused root should remain visible")
equal(#mapped.sections[1].rows, 2, "module dependencies should render as stable boundary rows")
equal(#mapped.sections[2].rows, 1, "module dependents should render separately")
equal(result.contributors, { { id = "go_build", label = "Go tool" } })

local outbound_only = run(focus, nil, false)
equal(#outbound_only.edges, 2, "disabling inbound analysis should omit module dependents")

equal(vim.fn.readfile(invocations)[1], "xx", "a workspace scan should run two Go commands")
local sdk_context = rows["module_imports\0go-module:" .. module_specs.sdk.path].target.context
equal(sdk_context.go_workspace_file, vim.fs.joinpath(project, "go.work"))
equal(
  sdk_context.enclosing_boundaries[1].boundary_level,
  "workspace",
  "module relationship targets should retain their workspace parent"
)
local sdk_result = run(sdk_context)
equal(#sdk_result.edges, 2, "focused workspace peers should reuse the cached module graph")
equal(
  vim.fn.readfile(invocations)[1],
  "xx",
  "module navigation within one workspace should reuse the Go scan"
)

local work_file = vim.fs.joinpath(project, "go.work")
local workspace_focus = boundaries.context({
  root_dir = project,
  path = work_file,
  language = "go",
}, go_workspace.boundary(work_file))
equal(go_modules.supports(workspace_focus), true, "Go workspace boundaries should enable members")
local workspace_result, workspace_outcome = run(workspace_focus)
equal(workspace_outcome, nil, "a successful workspace member scan should complete normally")
equal(#workspace_result.edges, 3, "workspace focus should expose each active module once")
for _, edge in ipairs(workspace_result.edges) do
  equal(edge.kind, "workspace_members")
  local member = assert(graph.related_node(edge))
  equal(member.visibility_scope, "project")
  equal(member.context.enclosing_boundaries[1].boundary_id, workspace_focus.boundary_id)
end
local workspace_model = model.build(
  workspace_focus,
  vim.tbl_extend("force", workspace_result, {
    focus = graph.node_from_context(workspace_focus),
  }),
  { include_external = false }
)
equal(#workspace_model.sections, 1)
equal(workspace_model.sections[1].label, "Workspace modules")
equal(#workspace_model.sections[1].rows, 3)
equal(
  vim.fn.readfile(invocations)[1],
  "xxx",
  "workspace membership should require only the module-list command"
)

go_modules.clear_cache()
run(focus)
equal(vim.fn.readfile(invocations)[1], "xxxxx", "cache clearing should rebuild the module graph")

local fallback, unavailable = run(focus, vim.fs.joinpath(project, "missing-go"))
equal(unavailable.state, "unavailable", "a missing Go command should use a typed outcome")
equal(#fallback.edges, 0, "unavailable module analysis should return an empty bounded delta")
assert(
  table.concat(fallback.notes, "\n"):find("Go module analysis was skipped", 1, true),
  "module analysis fallback should explain the missing command"
)

local slow_go = vim.fs.joinpath(project, "slow-go")
vim.fn.writefile(
  { "#!/bin/sh", "sleep 1", "exec " .. vim.fn.shellescape(fake_go) .. ' "$@"' },
  slow_go
)
assert(vim.uv.fs_chmod(slow_go, 493))
local timed_out, timeout_outcome = run(focus, slow_go, true, 20)
equal(timeout_outcome.state, "timed_out", "slow module discovery should retain its timeout outcome")
equal(#timed_out.edges, 0, "timed-out module analysis should keep a bounded empty result")

print("archlens.nvim Go module provider tests passed")

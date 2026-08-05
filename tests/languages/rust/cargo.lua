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

local fixture_manifest = assert(
  vim.api.nvim_get_runtime_file("tests/fixtures/rust-workspace/Cargo.toml", false)[1],
  "Rust workspace fixture is unavailable"
)
local fixture_root = vim.fs.dirname(fixture_manifest)
local app_manifest = vim.fs.joinpath(fixture_root, "app", "Cargo.toml")
local app_source = vim.fs.joinpath(fixture_root, "app", "src", "lib.rs")
local shared_core_source = vim.fs.joinpath(fixture_root, "shared", "core.rs")
local cargo_command = assert(vim.fn.exepath("cargo"), "Cargo is unavailable")

local metadata_result = vim
  .system({
    cargo_command,
    "metadata",
    "--format-version",
    "1",
    "--locked",
    "--offline",
    "--manifest-path",
    app_manifest,
  }, { text = true })
  :wait()
equal(metadata_result.code, 0, "the real Cargo fixture metadata command should succeed")
local declared_metadata_result = vim
  .system({
    cargo_command,
    "metadata",
    "--format-version",
    "1",
    "--no-deps",
    "--offline",
    "--manifest-path",
    app_manifest,
  }, { text = true })
  :wait()
equal(declared_metadata_result.code, 0, "declaration-only Cargo metadata should succeed")

local temp = vim.fn.tempname()
vim.fn.mkdir(temp, "p")
local metadata_path = vim.fs.joinpath(temp, "metadata.json")
vim.fn.writefile({ metadata_result.stdout }, metadata_path, "b")
local invocations = vim.fs.joinpath(temp, "invocations")
local fake_cargo = vim.fs.joinpath(temp, "cargo")
local cat_command = assert(vim.fn.exepath("cat"), "cat is unavailable")
vim.fn.writefile({
  "#!/bin/sh",
  "printf x >> " .. vim.fn.shellescape(invocations),
  "exec " .. vim.fn.shellescape(cat_command) .. " " .. vim.fn.shellescape(metadata_path),
}, fake_cargo)
assert(vim.uv.fs_chmod(fake_cargo, 493))

local cargo = require("archlens.languages.rust.cargo")
local graph = require("archlens.graph")
local declared_index =
  cargo._build_index(vim.json.decode(declared_metadata_result.stdout), app_manifest, 32, "declared")
equal(
  declared_index.optional_dependencies,
  1,
  "declaration-only metadata should count omitted optional dependencies"
)
equal(
  declared_index.unresolved_dependencies,
  1,
  "declaration-only metadata should report dependencies outside its package set"
)
local options = {
  command = fake_cargo,
  timeout_ms = 1000,
  max_packages = 32,
  max_output_bytes = 128 * 1024,
}

local function discover(path, current_options)
  local descriptors
  local outcome
  cargo.discover(path, fixture_root, {}, function(value, terminal)
    descriptors = value or false
    outcome = terminal
  end, current_options or options)
  assert(
    vim.wait(3000, function()
      return descriptors ~= nil
    end, 10),
    "Cargo boundary discovery timed out in the test harness"
  )
  return descriptors ~= false and descriptors or nil, outcome
end

local refresh_root = vim.fs.joinpath(temp, "refresh-workspace")
local refresh_package = vim.fs.joinpath(refresh_root, "app")
local refresh_source = vim.fs.joinpath(refresh_package, "src", "lib.rs")
vim.fn.mkdir(vim.fs.dirname(refresh_source), "p")
vim.fn.writefile({
  "[workspace]",
  'members = ["app"]',
  'resolver = "3"',
}, vim.fs.joinpath(refresh_root, "Cargo.toml"))
local function write_refresh_manifest(name)
  vim.fn.writefile({
    "[package]",
    'name = "' .. name .. '"',
    'edition = "2024"',
    'version = "0.1.0"',
  }, vim.fs.joinpath(refresh_package, "Cargo.toml"))
end
write_refresh_manifest("before-refresh")
vim.fn.writefile({ "pub fn value() -> usize { 1 }" }, refresh_source)
local refresh_options = {
  command = cargo_command,
  timeout_ms = 1000,
  max_packages = 8,
  max_output_bytes = 128 * 1024,
}
cargo.clear_cache()
local before_refresh = discover(refresh_source, refresh_options)
equal(before_refresh[1].name, "before-refresh")
write_refresh_manifest("after-refresh")
local still_cached = discover(refresh_source, refresh_options)
equal(still_cached[1].name, "before-refresh", "Cargo metadata should remain cached until refresh")
cargo.clear_cache()
local after_refresh = discover(refresh_source, refresh_options)
equal(
  after_refresh[1].name,
  "after-refresh",
  "clearing the Cargo cache should re-read changed manifests"
)

cargo.clear_cache()
local descriptors, discovery_outcome = discover(app_source)
equal(discovery_outcome, nil, "Cargo boundary discovery should complete normally")
equal(#descriptors, 2, "a workspace member should expose package and workspace boundaries")
equal(descriptors[1].level, "package")
equal(descriptors[1].name, "archlens-app")
equal(descriptors[1].path, vim.fs.joinpath(fixture_root, "app"))
equal(descriptors[1].representative_path, app_manifest)
equal(descriptors[1].evidence.method, "cargo metadata/packages")
equal(descriptors[2].level, "workspace")
equal(descriptors[2].path, fixture_root)
equal(descriptors[2].representative_path, fixture_manifest)
equal(vim.fn.readfile(invocations)[1], "x", "boundary discovery should invoke Cargo once")

local shared_descriptors, shared_outcome = discover(shared_core_source)
equal(shared_outcome, nil, "Cargo target sources outside a package directory should resolve")
equal(
  vim.tbl_map(function(descriptor)
    return { level = descriptor.level, name = descriptor.name }
  end, shared_descriptors),
  {
    { level = "package", name = "archlens-core" },
    { level = "workspace", name = "rust-workspace" },
  },
  "Cargo targets should provide authoritative package ownership outside the manifest directory"
)
equal(
  shared_descriptors[1].path,
  vim.fs.joinpath(fixture_root, "core"),
  "target ownership should retain the package directory as its boundary path"
)
equal(
  vim.fn.readfile(invocations)[1],
  "x",
  "target ownership should reuse the cached workspace metadata"
)

local boundary_contexts = require("archlens.boundaries").contexts({
  language = "rust",
  root_dir = fixture_root,
  path = app_source,
}, descriptors)
local app_context = boundary_contexts[1]
local workspace_context = boundary_contexts[2]
equal(app_context.boundary_level, "package")
equal(app_context.enclosing_boundaries[1].boundary_level, "workspace")

local function relationships(context, current_options, limits)
  local result
  local outcome
  cargo.relationships(context, 0, {
    build = current_options or options,
    include_dependents = true,
    max_imports = limits and limits.max_imports or 24,
    max_importers = limits and limits.max_importers or 24,
  }, function(value, terminal)
    result = value
    outcome = terminal
  end)
  assert(
    vim.wait(3000, function()
      return result ~= nil
    end, 10),
    "Cargo relationships timed out in the test harness"
  )
  return result, outcome
end

local app_relationships, app_outcome = relationships(app_context)
equal(app_outcome, nil)
equal(#app_relationships.edges, 5, "Cargo should distinguish normal, build, and dev edges")
local by_kind = {}
for _, edge in ipairs(app_relationships.edges) do
  by_kind[edge.kind] = by_kind[edge.kind] or {}
  by_kind[edge.kind][#by_kind[edge.kind] + 1] = graph.related_node(edge)
end
equal(#by_kind.module_imports, 3, "ordinary Cargo dependencies should remain package dependencies")
equal(#by_kind.build_dependencies, 1, "build dependencies should have their own relationship")
equal(#by_kind.test_dependencies, 1, "dev dependencies should remain test-only relationships")
equal(by_kind.build_dependencies[1].name, "archlens-build-helper")
equal(by_kind.test_dependencies[1].name, "archlens-dev-helper")
equal(
  vim.tbl_map(function(edge)
    return edge.kind .. ":" .. graph.related_node(edge).name
  end, app_relationships.edges),
  {
    "module_imports:archlens-core",
    "module_imports:archlens-external",
    "module_imports:archlens-renamed",
    "build_dependencies:archlens-build-helper",
    "test_dependencies:archlens-dev-helper",
  },
  "Cargo relationship ordering should be deterministic across dependency kinds"
)
assert(not vim.iter(app_relationships.edges):any(function(edge)
  return graph.related_node(edge).name == "archlens-optional"
end), "disabled optional dependencies should not appear in the resolved graph")
local renamed = vim.iter(by_kind.module_imports):find(function(node)
  return node.name == "archlens-renamed"
end)
assert(
  renamed and renamed.detail:find("as renamed_core", 1, true),
  "renamed dependencies should retain their alias"
)
local external = vim.iter(by_kind.module_imports):find(function(node)
  return node.name == "archlens-external"
end)
equal(
  external and external.visibility_scope,
  "external",
  "path dependencies outside the workspace should retain external visibility"
)
equal(
  app_relationships.edges[1].evidence.provider,
  "Cargo",
  "Cargo relationships should retain their evidence provider"
)
equal(
  vim.fn.readfile(invocations)[1],
  "x",
  "package relationships should reuse boundary discovery metadata"
)

local package_model = require("archlens.model").build(
  app_context,
  (function()
    local snapshot = graph.new(app_context)
    graph.merge(snapshot, app_relationships)
    return snapshot
  end)(),
  {}
)
equal(
  vim.tbl_map(function(section)
    return { id = section.id, label = section.label, rows = #section.rows }
  end, package_model.sections),
  {
    { id = "module_imports", label = "Package dependencies", rows = 2 },
    { id = "build_dependencies", label = "Build dependencies", rows = 1 },
    { id = "test_dependencies", label = "Test dependencies", rows = 1 },
  },
  "Cargo package relationships should render with Rust package vocabulary"
)
assert(
  table.concat(package_model.notes, "\n"):find("1 external relationship hidden", 1, true),
  "Cargo dependencies outside the workspace should use the shared external summary"
)

local workspace_relationships, workspace_outcome = relationships(workspace_context)
equal(workspace_outcome, nil)
equal(#workspace_relationships.edges, 5, "the Cargo workspace should expose every member once")
for _, edge in ipairs(workspace_relationships.edges) do
  equal(edge.kind, "workspace_members")
  equal(graph.related_node(edge).visibility_scope, "project")
end
local workspace_snapshot = graph.new(workspace_context)
graph.merge(workspace_snapshot, workspace_relationships)
local workspace_model = require("archlens.model").build(workspace_context, workspace_snapshot, {})
equal(workspace_model.sections[1].label, "Workspace packages")
equal(#workspace_model.sections[1].rows, 5)

local core_row = vim.iter(workspace_model.sections[1].rows):find(function(row)
  return row.name == "archlens-core"
end)
assert(core_row and core_row.context, "workspace package rows should remain navigable boundaries")
local core_relationships = relationships(core_row.context)
equal(#core_relationships.edges, 1)
equal(core_relationships.edges[1].kind, "module_importers")
equal(graph.related_node(core_relationships.edges[1]).name, "archlens-app")
for _, case in ipairs({
  { package = "archlens-build-helper", kind = "build_dependents" },
  { package = "archlens-dev-helper", kind = "test_dependents" },
}) do
  local row = vim.iter(workspace_model.sections[1].rows):find(function(candidate)
    return candidate.name == case.package
  end)
  assert(row and row.context, case.package .. " should remain a navigable package boundary")
  local dependent_result = relationships(row.context)
  equal(#dependent_result.edges, 1, case.package .. " should have one dependent")
  equal(
    dependent_result.edges[1].kind,
    case.kind,
    case.package .. " should preserve its incoming dependency kind"
  )
end

local limited = relationships(app_context, nil, { max_imports = 1, max_importers = 1 })
equal(#limited.edges, 1, "Cargo dependency classes should share the configured outgoing limit")
assert(
  table.concat(limited.notes, "\n"):find("4 Cargo relationships", 1, true),
  "relationship limits should report every omitted Cargo class"
)

cargo.clear_cache()
local refreshed_metadata = vim.json.decode(metadata_result.stdout)
for _, package in ipairs(refreshed_metadata.packages) do
  if package.manifest_path == app_manifest then
    package.name = "archlens-app-refreshed"
  end
end
vim.fn.writefile({ vim.json.encode(refreshed_metadata) }, metadata_path, "b")
local refreshed = discover(app_source)
equal(vim.fn.readfile(invocations)[1], "xx", "clearing caches should force fresh Cargo metadata")
equal(
  refreshed[1].name,
  "archlens-app-refreshed",
  "fresh Cargo metadata should replace cached boundary details"
)
vim.fn.writefile({ metadata_result.stdout }, metadata_path, "b")
cargo.clear_cache()

local disabled, disabled_outcome = discover(app_source, { enabled = false })
equal(disabled, nil)
equal(disabled_outcome, nil, "disabling Rust analysis should omit boundaries without an error")

local missing, unavailable = discover(app_source, {
  command = vim.fs.joinpath(temp, "missing-cargo"),
  timeout_ms = 100,
})
equal(missing, nil)
equal(unavailable.state, "unavailable", "a missing Cargo command should use a typed outcome")

local malformed_cargo = vim.fs.joinpath(temp, "malformed-cargo")
vim.fn.writefile({ "#!/bin/sh", "printf not-json" }, malformed_cargo)
assert(vim.uv.fs_chmod(malformed_cargo, 493))
local malformed, malformed_outcome = discover(app_source, {
  command = malformed_cargo,
  timeout_ms = 100,
})
equal(malformed, nil)
equal(malformed_outcome.state, "failed")
assert(malformed_outcome.message:find("malformed JSON", 1, true))

local declared_metadata_path = vim.fs.joinpath(temp, "declared-metadata.json")
vim.fn.writefile({ declared_metadata_result.stdout }, declared_metadata_path, "b")
local fallback_cargo = vim.fs.joinpath(temp, "fallback-cargo")
vim.fn.writefile({
  "#!/bin/sh",
  'case " $* " in *" --locked "*) printf \'locked metadata unavailable\' >&2; exit 1;; esac',
  "exec " .. vim.fn.shellescape(cat_command) .. " " .. vim.fn.shellescape(declared_metadata_path),
}, fallback_cargo)
assert(vim.uv.fs_chmod(fallback_cargo, 493))
local fallback_options = {
  command = fallback_cargo,
  timeout_ms = 1000,
  max_packages = 32,
  max_output_bytes = 128 * 1024,
}
local fallback_descriptors, fallback_outcome = discover(app_source, fallback_options)
equal(fallback_outcome, nil, "declaration-only fallback should still resolve boundaries")
local fallback_context = require("archlens.boundaries").contexts({
  language = "rust",
  root_dir = fixture_root,
  path = app_source,
}, fallback_descriptors)[1]
local fallback_relationships = relationships(fallback_context, fallback_options)
equal(#fallback_relationships.edges, 4, "fallback should retain workspace-local declarations")
local fallback_notes = table.concat(fallback_relationships.notes, "\n")
assert(fallback_notes:find("locked metadata unavailable", 1, true))
assert(fallback_notes:find("1 optional dependency was omitted", 1, true))
assert(fallback_notes:find("1 Cargo dependency reference", 1, true))

local slow_cargo = vim.fs.joinpath(temp, "slow-cargo")
local termination_marker = vim.fs.joinpath(temp, "cargo-terminated")
vim.fn.writefile({
  "#!/bin/sh",
  "trap 'printf terminated > " .. vim.fn.shellescape(termination_marker) .. "; exit 0' TERM",
  "while :; do sleep 0.01; done",
}, slow_cargo)
assert(vim.uv.fs_chmod(slow_cargo, 493))
local timed_out, timeout_outcome = discover(app_source, {
  command = slow_cargo,
  timeout_ms = 20,
})
equal(timed_out, nil)
equal(timeout_outcome.state, "timed_out")
vim.fn.delete(termination_marker)

local cancelled_callbacks = 0
cargo.clear_cache()
local cancel = cargo.discover(app_source, fixture_root, {}, function()
  cancelled_callbacks = cancelled_callbacks + 1
end, {
  command = slow_cargo,
  timeout_ms = 100,
})
cancel()
assert(
  vim.wait(500, function()
    return vim.uv.fs_stat(termination_marker) ~= nil
  end, 10),
  "cancelling the last Cargo subscriber should stop the metadata process"
)
equal(cancelled_callbacks, 0, "cancelled Cargo subscribers must ignore late completion")

print("archlens.nvim Cargo provider tests passed")

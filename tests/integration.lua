local fixture_root = assert(vim.env.ARCHLENS_FIXTURE_ROOT, "ARCHLENS_FIXTURE_ROOT is required")
local ast_grep_command = assert(vim.env.ARCHLENS_AST_GREP, "ARCHLENS_AST_GREP is required")
local rust_fixture_root =
  assert(vim.env.ARCHLENS_RUST_FIXTURE_ROOT, "ARCHLENS_RUST_FIXTURE_ROOT is required")
local cargo_command = assert(vim.env.ARCHLENS_CARGO, "ARCHLENS_CARGO is required")

local graph = require("archlens.graph")
local model = require("archlens.model")
local test_paths = require("archlens.test_paths")
local boundaries = require("archlens.boundaries")
local treesitter = require("archlens.treesitter")

local function assert_equal(actual, expected, message)
  if actual ~= expected then
    error(string.format("%s: expected %s, got %s", message, expected, actual))
  end
end

local function names(contexts)
  return vim.tbl_map(function(context)
    return context.name
  end, contexts or {})
end

local function contains(values, expected)
  for _, value in ipairs(values) do
    if value == expected then
      return true
    end
  end
  return false
end

local cases = {
  {
    file = "flake.nix",
    filetype = "nix",
    position = { line = 5, character = 8 },
    name = "service",
    child = "port",
  },
  {
    file = "main.go",
    filetype = "go",
    position = { line = 7, character = 6 },
    name = "Run",
    sibling = "helper",
  },
  {
    file = "main.go",
    filetype = "go",
    position = { line = 10, character = 0 },
    name = "Manager",
    selection_character = 5,
    absent_child = "Manager",
    file_fallback = true,
  },
  {
    file = "main.rs",
    filetype = "rust",
    position = { line = 3, character = 12 },
    name = "run",
    ancestor = "Worker",
    sibling = "helper",
  },
  {
    file = "main.ml",
    filetype = "ocaml",
    position = { line = 2, character = 5 },
    name = "run",
    child = "adjusted",
    sibling = "helper",
  },
  {
    file = "imports.mli",
    filetype = "ocaml",
    position = { line = 3, character = 5 },
    name = "run",
    language = "ocaml_interface",
  },
}

local contexts = {}
for _, case in ipairs(cases) do
  vim.cmd.edit(vim.fn.fnameescape(fixture_root .. "/" .. case.file))
  vim.bo.filetype = case.filetype
  local base_context
  if case.file_fallback then
    base_context = require("archlens.model").context_from_item({
      name = case.file,
      kind = vim.lsp.protocol.SymbolKind.File,
      uri = vim.uri_from_bufnr(0),
      range = { start = case.position, ["end"] = case.position },
      selectionRange = { start = case.position, ["end"] = case.position },
    }, {
      id = 1,
      name = "fixture-lsp",
      offset_encoding = "utf-8",
      root_dir = fixture_root,
      supports_calls = false,
    })
    base_context.file_fallback = true
  end
  local context = treesitter.resolve(0, case.position, base_context)
  assert(context, case.file .. " did not resolve through Tree-sitter")
  assert_equal(context.name, case.name, case.file .. " resolved the wrong symbol")
  if case.selection_character then
    assert_equal(
      context.location.range.start.character,
      case.selection_character,
      case.file .. " selected the declaration keyword instead of its identifier"
    )
  end
  if case.child then
    assert(contains(names(context.syntax.children), case.child), case.file .. " child is missing")
  end
  if case.sibling then
    assert(
      contains(names(context.syntax.siblings), case.sibling),
      case.file .. " sibling is missing"
    )
  end
  if case.ancestor then
    assert(
      contains(names(context.syntax.ancestors), case.ancestor),
      case.file .. " ancestor is missing"
    )
  end
  if case.language then
    assert_equal(context.language, case.language, case.file .. " selected the wrong grammar")
  end
  if case.absent_child then
    assert(
      not contains(names(context.syntax.children), case.absent_child),
      case.file .. " contains the focused symbol as its own child"
    )
  end
  contexts[case.file] = context
end

local go_boundaries = contexts["main.go"].enclosing_boundaries
assert(go_boundaries, "Go symbols should resolve their containing boundaries")
assert_equal(#go_boundaries, 2, "Go symbols should resolve package and module boundaries")
local go_boundary = go_boundaries[1]
assert(go_boundary, "Go symbols should resolve their containing package boundary")
assert_equal(
  go_boundary.boundary_id,
  "go-package:example.com/project",
  "Go package boundaries should use the import path as stable identity"
)
assert_equal(go_boundary.kind_name, "Go package", "Go boundaries should retain language terms")
assert_equal(go_boundary.name, "project", "root Go packages should use a compact label")
assert_equal(go_boundary.boundary_level, "package", "the immediate Go boundary should be a package")
local go_module = go_boundaries[2]
assert_equal(
  go_module.boundary_id,
  "go-module:example.com/project",
  "Go modules should use the declared module path as stable identity"
)
assert_equal(go_module.kind_name, "Go module", "Go module boundaries should retain build terms")
assert_equal(go_module.boundary_level, "module", "the outer Go boundary should be a module")
assert_equal(go_module.boundary_class, "build", "Go modules should be build boundaries")
assert_equal(
  go_boundary.enclosing_boundaries[1].boundary_id,
  go_module.boundary_id,
  "package focus should retain its immediate module parent"
)

local function resolve_fixture(file, filetype, position)
  vim.cmd.edit(vim.fn.fnameescape(fixture_root .. "/" .. file))
  vim.bo.filetype = filetype
  return assert(treesitter.resolve(0, position), file .. " did not resolve through Tree-sitter")
end

vim.cmd.edit(vim.fn.fnameescape(fixture_root .. "/main.go"))
vim.bo.filetype = "go"
local followed_go_boundary = boundaries.for_buffer(0, "package")
assert(followed_go_boundary, "Go buffers should resolve a package boundary without a symbol")
assert_equal(
  followed_go_boundary.boundary_id,
  go_boundary.boundary_id,
  "buffer-level package resolution should retain stable boundary identity"
)
local refocused_go_boundary = treesitter.resolve(0, { line = 2, character = 5 }, go_boundary)
assert_equal(
  refocused_go_boundary.boundary_id,
  go_boundary.boundary_id,
  "boundary focus should not collapse back into its representative symbol"
)
assert_equal(refocused_go_boundary.is_boundary, true, "boundary focus should retain its scope")

local refocused_go_module = treesitter.resolve(0, { line = 2, character = 5 }, go_module)
assert_equal(
  refocused_go_module.boundary_id,
  go_module.boundary_id,
  "module focus should not collapse back into its representative symbol"
)
assert_equal(refocused_go_module.is_boundary, true, "module focus should retain boundary scope")

vim.cmd.edit(vim.fn.fnameescape(fixture_root .. "/go.mod"))
vim.bo.filetype = "gomod"
local opened_go_module = treesitter.resolve(0, { line = 0, character = 0 }, go_module)
assert_equal(
  opened_go_module.language,
  "go",
  "boundary focus should retain its adapter language when its representative has another filetype"
)

local go_interface = resolve_fixture("types.go", "go", { line = 2, character = 0 })
assert_equal(go_interface.name, "Contract", "Go type-keyword focus should select the type spec")
assert_equal(
  go_interface.kind_name,
  "Type",
  "syntax-only Go interfaces retain the generic type kind"
)
assert(
  vim.deep_equal(names(go_interface.syntax.children), { "First", "Second" }),
  "Go interface methods should be exposed as type members"
)
assert_equal(#go_interface.syntax.ancestors, 0, "Go type wrappers must stay out of the focus trail")
local semantic_go_interface = require("archlens.model").context_from_item({
  name = "Contract",
  kind = vim.lsp.protocol.SymbolKind.Interface,
  uri = vim.uri_from_bufnr(0),
  range = {
    start = { line = 2, character = 0 },
    ["end"] = { line = 5, character = 1 },
  },
  selectionRange = {
    start = { line = 2, character = 5 },
    ["end"] = { line = 2, character = 13 },
  },
}, {
  id = 10,
  name = "gopls",
  offset_encoding = "utf-8",
  root_dir = fixture_root,
  supports_calls = false,
})
local enriched_go_interface =
  treesitter.resolve(0, { line = 2, character = 6 }, semantic_go_interface)
assert_equal(
  enriched_go_interface.kind,
  vim.lsp.protocol.SymbolKind.Interface,
  "Tree-sitter range enrichment should preserve the semantic interface kind"
)
assert_equal(
  enriched_go_interface.kind_name,
  "Interface",
  "type presentation should retain the semantic interface label"
)
assert_equal(
  #enriched_go_interface.syntax.ancestors,
  0,
  "semantic type enrichment should not reintroduce a duplicate wrapper ancestor"
)

local go_struct = resolve_fixture("types.go", "go", { line = 7, character = 5 })
assert(
  vim.deep_equal(names(go_struct.syntax.children), {
    "Left",
    "Right",
    "Embedded",
    "pkg.Qualified",
  }),
  "Go struct members should include grouped and embedded fields"
)
local go_second_field = resolve_fixture("types.go", "go", { line = 8, character = 8 })
assert_equal(go_second_field.name, "Right", "Go grouped fields should resolve the selected name")
assert_equal(go_second_field.kind_name, "Field", "Go grouped fields should retain their kind")
local broad_go_parent = require("archlens.model").context_from_item({
  name = "Point",
  kind = vim.lsp.protocol.SymbolKind.Struct,
  uri = vim.uri_from_bufnr(0),
  range = {
    start = { line = 7, character = 0 },
    ["end"] = { line = 11, character = 1 },
  },
  selectionRange = {
    start = { line = 7, character = 5 },
    ["end"] = { line = 7, character = 10 },
  },
}, {
  id = 12,
  name = "gopls",
  offset_encoding = "utf-8",
  root_dir = fixture_root,
  supports_calls = false,
})
local enriched_go_field = treesitter.resolve(0, { line = 8, character = 8 }, broad_go_parent)
assert_equal(enriched_go_field.name, "Right", "Tree-sitter should retain the narrower field focus")
assert_equal(
  enriched_go_field.kind_name,
  "Field",
  "a broader semantic parent must not lend its type kind to a nested field"
)

local rust_trait = resolve_fixture("types.rs", "rust", { line = 0, character = 11 })
assert(
  vim.deep_equal(names(rust_trait.syntax.children), {
    "Output",
    "NAME",
    "required",
    "defaulted",
  }),
  "Rust traits should expose associated items and required and default methods"
)
local rust_enum = resolve_fixture("types.rs", "rust", { line = 16, character = 10 })
assert(
  vim.deep_equal(names(rust_enum.syntax.children), { "Ready", "Failed" }),
  "Rust enums should expose their variants"
)
for _, child in ipairs(rust_enum.syntax.children) do
  assert_equal(child.kind_name, "EnumMember", "Rust variants should retain their member kind")
end

local ocaml_variant = resolve_fixture("types.ml", "ocaml", { line = 0, character = 0 })
assert_equal(ocaml_variant.name, "status", "OCaml type-keyword focus should select the binding")
assert(
  vim.deep_equal(names(ocaml_variant.syntax.children), { "Ready", "Failed" }),
  "OCaml variants should expose their constructors"
)
assert_equal(
  #ocaml_variant.syntax.ancestors,
  0,
  "OCaml type wrappers must stay out of the focus trail"
)
local ocaml_record = resolve_fixture("types.ml", "ocaml", { line = 2, character = 5 })
assert(
  vim.deep_equal(names(ocaml_record.syntax.children), { "first", "second" }),
  "OCaml records should expose their fields"
)
local semantic_ocaml_type = require("archlens.model").context_from_item({
  name = "record",
  kind = vim.lsp.protocol.SymbolKind.TypeParameter,
  uri = vim.uri_from_bufnr(0),
  range = {
    start = { line = 2, character = 0 },
    ["end"] = { line = 5, character = 1 },
  },
  selectionRange = {
    start = { line = 2, character = 5 },
    ["end"] = { line = 2, character = 11 },
  },
}, {
  id = 11,
  name = "ocamllsp",
  offset_encoding = "utf-8",
  root_dir = fixture_root,
  supports_calls = false,
})
local enriched_ocaml_type = treesitter.resolve(0, { line = 2, character = 6 }, semantic_ocaml_type)
assert_equal(
  enriched_ocaml_type.kind_name,
  "Type",
  "Tree-sitter should retain a clearer language label for an equivalent semantic kind"
)
local ocaml_poly = resolve_fixture("types.ml", "ocaml", { line = 7, character = 5 })
assert(
  vim.deep_equal(names(ocaml_poly.syntax.children), { "`One", "`Two" }),
  "OCaml polymorphic variants should expose their tags"
)
local ocaml_recursive = resolve_fixture("types.ml", "ocaml", { line = 10, character = 5 })
assert_equal(ocaml_recursive.name, "second", "OCaml recursive bindings should focus independently")
assert_equal(#ocaml_recursive.syntax.ancestors, 0, "a sibling type binding is not an ancestor")

local ocaml_interface_record = resolve_fixture("types.mli", "ocaml", { line = 2, character = 5 })
assert_equal(
  ocaml_interface_record.language,
  "ocaml_interface",
  "OCaml interface members should use the interface grammar"
)
assert(
  vim.deep_equal(names(ocaml_interface_record.syntax.children), { "first", "second" }),
  "OCaml interface records should expose their fields"
)

vim.cmd.edit(vim.fn.fnameescape(fixture_root .. "/main.go"))
vim.bo.filetype = "go"
local type_context = vim.deepcopy(contexts["main.go"])
type_context.client_id = 7
type_context.client_name = "gopls"
type_context.supports_calls = false
type_context.wire_type_item = { data = { opaque = "type-hierarchy-state" } }
local merged_type_context = treesitter.resolve(0, { line = 10, character = 5 }, type_context)
assert(
  vim.deep_equal(merged_type_context.wire_type_item, type_context.wire_type_item),
  "Tree-sitter enrichment should preserve opaque type hierarchy state"
)
local module_context = vim.deepcopy(type_context)
module_context.module_context = true
local merged_module_context = treesitter.resolve(0, { line = 10, character = 5 }, module_context)
assert(
  merged_module_context.module_context == true,
  "Tree-sitter enrichment should preserve file-level module focus"
)

vim.cmd.edit(vim.fn.fnameescape(fixture_root .. "/configuration.go"))
vim.bo.filetype = "go"
local function field_context(line, container)
  local range = {
    start = { line = line, character = 4 },
    ["end"] = { line = line, character = 11 },
  }
  return require("archlens.model").context_from_item({
    name = "Enabled",
    kind = vim.lsp.protocol.SymbolKind.Field,
    uri = vim.uri_from_bufnr(0),
    range = range,
    selectionRange = range,
  }, {
    id = 8,
    name = "gopls",
    offset_encoding = "utf-8",
    root_dir = fixture_root,
    supports_calls = false,
  }),
    container
end
local configuration_context = treesitter.resolve(0, { line = 3, character = 5 }, field_context(3))
assert(
  vim.deep_equal(configuration_context.configuration, {
    key = "Enabled",
    container = "TLSConfig",
    source = "field",
  }),
  "tagged fields in Go configuration containers should be classified"
)
local ordinary_field = treesitter.resolve(0, { line = 7, character = 5 }, field_context(7))
assert(
  ordinary_field.configuration == nil,
  "serialized fields in ordinary response types should not be called configuration"
)

vim.cmd.edit(vim.fn.fnameescape(fixture_root .. "/configuration.rs"))
vim.bo.filetype = "rust"
local function rust_field_context(line)
  local range = {
    start = { line = line, character = 8 },
    ["end"] = { line = line, character = 13 },
  }
  return require("archlens.model").context_from_item({
    name = "token",
    kind = vim.lsp.protocol.SymbolKind.Field,
    uri = vim.uri_from_bufnr(0),
    range = range,
    selectionRange = range,
  }, {
    id = 9,
    name = "rust-analyzer",
    offset_encoding = "utf-8",
    root_dir = fixture_root,
    supports_calls = false,
  })
end
local rust_configuration_context =
  treesitter.resolve(0, { line = 4, character = 9 }, rust_field_context(4))
assert(
  vim.deep_equal(rust_configuration_context.configuration, {
    key = "token",
    container = "Config",
    source = "field",
  }),
  "deserializable Rust configuration fields should be classified"
)
local rust_syntax_configuration = treesitter.resolve(0, { line = 4, character = 9 })
assert(
  rust_syntax_configuration.name == "token"
    and rust_syntax_configuration.kind == vim.lsp.protocol.SymbolKind.Field
    and vim.deep_equal(rust_syntax_configuration.configuration, {
      key = "token",
      container = "Config",
      source = "field",
    }),
  "Tree-sitter should classify Rust configuration fields without LSP document symbols: "
    .. vim.inspect(rust_syntax_configuration)
)
local rust_ordinary_field =
  treesitter.resolve(0, { line = 9, character = 9 }, rust_field_context(9))
assert(
  rust_ordinary_field.configuration == nil,
  "deserializable fields outside Rust configuration containers should remain ordinary"
)

local inline_tests_path = fixture_root .. "/inline_tests.rs"
assert(
  test_paths.is_test("rust", inline_tests_path, fixture_root, 6),
  "references inside #[cfg(test)] modules should be classified as test relationships"
)
assert(
  not test_paths.is_test("rust", inline_tests_path, fixture_root, 0),
  "production lines in a file containing inline tests must remain production relationships"
)

local inline_tests_uri = vim.uri_from_fname(inline_tests_path)
local rust_focus_context = model.context_from_item({
  name = "helper",
  kind = vim.lsp.protocol.SymbolKind.Function,
  uri = inline_tests_uri,
  range = {
    start = { line = 0, character = 0 },
    ["end"] = { line = 0, character = 14 },
  },
  selectionRange = {
    start = { line = 0, character = 3 },
    ["end"] = { line = 0, character = 9 },
  },
}, {
  id = 1,
  name = "rust-analyzer",
  offset_encoding = "utf-8",
  root_dir = fixture_root,
  supports_calls = true,
})
rust_focus_context.language = "rust"
local rust_test_caller = model.context_from_item({
  name = "helper_is_available",
  kind = vim.lsp.protocol.SymbolKind.Function,
  uri = inline_tests_uri,
  range = {
    start = { line = 5, character = 4 },
    ["end"] = { line = 7, character = 5 },
  },
  selectionRange = {
    start = { line = 5, character = 7 },
    ["end"] = { line = 5, character = 26 },
  },
}, {
  id = 1,
  name = "rust-analyzer",
  offset_encoding = "utf-8",
  root_dir = fixture_root,
  supports_calls = true,
})
local rust_call_range = {
  start = { line = 6, character = 8 },
  ["end"] = { line = 6, character = 23 },
}
local rust_usage_graph = graph.new(rust_focus_context)
graph.add_edge(
  rust_usage_graph,
  graph.edge("incoming", graph.node_from_context(rust_test_caller), rust_usage_graph.focus, {
    provider = "rust-analyzer",
    method = "callHierarchy/incomingCalls",
    class = "semantic",
  }, { occurrences = { { uri = inline_tests_uri, ranges = { rust_call_range } } } })
)
local rust_reference = graph.node_from_location({
  uri = inline_tests_uri,
  range = rust_call_range,
})
graph.add_edge(
  rust_usage_graph,
  graph.edge("test_references", rust_reference, rust_usage_graph.focus, {
    provider = "rust-analyzer",
    method = "textDocument/references",
    class = "semantic",
  })
)
local rust_usage_map = model.build(rust_focus_context, rust_usage_graph, {})
assert(not vim.iter(rust_usage_map.sections):find(function(section)
  return section.id == "incoming"
end), "callers inside Rust #[cfg(test)] modules must not remain under Entered through")
local rust_test_references = vim.iter(rust_usage_map.sections):find(function(section)
  return section.id == "test_references"
end)
assert_equal(
  #rust_test_references.rows,
  1,
  "Rust inline-test callers and references should coalesce without duplicate rows"
)
assert_equal(
  rust_test_references.rows[1].name,
  "helper_is_available",
  "Rust inline-test callers should appear under Referenced from tests"
)
assert(
  vim.deep_equal(rust_test_references.rows[1].evidence_records, {
    {
      provider = "rust-analyzer",
      method = "callHierarchy/incomingCalls",
      class = "semantic",
    },
    {
      provider = "rust-analyzer",
      method = "textDocument/references",
      class = "semantic",
    },
  }),
  "Rust inline-test callers should retain call hierarchy and reference evidence"
)

for _, case in ipairs({
  {
    file = "imports.go",
    filetype = "go",
    expected = { "example.com/project/internal/service", "example.com/project/internal/generated" },
  },
  {
    file = "imports.rs",
    filetype = "rust",
    expected = { "crate::worker" },
    target = "worker.rs",
  },
  {
    file = "imports.nix",
    filetype = "nix",
    expected = { "./module.nix", "./module2.nix" },
    target = "module.nix",
  },
  {
    file = "imports.ml",
    filetype = "ocaml",
    expected = { "Helper", "Shared" },
    targets = { "helper.ml", "shared.ml" },
  },
  {
    file = "imports.mli",
    filetype = "ocaml",
    expected = { "Helper", "Shared" },
    targets = { "helper.ml", "shared.ml" },
  },
  {
    file = "nested_imports.rs",
    filetype = "rust",
    expected = { "crate::outer::child", "crate::renamed" },
    targets = { "child.rs", "custom_module.rs" },
  },
  {
    file = "lib/application/wrapped_import.ml",
    filetype = "ocaml",
    expected = { "Camlet_domain" },
    target = "dune",
    provider = "Tree-sitter+Dune",
  },
}) do
  vim.cmd.edit(vim.fn.fnameescape(fixture_root .. "/" .. case.file))
  vim.bo.filetype = case.filetype
  local sites, err = treesitter.import_sites(0)
  assert(not err, case.file .. " import extraction failed: " .. tostring(err))
  assert(
    vim.deep_equal(names(sites), case.expected),
    case.file .. " returned unexpected imports: " .. vim.inspect(names(sites))
  )
  if case.target then
    assert_equal(
      vim.fs.basename(vim.uri_to_fname(sites[1].target_locations[1].uri)),
      case.target,
      case.file .. " did not resolve its static module target"
    )
  end
  if case.targets then
    local targets = vim.tbl_map(function(site)
      return vim.fs.basename(vim.uri_to_fname(site.target_locations[1].uri))
    end, sites)
    assert(
      vim.deep_equal(targets, case.targets),
      case.file .. " did not resolve its static module targets: " .. vim.inspect(targets)
    )
  end
  if case.provider then
    assert_equal(
      sites[1].resolution_provider,
      case.provider,
      case.file .. " returned the wrong static resolution evidence"
    )
  end
end

vim.cmd.edit(vim.fn.fnameescape(fixture_root .. "/imports.rs"))
vim.bo.filetype = "rust"
local importer_file_context = {
  name = "imports.rs",
  kind = vim.lsp.protocol.SymbolKind.File,
  kind_name = "File",
  scope = "file",
  root_dir = fixture_root,
  supports_calls = false,
  module_context = true,
  preserve_file_identity = true,
  location = {
    uri = vim.uri_from_bufnr(0),
    range = {
      start = { line = 0, character = 4 },
      ["end"] = { line = 0, character = 10 },
    },
  },
}
local preserved_file = treesitter.resolve(0, { line = 0, character = 4 }, importer_file_context)
assert_equal(preserved_file.scope, "file", "importer focus should preserve file identity")
assert_equal(preserved_file.name, "imports.rs", "importer focus should not become the mod item")

local enclosing, enclosing_error = treesitter.enclosing_containers(
  fixture_root .. "/inline_tests.rs",
  { { line = 6, character = 15 } }
)
assert(not enclosing_error, "Rust container extraction failed: " .. tostring(enclosing_error))
assert_equal(
  enclosing[1].name,
  "helper_is_available",
  "the nearest test function should group uses"
)
assert(
  vim.deep_equal(enclosing[1].trail, { "tests" }),
  "Rust inline test groups should retain their module trail"
)

for _, case in ipairs({
  { file = "imports.nix", language = "nix", expected = { "./module.nix", "./module2.nix" } },
  {
    file = "nested_imports.rs",
    language = "rust",
    expected = { "crate::outer::child", "crate::renamed" },
  },
  { file = "imports.ml", language = "ocaml", expected = { "Helper", "Shared" } },
  {
    file = "imports.mli",
    language = "ocaml_interface",
    expected = { "Helper", "Shared" },
  },
}) do
  local path = fixture_root .. "/" .. case.file
  local loaded = vim.fn.bufnr(path)
  if loaded ~= -1 then
    vim.api.nvim_buf_delete(loaded, { force = true })
  end
  local sites, err = treesitter.import_sites_from_path(path, case.language)
  assert(not err, case.file .. " string import extraction failed: " .. tostring(err))
  assert(
    vim.deep_equal(names(sites), case.expected),
    case.file .. " returned unexpected string imports: " .. vim.inspect(names(sites))
  )
end

vim.cmd.edit(vim.fn.fnameescape(fixture_root .. "/imports.mli"))
vim.bo.filetype = "ocaml"
local health = require("archlens.health")
local interface_buffer = health._inspect_buffer(0)
assert_equal(
  interface_buffer.language,
  "ocaml_interface",
  "health should select its grammar using the interface path"
)
local interface_health = health._inspect_treesitter(0, interface_buffer)
assert(interface_health.parser, "health should probe the ocaml_interface parser for .mli files")
assert(interface_health.adapter, "health should select the ocaml_interface adapter for .mli files")
assert(
  interface_health.query,
  "the configured ocaml_interface import query should compile: "
    .. tostring(interface_health.query_error)
)
local interface_containers, interface_container_error =
  treesitter.enclosing_containers(fixture_root .. "/imports.mli", {
    { line = 3, character = 5 },
  })
assert(
  not interface_container_error,
  "path-based container parsing should use the interface grammar: "
    .. tostring(interface_container_error)
)
assert(
  vim.deep_equal(interface_containers, {}),
  "top-level value specs have no enclosing container"
)

for _, case in ipairs({
  { file = "module.nix", filetype = "nix", importer = "imports.nix", anchor = "module.nix" },
  {
    file = "imports/worker.rs",
    filetype = "rust",
    importer = "imports.rs",
    anchor = "imports/worker.rs",
  },
  {
    file = "helper.ml",
    filetype = "ocaml",
    importer = "imports.ml",
    additional_importer = "imports.mli",
    anchor = "helper.ml",
  },
  {
    file = "internal/service/service.go",
    filetype = "go",
    importer = "imports.go",
    anchor = "internal/service",
  },
  {
    file = "lib/domain/dune",
    filetype = "dune",
    scan_filetype = "ocaml",
    importer = "wrapped_import.ml",
    anchor = "lib/domain/dune",
  },
}) do
  local path = fixture_root .. "/" .. case.file
  vim.cmd.edit(vim.fn.fnameescape(path))
  vim.bo.filetype = case.filetype
  local context = {
    name = vim.fs.basename(path),
    kind = vim.lsp.protocol.SymbolKind.File,
    kind_name = "File",
    scope = "file",
    root_dir = fixture_root,
    supports_calls = false,
    location = {
      uri = vim.uri_from_fname(path),
      range = {
        start = { line = 0, character = 0 },
        ["end"] = { line = 0, character = 0 },
      },
    },
  }
  local relationships
  require("archlens.import_index").relationships(context, 0, {
    command = "rg",
    filetype = case.scan_filetype,
    timeout_ms = 5000,
    max_index_files = 100,
    max_file_bytes = 1024 * 1024,
    batch_size = 4,
    max_importers = 20,
    filters = {},
  }, function(result)
    relationships = result
  end)
  assert(
    vim.wait(6000, function()
      return relationships ~= nil
    end, 20),
    case.file .. " reverse module indexing timed out"
  )
  local importer_found = false
  local additional_importer_found = case.additional_importer == nil
  for _, edge in ipairs(relationships.edges) do
    local importer = vim.fs.basename(vim.uri_to_fname(edge.source.location.uri))
    if importer == case.additional_importer then
      additional_importer_found = true
    end
    if importer == case.importer then
      importer_found = true
      assert_equal(edge.kind, "module_importers", case.file .. " returned the wrong relation")
      assert_equal(
        edge.presentation.section_anchor.prefix,
        "for",
        case.file .. " returned the wrong module anchor prefix"
      )
      assert_equal(
        edge.presentation.section_anchor.label,
        case.anchor,
        case.file .. " returned the wrong module anchor label"
      )
    end
  end
  assert(importer_found, case.file .. " did not find importer " .. case.importer)
  assert(
    additional_importer_found,
    case.file .. " did not find importer " .. tostring(case.additional_importer)
  )
  assert(
    not table.concat(relationships.notes or {}, "\n"):find("could not be parsed", 1, true),
    case.file .. " mixed-language module indexing reported parser failures"
  )
end

local completed = false
local structural
require("archlens.ast_grep").relationships(contexts["flake.nix"], {
  command = ast_grep_command,
  timeout_ms = 5000,
  max_results = 20,
}, function(result)
  structural = result
  completed = true
end)
assert(
  vim.wait(7000, function()
    return completed
  end, 20),
  "ast-grep integration timed out"
)
assert(
  vim.tbl_contains(
    vim.tbl_map(function(value)
      return value.label
    end, structural.contributors),
    "ast-grep"
  ),
  "ast-grep did not run against the Nix fixture"
)
assert(#structural.edges >= 2, "ast-grep did not find project-level Nix usages")
for _, edge in ipairs(structural.edges) do
  assert(edge.kind == "structural", "ast-grep returned a non-structural graph edge")
end

local rust_source = rust_fixture_root .. "/app/src/lib.rs"
vim.cmd.edit(vim.fn.fnameescape(rust_source))
vim.bo.filetype = "rust"
local rust_context = assert(
  treesitter.resolve(0, { line = 3, character = 7 }),
  "the Cargo fixture did not resolve through Tree-sitter"
)
local discovered_rust
local rust_discovery_outcome
boundaries.discover(rust_context, {
  timeout_ms = 5000,
  adapters = {
    rust = {
      command = cargo_command,
      timeout_ms = 4000,
      max_packages = 32,
      max_output_bytes = 128 * 1024,
    },
  },
}, function(enriched, outcome)
  discovered_rust = enriched
  rust_discovery_outcome = outcome
end)
assert(
  vim.wait(6000, function()
    return discovered_rust ~= nil
  end, 20),
  "Cargo boundary integration timed out"
)
assert(not rust_discovery_outcome, "Cargo boundary discovery failed")
assert_equal(
  #discovered_rust.enclosing_boundaries,
  2,
  "the Cargo fixture should expose package and workspace boundaries"
)
local rust_package = discovered_rust.enclosing_boundaries[1]
local rust_workspace = discovered_rust.enclosing_boundaries[2]
assert_equal(rust_package.boundary_level, "package", "the nearest Cargo boundary is wrong")
assert_equal(rust_package.name, "archlens-app", "the Cargo package name is wrong")
assert_equal(rust_workspace.boundary_level, "workspace", "the outer Cargo boundary is wrong")

local rust_relationships
local rust_relationship_outcome
require("archlens.languages.rust.cargo").relationships(rust_package, 0, {
  build = {
    command = cargo_command,
    timeout_ms = 4000,
    max_packages = 32,
    max_output_bytes = 128 * 1024,
  },
  include_dependents = true,
  max_imports = 24,
  max_importers = 24,
}, function(result, outcome)
  rust_relationships = result
  rust_relationship_outcome = outcome
end)
assert(
  vim.wait(6000, function()
    return rust_relationships ~= nil
  end, 20),
  "Cargo relationship integration timed out"
)
assert(not rust_relationship_outcome, "Cargo relationship discovery failed")
assert_equal(#rust_relationships.edges, 5, "Cargo should expose all local dependency kinds")
local rust_kinds = {}
for _, edge in ipairs(rust_relationships.edges) do
  rust_kinds[edge.kind] = (rust_kinds[edge.kind] or 0) + 1
end
assert_equal(rust_kinds.module_imports, 3, "Cargo normal dependencies are incomplete")
assert_equal(rust_kinds.build_dependencies, 1, "Cargo build dependencies are incomplete")
assert_equal(rust_kinds.test_dependencies, 1, "Cargo dev dependencies are incomplete")

print("archlens.nvim parser, ast-grep, and Cargo integration tests passed")
vim.cmd.quitall()

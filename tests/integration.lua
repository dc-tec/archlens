local fixture_root = assert(vim.env.ARCHLENS_FIXTURE_ROOT, "ARCHLENS_FIXTURE_ROOT is required")
local ast_grep_command = assert(vim.env.ARCHLENS_AST_GREP, "ARCHLENS_AST_GREP is required")

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
  if case.absent_child then
    assert(
      not contains(names(context.syntax.children), case.absent_child),
      case.file .. " contains the focused symbol as its own child"
    )
  end
  contexts[case.file] = context
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
assert(structural.ast_grep_ran, "ast-grep did not run against the Nix fixture")
assert(#structural.structural >= 2, "ast-grep did not find project-level Nix usages")

print("archlens.nvim parser and ast-grep integration tests passed")
vim.cmd.quitall()

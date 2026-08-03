local source = debug.getinfo(1, "S").source:sub(2)
local fallback_root = vim.fn.fnamemodify(source, ":p:h:h")
vim.opt.runtimepath:prepend(fallback_root)
local runtime_health = vim.api.nvim_get_runtime_file("lua/archlens/health.lua", false)[1]
local root = runtime_health and vim.fn.fnamemodify(runtime_health, ":p:h:h:h") or fallback_root

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

local function section(report, title)
  for _, candidate in ipairs(report) do
    if candidate.title == title then
      return candidate
    end
  end
  error("missing health section: " .. title)
end

local function diagnostic(report_section, level, text)
  for _, candidate in ipairs(report_section.items) do
    if candidate.level == level and candidate.message:find(text, 1, true) then
      return candidate
    end
  end
  error(string.format("missing %s diagnostic containing %q", level, text))
end

local function contains(lines, text)
  for _, line in ipairs(lines) do
    if line:find(text, 1, true) then
      return true
    end
  end
  return false
end

local function run()
  local health = require("archlens.health")

  local healthy = health._diagnose({
    version = { major = 0, minor = 12, patch = 4 },
    buffer = {
      valid = true,
      bufnr = 7,
      name = "/workspace/internal/controller.go",
      filetype = "go",
      root = "/workspace",
      marker_root = true,
    },
    treesitter = { parser = true, adapter = true },
    lsp = {
      clients = {
        {
          id = 3,
          name = "example-lsp",
          methods = { "document symbols", "implementations", "project references" },
          errors = {},
        },
      },
    },
    ast_grep = {
      command = "ast-grep",
      path = "/tools/ast-grep",
      supported = true,
      available = true,
      version = "ast-grep 0.40.0",
    },
    ripgrep = {
      command = "rg",
      path = "/tools/rg",
      supported = true,
      available = true,
      version = "ripgrep 15.1.0",
    },
  })
  diagnostic(section(healthy, "ArchLens runtime"), "ok", "Neovim 0.12.4")
  diagnostic(section(healthy, "ArchLens context"), "ok", "Project root: /workspace")
  diagnostic(section(healthy, "ArchLens Tree-sitter"), "ok", "parser is available")
  diagnostic(
    section(healthy, "ArchLens LSP"),
    "ok",
    "document symbols, implementations, project references"
  )
  diagnostic(section(healthy, "ArchLens ast-grep"), "ok", "ast-grep 0.40.0")
  diagnostic(section(healthy, "ArchLens ripgrep"), "ok", "Executable: /tools/rg")
  diagnostic(section(healthy, "ArchLens ripgrep"), "ok", "ripgrep 15.1.0")

  local degraded = health._diagnose({
    version = { major = 0, minor = 11, patch = 3 },
    buffer = {
      valid = true,
      bufnr = 2,
      name = "/tmp/example/source.unknown",
      filetype = "unknown",
      root = "/tmp/example",
      marker_root = false,
    },
    treesitter = { parser = false, adapter = false },
    lsp = { clients = {} },
    ast_grep = { command = "ast-grep", available = false },
    ripgrep = { command = "rg", supported = true, available = false },
  })
  diagnostic(section(degraded, "ArchLens runtime"), "error", "requires Neovim 0.12")
  diagnostic(section(degraded, "ArchLens context"), "warn", "project scope falls back")
  diagnostic(section(degraded, "ArchLens Tree-sitter"), "warn", "No Tree-sitter parser")
  diagnostic(section(degraded, "ArchLens Tree-sitter"), "warn", "No ArchLens Tree-sitter adapter")
  diagnostic(section(degraded, "ArchLens LSP"), "warn", "No LSP clients")
  diagnostic(section(degraded, "ArchLens ast-grep"), "warn", "structural project matches")
  diagnostic(section(degraded, "ArchLens ripgrep"), "warn", "reverse module relationships")

  local disabled = health._diagnose({
    version = { major = 0, minor = 12, patch = 4 },
    buffer = { valid = false },
    treesitter = { parser = false, adapter = false },
    lsp = { clients = {} },
    ast_grep = { command = "/custom/ast-grep", enabled = false },
    ripgrep = { command = "/custom/rg", enabled = false },
  })
  diagnostic(
    section(disabled, "ArchLens ast-grep"),
    "info",
    "disabled by the ArchLens configuration"
  )
  diagnostic(section(disabled, "ArchLens ripgrep"), "info", "Reverse module analysis is disabled")

  local unsupported = health._diagnose({
    version = { major = 0, minor = 12, patch = 4 },
    buffer = {
      valid = true,
      bufnr = 4,
      name = "/workspace/main.ml",
      filetype = "ocaml",
      root = "/workspace",
      marker_root = true,
    },
    treesitter = { parser = true, adapter = true },
    lsp = { clients = {} },
    ast_grep = {
      command = "ast-grep",
      enabled = true,
      supported = false,
      note = "ast-grep has no OCaml parser; semantic references remain available.",
    },
    ripgrep = { command = "rg", enabled = true, supported = false },
  })
  diagnostic(section(unsupported, "ArchLens ast-grep"), "info", "no OCaml parser")
  diagnostic(section(unsupported, "ArchLens ripgrep"), "warn", "reverse module adapter")

  local invalid = health._diagnose({
    version = { major = 0, minor = 12, patch = 4 },
    buffer = { valid = false },
    treesitter = { parser = false, adapter_error = "adapter exploded" },
    lsp = { clients = {}, error = "client lookup exploded" },
    ast_grep = {
      command = "ast-grep",
      path = "/tools/ast-grep",
      available = true,
      error = "version lookup timed out",
    },
    ripgrep = {
      command = "rg",
      path = "/tools/rg",
      available = true,
      error = "version lookup timed out",
    },
  })
  diagnostic(section(invalid, "ArchLens context"), "error", "No source buffer")
  diagnostic(section(invalid, "ArchLens Tree-sitter"), "error", "adapter exploded")
  diagnostic(section(invalid, "ArchLens LSP"), "error", "client lookup exploded")
  diagnostic(section(invalid, "ArchLens ast-grep"), "warn", "version lookup timed out")
  diagnostic(section(invalid, "ArchLens ripgrep"), "warn", "version lookup timed out")

  local query_mismatch = health._diagnose({
    version = { major = 0, minor = 12, patch = 4 },
    buffer = {
      valid = true,
      bufnr = 5,
      name = "/workspace/api.mli",
      filetype = "ocaml",
      language = "ocaml_interface",
    },
    treesitter = {
      language = "ocaml_interface",
      parser = true,
      adapter = true,
      query_error = "Invalid node type open_module_signature",
    },
    lsp = { clients = {} },
    ast_grep = { command = "ast-grep", supported = false },
    ripgrep = { command = "rg", supported = false },
  })
  diagnostic(
    section(query_mismatch, "ArchLens Tree-sitter"),
    "error",
    "import query is invalid for the ocaml_interface grammar"
  )

  local fixture = root .. "/tests/fixtures/project/main.go"
  vim.cmd.edit(vim.fn.fnameescape(fixture))
  vim.bo.filetype = "go"
  local source_buffer = vim.api.nvim_get_current_buf()
  vim.cmd("checkhealth archlens")
  assert_equal(
    health._context_buffer(),
    source_buffer,
    ":checkhealth should inspect the source buffer rather than health://"
  )
  local output = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  assert(contains(output, "ArchLens context"), "the standard health provider should be discovered")
  assert(contains(output, fixture), "the health report should name the originating source buffer")
  assert(
    contains(output, "Project root: " .. root),
    "the health report should include the project root"
  )
end

local ok, err = xpcall(run, debug.traceback)
if not ok then
  vim.api.nvim_err_writeln(err)
  vim.cmd("cquit 1")
end

print("archlens.nvim health tests passed")
vim.cmd("quitall")

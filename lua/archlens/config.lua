local ast_grep = require("archlens.ast_grep")

local M = {}

local defaults = {
  width = 56,
  max_items = 8,
  include_external = false,
  filters = {
    include_generated = false,
    include_vendored = false,
    exclude = {},
  },
  imports = {
    enabled = true,
    timeout_ms = 5000,
    max_imports = 24,
    max_sites = 96,
    concurrency = 4,
    inbound = {
      enabled = true,
      command = "rg",
      timeout_ms = 8000,
      max_index_files = 1000,
      max_candidate_files = 2000,
      max_file_bytes = 1024 * 1024,
      batch_size = 16,
      max_importers = 24,
    },
  },
  lsp = {
    resolve_timeout_ms = 5000,
    relationship_timeout_ms = 8000,
  },
  grouping = {
    enabled = true,
    timeout_ms = 1500,
    batch_size = 4,
    max_file_bytes = 1024 * 1024,
    max_edges = 500,
  },
  ast_grep = {
    enabled = true,
    command = "ast-grep",
    timeout_ms = 15000,
    max_results = 80,
    min_name_length = 5,
    threads = 1,
    globs = vim.deepcopy(ast_grep.default_globs),
  },
}

local function validate_table(value, path)
  if value ~= nil and type(value) ~= "table" then
    error(string.format("ArchLens setup: %s must be a table", path), 3)
  end
end

local function validate(options)
  validate_table(options, "options")
  if not options then
    return
  end

  for _, key in ipairs({ "filters", "imports", "lsp", "grouping", "ast_grep" }) do
    validate_table(options[key], key)
  end
  if type(options.imports) == "table" then
    validate_table(options.imports.inbound, "imports.inbound")
  end
  if type(options.filters) == "table" then
    validate_table(options.filters.exclude, "filters.exclude")
  end
  if type(options.ast_grep) == "table" then
    validate_table(options.ast_grep.globs, "ast_grep.globs")
  end
end

function M.new()
  return vim.deepcopy(defaults)
end

function M.merge(current, options)
  validate(options)
  return vim.tbl_deep_extend("force", current, options or {})
end

return M

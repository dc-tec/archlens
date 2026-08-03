local ast_grep = require("archlens.ast_grep")

local M = {}

local defaults = {
  width = 56,
  max_items = 8,
  sections = {
    collapse_secondary = true,
    default_collapsed = { "siblings" },
    hidden = {},
    max_items = {},
    order = {},
  },
  include_external = false,
  cursor_follow = {
    enabled = false,
    debounce_ms = 150,
  },
  providers = {},
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
    cold_start_retry = {
      enabled = true,
      delay_ms = 3000,
      window_ms = 10000,
    },
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

local function validate_section_ids(value, path)
  if value == nil then
    return
  end
  validate_table(value, path)
  if not vim.islist(value) then
    error(string.format("ArchLens setup: %s must be a list of section IDs", path), 3)
  end
  local seen = {}
  for index, section_id in ipairs(value) do
    if type(section_id) ~= "string" or section_id == "" then
      error(string.format("ArchLens setup: %s[%d] must be a non-empty section ID", path, index), 3)
    end
    if seen[section_id] then
      error(
        string.format("ArchLens setup: %s contains duplicate section ID %s", path, section_id),
        3
      )
    end
    seen[section_id] = true
  end
end

local function validate_section_limits(value)
  if value == nil then
    return
  end
  validate_table(value, "sections.max_items")
  for section_id, limit in pairs(value) do
    if type(section_id) ~= "string" or section_id == "" then
      error("ArchLens setup: sections.max_items keys must be non-empty section IDs", 3)
    end
    if type(limit) ~= "number" or limit < 1 or limit % 1 ~= 0 then
      error(
        string.format(
          "ArchLens setup: sections.max_items.%s must be a positive integer",
          section_id
        ),
        3
      )
    end
  end
end

local function validate_cold_start_retry(value)
  if value == nil then
    return
  end
  validate_table(value, "lsp.cold_start_retry")
  if value.enabled ~= nil and type(value.enabled) ~= "boolean" then
    error("ArchLens setup: lsp.cold_start_retry.enabled must be a boolean", 3)
  end
  for _, field in ipairs({ "delay_ms", "window_ms" }) do
    local setting = value[field]
    if setting ~= nil and (type(setting) ~= "number" or setting < 0 or setting % 1 ~= 0) then
      error(
        string.format(
          "ArchLens setup: lsp.cold_start_retry.%s must be a non-negative integer",
          field
        ),
        3
      )
    end
  end
end

local function validate_cursor_follow(value)
  if value == nil then
    return
  end
  validate_table(value, "cursor_follow")
  if value.enabled ~= nil and type(value.enabled) ~= "boolean" then
    error("ArchLens setup: cursor_follow.enabled must be a boolean", 3)
  end
  if
    value.debounce_ms ~= nil
    and (type(value.debounce_ms) ~= "number" or value.debounce_ms < 0 or value.debounce_ms % 1 ~= 0)
  then
    error("ArchLens setup: cursor_follow.debounce_ms must be a non-negative integer", 3)
  end
end

local function validate(options)
  validate_table(options, "options")
  if not options then
    return
  end

  for _, key in ipairs({
    "sections",
    "cursor_follow",
    "providers",
    "filters",
    "imports",
    "lsp",
    "grouping",
    "ast_grep",
  }) do
    validate_table(options[key], key)
  end
  validate_cursor_follow(options.cursor_follow)
  if type(options.lsp) == "table" then
    validate_cold_start_retry(options.lsp.cold_start_retry)
  end
  if type(options.sections) == "table" then
    if
      options.sections.collapse_secondary ~= nil
      and type(options.sections.collapse_secondary) ~= "boolean"
    then
      error("ArchLens setup: sections.collapse_secondary must be a boolean", 3)
    end
    validate_section_ids(options.sections.default_collapsed, "sections.default_collapsed")
    validate_section_ids(options.sections.hidden, "sections.hidden")
    validate_section_ids(options.sections.order, "sections.order")
    validate_section_limits(options.sections.max_items)
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

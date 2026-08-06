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
  boundaries = {
    timeout_ms = 8000,
  },
  providers = {},
  filters = {
    include_generated = false,
    include_vendored = false,
    exclude = {},
  },
  imports = {
    enabled = true,
    show_on_symbols = false,
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
    max_results = 256,
    max_occurrences = 256,
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
    max_output_bytes = 1024 * 1024,
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

local function validate_known_keys(value, path, keys)
  if value == nil then
    return
  end
  validate_table(value, path)
  for key in pairs(value) do
    if type(key) ~= "string" or not keys[key] then
      error(
        string.format("ArchLens setup: %s.%s is not a recognized option", path, tostring(key)),
        3
      )
    end
  end
end

local function validate_boolean(value, path)
  if value ~= nil and type(value) ~= "boolean" then
    error(string.format("ArchLens setup: %s must be a boolean", path), 3)
  end
end

local function is_integer(value)
  return type(value) == "number"
    and value == value
    and value ~= math.huge
    and value ~= -math.huge
    and value % 1 == 0
end

local function validate_integer(value, path, minimum, label)
  if value ~= nil and (not is_integer(value) or value < minimum) then
    error(string.format("ArchLens setup: %s must be a %s integer", path, label), 3)
  end
end

local function validate_command(value, path)
  if value ~= nil and (type(value) ~= "string" or value == "") then
    error(string.format("ArchLens setup: %s must be a non-empty string", path), 3)
  end
end

local function validate_string_list(value, path, item_label)
  if value == nil then
    return
  end
  validate_table(value, path)
  if not vim.islist(value) then
    error(string.format("ArchLens setup: %s must be a list of %s", path, item_label), 3)
  end
  for index, item in ipairs(value) do
    if type(item) ~= "string" or item == "" then
      error(string.format("ArchLens setup: %s[%d] must be a non-empty string", path, index), 3)
    end
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
    if not is_integer(limit) or limit < 1 then
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
  validate_known_keys(value, "lsp.cold_start_retry", {
    enabled = true,
    delay_ms = true,
    window_ms = true,
  })
  validate_boolean(value.enabled, "lsp.cold_start_retry.enabled")
  for _, field in ipairs({ "delay_ms", "window_ms" }) do
    validate_integer(value[field], "lsp.cold_start_retry." .. field, 0, "non-negative")
  end
end

local function validate_cursor_follow(value)
  if value == nil then
    return
  end
  validate_table(value, "cursor_follow")
  validate_known_keys(value, "cursor_follow", { enabled = true, debounce_ms = true })
  validate_boolean(value.enabled, "cursor_follow.enabled")
  validate_integer(value.debounce_ms, "cursor_follow.debounce_ms", 0, "non-negative")
end

local function validate(options)
  validate_table(options, "options")
  if not options then
    return
  end

  validate_known_keys(options, "options", {
    width = true,
    max_items = true,
    sections = true,
    include_external = true,
    cursor_follow = true,
    boundaries = true,
    providers = true,
    filters = true,
    imports = true,
    lsp = true,
    grouping = true,
    ast_grep = true,
  })

  for _, key in ipairs({
    "sections",
    "cursor_follow",
    "boundaries",
    "providers",
    "filters",
    "imports",
    "lsp",
    "grouping",
    "ast_grep",
  }) do
    validate_table(options[key], key)
  end

  validate_integer(options.width, "width", 1, "positive")
  validate_integer(options.max_items, "max_items", 1, "positive")
  validate_boolean(options.include_external, "include_external")
  validate_cursor_follow(options.cursor_follow)

  if type(options.boundaries) == "table" then
    validate_known_keys(options.boundaries, "boundaries", { timeout_ms = true })
    validate_integer(options.boundaries.timeout_ms, "boundaries.timeout_ms", 0, "non-negative")
  end

  if type(options.sections) == "table" then
    validate_known_keys(options.sections, "sections", {
      collapse_secondary = true,
      default_collapsed = true,
      hidden = true,
      max_items = true,
      order = true,
    })
    validate_boolean(options.sections.collapse_secondary, "sections.collapse_secondary")
    validate_section_ids(options.sections.default_collapsed, "sections.default_collapsed")
    validate_section_ids(options.sections.hidden, "sections.hidden")
    validate_section_ids(options.sections.order, "sections.order")
    validate_section_limits(options.sections.max_items)
  end

  if type(options.filters) == "table" then
    validate_known_keys(options.filters, "filters", {
      include_generated = true,
      include_vendored = true,
      exclude = true,
    })
    validate_boolean(options.filters.include_generated, "filters.include_generated")
    validate_boolean(options.filters.include_vendored, "filters.include_vendored")
    validate_string_list(options.filters.exclude, "filters.exclude", "path prefixes")
  end
  if type(options.imports) == "table" then
    validate_known_keys(options.imports, "imports", {
      enabled = true,
      show_on_symbols = true,
      timeout_ms = true,
      max_imports = true,
      max_sites = true,
      concurrency = true,
      inbound = true,
    })
    validate_boolean(options.imports.enabled, "imports.enabled")
    validate_boolean(options.imports.show_on_symbols, "imports.show_on_symbols")
    validate_integer(options.imports.timeout_ms, "imports.timeout_ms", 0, "non-negative")
    for _, field in ipairs({ "max_imports", "max_sites", "concurrency" }) do
      validate_integer(options.imports[field], "imports." .. field, 1, "positive")
    end
    validate_table(options.imports.inbound, "imports.inbound")
    if type(options.imports.inbound) == "table" then
      validate_known_keys(options.imports.inbound, "imports.inbound", {
        enabled = true,
        command = true,
        timeout_ms = true,
        max_index_files = true,
        max_candidate_files = true,
        max_file_bytes = true,
        batch_size = true,
        max_importers = true,
      })
      validate_boolean(options.imports.inbound.enabled, "imports.inbound.enabled")
      validate_command(options.imports.inbound.command, "imports.inbound.command")
      validate_integer(
        options.imports.inbound.timeout_ms,
        "imports.inbound.timeout_ms",
        0,
        "non-negative"
      )
      for _, field in ipairs({
        "max_index_files",
        "max_candidate_files",
        "max_file_bytes",
        "batch_size",
        "max_importers",
      }) do
        validate_integer(options.imports.inbound[field], "imports.inbound." .. field, 1, "positive")
      end
    end
  end
  if type(options.lsp) == "table" then
    validate_known_keys(options.lsp, "lsp", {
      resolve_timeout_ms = true,
      relationship_timeout_ms = true,
      max_results = true,
      max_occurrences = true,
      cold_start_retry = true,
    })
    validate_integer(options.lsp.resolve_timeout_ms, "lsp.resolve_timeout_ms", 0, "non-negative")
    validate_integer(
      options.lsp.relationship_timeout_ms,
      "lsp.relationship_timeout_ms",
      0,
      "non-negative"
    )
    validate_integer(options.lsp.max_results, "lsp.max_results", 1, "positive")
    validate_integer(options.lsp.max_occurrences, "lsp.max_occurrences", 1, "positive")
    validate_cold_start_retry(options.lsp.cold_start_retry)
  end
  if type(options.grouping) == "table" then
    validate_known_keys(options.grouping, "grouping", {
      enabled = true,
      timeout_ms = true,
      batch_size = true,
      max_file_bytes = true,
      max_edges = true,
    })
    validate_boolean(options.grouping.enabled, "grouping.enabled")
    validate_integer(options.grouping.timeout_ms, "grouping.timeout_ms", 0, "non-negative")
    for _, field in ipairs({ "batch_size", "max_file_bytes", "max_edges" }) do
      validate_integer(options.grouping[field], "grouping." .. field, 1, "positive")
    end
  end
  if type(options.ast_grep) == "table" then
    validate_known_keys(options.ast_grep, "ast_grep", {
      enabled = true,
      command = true,
      timeout_ms = true,
      max_results = true,
      max_output_bytes = true,
      min_name_length = true,
      threads = true,
      globs = true,
    })
    validate_boolean(options.ast_grep.enabled, "ast_grep.enabled")
    validate_command(options.ast_grep.command, "ast_grep.command")
    validate_integer(options.ast_grep.timeout_ms, "ast_grep.timeout_ms", 0, "non-negative")
    validate_integer(options.ast_grep.max_results, "ast_grep.max_results", 1, "positive")
    validate_integer(options.ast_grep.max_output_bytes, "ast_grep.max_output_bytes", 1, "positive")
    validate_integer(
      options.ast_grep.min_name_length,
      "ast_grep.min_name_length",
      0,
      "non-negative"
    )
    validate_integer(options.ast_grep.threads, "ast_grep.threads", 0, "non-negative")
    validate_string_list(options.ast_grep.globs, "ast_grep.globs", "glob patterns")
  end
end

function M.new()
  return vim.deepcopy(defaults)
end

function M.resolve(options)
  return M.merge(M.new(), options)
end

function M.merge(current, options)
  validate(options)
  local merged = vim.tbl_deep_extend("force", current, options or {})
  validate(merged)
  return merged
end

return M

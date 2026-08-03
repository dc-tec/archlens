local source = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(source, ":p:h:h")
vim.opt.runtimepath:prepend(root)

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

local function run()
  local config = require("archlens.config")
  local first = config.new()
  local second = config.new()
  first.filters.exclude[1] = "generated"
  assert_equal(second.filters.exclude, {}, "default configurations should not share nested state")
  assert_equal(
    second.sections.default_collapsed,
    { "siblings" },
    "nearby definitions should be the only section collapsed by default"
  )
  assert_equal(
    second.sections.collapse_secondary,
    true,
    "unmatched structural candidates should be secondary to semantic usage by default"
  )
  assert_equal(second.sections.max_items, {}, "section limits should fall back to max_items")
  assert_equal(second.sections.hidden, {}, "sections should remain visible by default")
  assert_equal(second.sections.order, {}, "relation registry order should remain the default")
  assert_equal(second.cursor_follow, {
    enabled = false,
    debounce_ms = 150,
  }, "cursor following should be opt-in and debounced by default")
  assert_equal(
    second.providers,
    {},
    "custom providers should have an empty configuration namespace"
  )
  assert_equal(second.lsp.cold_start_retry, {
    enabled = true,
    delay_ms = 3000,
    window_ms = 10000,
  }, "cold language servers should receive one bounded empty-result retry")

  local merged = config.merge(second, {
    width = 72,
    imports = {
      inbound = { max_importers = 12 },
    },
    sections = {
      collapse_secondary = false,
      default_collapsed = { "references", "siblings" },
      hidden = { "structural" },
      max_items = { references = 12 },
      order = { "incoming", "outgoing", "references" },
    },
  })
  assert_equal(merged.width, 72, "top-level options should override defaults")
  assert_equal(merged.imports.inbound.max_importers, 12, "nested options should override defaults")
  assert_equal(
    merged.imports.inbound.timeout_ms,
    8000,
    "unspecified nested defaults should remain available"
  )
  assert_equal(
    merged.sections.default_collapsed,
    { "references", "siblings" },
    "configured default-collapsed sections should replace the default list"
  )
  assert_equal(
    merged.sections.collapse_secondary,
    false,
    "secondary structural collapsing should remain configurable"
  )
  assert_equal(
    merged.sections.max_items.references,
    12,
    "per-section item limits should override the global fallback"
  )
  assert_equal(
    merged.sections.hidden,
    { "structural" },
    "hidden sections should replace the default list"
  )
  assert_equal(
    merged.sections.order,
    { "incoming", "outgoing", "references" },
    "configured section order should replace registry order"
  )

  local ok, err = pcall(config.merge, merged, { imports = false })
  assert(not ok, "malformed nested configuration should fail during setup")
  assert(
    tostring(err):find("imports must be a table", 1, true),
    "configuration failures should identify the malformed option"
  )
  assert_equal(
    merged.imports.inbound.max_importers,
    12,
    "rejected configuration should not mutate the active configuration"
  )

  local invalid_options = {
    {
      options = { sections = { collapse_secondary = "yes" } },
      message = "sections.collapse_secondary must be a boolean",
    },
    {
      options = { sections = { default_collapsed = { siblings = true } } },
      message = "sections.default_collapsed must be a list of section IDs",
    },
    {
      options = { sections = { default_collapsed = { "siblings", 2 } } },
      message = "sections.default_collapsed[2] must be a non-empty section ID",
    },
    {
      options = { sections = { max_items = { references = 0 } } },
      message = "sections.max_items.references must be a positive integer",
    },
    {
      options = { sections = { hidden = { "references", "references" } } },
      message = "sections.hidden contains duplicate section ID references",
    },
    {
      options = { sections = { order = { incoming = true } } },
      message = "sections.order must be a list of section IDs",
    },
    {
      options = { lsp = { cold_start_retry = false } },
      message = "lsp.cold_start_retry must be a table",
    },
    {
      options = { lsp = { cold_start_retry = { delay_ms = -1 } } },
      message = "lsp.cold_start_retry.delay_ms must be a non-negative integer",
    },
    {
      options = { lsp = { cold_start_retry = { enabled = "yes" } } },
      message = "lsp.cold_start_retry.enabled must be a boolean",
    },
    {
      options = { cursor_follow = { enabled = "yes" } },
      message = "cursor_follow.enabled must be a boolean",
    },
    {
      options = { cursor_follow = { debounce_ms = -1 } },
      message = "cursor_follow.debounce_ms must be a non-negative integer",
    },
  }
  for _, case in ipairs(invalid_options) do
    local valid, validation_error = pcall(config.merge, merged, case.options)
    assert(not valid, "malformed section policy should fail during setup")
    assert(
      tostring(validation_error):find(case.message, 1, true),
      "section policy failures should identify the malformed option"
    )
    assert_equal(
      merged.sections.max_items.references,
      12,
      "rejected section policy should not mutate the active configuration"
    )
  end
end

local ok, err = xpcall(run, debug.traceback)
if not ok then
  vim.api.nvim_err_writeln(err)
  vim.cmd("cquit 1")
end

print("archlens.nvim configuration tests passed")
vim.cmd("quitall!")

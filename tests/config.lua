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
  assert_equal(second.sections.max_items, {}, "section limits should fall back to max_items")

  local merged = config.merge(second, {
    width = 72,
    imports = {
      inbound = { max_importers = 12 },
    },
    sections = {
      default_collapsed = { "references", "siblings" },
      max_items = { references = 12 },
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
    merged.sections.max_items.references,
    12,
    "per-section item limits should override the global fallback"
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

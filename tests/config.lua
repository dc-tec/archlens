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

  local merged = config.merge(second, {
    width = 72,
    imports = {
      inbound = { max_importers = 12 },
    },
  })
  assert_equal(merged.width, 72, "top-level options should override defaults")
  assert_equal(merged.imports.inbound.max_importers, 12, "nested options should override defaults")
  assert_equal(
    merged.imports.inbound.timeout_ms,
    8000,
    "unspecified nested defaults should remain available"
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
end

local ok, err = xpcall(run, debug.traceback)
if not ok then
  vim.api.nvim_err_writeln(err)
  vim.cmd("cquit 1")
end

print("archlens.nvim configuration tests passed")
vim.cmd("quitall!")

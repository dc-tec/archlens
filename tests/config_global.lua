local source = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(source, ":p:h:h")
vim.opt.runtimepath:prepend(root)

local function equal(actual, expected, message)
  if not vim.deep_equal(actual, expected) then
    error(
      string.format(
        "%s\nexpected: %s\nactual:   %s",
        message,
        vim.inspect(expected),
        vim.inspect(actual)
      )
    )
  end
end

vim.g.archlens = {
  width = 72,
  imports = { inbound = { max_importers = 12 } },
}

local archlens = require("archlens")
local configured = archlens.get_config()
equal(configured.width, 72, "the global table should override defaults on first use")
equal(
  configured.imports.inbound.max_importers,
  12,
  "the global table should merge nested options with defaults"
)
equal(
  configured.imports.inbound.timeout_ms,
  8000,
  "unspecified nested defaults should remain available"
)

vim.g.archlens = { width = 90 }
equal(
  archlens.get_config().width,
  72,
  "configuration should remain stable after its first resolution"
)

local deprecated = {}
local original_deprecate = vim.deprecate
vim.deprecate = function(name, alternative, version, plugin)
  deprecated[#deprecated + 1] = {
    name = name,
    alternative = alternative,
    version = version,
    plugin = plugin,
  }
end

archlens.setup({ width = 80, lsp = { resolve_timeout_ms = 12 } })
equal(archlens.get_config().width, 80, "the compatibility API should replace global options")
equal(
  vim.g.archlens,
  { width = 80, lsp = { resolve_timeout_ms = 12 } },
  "the compatibility API should update the canonical global table"
)

archlens.setup({})
equal(archlens.get_config().width, 56, "an empty compatibility setup should restore defaults")
equal(
  archlens.get_config().lsp.resolve_timeout_ms,
  5000,
  "nested options from an earlier compatibility setup should not accumulate"
)
equal(#deprecated, 2, "each compatibility setup call should report its deprecation")
equal(deprecated[1].alternative, "vim.g.archlens", "the deprecation should name the replacement")
equal(deprecated[1].version, "0.3.0", "the compatibility removal version should be explicit")

local before_invalid = archlens.get_config()
local global_before_invalid = vim.deepcopy(vim.g.archlens)
local ok = pcall(archlens.setup, { width = "wide" })
assert(not ok, "invalid compatibility options should still be rejected")
equal(
  archlens.get_config(),
  before_invalid,
  "rejected compatibility options should preserve the resolved configuration"
)
equal(
  vim.g.archlens,
  global_before_invalid,
  "rejected compatibility options should preserve the global configuration"
)
assert(
  vim.fn.exists("#archlens_lifecycle") == 0,
  "configuration should not initialize runtime lifecycle autocmds"
)

vim.deprecate = original_deprecate

print("archlens.nvim global configuration tests passed")
vim.cmd("quitall!")

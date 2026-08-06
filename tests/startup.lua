local source = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(source, ":p:h:h")
vim.opt.runtimepath:prepend(root)

local function archlens_modules()
  local modules = {}
  for name in pairs(package.loaded) do
    if name == "archlens" or name:match("^archlens%.") then
      modules[#modules + 1] = name
    end
  end
  table.sort(modules)
  return modules
end

assert(#archlens_modules() == 0, "the startup test should begin without loaded ArchLens modules")

vim.cmd.runtime("plugin/archlens.lua")

assert(vim.fn.exists(":ArchLensHere") == 2, "the primary user command should be registered")
assert(vim.fn.exists(":ArchLensRefresh") == 2, "the refresh command should be registered")
assert(vim.fn.exists(":ArchLensClose") == 2, "the close command should be registered")
assert(
  #archlens_modules() == 0,
  "registering ArchLens commands should not load implementation modules"
)

local bootstrap_autocmds = vim.api.nvim_get_autocmds({
  group = "archlens_bootstrap",
  event = "LspAttach",
})
assert(#bootstrap_autocmds == 1, "startup should retain one lightweight LSP readiness hook")

vim.api.nvim_exec_autocmds("LspAttach", { data = { client_id = 37 } })
local readiness = require("archlens.lsp.readiness")
assert(readiness.recent(37, 1000), "the bootstrap hook should record early LSP attachments")
local after_attach = archlens_modules()
assert(
  vim.deep_equal(after_attach, { "archlens.lsp.readiness" }),
  "an LSP attachment should load only the readiness tracker"
)

vim.cmd.ArchLensClose()
assert(package.loaded.archlens, "invoking an ArchLens command should load the implementation")
assert(
  vim.fn.exists("#archlens_lifecycle") == 0,
  "a command that does not open a session should not initialize the lifecycle"
)

vim.cmd.ArchLensHere()
assert(
  vim.fn.exists("#archlens_lifecycle") == 1,
  "ArchLensHere should initialize the lifecycle without an explicit setup call"
)
vim.cmd.ArchLensClose()

print("archlens.nvim startup tests passed")
vim.cmd("quitall!")

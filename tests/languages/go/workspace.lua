local source = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(source, ":p:h:h:h:h")
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

local project = vim.fn.tempname()
local plugin = vim.fs.joinpath(project, "plugin")
local sdk = project .. " sdk with space"
local unlisted = vim.fs.joinpath(project, "unlisted")
for _, directory in ipairs({ plugin, sdk, unlisted }) do
  vim.fn.mkdir(directory, "p")
  vim.fn.writefile(
    { "module example.test/" .. vim.fs.basename(directory) },
    vim.fs.joinpath(directory, "go.mod")
  )
  vim.fn.writefile({ "package example" }, vim.fs.joinpath(directory, "example.go"))
end
local work_file = vim.fs.joinpath(project, "go.work")
vim.fn.writefile({
  "go 1.26.5",
  "",
  "use (",
  "  ./plugin",
  '  "../' .. vim.fs.basename(sdk) .. '" // an explicitly quoted external member',
  ")",
}, work_file)

local previous_gowork = vim.env.GOWORK
vim.env.GOWORK = "auto"
package.loaded["archlens.languages.go.workspace"] = nil
local go_workspace = require("archlens.languages.go.workspace")

equal(
  go_workspace.find(vim.fs.joinpath(plugin, "example.go")),
  work_file,
  "automatic workspace discovery should find the nearest go.work"
)
local expected_members = { plugin, sdk }
table.sort(expected_members)
equal(
  go_workspace.members(work_file),
  expected_members,
  "workspace parsing should resolve block, quoted, and relative use paths"
)
equal(
  go_workspace.find(vim.fs.joinpath(sdk, "example.go")),
  work_file,
  "a discovered workspace should retain explicit members outside its directory tree"
)
local plugin_workspace = go_workspace.resolve(vim.fs.joinpath(plugin, "example.go"))
assert(plugin_workspace, "an explicitly used module should resolve its workspace")
equal(plugin_workspace.file, work_file)
equal(plugin_workspace.root, project)
equal(plugin_workspace.name, vim.fs.basename(project))
equal(
  go_workspace.resolve(vim.fs.joinpath(unlisted, "example.go")),
  nil,
  "a module below go.work should not become a member unless use includes it"
)

local boundary = go_workspace.boundary(work_file)
equal(boundary.level, "workspace")
equal(boundary.class, "build")
equal(boundary.kind_name, "Go workspace")
equal(boundary.representative_path, work_file)
equal(boundary.evidence.method, "go.work/use")

vim.env.GOWORK = work_file
equal(
  go_workspace.find(vim.fs.joinpath(unlisted, "example.go")),
  work_file,
  "an explicit GOWORK path should override upward discovery"
)
vim.env.GOWORK = "off"
equal(
  go_workspace.find(vim.fs.joinpath(plugin, "example.go"), work_file),
  nil,
  "GOWORK=off should disable configured and automatic workspace discovery"
)

vim.env.GOWORK = previous_gowork
print("archlens.nvim Go workspace tests passed")
vim.cmd("quitall!")

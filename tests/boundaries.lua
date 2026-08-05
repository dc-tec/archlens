local source = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(source, ":p:h:h")
vim.opt.runtimepath:prepend(root)

local function equal(actual, expected, message)
  assert(vim.deep_equal(actual, expected), message or vim.inspect({ actual, expected }))
end

local project = vim.fn.tempname()
local source_dir = vim.fs.joinpath(project, "src")
local source_path = vim.fs.joinpath(source_dir, "lib.rs")
vim.fn.mkdir(source_dir, "p")
vim.fn.writefile({ "[package]", 'name = "fixture"' }, vim.fs.joinpath(project, "Cargo.toml"))
vim.fn.writefile({ "pub fn fixture() {}" }, source_path)

local requests = {}
require("archlens.adapters").register("async_boundary_fixture", {
  filetypes = { "async_boundary_fixture" },
  boundaries = {
    resolve = function()
      return nil
    end,
    discover = function(path, discovered_root, context, done)
      local request = {
        path = path,
        root = discovered_root,
        context = context,
        done = done,
        cancelled = false,
      }
      requests[#requests + 1] = request
      return function()
        request.cancelled = true
      end
    end,
  },
})

local function descriptors()
  return {
    {
      id = "cargo-target:fixture/lib",
      class = "build",
      level = "target",
      kind_name = "Rust crate",
      name = "fixture",
      path = source_dir,
      representative_path = source_path,
      symbol_kind = vim.lsp.protocol.SymbolKind.Module,
    },
    {
      id = "cargo-package:fixture",
      class = "build",
      level = "package",
      kind_name = "Cargo package",
      name = "fixture",
      path = project,
      representative_path = vim.fs.joinpath(project, "Cargo.toml"),
    },
    {
      id = "cargo-workspace:" .. project,
      class = "build",
      level = "workspace",
      kind_name = "Cargo workspace",
      name = vim.fs.basename(project),
      path = project,
      representative_path = vim.fs.joinpath(project, "Cargo.toml"),
    },
  }
end

local context = {
  language = "async_boundary_fixture",
  name = "fixture",
  kind = vim.lsp.protocol.SymbolKind.Function,
  kind_name = "Function",
  root_dir = project,
  path = source_path,
  location = {
    uri = vim.uri_from_fname(source_path),
    range = {
      start = { line = 0, character = 0 },
      ["end"] = { line = 0, character = 7 },
    },
  },
}

local boundaries = require("archlens.boundaries")
local discovered
local discovery_outcome
local cancel = assert(boundaries.discover(context, { timeout_ms = 100 }, function(value, outcome)
  discovered = value
  discovery_outcome = outcome
end))
equal(#requests, 1, "boundary discovery should start the adapter once")
requests[1].done(descriptors())
equal(discovery_outcome, nil)
equal(#discovered.enclosing_boundaries, 3)
local target = discovered.enclosing_boundaries[1]
equal(target.boundary_level, "target", "arbitrary boundary levels should reach contexts")
equal(target.kind, vim.lsp.protocol.SymbolKind.Module)
equal(target.enclosing_boundaries[1].boundary_level, "package")
equal(target.enclosing_boundaries[2].boundary_level, "workspace")
equal(
  discovered.enclosing_boundaries[2].enclosing_boundaries[1].boundary_level,
  "workspace",
  "adapter order should define the boundary hierarchy"
)
cancel()
equal(requests[1].cancelled, false, "completed discovery should ignore late cancellation")

local buffer = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_name(buffer, source_path)
vim.bo[buffer].filetype = "async_boundary_fixture"
local followed
local follow_outcome
local cancel_follow = boundaries.resolve_buffer(
  buffer,
  "target",
  { timeout_ms = 100 },
  function(value, outcome)
    followed = value
    follow_outcome = outcome
  end
)
equal(#requests, 2, "a cache miss while following should discover the active boundary")
requests[2].done(descriptors())
equal(follow_outcome, nil)
equal(followed.boundary_id, "cargo-target:fixture/lib")
cancel_follow()

local cancelled_callbacks = 0
local cancel_pending = assert(boundaries.discover(context, { timeout_ms = 100 }, function()
  cancelled_callbacks = cancelled_callbacks + 1
end))
equal(#requests, 3)
cancel_pending()
equal(requests[3].cancelled, true, "cancellation should propagate to adapter discovery")
requests[3].done(descriptors())
equal(cancelled_callbacks, 0, "cancelled discovery must ignore late completion")

local timed_out
local timeout_context
boundaries.discover(context, { timeout_ms = 5 }, function(value, outcome)
  timeout_context = value
  timed_out = outcome
end)
equal(#requests, 4)
assert(
  vim.wait(500, function()
    return timed_out ~= nil
  end, 5),
  "boundary discovery should respect its timeout"
)
equal(timed_out.state, "timed_out")
equal(requests[4].cancelled, true, "timed-out discovery should cancel adapter work")
assert(
  timeout_context.adapter_issues[1]:find("boundary discovery exceeded 5 ms", 1, true),
  "boundary timeouts should remain visible as adapter issues"
)

vim.api.nvim_buf_delete(buffer, { force = true })
print("archlens.nvim asynchronous boundary tests passed")
vim.cmd("quitall!")

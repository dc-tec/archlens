local source = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(source, ":p:h:h")
vim.opt.runtimepath:prepend(root)

local readiness = require("archlens.lsp.readiness")

readiness.clear()
assert(readiness.age(7, 100) == nil, "unknown clients should not have an attach age")
assert(not readiness.recent(7, 1000, 100), "unknown clients should not be treated as cold")

readiness.record(7, 100)
assert(readiness.age(7, 125) == 25, "client age should use the recorded attach time")
assert(readiness.recent(7, 25, 125), "the retry window should include its boundary")
assert(not readiness.recent(7, 24, 125), "clients outside the retry window should be warm")

readiness.record("invalid", 100)
assert(readiness.age("invalid", 125) == nil, "invalid client IDs should be ignored")

readiness.clear()
assert(readiness.age(7, 125) == nil, "clearing readiness should discard attach history")

print("archlens.nvim LSP readiness tests passed")
vim.cmd("quitall!")

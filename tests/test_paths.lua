local source = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(source, ":p:h:h")
vim.opt.runtimepath:prepend(root)

local test_paths = require("archlens.test_paths")

assert(test_paths.is_test("go", "/workspace/internal/service_test.go"))
assert(not test_paths.is_test("go", "/workspace/internal/service.go"))
assert(test_paths.is_test("rust", "/workspace/tests/service.rs", "/workspace"))
assert(test_paths.is_test("rust", "/workspace/src/service_test.rs"))
assert(not test_paths.is_test("rust", "/workspace/src/service.rs"))
assert(not test_paths.is_test("rust", "/tmp/tests/project/src/main.rs", "/tmp/tests/project"))
assert(not test_paths.is_test("ocaml", "/workspace/test/service.ml"))
assert(not test_paths.is_test("nix", "/workspace/tests/service.nix"))

print("archlens test path tests passed")
vim.cmd("quitall")

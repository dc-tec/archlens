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

local lsp = require("archlens.lsp")
local original_get_clients = vim.lsp.get_clients
local function client(id, name, supported)
  return {
    id = id,
    name = name,
    initialized = true,
    root_dir = "/workspace/" .. name,
    is_stopped = function()
      return false
    end,
    supports_method = function(_, method)
      return supported[method] == true
    end,
  }
end

local primary = client(1, "primary-lsp", { ["textDocument/references"] = true })
local secondary = client(2, "secondary-lsp", { ["textDocument/implementation"] = true })
local symbols_only = client(3, "symbols-only", { ["textDocument/documentSymbol"] = true })
vim.lsp.get_clients = function()
  return { symbols_only, secondary, primary }
end

local context = {
  client_id = primary.id,
  client_name = primary.name,
  root_dir = primary.root_dir,
  position_encoding = "utf-8",
  supports_calls = true,
  call_item = { name = "Focus" },
  wire_call_item = { name = "Focus", data = { opaque = true } },
  wire_type_item = { name = "FocusType", data = { opaque = true } },
  name = "Focus",
  location = {
    uri = "file:///workspace/main.lua",
    range = {
      start = { line = 0, character = 0 },
      ["end"] = { line = 0, character = 5 },
    },
  },
}
local contexts = lsp.relationship_contexts(context, 0)
equal(#contexts, 2, "only clients with relationship capabilities should participate")
assert(contexts[1] == context, "the resolved primary context should remain canonical")
equal(contexts[2].client_id, secondary.id, "secondary clients should be sorted and retained")
equal(contexts[2].client_name, secondary.name, "secondary provider names should remain visible")
equal(contexts[2].location, context.location, "secondary clients should query the canonical focus")
equal(contexts[2].position_encoding, "utf-8", "graph contexts should stay byte-oriented")
assert(not contexts[2].supports_calls, "secondary clients need their own call-hierarchy item")
assert(contexts[2].wire_call_item == nil, "opaque call items must not cross client boundaries")
assert(contexts[2].wire_type_item == nil, "opaque type items must not cross client boundaries")

vim.lsp.get_clients = original_get_clients

print("archlens.nvim multi-client LSP tests passed")
vim.cmd("quitall!")

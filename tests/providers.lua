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

local graph = require("archlens.graph")
local relationship_callbacks = {}
local request_contexts = {}
local recently_attached = true
local retry_window
local multi_client = false

package.loaded["archlens.lsp"] = {
  relationship_contexts = function(primary)
    if not multi_client then
      return { primary }
    end
    local secondary = vim.deepcopy(primary)
    secondary.client_id = 8
    secondary.client_name = "secondary-lsp"
    secondary.supports_calls = false
    secondary.wire_call_item = nil
    return { primary, secondary }
  end,
  relationships = function(request_context, _, callback)
    request_contexts[#request_contexts + 1] = vim.deepcopy(request_context)
    relationship_callbacks[#relationship_callbacks + 1] = callback
    return function() end
  end,
  recently_attached = function(_, window_ms)
    retry_window = window_ms
    return recently_attached
  end,
}
package.loaded["archlens.ast_grep"] = {
  default_globs = {},
  relationships = function()
    error("ast-grep should be disabled")
  end,
}
package.loaded["archlens.containers"] = {
  clear_cache = function() end,
  enrich = function(result, _, _, callback)
    callback(result)
    return function() end
  end,
}
package.loaded["archlens.imports"] = {
  clear_cache = function() end,
  relationships = function()
    error("imports should be disabled")
  end,
}
package.loaded["archlens.import_index"] = {
  relationships = function()
    error("module dependents should be disabled")
  end,
}
package.loaded["archlens.treesitter"] = {
  supports_imports = function()
    return false
  end,
}
package.loaded["archlens.providers"] = nil

local providers = require("archlens.providers")
local bufnr = vim.api.nvim_get_current_buf()
local uri = vim.uri_from_bufnr(bufnr)
local context = {
  client_id = 7,
  client_name = "cold-lsp",
  name = "Focus",
  kind = vim.lsp.protocol.SymbolKind.Function,
  kind_name = "Function",
  position_encoding = "utf-8",
  root_dir = "/tmp",
  supports_calls = false,
  location = {
    uri = uri,
    range = {
      start = { line = 0, character = 0 },
      ["end"] = { line = 0, character = 1 },
    },
  },
}
local config = {
  include_external = false,
  providers = {},
  filters = {},
  ast_grep = { enabled = false },
  imports = { enabled = false, inbound = { enabled = false } },
  grouping = { enabled = false },
  lsp = {
    relationship_timeout_ms = 1000,
    cold_start_retry = { enabled = true, delay_ms = 1, window_ms = 9000 },
  },
}
local metadata = {
  request_count = 1,
  request_labels = { "Project references" },
}

local function run_provider(target_context)
  local updates = {}
  local cancels = {}
  providers.run(target_context or context, bufnr, config, {
    is_current = function()
      return true
    end,
    on_update = function(value)
      updates[#updates + 1] = vim.deepcopy(value)
    end,
    register_cancel = function(cancel)
      cancels[#cancels + 1] = cancel
    end,
  })
  return updates, cancels
end

local updates = run_provider()
equal(
  updates[#updates].pending,
  { { id = "lsp", label = "cold-lsp" } },
  "the first request should be pending"
)
relationship_callbacks[1](graph.delta(), metadata)
assert(
  vim.wait(1000, function()
    return #relationship_callbacks == 2
  end, 10),
  "a recently attached client should receive one delayed retry"
)
equal(retry_window, 9000, "the configured cold-client window should reach readiness detection")
equal(
  updates[#updates].pending,
  { { id = "lsp", label = "cold-lsp" } },
  "the provider should remain pending during the retry"
)

relationship_callbacks[2](graph.delta(), metadata)
equal(updates[#updates].pending, {}, "the provider should complete after its one retry")
assert(
  table.concat(updates[#updates].notes, "\n"):find(
    "cold-lsp returned no semantic relationships after one cold-start retry (Project references).",
    1,
    true
  ),
  "a retried empty result should explain exactly what the server returned"
)

recently_attached = false
local warm_updates = run_provider()
relationship_callbacks[3](graph.delta(), metadata)
equal(warm_updates[#warm_updates].pending, {}, "warm empty results should complete immediately")
assert(
  table
    .concat(warm_updates[#warm_updates].notes, "\n")
    :find("cold-lsp returned no semantic relationships (Project references).", 1, true),
  "warm empty results should remain visible without claiming a retry"
)
vim.wait(20, function()
  return false
end, 10)
equal(#relationship_callbacks, 3, "a warm client should not receive an empty-result retry")

local custom_started = 0
providers.register("custom", {
  order = 25,
  label = "Custom relationships",
  queued = true,
  enabled = function(_, _, current_config)
    return current_config.providers.custom.enabled
  end,
  start = function(_, _, _, done)
    custom_started = custom_started + 1
    local result = graph.delta()
    graph.add_contributor(result, "custom", "Custom relationships")
    graph.add_note(result, "Custom provider completed.")
    done(result)
    return function() end
  end,
})
local provider_ids = vim.tbl_map(function(provider)
  return provider.id
end, providers.ordered())
equal(
  provider_ids,
  { "lsp", "imports", "custom", "importers", "ast_grep" },
  "custom providers should participate in stable orchestration order"
)
equal(providers.local_pending(config), {
  { id = "lsp", label = "LSP" },
  { id = "custom", label = "Custom relationships" },
}, "queued custom providers should be visible before semantic focus resolves")
local duplicate_ok = pcall(providers.register, "custom", {})
assert(not duplicate_ok, "provider IDs should be unique")

config.providers.custom = { enabled = true }
local syntax_context = vim.deepcopy(context)
syntax_context.client_id = nil
syntax_context.client_name = nil
local custom_updates = run_provider(syntax_context)
equal(custom_started, 1, "eligible custom providers should start through the shared runner")
equal(custom_updates[#custom_updates].pending, {}, "synchronous custom providers should complete")
assert(
  table
    .concat(custom_updates[#custom_updates].notes, "\n")
    :find("Custom provider completed.", 1, true),
  "custom provider deltas should merge into the focused graph"
)

config.providers.custom.enabled = false
multi_client = true
local multi_updates = run_provider()
equal(
  multi_updates[#multi_updates].pending,
  { { id = "lsp", label = "cold-lsp + secondary-lsp" } },
  "all participating LSP clients should share one pending provider task"
)
equal(#relationship_callbacks, 5, "each applicable LSP client should receive a relationship run")
equal(request_contexts[4].client_name, "cold-lsp", "the primary LSP should run first")
equal(
  request_contexts[5].client_name,
  "secondary-lsp",
  "secondary LSPs should retain their identity"
)

local function reference_delta(request_context)
  local result = graph.delta()
  local focus = graph.node_from_context(request_context)
  local related = graph.node_from_location({
    uri = uri,
    range = {
      start = { line = 2, character = 0 },
      ["end"] = { line = 2, character = 5 },
    },
  }, { name = "Focus()", kind_name = "Reference" })
  graph.add_edge(
    result,
    graph.edge("references", related, focus, {
      provider = request_context.client_name,
      method = "textDocument/references",
      class = "semantic",
    })
  )
  return result
end

relationship_callbacks[4](reference_delta(request_contexts[4]), metadata)
equal(
  multi_updates[#multi_updates].pending,
  { { id = "lsp", label = "cold-lsp + secondary-lsp" } },
  "the shared LSP task should wait for every client"
)
relationship_callbacks[5](reference_delta(request_contexts[5]), metadata)
equal(multi_updates[#multi_updates].pending, {}, "the shared LSP task should complete once")
local multi_model = require("archlens.model").build(context, multi_updates[#multi_updates], {
  include_external = true,
})
local references = vim.iter(multi_model.sections):find(function(section)
  return section.id == "references"
end)
assert(references and #references.rows == 1, "matching multi-client rows should deduplicate")
equal(references.rows[1].evidence_records, {
  {
    provider = "cold-lsp",
    method = "textDocument/references",
    class = "semantic",
  },
  {
    provider = "secondary-lsp",
    method = "textDocument/references",
    class = "semantic",
  },
}, "multi-client corroboration should retain independent evidence records")

print("archlens.nvim provider retry tests passed")
vim.cmd("quitall!")

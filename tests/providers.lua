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
local clock = 0
local supports_imports = false

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
  dependencies = function()
    error("package dependencies should be disabled")
  end,
  dependents = function()
    error("package dependents should be disabled")
  end,
  relationships = function()
    error("module dependents should be disabled")
  end,
}
package.loaded["archlens.treesitter"] = {
  supports_imports = function()
    return supports_imports
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
    now = function()
      return clock
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
local retry_update
for _, update in ipairs(updates) do
  if update.provider_runs[1] and update.provider_runs[1].state == "retrying" then
    retry_update = update
    break
  end
end
assert(retry_update, "a cold-start retry should publish its lifecycle state")
equal(
  retry_update.provider_runs[1].retry_delay_ms,
  1,
  "retry lifecycle state should expose the configured delay"
)
equal(retry_window, 9000, "the configured cold-client window should reach readiness detection")
equal(
  updates[#updates].pending,
  { { id = "lsp", label = "cold-lsp" } },
  "the provider should remain pending during the retry"
)

clock = 42
relationship_callbacks[2](graph.delta(), metadata)
equal(updates[#updates].pending, {}, "the provider should complete after its one retry")
equal(updates[#updates].provider_runs[1], {
  id = "lsp",
  label = "cold-lsp",
  state = "completed",
  duration_ms = 42,
}, "completed providers should expose their total duration")
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
clock = 50
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
  start = function(_, _, current_config, done, report)
    custom_started = custom_started + 1
    local options = current_config.providers.custom or {}
    report("retrying", { retry_delay_ms = 25, message = "Waiting for the project tool." })
    local result = graph.delta()
    graph.add_contributor(result, "custom", "Custom relationships")
    graph.add_note(result, "Custom provider completed.")
    if options.defer_completion then
      return function()
        report("running", { message = "Cancelled provider reported too late." })
        done(result, options.outcome)
      end
    end
    done(options.invalid_delta and {} or result, options.outcome)
    if options.error_after_done then
      error("error after completion")
    end
    return function() end
  end,
})
providers.register("broken", {
  order = 26,
  label = "Broken provider",
  enabled = function(_, _, current_config)
    local options = current_config.providers.broken or {}
    return options.enabled == true
  end,
  start = function()
    error("provider unavailable")
  end,
})
local provider_ids = vim.tbl_map(function(provider)
  return provider.id
end, providers.ordered())
equal(
  provider_ids,
  { "lsp", "imports", "custom", "broken", "importers", "ast_grep" },
  "custom providers should participate in stable orchestration order"
)
equal(providers.local_pending(config), {
  { id = "lsp", label = "LSP" },
  { id = "custom", label = "Custom relationships" },
}, "queued custom providers should be visible before semantic focus resolves")
local registered = {}
for _, provider in ipairs(providers.ordered()) do
  registered[provider.id] = provider
end
supports_imports = true
config.imports = {
  enabled = true,
  show_on_symbols = false,
  inbound = { enabled = true },
}
local boundary_symbol = vim.deepcopy(context)
boundary_symbol.enclosing_boundaries = { { boundary_id = "go-package:example.test/project" } }
equal(
  registered.imports.enabled(boundary_symbol, bufnr, config),
  false,
  "symbols with a real boundary should omit repeated package dependencies by default"
)
equal(
  registered.importers.enabled(boundary_symbol, bufnr, config),
  false,
  "symbols with a real boundary should omit repeated package dependents by default"
)
config.imports.show_on_symbols = true
equal(registered.imports.enabled(boundary_symbol, bufnr, config), true)
equal(registered.importers.enabled(boundary_symbol, bufnr, config), true)
config.imports.show_on_symbols = false
local boundary_context = vim.deepcopy(context)
boundary_context.is_boundary = true
boundary_context.module_context = true
boundary_context.boundary_level = "package"
boundary_context.boundary_keys = { "go-package:example.test/project" }
equal(registered.imports.enabled(boundary_context, bufnr, config), true)
equal(registered.importers.enabled(boundary_context, bufnr, config), true)
local module_boundary = vim.deepcopy(boundary_context)
module_boundary.boundary_level = "module"
module_boundary.boundary_keys = {}
equal(registered.imports.enabled(module_boundary, bufnr, config), false)
equal(registered.importers.enabled(module_boundary, bufnr, config), false)
supports_imports = false
config.imports = { enabled = false, inbound = { enabled = false } }
local duplicate_ok = pcall(providers.register, "custom", {})
assert(not duplicate_ok, "provider IDs should be unique")

config.providers.custom = { enabled = true }
local syntax_context = vim.deepcopy(context)
syntax_context.client_id = nil
syntax_context.client_name = nil
local custom_updates = run_provider(syntax_context)
equal(custom_started, 1, "eligible custom providers should start through the shared runner")
equal(custom_updates[#custom_updates].pending, {}, "synchronous custom providers should complete")
local custom_retry
for _, update in ipairs(custom_updates) do
  for _, run in ipairs(update.provider_runs or {}) do
    if run.id == "custom" and run.state == "retrying" then
      custom_retry = run
    end
  end
end
equal(custom_retry, {
  id = "custom",
  label = "Custom relationships",
  state = "retrying",
  elapsed_ms = 0,
  retry_delay_ms = 25,
  message = "Waiting for the project tool.",
}, "custom providers should publish retry metadata through the shared lifecycle")
assert(
  table
    .concat(custom_updates[#custom_updates].notes, "\n")
    :find("Custom provider completed.", 1, true),
  "custom provider deltas should merge into the focused graph"
)

config.providers.custom.outcome = {
  state = "timed_out",
  message = "Custom analysis exceeded its deadline.",
}
local timed_out_updates = run_provider(syntax_context)
local timed_out_run = timed_out_updates[#timed_out_updates].provider_runs[1]
equal(timed_out_run.state, "timed_out", "providers should publish explicit timeout outcomes")
equal(timed_out_run.duration_ms, 0, "terminal outcomes should retain provider duration")
equal(
  timed_out_run.message,
  "Custom analysis exceeded its deadline.",
  "terminal outcomes should retain their message"
)
equal(timed_out_run.retry_delay_ms, nil, "terminal outcomes should clear retry metadata")
assert(
  table
    .concat(timed_out_updates[#timed_out_updates].notes, "\n")
    :find("Custom provider completed.", 1, true),
  "partial provider results should merge for exceptional terminal outcomes"
)

config.providers.custom.outcome = { state = "running" }
local invalid_outcome_updates = run_provider(syntax_context)
local invalid_outcome_run = invalid_outcome_updates[#invalid_outcome_updates].provider_runs[1]
equal(invalid_outcome_run.state, "failed", "invalid terminal outcomes should fail the provider")
assert(
  invalid_outcome_run.message:find("unsupported terminal provider state", 1, true),
  "invalid outcomes should explain the provider contract"
)

config.providers.custom.outcome = nil
config.providers.custom.invalid_delta = true
local invalid_delta_updates = run_provider(syntax_context)
local invalid_delta_run = invalid_delta_updates[#invalid_delta_updates].provider_runs[1]
equal(invalid_delta_run.state, "failed", "invalid graph deltas must not leave providers running")
assert(
  invalid_delta_run.message:find("invalid graph delta", 1, true),
  "invalid graph deltas should retain the merge failure"
)

config.providers.custom.invalid_delta = false
config.providers.custom.error_after_done = true
local completed_before_error = run_provider(syntax_context)
equal(
  completed_before_error[#completed_before_error].provider_runs[1].state,
  "completed",
  "an exception after synchronous completion must not replace the terminal state"
)

config.providers.custom.error_after_done = false
config.providers.custom.defer_completion = true
local cancelled_updates, custom_cancellations = run_provider(syntax_context)
local renders_before_cancel = #cancelled_updates
equal(#custom_cancellations, 1, "active providers should register one cancellation wrapper")
custom_cancellations[1]()
equal(
  #cancelled_updates,
  renders_before_cancel,
  "provider callbacks from cancellation must not redraw the abandoned run"
)
config.providers.custom.defer_completion = false

local stale_start_current = true
local stale_start_cancellations = 0
providers.register("stale_start", {
  order = 27,
  label = "Stale start",
  enabled = function(_, _, current_config)
    local options = current_config.providers.stale_start or {}
    return options.enabled == true
  end,
  start = function()
    stale_start_current = false
    return function()
      stale_start_cancellations = stale_start_cancellations + 1
    end
  end,
})
config.providers.custom.enabled = false
config.providers.stale_start = { enabled = true }
local stale_start_registered = {}
providers.run(syntax_context, bufnr, config, {
  is_current = function()
    return stale_start_current
  end,
  on_update = function() end,
  register_cancel = function(cancel)
    stale_start_registered[#stale_start_registered + 1] = cancel
  end,
  now = function()
    return clock
  end,
})
equal(
  stale_start_cancellations,
  1,
  "providers that become stale during startup should be cancelled immediately"
)
equal(
  #stale_start_registered,
  0,
  "stale provider cancellation must not be registered against a replacement run"
)
config.providers.stale_start.enabled = false

config.providers.custom.enabled = false
config.providers.broken = { enabled = true }
local broken_updates = run_provider(syntax_context)
local broken_run = broken_updates[#broken_updates].provider_runs[1]
equal(broken_run.id, "broken", "the failed provider should retain its identity")
equal(broken_run.label, "Broken provider", "the failed provider should retain its label")
equal(broken_run.state, "failed", "start failures should publish a terminal state")
equal(broken_run.duration_ms, 0, "start failures should retain their elapsed duration")
assert(
  broken_run.message:find("provider unavailable", 1, true),
  "failed provider lifecycle state should retain the cause"
)
assert(
  table
    .concat(broken_updates[#broken_updates].errors, "\n")
    :find("Broken provider failed to start", 1, true),
  "provider start failures should remain visible as graph errors"
)

config.providers.broken.enabled = false
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

local degraded_updates = run_provider()
relationship_callbacks[6](reference_delta(request_contexts[6]), metadata)
relationship_callbacks[7](graph.delta(), {
  request_count = 1,
  request_labels = { "Project references" },
  outcome = {
    state = "timed_out",
    message = "Relationship requests exceeded the deadline.",
  },
})
local degraded_run = degraded_updates[#degraded_updates].provider_runs[1]
equal(degraded_run.state, "timed_out", "one timed-out client should degrade the shared LSP run")
assert(
  degraded_run.message:find("secondary%-lsp: Relationship requests exceeded the deadline%."),
  "multi-client outcomes should identify the affected language server"
)
local degraded_model =
  require("archlens.model").build(context, degraded_updates[#degraded_updates], {
    include_external = true,
  })
assert(
  vim.iter(degraded_model.sections):find(function(section)
    return section.id == "references"
  end),
  "a timed-out multi-client run should retain successful client relationships"
)

local partially_available_updates = run_provider()
relationship_callbacks[8](reference_delta(request_contexts[8]), metadata)
relationship_callbacks[9](graph.delta(), {
  request_count = 0,
  request_labels = {},
  outcome = { state = "unavailable", message = "Relationship analysis is unavailable." },
})
equal(
  partially_available_updates[#partially_available_updates].provider_runs[1].state,
  "completed",
  "one available client should keep the shared LSP run completed"
)
assert(
  table
    .concat(partially_available_updates[#partially_available_updates].notes, "\n")
    :find("secondary%-lsp: Relationship analysis is unavailable%."),
  "partial multi-client availability should remain an inspectable result caveat"
)

local unavailable_updates = run_provider()
relationship_callbacks[10](graph.delta(), {
  request_count = 0,
  request_labels = {},
  outcome = { state = "unavailable", message = "Primary analysis is unavailable." },
})
relationship_callbacks[11](graph.delta(), {
  request_count = 0,
  request_labels = {},
  outcome = { state = "unavailable", message = "Secondary analysis is unavailable." },
})
local unavailable_run = unavailable_updates[#unavailable_updates].provider_runs[1]
equal(unavailable_run.state, "unavailable", "all unavailable clients should degrade the LSP run")
assert(
  unavailable_run.message:find("cold%-lsp: Primary analysis is unavailable%.")
    and unavailable_run.message:find("secondary%-lsp: Secondary analysis is unavailable%."),
  "an unavailable multi-client outcome should retain every client message"
)

print("archlens.nvim provider retry tests passed")
vim.cmd("quitall!")

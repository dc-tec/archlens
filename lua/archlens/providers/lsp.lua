local containers = require("archlens.containers")
local graph = require("archlens.graph")
local lsp = require("archlens.lsp")
local support = require("archlens.providers.support")

local terminal_state_priority = {
  completed = 0,
  cancelled = 1,
  unavailable = 2,
  timed_out = 3,
  failed = 4,
}

local function combine_outcomes(left, right)
  if not right or right.state == "completed" then
    return left
  end
  if not left or left.state == "completed" then
    return vim.deepcopy(right)
  end
  local combined = terminal_state_priority[right.state] > terminal_state_priority[left.state]
      and vim.deepcopy(right)
    or vim.deepcopy(left)
  local messages = {}
  local seen = {}
  for _, outcome in ipairs({ left, right }) do
    if outcome.message and not seen[outcome.message] then
      messages[#messages + 1] = outcome.message
      seen[outcome.message] = true
    end
  end
  combined.message = #messages > 0 and table.concat(messages, "; ") or nil
  return combined
end

local function empty_semantic_result(result, metadata)
  return (metadata and metadata.request_count or 0) > 0
    and #(result.edges or {}) == 0
    and #(result.errors or {}) == 0
    and #(result.notes or {}) == 0
end

local function explain_empty_semantic_result(result, context, metadata, retried)
  if not empty_semantic_result(result, metadata) then
    return
  end
  local methods = table.concat(metadata.request_labels or {}, ", ")
  local suffix = methods ~= "" and " (" .. methods .. ")" or ""
  graph.add_note(
    result,
    string.format(
      "%s returned no semantic relationships%s%s.",
      context.client_name or "The language server",
      retried and " after one cold-start retry" or "",
      suffix
    ),
    { summary = "no semantic relationships", severity = "info" }
  )
end

local function lsp_contexts(context, source_buffer)
  if type(lsp.relationship_contexts) == "function" then
    return lsp.relationship_contexts(context, source_buffer)
  end
  return { context }
end

local function start_lsp_context(context, source_buffer, config, done, report)
  local lsp_cancel = function() end
  local retry_timer
  local retried = false
  local cancelled = false
  local run

  local function finish(result, metadata)
    if cancelled then
      return
    end
    local outcome = metadata and metadata.outcome
    local retry = config.lsp.cold_start_retry or {}
    local retryable = not retried
      and retry.enabled ~= false
      and (not outcome or outcome.state == "completed")
      and empty_semantic_result(result, metadata)
      and type(lsp.recently_attached) == "function"
      and lsp.recently_attached(context.client_id, retry.window_ms or 10000)
    if retryable then
      retried = true
      report("retrying", { retry_delay_ms = math.max(0, retry.delay_ms or 3000) })
      retry_timer = vim.defer_fn(function()
        retry_timer = nil
        if not cancelled then
          report("running")
          run()
        end
      end, math.max(0, retry.delay_ms or 3000))
      return
    end

    if not outcome or outcome.state == "completed" then
      explain_empty_semantic_result(result, context, metadata, retried)
    elseif outcome.message then
      outcome = vim.deepcopy(outcome)
      local label = context.client_name or "LSP"
      if not vim.startswith(outcome.message, label) then
        outcome.message = string.format("%s: %s", label, outcome.message)
      end
    end
    done(result, outcome)
  end

  run = function()
    lsp_cancel = lsp.relationships(context, source_buffer, finish, {
      timeout_ms = config.lsp.relationship_timeout_ms,
      max_results = config.lsp.max_results,
      max_occurrences = config.lsp.max_occurrences,
      filters = vim.tbl_extend(
        "force",
        vim.deepcopy(config.filters),
        { include_external = config.include_external }
      ),
    })
  end
  run()

  return function()
    cancelled = true
    if retry_timer and not retry_timer:is_closing() then
      retry_timer:stop()
      retry_timer:close()
    end
    pcall(lsp_cancel)
  end
end

local function start_lsp(context, source_buffer, config, done, report)
  local contexts = lsp_contexts(context, source_buffer)
  local combined = graph.delta()
  local pending = #contexts
  local cancellations = {}
  local outcomes = {}
  local grouping_cancel = function() end
  local cancelled = false

  local function finish(result, outcome)
    if cancelled then
      return
    end
    graph.merge(combined, result)
    outcomes[#outcomes + 1] = outcome or { state = "completed" }
    pending = pending - 1
    if pending ~= 0 then
      return
    end
    local terminal_outcome
    local unavailable = {}
    for _, current in ipairs(outcomes) do
      if current.state == "unavailable" then
        unavailable[#unavailable + 1] = current
      elseif current.state ~= "completed" then
        terminal_outcome = combine_outcomes(terminal_outcome, current)
      end
    end
    if terminal_outcome then
      for _, current in ipairs(unavailable) do
        terminal_outcome = combine_outcomes(terminal_outcome, current)
      end
    elseif #unavailable == #outcomes then
      for _, current in ipairs(unavailable) do
        terminal_outcome = combine_outcomes(terminal_outcome, current)
      end
    elseif #unavailable > 0 then
      for _, current in ipairs(unavailable) do
        graph.add_note(combined, current.message or "Some semantic analysis was unavailable.", {
          summary = "some semantic analysis unavailable",
          severity = "warn",
        })
      end
    end
    if not config.grouping.enabled then
      done(combined, terminal_outcome)
      return
    end
    grouping_cancel = containers.enrich(
      combined,
      context,
      support.options(config.grouping, config),
      function(result)
        done(result, terminal_outcome)
      end
    )
  end

  for _, semantic_context in ipairs(contexts) do
    cancellations[#cancellations + 1] =
      start_lsp_context(semantic_context, source_buffer, config, finish, report)
  end

  return function()
    cancelled = true
    for _, cancel in ipairs(cancellations) do
      pcall(cancel)
    end
    pcall(grouping_cancel)
  end
end

local function lsp_label(context, source_buffer)
  local names = {}
  for _, semantic_context in ipairs(lsp_contexts(context, source_buffer)) do
    names[#names + 1] = semantic_context.client_name or "LSP"
  end
  return table.concat(names, " + ")
end

return {
  id = "lsp",
  spec = {
    order = 10,
    label = lsp_label,
    queued = true,
    queued_label = "LSP",
    enabled = function(context)
      return context.client_id ~= nil and not context.module_context
    end,
    start = start_lsp,
  },
}

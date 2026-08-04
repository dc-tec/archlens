local ast_grep = require("archlens.ast_grep")
local containers = require("archlens.containers")
local graph = require("archlens.graph")
local go_packages = require("archlens.go_packages")
local import_index = require("archlens.import_index")
local imports = require("archlens.imports")
local lsp = require("archlens.lsp")
local treesitter = require("archlens.treesitter")

local M = {}

---@alias ArchLensProviderTerminalState "cancelled"|"completed"|"failed"|"timed_out"|"unavailable"

---@class ArchLensProviderOutcome
---@field state ArchLensProviderTerminalState
---@field message? string

---@class ArchLensProviderProgress
---@field retry_delay_ms? number
---@field message? string

---@class ArchLensProviderSpec
---@field order integer
---@field label string|function
---@field enabled function
---@field start function
---@field queued? boolean|function
---@field queued_label? string
---@field clear_cache? function

---@class ArchLensProvider: ArchLensProviderSpec
---@field id string

---@class ArchLensProviderControls
---@field is_current fun(): boolean
---@field register_cancel fun(cancel: function)
---@field on_update fun(snapshot: ArchLensGraphDelta)
---@field now? fun(): number

---@type table<string, ArchLensProvider>
local registry = {}

local allowed_provider_fields = {
  clear_cache = true,
  enabled = true,
  id = true,
  label = true,
  order = true,
  queued = true,
  queued_label = true,
  start = true,
}

local function nonempty_string(value)
  return type(value) == "string" and value:match("%S") ~= nil
end

local terminal_provider_states = {
  cancelled = true,
  completed = true,
  failed = true,
  timed_out = true,
  unavailable = true,
}

local terminal_state_priority = {
  completed = 0,
  cancelled = 1,
  unavailable = 2,
  timed_out = 3,
  failed = 4,
}

---@param outcome? ArchLensProviderOutcome
---@return ArchLensProviderOutcome
local function normalize_terminal_outcome(outcome)
  if outcome == nil then
    return { state = "completed" }
  end
  assert(type(outcome) == "table", "provider outcome must be a table")
  for key in pairs(outcome) do
    assert(key == "state" or key == "message", "unsupported provider outcome field: " .. key)
  end
  assert(
    terminal_provider_states[outcome.state],
    "unsupported terminal provider state: " .. tostring(outcome.state)
  )
  assert(
    outcome.message == nil or nonempty_string(outcome.message),
    "provider outcome message must be a non-empty string"
  )
  return vim.deepcopy(outcome)
end

---@param left? ArchLensProviderOutcome
---@param right? ArchLensProviderOutcome
---@return ArchLensProviderOutcome?
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

---@param id string
---@param spec ArchLensProviderSpec
---@return ArchLensProvider
local function normalize_provider(id, spec)
  assert(
    nonempty_string(id) and id:match("^[%l][%l%d_%-]*$"),
    "provider id must be a lowercase identifier"
  )
  assert(type(spec) == "table", "provider specification must be a table")
  local normalized = vim.deepcopy(spec)
  normalized.id = id
  for key in pairs(normalized) do
    assert(allowed_provider_fields[key], "unsupported provider field: " .. tostring(key))
  end
  assert(
    nonempty_string(normalized.label) or type(normalized.label) == "function",
    "provider label must be a non-empty string or function"
  )
  assert(
    type(normalized.order) == "number"
      and normalized.order >= 0
      and normalized.order < math.huge
      and normalized.order == math.floor(normalized.order),
    "provider order must be a non-negative integer"
  )
  assert(type(normalized.enabled) == "function", "provider enabled must be a function")
  assert(type(normalized.start) == "function", "provider start must be a function")
  if normalized.queued ~= nil then
    assert(
      type(normalized.queued) == "boolean" or type(normalized.queued) == "function",
      "provider queued must be a boolean or function"
    )
  end
  if normalized.queued_label ~= nil then
    assert(
      nonempty_string(normalized.queued_label),
      "provider queued_label must be a non-empty string"
    )
  end
  if normalized.clear_cache ~= nil then
    assert(type(normalized.clear_cache) == "function", "provider clear_cache must be a function")
  end
  return normalized
end

---@param id string
---@param spec ArchLensProviderSpec
---@return ArchLensProvider
function M.register(id, spec)
  assert(registry[id] == nil, string.format("provider already registered: %s", tostring(id)))
  local normalized = normalize_provider(id, spec)
  registry[id] = normalized
  return vim.deepcopy(normalized)
end

---@return ArchLensProvider[]
function M.ordered()
  local providers = {}
  for _, provider in pairs(registry) do
    providers[#providers + 1] = vim.deepcopy(provider)
  end
  table.sort(providers, function(left, right)
    if left.order ~= right.order then
      return left.order < right.order
    end
    return left.id < right.id
  end)
  return providers
end

local function provider_options(options, config)
  options = vim.deepcopy(options)
  options.filters = vim.deepcopy(config.filters)
  options.filters.include_external = config.include_external
  return options
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
      provider_options(config.grouping, config),
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

M.register("lsp", {
  order = 10,
  label = lsp_label,
  queued = true,
  queued_label = "LSP",
  enabled = function(context)
    return context.client_id ~= nil and not context.module_context
  end,
  start = start_lsp,
})

local function go_package_provider_enabled(context, config)
  local options = config.providers.go or {}
  return go_packages.supports(context) and options.enabled ~= false and config.imports.enabled
end

M.register("go", {
  order = 19,
  label = "Go build",
  enabled = function(context, _, config)
    return go_package_provider_enabled(context, config)
  end,
  start = function(context, source_buffer, config, done)
    local import_options = provider_options(config.imports.inbound, config)
    import_options.filetype = context.import_filetype
    import_options.max_imports = config.imports.max_imports
    return go_packages.relationships(context, source_buffer, {
      build = config.providers.go or {},
      imports = import_options,
      include_dependents = config.imports.inbound.enabled,
      max_imports = config.imports.max_imports,
      max_importers = config.imports.inbound.max_importers,
    }, done)
  end,
  clear_cache = go_packages.clear_cache,
})

M.register("imports", {
  order = 20,
  label = function(context)
    return context.is_boundary and "Package dependencies" or "Module dependencies"
  end,
  enabled = function(context, source_buffer, config)
    if context.is_boundary then
      return context.boundary_level == "package"
        and not go_package_provider_enabled(context, config)
        and config.imports.enabled
        and treesitter.supports_imports(source_buffer)
    end
    return config.imports.enabled
      and treesitter.supports_imports(source_buffer)
      and (
        not context.enclosing_boundaries
        or #context.enclosing_boundaries == 0
        or config.imports.show_on_symbols == true
      )
  end,
  start = function(context, source_buffer, config, done)
    if context.is_boundary and context.boundary_level == "package" then
      local options = provider_options(config.imports.inbound, config)
      options.filetype = context.import_filetype
      options.max_imports = config.imports.max_imports
      return import_index.dependencies(context, source_buffer, options, done)
    end
    return imports.relationships(
      context,
      source_buffer,
      provider_options(config.imports, config),
      done
    )
  end,
  clear_cache = imports.clear_cache,
})

M.register("importers", {
  order = 30,
  label = function(context)
    return context.is_boundary and "Package dependents" or "Module dependents"
  end,
  enabled = function(context, source_buffer, config)
    if context.is_boundary then
      return context.boundary_level == "package"
        and not go_package_provider_enabled(context, config)
        and config.imports.enabled
        and config.imports.inbound.enabled
        and (treesitter.supports_imports(source_buffer) or context.import_filetype)
    end
    return config.imports.enabled
      and config.imports.inbound.enabled
      and (treesitter.supports_imports(source_buffer) or context.import_filetype)
      and (
        not context.enclosing_boundaries
        or #context.enclosing_boundaries == 0
        or config.imports.show_on_symbols == true
      )
  end,
  start = function(context, source_buffer, config, done)
    local options = provider_options(config.imports.inbound, config)
    options.filetype = context.import_filetype
    if context.is_boundary and context.boundary_level == "package" then
      return import_index.dependents(context, source_buffer, options, done)
    end
    return import_index.relationships(context, source_buffer, options, done)
  end,
})

M.register("ast_grep", {
  order = 40,
  label = "ast-grep",
  queued = function(config)
    return config.ast_grep.enabled
  end,
  enabled = function(context, _, config)
    return config.ast_grep.enabled and not context.module_context and not context.configuration
  end,
  start = function(context, _, config, done)
    return ast_grep.relationships(context, provider_options(config.ast_grep, config), done)
  end,
})

---@param config table
---@return { id: string, label: string }[]
function M.local_pending(config)
  local pending = {}
  for _, provider in ipairs(M.ordered()) do
    local queued = provider.queued
    if type(queued) == "function" then
      local ok, value = pcall(queued, config)
      queued = ok and value or false
    end
    if queued then
      pending[#pending + 1] = {
        id = provider.id,
        label = provider.queued_label
          or (type(provider.label) == "string" and provider.label)
          or provider.id,
      }
    end
  end
  return pending
end

local function tasks_for(context, source_buffer, config)
  local tasks = {}
  for _, provider in ipairs(M.ordered()) do
    local current_provider = provider
    local enabled_ok, enabled = pcall(provider.enabled, context, source_buffer, config)
    if enabled_ok and enabled then
      local label_ok, label = pcall(function()
        return type(current_provider.label) == "function"
            and current_provider.label(context, source_buffer, config)
          or current_provider.label
      end)
      if label_ok and not nonempty_string(label) then
        label_ok = false
        label = "provider label function must return a non-empty string"
      end
      tasks[#tasks + 1] = {
        id = current_provider.id,
        label = label_ok and label or current_provider.id,
        start = function(done, report)
          if not label_ok then
            error(label)
          end
          return current_provider.start(context, source_buffer, config, done, report)
        end,
      }
    elseif not enabled_ok then
      local enabled_error = enabled
      tasks[#tasks + 1] = {
        id = current_provider.id,
        label = type(current_provider.label) == "string" and current_provider.label
          or current_provider.id,
        start = function()
          error(enabled_error)
        end,
      }
    end
  end
  return tasks
end

---@param context table
---@param source_buffer integer
---@param config table
---@param controls ArchLensProviderControls
---@return ArchLensGraphDelta
function M.run(context, source_buffer, config, controls)
  local relationships = graph.new(context)
  local tasks = tasks_for(context, source_buffer, config)
  local now = controls.now or function()
    return math.floor(vim.uv.hrtime() / 1000000)
  end
  local runs = {}
  for _, task in ipairs(tasks) do
    runs[task.id] = {
      id = task.id,
      label = task.label,
      state = "queued",
    }
  end

  local function update()
    if not controls.is_current() then
      return
    end
    local provider_runs = {}
    local current_time = now()
    for _, task in ipairs(tasks) do
      local run = runs[task.id]
      local published = {
        id = run.id,
        label = run.label,
        state = run.state,
        duration_ms = run.duration_ms,
        retry_delay_ms = run.retry_delay_ms,
        message = run.message,
      }
      if run.started_at_ms and not run.duration_ms then
        published.elapsed_ms = math.max(0, current_time - run.started_at_ms)
      end
      provider_runs[#provider_runs + 1] = published
    end
    graph.set_provider_runs(relationships, provider_runs)
    controls.on_update(relationships)
  end

  -- Local Tree-sitter context is already available. Publish it before any
  -- project-wide provider can complete synchronously.
  update()

  for _, task in ipairs(tasks) do
    local run = runs[task.id]
    run.state = "running"
    run.started_at_ms = now()
  end
  update()

  for _, task in ipairs(tasks) do
    local completed = false
    local run = runs[task.id]
    local function fail(message, graph_message)
      if completed or not controls.is_current() then
        return
      end
      completed = true
      run.state = "failed"
      run.duration_ms = math.max(0, now() - run.started_at_ms)
      run.retry_delay_ms = nil
      run.message = tostring(message)
      graph.add_error(
        relationships,
        graph_message or string.format("%s failed: %s", task.label, tostring(message))
      )
      update()
    end
    local function report(state, fields)
      if completed or not controls.is_current() then
        return
      end
      assert(
        state == "running" or state == "retrying",
        "provider progress state must be running or retrying"
      )
      fields = fields or {}
      run.state = state
      run.retry_delay_ms = fields.retry_delay_ms
      run.message = fields.message
      update()
    end

    local function done(result, outcome)
      if completed or not controls.is_current() then
        return
      end
      local outcome_ok, normalized = pcall(normalize_terminal_outcome, outcome)
      if not outcome_ok then
        fail(normalized)
        return
      end
      local merged, merge_error = pcall(graph.merge, relationships, result or graph.delta())
      if not merged then
        fail("invalid graph delta: " .. tostring(merge_error))
        return
      end
      completed = true
      run.state = normalized.state
      run.duration_ms = math.max(0, now() - run.started_at_ms)
      run.retry_delay_ms = nil
      run.message = normalized.message
      update()
    end

    local ok, cancel_or_error = pcall(task.start, done, report)
    if ok then
      if not completed and type(cancel_or_error) == "function" then
        local function cancel()
          if completed then
            return
          end
          completed = true
          pcall(cancel_or_error)
        end
        if controls.is_current() then
          controls.register_cancel(cancel)
        else
          cancel()
        end
      end
    elseif not completed and controls.is_current() then
      fail(
        tostring(cancel_or_error),
        string.format("%s failed to start: %s", task.label, tostring(cancel_or_error))
      )
    end
  end

  return relationships
end

---@param root? string
function M.clear_cache(root)
  for _, provider in ipairs(M.ordered()) do
    if provider.clear_cache then
      pcall(provider.clear_cache, root)
    end
  end
  containers.clear_cache()
end

return M

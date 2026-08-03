local ast_grep = require("archlens.ast_grep")
local containers = require("archlens.containers")
local graph = require("archlens.graph")
local import_index = require("archlens.import_index")
local imports = require("archlens.imports")
local lsp = require("archlens.lsp")
local treesitter = require("archlens.treesitter")

local M = {}
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

function M.register(id, spec)
  assert(registry[id] == nil, string.format("provider already registered: %s", tostring(id)))
  local normalized = normalize_provider(id, spec)
  registry[id] = normalized
  return vim.deepcopy(normalized)
end

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
    )
  )
end

local function lsp_contexts(context, source_buffer)
  if type(lsp.relationship_contexts) == "function" then
    return lsp.relationship_contexts(context, source_buffer)
  end
  return { context }
end

local function start_lsp_context(context, source_buffer, config, done)
  local lsp_cancel = function() end
  local retry_timer
  local retried = false
  local cancelled = false
  local run

  local function finish(result, metadata)
    if cancelled then
      return
    end
    local retry = config.lsp.cold_start_retry or {}
    local retryable = not retried
      and retry.enabled ~= false
      and empty_semantic_result(result, metadata)
      and type(lsp.recently_attached) == "function"
      and lsp.recently_attached(context.client_id, retry.window_ms or 10000)
    if retryable then
      retried = true
      retry_timer = vim.defer_fn(function()
        retry_timer = nil
        if not cancelled then
          run()
        end
      end, math.max(0, retry.delay_ms or 3000))
      return
    end

    explain_empty_semantic_result(result, context, metadata, retried)
    done(result)
  end

  run = function()
    lsp_cancel = lsp.relationships(context, source_buffer, finish, {
      timeout_ms = config.lsp.relationship_timeout_ms,
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

local function start_lsp(context, source_buffer, config, done)
  local contexts = lsp_contexts(context, source_buffer)
  local combined = graph.delta()
  local pending = #contexts
  local cancellations = {}
  local grouping_cancel = function() end
  local cancelled = false

  local function finish(result)
    if cancelled then
      return
    end
    graph.merge(combined, result)
    pending = pending - 1
    if pending ~= 0 then
      return
    end
    if not config.grouping.enabled then
      done(combined)
      return
    end
    grouping_cancel =
      containers.enrich(combined, context, provider_options(config.grouping, config), done)
  end

  for _, semantic_context in ipairs(contexts) do
    cancellations[#cancellations + 1] =
      start_lsp_context(semantic_context, source_buffer, config, finish)
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

M.register("imports", {
  order = 20,
  label = "Module dependencies",
  enabled = function(_, source_buffer, config)
    return config.imports.enabled and treesitter.supports_imports(source_buffer)
  end,
  start = function(context, source_buffer, config, done)
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
  label = "Module dependents",
  enabled = function(context, source_buffer, config)
    return config.imports.enabled
      and config.imports.inbound.enabled
      and (treesitter.supports_imports(source_buffer) or context.import_filetype)
  end,
  start = function(context, source_buffer, config, done)
    local options = provider_options(config.imports.inbound, config)
    options.filetype = context.import_filetype
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
        start = function(done)
          if not label_ok then
            error(label)
          end
          return current_provider.start(context, source_buffer, config, done)
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

function M.run(context, source_buffer, config, controls)
  local relationships = graph.new(context)
  local tasks = tasks_for(context, source_buffer, config)
  local pending = {}
  for _, task in ipairs(tasks) do
    pending[task.id] = true
  end

  local function update()
    if not controls.is_current() then
      return
    end
    local pending_providers = {}
    for _, task in ipairs(tasks) do
      if pending[task.id] then
        pending_providers[#pending_providers + 1] = { id = task.id, label = task.label }
      end
    end
    graph.set_pending(relationships, pending_providers)
    controls.on_update(relationships)
  end

  -- Local Tree-sitter context is already available. Publish it before any
  -- project-wide provider can complete synchronously.
  update()

  for _, task in ipairs(tasks) do
    local completed = false
    local function done(result)
      if completed or not controls.is_current() then
        return
      end
      completed = true
      graph.merge(relationships, result or graph.delta())
      pending[task.id] = nil
      update()
    end

    local ok, cancel_or_error = pcall(task.start, done)
    if ok then
      controls.register_cancel(cancel_or_error)
    elseif not completed and controls.is_current() then
      completed = true
      pending[task.id] = nil
      graph.add_error(
        relationships,
        string.format("%s failed to start: %s", task.label, tostring(cancel_or_error))
      )
      update()
    end
  end

  return relationships
end

function M.clear_cache(root)
  for _, provider in ipairs(M.ordered()) do
    if provider.clear_cache then
      pcall(provider.clear_cache, root)
    end
  end
  containers.clear_cache()
end

return M

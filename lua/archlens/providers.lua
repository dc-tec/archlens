local containers = require("archlens.containers")
local graph = require("archlens.graph")

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
---@field replaces? string[]|function
---@field clear_cache? function
---@field tools? function

---@class ArchLensProviderTool
---@field id string
---@field provider_id string
---@field label string
---@field command string
---@field enabled boolean
---@field version_args string[]
---@field disabled_message? string
---@field unavailable_message? string
---@field version_label? string

---@class ArchLensProviderToolIssue
---@field provider_id string
---@field message string

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
  replaces = true,
  start = true,
  tools = true,
}

local function nonempty_string(value)
  return type(value) == "string" and value:match("%S") ~= nil
end

local function validate_provider_ids(value, label)
  assert(type(value) == "table" and vim.islist(value), label .. " must be a list")
  local seen = {}
  for index, id in ipairs(value) do
    assert(
      nonempty_string(id) and id:match("^[%l][%l%d_%-]*$"),
      string.format("%s[%d] must be a lowercase provider id", label, index)
    )
    assert(not seen[id], string.format("%s contains duplicate provider id: %s", label, id))
    seen[id] = true
  end
end

local terminal_provider_states = {
  cancelled = true,
  completed = true,
  failed = true,
  timed_out = true,
  unavailable = true,
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
  if normalized.replaces ~= nil then
    assert(
      type(normalized.replaces) == "table" or type(normalized.replaces) == "function",
      "provider replaces must be a list or function"
    )
    if type(normalized.replaces) == "table" then
      validate_provider_ids(normalized.replaces, "provider replaces")
      assert(not vim.list_contains(normalized.replaces, id), "providers cannot replace themselves")
    end
  end
  if normalized.clear_cache ~= nil then
    assert(type(normalized.clear_cache) == "function", "provider clear_cache must be a function")
  end
  if normalized.tools ~= nil then
    assert(type(normalized.tools) == "function", "provider tools must be a function")
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

local function normalize_provider_tool(provider_id, spec)
  assert(type(spec) == "table", "provider tool must be a table")
  local normalized = vim.deepcopy(spec)
  local allowed_fields = {
    command = true,
    disabled_message = true,
    enabled = true,
    id = true,
    label = true,
    unavailable_message = true,
    version_args = true,
    version_label = true,
  }
  for key in pairs(normalized) do
    assert(allowed_fields[key], "unsupported provider tool field: " .. tostring(key))
  end
  assert(
    nonempty_string(normalized.id) and normalized.id:match("^[%l][%l%d_%-]*$"),
    "provider tool id must be a lowercase identifier"
  )
  assert(nonempty_string(normalized.label), "provider tool label must be a non-empty string")
  assert(nonempty_string(normalized.command), "provider tool command must be a non-empty string")
  if normalized.enabled ~= nil then
    assert(type(normalized.enabled) == "boolean", "provider tool enabled must be a boolean")
  end
  normalized.enabled = normalized.enabled ~= false
  if normalized.version_args ~= nil then
    assert(
      type(normalized.version_args) == "table" and vim.islist(normalized.version_args),
      "provider tool version_args must be a list"
    )
    for index, argument in ipairs(normalized.version_args) do
      assert(
        nonempty_string(argument),
        string.format("provider tool version_args[%d] must be a non-empty string", index)
      )
    end
  else
    normalized.version_args = { "--version" }
  end
  for _, field in ipairs({ "disabled_message", "unavailable_message", "version_label" }) do
    assert(
      normalized[field] == nil or nonempty_string(normalized[field]),
      "provider tool " .. field .. " must be a non-empty string"
    )
  end
  normalized.provider_id = provider_id
  return normalized
end

---@param buffer table
---@param config table
---@return ArchLensProviderTool[], ArchLensProviderToolIssue[]
function M.tools(buffer, config)
  local tools = {}
  local issues = {}
  for _, provider in ipairs(M.ordered()) do
    if provider.tools then
      local called, definitions = pcall(provider.tools, buffer, config)
      local declaration_error
      if not called then
        declaration_error = tostring(definitions)
      elseif type(definitions) ~= "table" or not vim.islist(definitions) then
        declaration_error = "provider tools must return a list"
      else
        local seen = {}
        local provider_tools = {}
        for _, definition in ipairs(definitions) do
          local valid, normalized = pcall(normalize_provider_tool, provider.id, definition)
          if not valid then
            declaration_error = tostring(normalized)
            break
          end
          if seen[normalized.id] then
            declaration_error = "provider tools contain duplicate id: " .. normalized.id
            break
          end
          seen[normalized.id] = true
          provider_tools[#provider_tools + 1] = normalized
        end
        if not declaration_error then
          vim.list_extend(tools, provider_tools)
        end
      end
      if declaration_error then
        issues[#issues + 1] = {
          provider_id = provider.id,
          message = declaration_error,
        }
      end
    end
  end
  return tools, issues
end

for _, module_name in ipairs(require("archlens.providers.builtins")) do
  local builtin = require(module_name)
  assert(type(builtin) == "table", module_name .. " must return a provider definition")
  assert(nonempty_string(builtin.id), module_name .. " must define a provider id")
  M.register(builtin.id, builtin.spec)
end

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

local function provider_replacements(provider, context, source_buffer, config)
  local replacements = provider.replaces
  if type(replacements) == "function" then
    replacements = replacements(context, source_buffer, config)
  end
  if replacements == nil then
    return {}
  end
  validate_provider_ids(replacements, string.format("provider %s replaces", provider.id))
  for _, id in ipairs(replacements) do
    assert(id ~= provider.id, string.format("provider %s cannot replace itself", provider.id))
    local replaced = registry[id]
    assert(
      replaced ~= nil,
      string.format("provider %s replaces unknown provider: %s", provider.id, id)
    )
    assert(
      replaced.order > provider.order,
      string.format(
        "provider %s can only replace later providers, but %s has order %d",
        provider.id,
        id,
        replaced.order
      )
    )
  end
  return replacements
end

local function tasks_for(context, source_buffer, config)
  local candidates = {}
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
      local replacements_ok, replacements =
        pcall(provider_replacements, current_provider, context, source_buffer, config)
      candidates[#candidates + 1] = {
        id = current_provider.id,
        label = label_ok and label or current_provider.id,
        replacements = replacements_ok and replacements or {},
        can_replace = label_ok and replacements_ok,
        start = function(done, report)
          if not label_ok then
            error(label)
          end
          if not replacements_ok then
            error(replacements)
          end
          return current_provider.start(context, source_buffer, config, done, report)
        end,
      }
    elseif not enabled_ok then
      local enabled_error = enabled
      candidates[#candidates + 1] = {
        id = current_provider.id,
        label = type(current_provider.label) == "string" and current_provider.label
          or current_provider.id,
        replacements = {},
        can_replace = false,
        start = function()
          error(enabled_error)
        end,
      }
    end
  end

  local tasks = {}
  local replaced = {}
  for _, candidate in ipairs(candidates) do
    if not replaced[candidate.id] then
      tasks[#tasks + 1] = candidate
      if candidate.can_replace then
        for _, id in ipairs(candidate.replacements) do
          replaced[id] = true
        end
      end
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

local adapters = require("archlens.adapters")

local M = {}

local function zero_range()
  return {
    start = { line = 0, character = 0 },
    ["end"] = { line = 0, character = 0 },
  }
end

local function add_issue(context, issue)
  context.adapter_issues = context.adapter_issues or {}
  context.adapter_issues[#context.adapter_issues + 1] = issue
end

local symbol_kinds = {
  module = vim.lsp.protocol.SymbolKind.Module,
  package = vim.lsp.protocol.SymbolKind.Package,
  workspace = vim.lsp.protocol.SymbolKind.Namespace,
}

function M.context(source, boundary, enclosing_boundaries)
  local representative = boundary.representative_path or source.path or boundary.path
  local location = {
    uri = vim.uri_from_fname(representative),
    range = zero_range(),
  }
  local path_label = source.root_dir and vim.fs.relpath(source.root_dir, representative)
    or representative
  return {
    id = boundary.id,
    name = boundary.name,
    kind = boundary.symbol_kind
      or symbol_kinds[boundary.level]
      or vim.lsp.protocol.SymbolKind.Namespace,
    kind_name = boundary.kind_name,
    scope = "boundary",
    root_dir = source.root_dir,
    supports_calls = false,
    location = location,
    path = representative,
    path_label = path_label,
    line = location.range and location.range.start.line + 1 or nil,
    language = source.language,
    import_filetype = source.language,
    is_boundary = true,
    module_context = true,
    preserve_file_identity = true,
    boundary_source_path = source.boundary_source_path or source.path,
    boundary_source_root_dir = source.boundary_source_root_dir or source.root_dir,
    enclosing_boundaries = vim.deepcopy(enclosing_boundaries or {}),
    boundary_id = boundary.id,
    boundary_class = boundary.class,
    boundary_level = boundary.level,
    boundary_path = vim.fs.normalize(boundary.path),
    boundary_keys = vim.deepcopy(boundary.import_keys or {}),
    boundary_evidence = vim.deepcopy(boundary.evidence),
  }
end

---@param source table
---@param resolved table[]
---@return table[]
function M.contexts(source, resolved)
  local contexts = {}
  for index = #resolved, 1, -1 do
    local enclosing = {}
    for outer = index + 1, #resolved do
      enclosing[#enclosing + 1] = contexts[outer]
    end
    contexts[index] = M.context(source, resolved[index], enclosing)
  end
  return contexts
end

---@param context table
---@return table
function M.attach(context)
  if not context or context.is_boundary or context.enclosing_boundaries then
    return context
  end
  local path = context.path
    or (context.location and context.location.uri and context.location.uri:match("^file:") and vim.uri_to_fname(
      context.location.uri
    ))
    or nil
  if not path or not context.language then
    return context
  end

  local resolved, err =
    adapters.resolve_boundaries(context.language, vim.fs.normalize(path), context.root_dir, context)
  if err then
    add_issue(context, err)
  elseif resolved then
    context.enclosing_boundaries = M.contexts(context, resolved)
  end
  return context
end

---@param context table
---@return boolean
function M.supports_discovery(context)
  return context ~= nil
    and context.language ~= nil
    and adapters.supports_boundary_discovery(context.language)
end

---@param context table
---@param options? { timeout_ms?: integer }
---@param callback fun(context: table, outcome: table?)
---@return function?
function M.discover(context, options, callback)
  assert(type(context) == "table", "boundary discovery requires a context")
  assert(type(callback) == "function", "boundary discovery requires a callback")
  if context.enclosing_boundaries and #context.enclosing_boundaries > 0 then
    callback(vim.deepcopy(context))
    return function() end
  end
  if not M.supports_discovery(context) then
    return nil
  end

  local path = context.path
    or (context.location and context.location.uri and context.location.uri:match("^file:") and vim.uri_to_fname(
      context.location.uri
    ))
    or nil
  if not path then
    return nil
  end
  path = vim.fs.normalize(path)
  local timeout_ms = math.max(0, math.floor(tonumber(options and options.timeout_ms) or 8000))
  local completed = false
  local cancelled = false
  local timer
  local cancel_adapter = function() end

  local function stop_timer()
    if timer and not timer:is_closing() then
      timer:stop()
      timer:close()
    end
    timer = nil
  end
  local function finish(resolved, outcome)
    if completed or cancelled then
      return
    end
    completed = true
    stop_timer()
    local enriched = vim.deepcopy(context)
    if resolved then
      enriched.enclosing_boundaries = M.contexts(enriched, resolved)
    end
    if outcome and outcome.message then
      add_issue(enriched, outcome.message)
    end
    callback(enriched, outcome)
  end

  local cancel =
    adapters.discover_boundaries(context.language, path, context.root_dir, context, finish)
  if type(cancel) ~= "function" then
    return nil
  end
  cancel_adapter = cancel
  if not completed then
    timer = vim.defer_fn(function()
      if completed or cancelled then
        return
      end
      pcall(cancel_adapter)
      finish(nil, {
        state = "timed_out",
        message = string.format(
          "%s boundary discovery exceeded %d ms and was stopped.",
          context.language,
          timeout_ms
        ),
      })
    end, timeout_ms)
  end

  return function()
    if completed or cancelled then
      return
    end
    cancelled = true
    stop_timer()
    pcall(cancel_adapter)
  end
end

local function refresh_source(context)
  local source = vim.deepcopy(context)
  source.path = context.boundary_source_path or context.path
  source.root_dir = context.boundary_source_root_dir or context.root_dir
  source.enclosing_boundaries = nil
  source.adapter_issues = nil
  if context.is_boundary then
    for _, field in ipairs({
      "boundary_class",
      "boundary_evidence",
      "boundary_id",
      "boundary_keys",
      "boundary_level",
      "boundary_path",
      "boundary_source_path",
      "boundary_source_root_dir",
      "is_boundary",
      "module_context",
      "preserve_file_identity",
    }) do
      source[field] = nil
    end
  end
  return source
end

local function select_refreshed_context(original, enriched)
  if not original.is_boundary then
    return enriched
  end
  for _, boundary in ipairs(enriched.enclosing_boundaries or {}) do
    if boundary.boundary_level == original.boundary_level then
      return boundary
    end
  end
  return nil
end

function M.clear_cache()
  adapters.clear_cache()
end

---@param context table
---@param options? { timeout_ms?: integer }
---@param callback fun(context: table?, outcome: table?)
---@return function
function M.refresh(context, options, callback)
  assert(type(context) == "table", "boundary refresh requires a context")
  assert(type(callback) == "function", "boundary refresh requires a callback")
  M.clear_cache()

  local source = refresh_source(context)
  local path = source.path
    or (source.location and source.location.uri and source.location.uri:match("^file:") and vim.uri_to_fname(
      source.location.uri
    ))
    or nil
  if not path or not source.language then
    callback(context.is_boundary and nil or source)
    return function() end
  end

  path = vim.fs.normalize(path)
  local resolved, err = adapters.resolve_boundaries(source.language, path, source.root_dir, source)
  if err then
    add_issue(source, err)
  elseif resolved then
    source.enclosing_boundaries = M.contexts(source, resolved)
    callback(select_refreshed_context(context, source))
    return function() end
  end

  if M.supports_discovery(source) then
    return M.discover(source, options, function(enriched, outcome)
      callback(select_refreshed_context(context, enriched), outcome)
    end) or function() end
  end

  if context.is_boundary then
    callback(nil, err and { state = "failed", message = err } or {
      state = "unavailable",
      message = string.format(
        "The refreshed %s boundary is no longer available.",
        context.boundary_level or "selected"
      ),
    })
  else
    callback(source, err and { state = "failed", message = err } or nil)
  end
  return function() end
end

local function source_for_buffer(bufnr)
  local path = vim.api.nvim_buf_get_name(bufnr)
  if path == "" then
    return nil
  end

  path = vim.fs.normalize(path)
  local filetype = vim.bo[bufnr].filetype
  local language = adapters.language_for_filetype(filetype, path)
  if not adapters.supports_boundaries(language) then
    return nil
  end
  return {
    language = language,
    path = path,
    root_dir = vim.fs.root(path, adapters.root_markers(filetype, path)) or vim.fs.dirname(path),
  }
end

---@param bufnr integer
---@param level string
---@return table?
function M.for_buffer(bufnr, level)
  local source = source_for_buffer(bufnr)
  if not source then
    return nil
  end
  source = M.attach(source)
  for _, boundary in ipairs(source.enclosing_boundaries or {}) do
    if boundary.boundary_level == level then
      return boundary
    end
  end
  return nil
end

---@param bufnr integer
---@param level string
---@param options? { timeout_ms?: integer }
---@param callback fun(context: table?, outcome: table?)
---@return function
function M.resolve_buffer(bufnr, level, options, callback)
  assert(type(callback) == "function", "boundary buffer resolution requires a callback")
  local current = M.for_buffer(bufnr, level)
  if current then
    callback(current)
    return function() end
  end
  local source = source_for_buffer(bufnr)
  if not source or not M.supports_discovery(source) then
    callback(nil)
    return function() end
  end
  return M.discover(source, options, function(enriched, outcome)
    for _, boundary in ipairs(enriched.enclosing_boundaries or {}) do
      if boundary.boundary_level == level then
        callback(boundary, outcome)
        return
      end
    end
    callback(nil, outcome)
  end) or function() end
end

return M

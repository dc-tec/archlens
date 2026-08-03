local graph = require("archlens.graph")
local lsp = require("archlens.lsp")
local model = require("archlens.model")
local scope = require("archlens.scope")
local treesitter = require("archlens.treesitter")

local M = {}
local target_cache = {}
local target_cache_order = {}
local target_cache_limit = 256

local function cache_key(context, bufnr, site)
  local changedtick = vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_get_changedtick(bufnr)
    or 0
  return table.concat({
    tostring(context.client_id or ""),
    site.location.uri,
    tostring(changedtick),
    tostring(site.position.line),
    tostring(site.position.character),
    site.name,
  }, ":")
end

local function cached_targets(key)
  return target_cache[key] and vim.deepcopy(target_cache[key]) or nil
end

local function remember_targets(key, locations)
  if target_cache[key] or not locations or #locations == 0 then
    return
  end
  target_cache[key] = vim.deepcopy(locations)
  target_cache_order[#target_cache_order + 1] = key
  while #target_cache_order > target_cache_limit do
    local expired = table.remove(target_cache_order, 1)
    target_cache[expired] = nil
  end
end

function M.clear_cache(root)
  target_cache = {}
  target_cache_order = {}
  require("archlens.adapters").clear_cache()
  require("archlens.import_index").clear_cache(root)
end

local function location_kind(context, location, filters)
  if not location or not location.uri or not location.uri:match("^file:") then
    return "external"
  end
  local ok, path = pcall(vim.uri_to_fname, location.uri)
  if not ok then
    return "external"
  end
  return scope.classify(context.root_dir, path, filters)
end

local function target_location(context, locations, filters)
  local candidates = vim.deepcopy(locations or {})
  table.sort(candidates, function(left, right)
    local left_kind = location_kind(context, left, filters)
    local right_kind = location_kind(context, right, filters)
    local left_visible = scope.visible(left_kind, filters)
    local right_visible = scope.visible(right_kind, filters)
    if left_visible ~= right_visible then
      return left_visible
    end
    local left_project = left_kind ~= "external"
    local right_project = right_kind ~= "external"
    if left_project ~= right_project then
      return left_project
    end
    local left_key = graph.location_key(left)
    local right_key = graph.location_key(right)
    return left_key < right_key
  end)
  return candidates[1]
end

local function import_edge(context, site, location, import_filetype)
  local target_context = model.context_from_item({
    name = site.name,
    kind = vim.lsp.protocol.SymbolKind.Module,
    uri = location.uri,
    range = location.full_range or location.range,
    selectionRange = location.range,
  }, {
    id = context.client_id,
    name = context.client_name,
    offset_encoding = "utf-8",
    root_dir = context.root_dir,
    supports_calls = false,
  })
  target_context.module_context = true
  target_context.import_filetype = import_filetype
  local source_path = vim.uri_to_fname(site.location.uri)
  local source = graph.node({
    name = vim.fs.basename(source_path),
    kind = vim.lsp.protocol.SymbolKind.File,
    kind_name = "File",
    scope = "file",
    path = source_path,
    path_label = context.root_dir and vim.fs.relpath(context.root_dir, source_path) or source_path,
    location = {
      uri = site.location.uri,
      range = {
        start = { line = 0, character = 0 },
        ["end"] = { line = 0, character = 0 },
      },
    },
  })
  local target = graph.node_from_context(target_context, {
    scope = "module",
  })
  return graph.edge("module_imports", source, target, {
    provider = site.resolution == "path" and (site.resolution_provider or "Tree-sitter")
      or "Tree-sitter+" .. (context.client_name or "LSP"),
    method = site.resolution == "path" and (site.resolution_method or "adapter/moduleTarget")
      or "textDocument/definition",
    class = "semantic",
  }, {
    occurrences = {
      {
        uri = site.location.uri,
        ranges = { vim.deepcopy(site.location.range) },
      },
    },
    presentation = {
      section_anchor = {
        prefix = "from",
        label = vim.fs.basename(source_path),
      },
    },
  })
end

function M.relationships(context, bufnr, options, callback)
  options = options or {}
  local result = graph.delta()
  local sites, extraction_error = treesitter.import_sites(bufnr)
  if extraction_error then
    graph.add_error(result, "Module dependency extraction failed: " .. extraction_error)
    callback(result)
    return function() end
  end
  if #sites == 0 then
    callback(result)
    return function() end
  end

  local client = context.client_id and vim.lsp.get_client_by_id(context.client_id) or nil
  local definition_available = client
    and not client:is_stopped()
    and client:supports_method("textDocument/definition", bufnr)
  local max_imports = math.max(1, math.floor(tonumber(options.max_imports) or 24))
  local max_sites = math.max(max_imports, math.floor(tonumber(options.max_sites) or 96))
  local omitted_sites = math.max(0, #sites - max_sites)
  while #sites > max_sites do
    table.remove(sites)
  end
  local filters = options.filters or {}
  local concurrency = math.max(1, math.floor(tonumber(options.concurrency) or 4))
  local active = 0
  local next_site = 1
  local unresolved = 0
  local requires_lsp = 0
  local completed = false
  local cancellations = {}
  local outcomes = {}
  local materialized = false
  local omitted_imports = 0
  local timer

  if definition_available then
    for _, site in ipairs(sites) do
      if not site.target_locations or #site.target_locations == 0 then
        graph.add_contributor(
          result,
          "lsp:" .. tostring(context.client_id),
          context.client_name or "LSP"
        )
        break
      end
    end
  end

  local function stop_requests()
    for _, cancel in pairs(cancellations) do
      pcall(cancel)
    end
    cancellations = {}
  end

  local function materialize()
    if materialized then
      return
    end
    materialized = true
    local admitted = {}
    local rejected = {}
    local visible_targets = 0
    for index = 1, #sites do
      local outcome = outcomes[index]
      if outcome and outcome.location then
        local edge = import_edge(context, outcome.site, outcome.location, vim.bo[bufnr].filetype)
        local kind = location_kind(context, outcome.location, filters)
        local visible = scope.visible(kind, filters)
        local target_key = edge.target.id
        if not visible or admitted[target_key] then
          graph.add_edge(result, edge)
        elseif visible_targets < max_imports then
          admitted[target_key] = true
          visible_targets = visible_targets + 1
          graph.add_edge(result, edge)
        elseif not rejected[target_key] then
          rejected[target_key] = true
          omitted_imports = omitted_imports + 1
        end
      end
    end
  end

  local function add_notes(all_require_lsp)
    if unresolved > 0 then
      graph.add_note(
        result,
        string.format(
          "%d module dependency target%s could not be resolved.",
          unresolved,
          unresolved == 1 and "" or "s"
        ),
        { summary = "module dependencies incomplete", severity = "warn" }
      )
    end
    if requires_lsp > 0 and not all_require_lsp then
      graph.add_note(
        result,
        string.format(
          "%d module dependency target%s require%s a definition-capable language server.",
          requires_lsp,
          requires_lsp == 1 and "" or "s",
          requires_lsp == 1 and "s" or ""
        ),
        { summary = "module dependencies need LSP", severity = "warn" }
      )
    end
    if omitted_imports > 0 then
      graph.add_note(
        result,
        string.format(
          "%d visible module dependenc%s omitted by the dependency limit.",
          omitted_imports,
          omitted_imports == 1 and "y" or "ies"
        ),
        { summary = "module results limited", severity = "warn" }
      )
    end
    if omitted_sites > 0 then
      graph.add_note(
        result,
        string.format(
          "%d module dependency declaration%s omitted by the scan limit.",
          omitted_sites,
          omitted_sites == 1 and "" or "s"
        ),
        { summary = "module scan limited", severity = "warn" }
      )
    end
  end

  local function unavailable_outcome()
    if #sites == 0 or requires_lsp ~= #sites then
      return nil
    end
    return {
      state = "unavailable",
      message = string.format(
        "%d module dependency target%s require%s a definition-capable language server.",
        requires_lsp,
        requires_lsp == 1 and "" or "s",
        requires_lsp == 1 and "s" or ""
      ),
    }
  end

  local function complete()
    if completed or active ~= 0 or next_site <= #sites then
      return
    end
    completed = true
    if timer and not timer:is_closing() then
      timer:stop()
      timer:close()
    end
    materialize()
    local outcome = unavailable_outcome()
    add_notes(outcome ~= nil)
    callback(result, outcome)
  end

  local pump
  local function launch(index, site)
    active = active + 1
    local settled = false
    local function resolved(locations, err)
      if completed or settled then
        return
      end
      settled = true
      cancellations[index] = nil
      active = active - 1
      local location = target_location(context, locations, filters)
      outcomes[index] = { site = site, location = location }
      if (err or not location) and not site.requires_lsp then
        unresolved = unresolved + 1
      end
      pump()
    end
    local cancel
    local key = cache_key(context, bufnr, site)
    local cached = cached_targets(key)
    if cached then
      resolved(cached, nil)
      cancel = function() end
    elseif site.target_locations and #site.target_locations > 0 then
      site.resolution = "path"
      resolved(site.target_locations, nil)
      cancel = function() end
    elseif not definition_available then
      requires_lsp = requires_lsp + 1
      site.requires_lsp = true
      resolved({}, nil)
      cancel = function() end
    else
      cancel = lsp.definition_at(
        context,
        bufnr,
        site.location,
        site.position,
        function(locations, err)
          if not err then
            remember_targets(key, locations)
          end
          resolved(locations, err)
        end
      )
    end
    if not settled then
      cancellations[index] = cancel
    end
  end

  pump = function()
    if completed then
      return
    end
    while active < concurrency and next_site <= #sites do
      local index = next_site
      next_site = next_site + 1
      launch(index, sites[index])
    end
    complete()
  end

  pump()
  if not completed then
    local timeout_ms = math.max(1, math.floor(tonumber(options.timeout_ms) or 5000))
    timer = vim.defer_fn(function()
      if completed then
        return
      end
      completed = true
      stop_requests()
      materialize()
      add_notes(false)
      callback(result, {
        state = "timed_out",
        message = string.format(
          "Module dependency resolution exceeded %d ms and was stopped.",
          timeout_ms
        ),
      })
    end, timeout_ms)
  end

  return function()
    if completed then
      return
    end
    completed = true
    if timer and not timer:is_closing() then
      timer:stop()
      timer:close()
    end
    stop_requests()
  end
end

return M

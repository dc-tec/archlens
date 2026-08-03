local graph = require("archlens.graph")
local relations = require("archlens.relations")
local scope = require("archlens.scope")
local treesitter = require("archlens.treesitter")

local M = {}
local cache = {}

local function stamp(path)
  local bufnr = vim.fn.bufnr(path)
  if bufnr ~= -1 and vim.api.nvim_buf_is_loaded(bufnr) then
    return "buffer:" .. tostring(vim.api.nvim_buf_get_changedtick(bufnr))
  end
  local stat = vim.uv.fs_stat(path)
  if not stat or stat.type ~= "file" then
    return "missing"
  end
  return table.concat({ stat.size or 0, stat.mtime.sec or 0, stat.mtime.nsec or 0 }, ":")
end

local function position_key(position)
  return table.concat({ position.line or 0, position.character or 0 }, ":")
end

local function container_id(container)
  return table.concat({
    "container",
    graph.location_key(container.location),
    container.kind_name or "",
    container.name or "",
  }, ":")
end

local function file_container(context, path)
  local relative = context.root_dir and vim.fs.relpath(context.root_dir, path) or nil
  local container = {
    name = relative or vim.fs.basename(path),
    kind_name = "File",
    location = {
      uri = vim.uri_from_fname(path),
      range = {
        start = { line = 0, character = 0 },
        ["end"] = { line = 0, character = 0 },
      },
    },
    trail = {},
  }
  container.context = {
    name = container.name,
    kind = vim.lsp.protocol.SymbolKind.File,
    kind_name = "File",
    scope = "file",
    root_dir = context.root_dir,
    supports_calls = false,
    module_context = true,
    preserve_file_identity = true,
    location = vim.deepcopy(container.location),
    path = path,
    path_label = relative or path,
    line = 1,
  }
  container.id = container_id(container)
  return container
end

local function annotate(edge, container)
  container = vim.deepcopy(container)
  container.id = container.id or container_id(container)
  edge.presentation = edge.presentation or {}
  edge.presentation.container = container
end

local function enrich_file(path, items)
  local current_stamp = stamp(path)
  local cached = cache[path]
  if not cached or cached.stamp ~= current_stamp then
    cached = { stamp = current_stamp, containers = {} }
    cache[path] = cached
  end

  local misses = {}
  local miss_keys = {}
  for _, item in ipairs(items) do
    local key = position_key(item.position)
    if cached.containers[key] == nil then
      misses[#misses + 1] = item.position
      miss_keys[#miss_keys + 1] = key
    end
  end
  if #misses > 0 then
    local resolved = treesitter.enclosing_containers(path, misses)
    for index, key in ipairs(miss_keys) do
      cached.containers[key] = resolved[index] or false
    end
  end
  for _, item in ipairs(items) do
    local container = cached.containers[position_key(item.position)]
    if container then
      annotate(item.edge, container)
    end
  end
end

function M.enrich(delta, context, options, callback)
  options = options or {}
  local by_path = {}
  local paths = {}
  local filters = options.filters or {}
  local scope_cache = {}
  local max_edges = math.max(1, math.floor(tonumber(options.max_edges) or 500))
  local eligible_edges = 0
  local file_grouped = 0
  for _, edge in ipairs(delta.edges or {}) do
    local relation = relations.get(edge.kind)
    local node = relation and relation.group_by == "container" and graph.related_node(edge) or nil
    local location = node and node.location
    if location and location.uri and location.uri:match("^file:") and location.range then
      local path = vim.fs.normalize(vim.uri_to_fname(location.uri))
      annotate(edge, file_container(context, path))
      eligible_edges = eligible_edges + 1
      if eligible_edges > max_edges then
        file_grouped = file_grouped + 1
      elseif
        scope.visible(scope.classify(context.root_dir, path, filters, scope_cache), filters)
      then
        local stat = vim.uv.fs_stat(path)
        if not stat or (stat.size or 0) <= (options.max_file_bytes or (1024 * 1024)) then
          if not by_path[path] then
            by_path[path] = {}
            paths[#paths + 1] = path
          end
          by_path[path][#by_path[path] + 1] = {
            edge = edge,
            position = vim.deepcopy(location.range.start),
          }
        end
      end
    end
  end
  if file_grouped > 0 then
    graph.add_note(
      delta,
      string.format(
        "%d relationship%s grouped by file because the context limit was reached.",
        file_grouped,
        file_grouped == 1 and " was" or "s were"
      ),
      { summary = "relationship grouping limited", severity = "warn" }
    )
  end
  if #paths == 0 then
    callback(delta)
    return function() end
  end
  table.sort(paths)

  local cursor = 1
  local completed = false
  local timer
  local batch_size = math.max(1, math.floor(tonumber(options.batch_size) or 4))
  local timeout_ms = math.max(1, math.floor(tonumber(options.timeout_ms) or 1500))

  local function finish(timed_out)
    if completed then
      return
    end
    completed = true
    if timer and not timer:is_closing() then
      timer:stop()
      timer:close()
    end
    if timed_out then
      graph.add_note(
        delta,
        string.format(
          "Relationship grouping stopped after %d ms; some uses are grouped by file.",
          timeout_ms
        ),
        { summary = "relationship grouping timed out", severity = "warn" }
      )
    end
    callback(delta)
  end

  local function process_batch()
    if completed then
      return
    end
    local last = math.min(#paths, cursor + batch_size - 1)
    for index = cursor, last do
      pcall(enrich_file, paths[index], by_path[paths[index]])
    end
    cursor = last + 1
    if cursor <= #paths then
      vim.schedule(process_batch)
    else
      finish(false)
    end
  end

  timer = vim.defer_fn(function()
    finish(true)
  end, timeout_ms)
  vim.schedule(process_batch)
  return function()
    if completed then
      return
    end
    completed = true
    if timer and not timer:is_closing() then
      timer:stop()
      timer:close()
    end
  end
end

function M.clear_cache()
  cache = {}
end

return M

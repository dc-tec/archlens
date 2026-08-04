local boundaries = require("archlens.boundaries")
local go_workspace = require("archlens.go_workspace")
local graph = require("archlens.graph")

local M = {}
local scans = {}

local defaults = {
  command = "go",
  timeout_ms = 8000,
  max_modules = 64,
  max_packages = 1000,
  max_output_bytes = 2 * 1024 * 1024,
}

local function normalized(path)
  return path and vim.fs.normalize(path) or nil
end

local function diagnostic_text(value)
  local line = vim.trim(value or ""):match("[^\r\n]+") or ""
  if #line > 400 then
    return line:sub(1, 400) .. "..."
  end
  return line
end

local function module_key(context)
  return context.boundary_id and context.boundary_id:match("^go%-module:(.+)$") or nil
end

local function module_root(context)
  return context.boundary_path and normalized(context.boundary_path) or nil
end

local function normalized_options(options)
  local result = vim.tbl_extend("force", vim.deepcopy(defaults), options or {})
  for _, field in ipairs({ "timeout_ms", "max_modules", "max_packages", "max_output_bytes" }) do
    local fallback = assert(tonumber(defaults[field]))
    result[field] = math.max(1, math.floor(tonumber(result[field]) or fallback))
  end
  return result
end

local function workspace_file(context, root)
  return go_workspace.find(root, context.go_workspace_file)
end

local function scan_key(root, workspace, mode, options)
  return table.concat({
    root,
    workspace or "",
    mode,
    tostring(options.command),
    tostring(options.timeout_ms),
    tostring(options.max_modules),
    tostring(options.max_packages),
    tostring(options.max_output_bytes),
  }, "\0")
end

local function decode_json_stream(stdout)
  local values = {}
  local start
  local depth = 0
  local quoted = false
  local escaped = false
  for index = 1, #(stdout or "") do
    local character = stdout:sub(index, index)
    if quoted then
      if escaped then
        escaped = false
      elseif character == "\\" then
        escaped = true
      elseif character == '"' then
        quoted = false
      end
    elseif character == '"' then
      quoted = true
    elseif character == "{" then
      if depth == 0 then
        start = index
      end
      depth = depth + 1
    elseif character == "}" and depth > 0 then
      depth = depth - 1
      if depth == 0 and start then
        local ok, value = pcall(vim.json.decode, stdout:sub(start, index))
        if not ok or type(value) ~= "table" then
          return values, "Go command returned malformed JSON"
        end
        values[#values + 1] = value
        start = nil
      end
    end
  end
  if quoted or depth ~= 0 then
    return values, "Go command returned incomplete JSON"
  end
  return values
end

local function run_go(root, workspace, options, arguments, callback)
  local completed = false
  local process
  local timer
  local stdout_chunks = {}
  local stdout_bytes = 0
  local stdout_limited = false
  local stdout_error
  local stderr_chunks = {}
  local stderr_bytes = 0
  local stderr_limited = false
  local stderr_error

  local function finish(values, outcome)
    if completed then
      return
    end
    completed = true
    if timer and not timer:is_closing() then
      timer:stop()
      timer:close()
    end
    vim.schedule(function()
      callback(values, outcome)
    end)
  end

  local function collect(chunks, byte_count, limited, set_error, err, data)
    if completed then
      return byte_count, limited
    end
    if err then
      set_error(tostring(err))
    end
    if not data or data == "" or limited then
      return byte_count, limited
    end
    local remaining = math.max(0, options.max_output_bytes - byte_count)
    if remaining > 0 then
      chunks[#chunks + 1] = data:sub(1, remaining)
      byte_count = byte_count + math.min(#data, remaining)
    end
    if #data > remaining then
      limited = true
      vim.schedule(function()
        if process and not completed then
          pcall(process.kill, process, 15)
        end
      end)
    end
    return byte_count, limited
  end

  local command = { options.command }
  vim.list_extend(command, arguments)
  local system_options = {
    cwd = root,
    text = true,
    stdout = function(err, data)
      stdout_bytes, stdout_limited = collect(
        stdout_chunks,
        stdout_bytes,
        stdout_limited,
        function(value)
          stdout_error = stdout_error or value
        end,
        err,
        data
      )
    end,
    stderr = function(err, data)
      stderr_bytes, stderr_limited = collect(
        stderr_chunks,
        stderr_bytes,
        stderr_limited,
        function(value)
          stderr_error = stderr_error or value
        end,
        err,
        data
      )
    end,
  }
  if workspace then
    system_options.env = { GOWORK = workspace }
  end
  local started, value = pcall(vim.system, command, system_options, function(result)
    if completed then
      return
    end
    local stderr = diagnostic_text(table.concat(stderr_chunks))
    local values, decode_error = decode_json_stream(table.concat(stdout_chunks))
    local failure = stdout_error
      or stderr_error
      or decode_error
      or (stderr_limited and string.format(
        "error output reached %d bytes",
        options.max_output_bytes
      ))
      or (stdout_limited and string.format("output reached %d bytes", options.max_output_bytes))
      or (result.code ~= 0 and (stderr ~= "" and stderr or "exited with code " .. result.code))
    if failure then
      finish(values, { state = "failed", message = "Go module analysis failed: " .. failure })
      return
    end
    finish(values)
  end)
  if not started then
    finish(nil, { state = "failed", message = "Go module analysis failed: " .. tostring(value) })
    return function() end
  end
  process = value
  timer = vim.defer_fn(function()
    if completed then
      return
    end
    pcall(process.kill, process, 15)
    finish(nil, {
      state = "timed_out",
      message = string.format(
        "Go module analysis exceeded %d ms and was stopped.",
        options.timeout_ms
      ),
    })
  end, options.timeout_ms)
  return function()
    if not completed then
      pcall(process.kill, process, 15)
      finish(nil, { state = "cancelled" })
    end
  end
end

local function select_modules(values, focus_key, maximum)
  local modules = {}
  local by_path = {}
  for _, module in ipairs(values or {}) do
    if
      module.Main == true
      and type(module.Path) == "string"
      and module.Path ~= ""
      and type(module.Dir) == "string"
      and module.Dir ~= ""
    then
      module.Dir = normalized(module.Dir)
      module.GoMod = normalized(module.GoMod or vim.fs.joinpath(module.Dir, "go.mod"))
      modules[#modules + 1] = module
      by_path[module.Path] = module
    end
  end
  table.sort(modules, function(left, right)
    return left.Path < right.Path
  end)
  local omitted = math.max(0, #modules - maximum)
  while #modules > maximum do
    table.remove(modules)
  end
  if focus_key and not by_path[focus_key] then
    return nil, omitted, "Focused module was not loaded by go list."
  end
  if
    focus_key
    and not vim.iter(modules):any(function(module)
      return module.Path == focus_key
    end)
  then
    return nil, omitted, "Focused module was omitted by the Go workspace module limit."
  end
  return modules, omitted
end

local function package_index(values, modules, maximum)
  local module_paths = {}
  for _, module in ipairs(modules) do
    module_paths[module.Path] = true
  end
  local index = {
    packages = {},
    by_import = {},
    omitted = math.max(0, #(values or {}) - maximum),
    errors = 0,
  }
  for value_index = 1, math.min(#(values or {}), maximum) do
    local package = values[value_index]
    local owner = package.Module and package.Module.Path
    if
      module_paths[owner]
      and type(package.ImportPath) == "string"
      and package.ImportPath ~= ""
    then
      index.packages[#index.packages + 1] = package
      index.by_import[package.ImportPath] = package
      if package.Error or #(package.DepsErrors or {}) > 0 then
        index.errors = index.errors + 1
      end
    end
  end
  return index
end

local function notify(scan)
  local subscribers = scan.subscribers
  scan.subscribers = {}
  for _, subscriber in ipairs(subscribers) do
    if not subscriber.cancelled then
      subscriber.callback(scan.workspace, scan.outcome)
    end
  end
end

local function start_scan(cache_key, root, workspace, focus_key, include_packages, options)
  local scan = {
    root = root,
    ready = false,
    subscribers = {},
  }
  scans[cache_key] = scan

  local function finish(result, outcome)
    scan.ready = true
    scan.workspace = result
    scan.outcome = outcome
    if outcome and scans[cache_key] == scan then
      scans[cache_key] = nil
    end
    notify(scan)
  end

  run_go(root, workspace, options, { "list", "-m", "-json" }, function(values, outcome)
    if outcome then
      finish(nil, outcome)
      return
    end
    local modules, omitted, selection_error = select_modules(values, focus_key, options.max_modules)
    if not modules then
      finish(nil, { state = "failed", message = selection_error })
      return
    end
    if not include_packages or #modules == 1 then
      finish({
        modules = modules,
        packages = package_index({}, modules, options.max_packages),
        omitted_modules = omitted,
      })
      return
    end

    local fields = table.concat({
      "Dir",
      "ImportPath",
      "Imports",
      "ImportMap",
      "Module",
      "Error",
      "DepsErrors",
    }, ",")
    local arguments = { "list", "-e", "-json=" .. fields }
    for _, module in ipairs(modules) do
      arguments[#arguments + 1] = vim.fs.joinpath(module.Dir, "...")
    end
    run_go(root, workspace, options, arguments, function(packages, package_outcome)
      if package_outcome then
        finish(nil, package_outcome)
        return
      end
      finish({
        modules = modules,
        packages = package_index(packages, modules, options.max_packages),
        omitted_modules = omitted,
      })
    end)
  end)
  return scan
end

local function scan(context, options, callback)
  options = normalized_options(options)
  local focus_key = module_key(context)
  local workspace_focus = context.boundary_level == "workspace"
  local root = workspace_focus and normalized(context.boundary_path) or module_root(context)
  if (not workspace_focus and not focus_key) or not root or not vim.uv.fs_stat(root) then
    callback(nil, { state = "failed", message = "Go module root could not be resolved." })
    return function() end
  end
  if vim.fn.executable(options.command) ~= 1 then
    callback(nil, {
      state = "unavailable",
      message = options.command .. " is unavailable; Go module analysis was skipped.",
    })
    return function() end
  end

  local work_file = workspace_focus and normalized(context.path) or workspace_file(context, root)
  if workspace_focus and (not work_file or not vim.uv.fs_stat(work_file)) then
    callback(nil, { state = "failed", message = "Go workspace file could not be resolved." })
    return function() end
  end
  local scan_root = work_file and vim.fs.dirname(work_file) or root
  local mode = workspace_focus and "members" or "relationships"
  local cache_key = scan_key(scan_root, work_file, mode, options)
  local current = scans[cache_key]
    or start_scan(cache_key, scan_root, work_file, focus_key, not workspace_focus, options)
  if current.ready then
    callback(current.workspace, current.outcome)
    return function() end
  end
  local subscriber = { callback = callback, cancelled = false }
  current.subscribers[#current.subscribers + 1] = subscriber
  return function()
    subscriber.cancelled = true
  end
end

local function mapped_import(package, import_path)
  return (package.ImportMap or {})[import_path] or import_path
end

local function module_context(module, workspace_file_path)
  local enclosing = {}
  if workspace_file_path then
    enclosing[1] = boundaries.context({
      root_dir = vim.fs.dirname(workspace_file_path),
      path = workspace_file_path,
      language = "go",
    }, go_workspace.boundary(workspace_file_path))
  end
  local result = boundaries.context({
    root_dir = module.Dir,
    path = module.GoMod,
    language = "go",
  }, {
    id = "go-module:" .. module.Path,
    class = "build",
    level = "module",
    kind_name = "Go module",
    name = module.Path,
    path = module.Dir,
    representative_path = module.GoMod,
    evidence = {
      provider = "Go tool",
      method = "go list -m",
      class = "semantic",
    },
  }, enclosing)
  result.go_workspace_file = workspace_file_path
  return result
end

local function add_workspace_member(result, context, module, work_file)
  local source = graph.node_from_context(context)
  local target = graph.node_from_context(module_context(module, work_file))
  target.visibility_scope = "project"
  local relative = vim.fs.relpath(context.boundary_path, module.Dir)
  if relative and relative ~= "." then
    target.detail = relative
  end
  graph.add_edge(
    result,
    graph.edge("workspace_members", source, target, {
      provider = "Go tool",
      method = "go list -m",
      class = "semantic",
    })
  )
end

local function add_omitted_module_note(result, workspace)
  if workspace.omitted_modules > 0 then
    graph.add_note(
      result,
      string.format(
        "%d workspace module%s omitted by the module limit.",
        workspace.omitted_modules,
        workspace.omitted_modules == 1 and " was" or "s were"
      ),
      { summary = "Go workspace scan limited", severity = "warn" }
    )
  end
end

local function workspace_relationships(context, workspace)
  local result = graph.delta()
  local work_file = normalized(context.path)
  for _, module in ipairs(workspace.modules or {}) do
    add_workspace_member(result, context, module, work_file)
  end
  graph.add_contributor(result, "go_build", "Go tool")
  add_omitted_module_note(result, workspace)
  return result
end

local function add_module_edge(result, kind, source_context, target_context, count)
  local source = graph.node_from_context(source_context)
  local target = graph.node_from_context(target_context)
  local related = kind == "module_imports" and target or source
  related.visibility_scope = "project"
  related.detail = string.format("%d package edge%s", count, count == 1 and "" or "s")
  graph.add_edge(
    result,
    graph.edge(kind, source, target, {
      provider = "Go tool",
      method = "go list/Imports by Module",
      class = "semantic",
    })
  )
end

local function module_relationships(context, workspace, options)
  local result = graph.delta()
  local focus_key = module_key(context)
  local modules = {}
  local contexts = {}
  local work_file = workspace_file(context, module_root(context))
  for _, module in ipairs(workspace.modules or {}) do
    modules[module.Path] = module
    contexts[module.Path] = module.Path == focus_key and context
      or module_context(module, work_file)
  end

  local connections = {}
  for _, package in ipairs(workspace.packages.packages or {}) do
    local source_module = package.Module and package.Module.Path
    if modules[source_module] and not package.Error then
      for _, import_path in ipairs(package.Imports or {}) do
        local target_package = workspace.packages.by_import[mapped_import(package, import_path)]
        local target_module = target_package
          and target_package.Module
          and target_package.Module.Path
        if target_module and modules[target_module] and source_module ~= target_module then
          connections[source_module] = connections[source_module] or {}
          connections[source_module][target_module] = connections[source_module][target_module]
            or {}
          connections[source_module][target_module][package.ImportPath .. "\0" .. target_package.ImportPath] =
            true
        end
      end
    end
  end

  local outgoing = {}
  for target, package_edges in pairs(connections[focus_key] or {}) do
    outgoing[#outgoing + 1] = { path = target, count = vim.tbl_count(package_edges) }
  end
  local incoming = {}
  if options.include_dependents ~= false then
    for source, targets in pairs(connections) do
      if targets[focus_key] then
        incoming[#incoming + 1] = { path = source, count = vim.tbl_count(targets[focus_key]) }
      end
    end
  end
  table.sort(outgoing, function(left, right)
    return left.path < right.path
  end)
  table.sort(incoming, function(left, right)
    return left.path < right.path
  end)

  local max_imports = math.max(1, math.floor(tonumber(options.max_imports) or 24))
  local max_importers = math.max(1, math.floor(tonumber(options.max_importers) or 24))
  local outgoing_omitted = math.max(0, #outgoing - max_imports)
  local incoming_omitted = math.max(0, #incoming - max_importers)
  while #outgoing > max_imports do
    table.remove(outgoing)
  end
  while #incoming > max_importers do
    table.remove(incoming)
  end

  for _, connection in ipairs(outgoing) do
    add_module_edge(result, "module_imports", context, contexts[connection.path], connection.count)
  end
  for _, connection in ipairs(incoming) do
    add_module_edge(
      result,
      "module_importers",
      contexts[connection.path],
      context,
      connection.count
    )
  end
  graph.add_contributor(result, "go_build", "Go tool")
  add_omitted_module_note(result, workspace)
  if workspace.packages.omitted > 0 then
    graph.add_note(
      result,
      string.format(
        "%d Go package%s omitted by the build package limit.",
        workspace.packages.omitted,
        workspace.packages.omitted == 1 and " was" or "s were"
      ),
      { summary = "Go build scan limited", severity = "warn" }
    )
  end
  if workspace.packages.errors > 0 then
    graph.add_note(
      result,
      string.format(
        "%d Go package%s reported build-loading errors; module relationships may be incomplete.",
        workspace.packages.errors,
        workspace.packages.errors == 1 and "" or "s"
      ),
      { summary = "Go build scan incomplete", severity = "warn" }
    )
  end
  if outgoing_omitted + incoming_omitted > 0 then
    graph.add_note(
      result,
      string.format(
        "%d module relationship%s omitted by the relationship limits.",
        outgoing_omitted + incoming_omitted,
        outgoing_omitted + incoming_omitted == 1 and " was" or "s were"
      ),
      { summary = "module results limited", severity = "warn" }
    )
  end
  return result
end

function M.supports(context)
  return context
    and context.is_boundary == true
    and (context.boundary_level == "module" or context.boundary_level == "workspace")
    and context.language == "go"
end

function M.relationships(context, _, options, callback)
  options = options or {}
  return scan(context, options.build, function(workspace, outcome)
    if outcome or not workspace then
      local result = graph.delta()
      if outcome and outcome.message then
        graph.add_note(result, outcome.message, {
          summary = "Go module analysis unavailable",
          severity = outcome.state == "unavailable" and "info" or "warn",
        })
      end
      callback(result, outcome)
      return
    end
    if context.boundary_level == "workspace" then
      callback(workspace_relationships(context, workspace))
      return
    end
    local focus_key = module_key(context)
    if
      not vim.iter(workspace.modules or {}):any(function(module)
        return module.Path == focus_key
      end)
    then
      local result = graph.delta()
      local omitted = {
        state = "failed",
        message = "Focused module was omitted by the Go workspace module limit.",
      }
      graph.add_note(result, omitted.message, {
        summary = "Go module analysis unavailable",
        severity = "warn",
      })
      callback(result, omitted)
      return
    end
    callback(module_relationships(context, workspace, options))
  end)
end

function M.clear_cache(_)
  scans = {}
  go_workspace.clear_cache()
end

M._decode_json_stream = decode_json_stream
M._package_index = package_index
M._select_modules = select_modules

return M

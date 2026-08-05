local graph = require("archlens.graph")

local M = {}
local scans = {}

local defaults = {
  command = "cargo",
  timeout_ms = 8000,
  max_packages = 1000,
  max_output_bytes = 2 * 1024 * 1024,
  features = {},
  all_features = false,
  no_default_features = false,
  offline = true,
}

local function normalized(path)
  return path and vim.fs.normalize(path) or nil
end

local function nonempty_string(value)
  return type(value) == "string" and value:match("%S") ~= nil
end

local function diagnostic_text(value)
  local line = vim.trim(value or ""):match("[^\r\n]+") or ""
  if #line > 400 then
    return line:sub(1, 400) .. "..."
  end
  return line
end

local function normalized_options(options)
  local result = vim.tbl_extend("force", vim.deepcopy(defaults), options or {})
  assert(nonempty_string(result.command), "providers.rust.command must be a non-empty string")
  for _, field in ipairs({ "timeout_ms", "max_packages", "max_output_bytes" }) do
    local fallback = assert(tonumber(defaults[field]))
    result[field] = math.max(1, math.floor(tonumber(result[field]) or fallback))
  end
  for _, field in ipairs({ "all_features", "no_default_features", "offline" }) do
    assert(type(result[field]) == "boolean", "providers.rust." .. field .. " must be boolean")
  end
  assert(
    type(result.features) == "table" and vim.islist(result.features),
    "providers.rust.features must be a list"
  )
  local seen = {}
  local features = {}
  for index, feature in ipairs(result.features) do
    assert(
      nonempty_string(feature),
      string.format("providers.rust.features[%d] must be a non-empty string", index)
    )
    if not seen[feature] then
      seen[feature] = true
      features[#features + 1] = feature
    end
  end
  table.sort(features)
  result.features = features
  assert(
    result.filter_platform == nil or nonempty_string(result.filter_platform),
    "providers.rust.filter_platform must be a non-empty string"
  )
  return result
end

local function manifest_for(path)
  path = normalized(path)
  if not path then
    return nil
  end
  if vim.fs.basename(path) == "Cargo.toml" and vim.uv.fs_stat(path) then
    return path
  end
  local root = vim.fs.root(path, "Cargo.toml")
  return root and normalized(vim.fs.joinpath(root, "Cargo.toml")) or nil
end

local function locked_mode(manifest)
  local lock_root = vim.fs.root(vim.fs.dirname(manifest), "Cargo.lock")
  return lock_root ~= nil and "resolved" or "declared"
end

local function scan_key(manifest, options)
  return table.concat({
    manifest,
    tostring(options.command),
    tostring(options.timeout_ms),
    tostring(options.max_packages),
    tostring(options.max_output_bytes),
    table.concat(options.features, ","),
    tostring(options.all_features),
    tostring(options.no_default_features),
    tostring(options.offline),
    tostring(options.filter_platform or ""),
    locked_mode(manifest),
  }, "\0")
end

local function metadata_command(manifest, options, mode)
  local command = {
    options.command,
    "metadata",
    "--format-version",
    "1",
    "--manifest-path",
    manifest,
  }
  if mode == "resolved" then
    command[#command + 1] = "--locked"
    if options.filter_platform then
      command[#command + 1] = "--filter-platform"
      command[#command + 1] = options.filter_platform
    end
  else
    command[#command + 1] = "--no-deps"
  end
  if options.offline then
    command[#command + 1] = "--offline"
  end
  if options.all_features then
    command[#command + 1] = "--all-features"
  elseif #options.features > 0 then
    command[#command + 1] = "--features"
    command[#command + 1] = table.concat(options.features, ",")
  end
  if options.no_default_features then
    command[#command + 1] = "--no-default-features"
  end
  return command
end

local function run_metadata(manifest, options, mode, callback)
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

  local function finish(stdout, outcome)
    if completed then
      return
    end
    completed = true
    if timer and not timer:is_closing() then
      timer:stop()
      timer:close()
    end
    callback(stdout, outcome)
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

  local started, value = pcall(vim.system, metadata_command(manifest, options, mode), {
    cwd = vim.fs.dirname(manifest),
    text = true,
    stdout = function(err, data)
      stdout_bytes, stdout_limited = collect(
        stdout_chunks,
        stdout_bytes,
        stdout_limited,
        function(message)
          stdout_error = stdout_error or message
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
        function(message)
          stderr_error = stderr_error or message
        end,
        err,
        data
      )
    end,
  }, function(result)
    if completed then
      return
    end
    local stderr = diagnostic_text(table.concat(stderr_chunks))
    local failure = stdout_error
      or stderr_error
      or (stderr_limited and string.format(
        "error output reached %d bytes",
        options.max_output_bytes
      ))
      or (stdout_limited and string.format("output reached %d bytes", options.max_output_bytes))
      or (result.code ~= 0 and (stderr ~= "" and stderr or "exited with code " .. result.code))
    if failure then
      finish(nil, { state = "failed", message = "cargo metadata failed: " .. failure })
      return
    end
    finish(table.concat(stdout_chunks))
  end)
  if not started then
    finish(nil, { state = "failed", message = "cargo metadata failed: " .. tostring(value) })
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
      message = string.format("cargo metadata exceeded %d ms and was stopped.", options.timeout_ms),
    })
  end, options.timeout_ms)
  return function()
    if not completed then
      pcall(process.kill, process, 15)
      completed = true
      if timer and not timer:is_closing() then
        timer:stop()
        timer:close()
      end
    end
  end
end

local function is_json_null(value)
  return value == nil or value == vim.NIL
end

local function dependency_kind(value)
  if is_json_null(value) or value == "normal" then
    return "normal"
  elseif value == "build" or value == "dev" then
    return value
  end
  return nil
end

local function within(root, path)
  root = normalized(root)
  path = normalized(path)
  return root ~= nil and path ~= nil and (path == root or vim.startswith(path, root .. "/"))
end

local function add_connection(index, source_id, target_id, kind, alias)
  if
    source_id == target_id
    or not kind
    or not index.by_id[source_id]
    or not index.by_id[target_id]
  then
    return
  end
  index.connections[source_id] = index.connections[source_id] or {}
  index.connections[source_id][target_id] = index.connections[source_id][target_id] or {}
  local record = index.connections[source_id][target_id][kind]
  if not record then
    record = { aliases = {} }
    index.connections[source_id][target_id][kind] = record
  end
  if nonempty_string(alias) and not vim.list_contains(record.aliases, alias) then
    record.aliases[#record.aliases + 1] = alias
    table.sort(record.aliases)
  end
end

local function select_packages(packages, workspace_ids, focus_manifest, maximum)
  local valid = {}
  for _, package in ipairs(packages or {}) do
    if
      nonempty_string(package.id)
      and nonempty_string(package.name)
      and nonempty_string(package.manifest_path)
    then
      package = vim.deepcopy(package)
      package.manifest_path = normalized(package.manifest_path)
      package.directory = normalized(vim.fs.dirname(package.manifest_path))
      package.target_paths = {}
      local target_paths = {}
      for _, target in ipairs(type(package.targets) == "table" and package.targets or {}) do
        if type(target) == "table" and nonempty_string(target.src_path) then
          target.src_path = normalized(target.src_path)
          if not target_paths[target.src_path] then
            target_paths[target.src_path] = true
            package.target_paths[#package.target_paths + 1] = target.src_path
          end
        end
      end
      table.sort(package.target_paths)
      valid[#valid + 1] = package
    end
  end
  table.sort(valid, function(left, right)
    local left_rank = left.manifest_path == focus_manifest and 0
      or workspace_ids[left.id] and 1
      or 2
    local right_rank = right.manifest_path == focus_manifest and 0
      or workspace_ids[right.id] and 1
      or 2
    if left_rank ~= right_rank then
      return left_rank < right_rank
    elseif left.name ~= right.name then
      return left.name < right.name
    end
    return left.manifest_path < right.manifest_path
  end)
  local omitted = math.max(0, #valid - maximum)
  while #valid > maximum do
    table.remove(valid)
  end
  return valid, omitted
end

local function build_index(metadata, focus_manifest, maximum, mode, limitation)
  assert(type(metadata) == "table", "cargo metadata must return an object")
  assert(nonempty_string(metadata.workspace_root), "cargo metadata omitted workspace_root")
  assert(
    type(metadata.packages) == "table" and vim.islist(metadata.packages),
    "cargo metadata omitted packages"
  )
  assert(
    type(metadata.workspace_members) == "table" and vim.islist(metadata.workspace_members),
    "cargo metadata omitted workspace_members"
  )
  if mode == "resolved" then
    assert(
      type(metadata.resolve) == "table"
        and type(metadata.resolve.nodes) == "table"
        and vim.islist(metadata.resolve.nodes),
      "cargo metadata omitted the resolved dependency graph"
    )
  end
  local workspace_ids = {}
  for _, id in ipairs(metadata.workspace_members) do
    if nonempty_string(id) then
      workspace_ids[id] = true
    end
  end
  local packages, omitted =
    select_packages(metadata.packages, workspace_ids, focus_manifest, maximum)
  local index = {
    mode = mode,
    limitation = limitation,
    workspace_root = normalized(metadata.workspace_root),
    workspace_manifest = normalized(vim.fs.joinpath(metadata.workspace_root, "Cargo.toml")),
    packages = packages,
    by_id = {},
    by_manifest = {},
    by_directory = {},
    by_target_path = {},
    by_name = {},
    workspace_ids = workspace_ids,
    workspace_packages = {},
    connections = {},
    omitted_packages = omitted,
    unresolved_dependencies = 0,
    optional_dependencies = 0,
  }
  for _, package in ipairs(packages) do
    package.workspace_member = workspace_ids[package.id] == true
    index.by_id[package.id] = package
    index.by_manifest[package.manifest_path] = package
    index.by_directory[package.directory] = package
    for _, target_path in ipairs(package.target_paths) do
      local existing = index.by_target_path[target_path]
      if existing == nil then
        index.by_target_path[target_path] = package
      elseif existing ~= package then
        index.by_target_path[target_path] = false
      end
    end
    if index.by_name[package.name] then
      index.by_name[package.name] = false
    else
      index.by_name[package.name] = package
    end
    if package.workspace_member then
      index.workspace_packages[#index.workspace_packages + 1] = package
    end
  end
  table.sort(index.workspace_packages, function(left, right)
    if left.name ~= right.name then
      return left.name < right.name
    end
    return left.manifest_path < right.manifest_path
  end)

  if mode == "resolved" then
    local nodes = metadata.resolve and metadata.resolve.nodes or {}
    for _, node in ipairs(nodes or {}) do
      if index.by_id[node.id] then
        for _, dependency in ipairs(node.deps or {}) do
          if index.by_id[dependency.pkg] then
            for _, kind_spec in ipairs(dependency.dep_kinds or {}) do
              local kind = dependency_kind(kind_spec.kind)
              local package = index.by_id[dependency.pkg]
              local expected = package and package.name:gsub("-", "_") or nil
              local alias = dependency.name ~= expected and dependency.name or nil
              add_connection(index, node.id, dependency.pkg, kind, alias)
            end
          else
            index.unresolved_dependencies = index.unresolved_dependencies + 1
          end
        end
      end
    end
  else
    for _, package in ipairs(packages) do
      for _, dependency in ipairs(package.dependencies or {}) do
        if dependency.optional == true then
          index.optional_dependencies = index.optional_dependencies + 1
        else
          local target
          if nonempty_string(dependency.path) then
            target = index.by_directory[normalized(dependency.path)]
          elseif is_json_null(dependency.source) then
            target = index.by_name[dependency.name]
          end
          if target then
            add_connection(
              index,
              package.id,
              target.id,
              dependency_kind(dependency.kind),
              dependency.rename
            )
          else
            index.unresolved_dependencies = index.unresolved_dependencies + 1
          end
        end
      end
    end
  end
  return index
end

local function decode_index(stdout, manifest, options, mode, limitation)
  local ok, metadata = pcall(vim.json.decode, stdout or "")
  if not ok then
    return nil, "cargo metadata returned malformed JSON"
  end
  local indexed, value =
    pcall(build_index, metadata, manifest, options.max_packages, mode, limitation)
  if not indexed then
    return nil, tostring(value)
  end
  return value
end

local function notify(scan)
  local subscribers = scan.subscribers
  scan.subscribers = {}
  for _, subscriber in ipairs(subscribers) do
    if not subscriber.cancelled then
      subscriber.callback(scan.index, scan.outcome)
    end
  end
end

local function alias_workspace_scan(scan, options)
  if not scan.index then
    return
  end
  for _, package in ipairs(scan.index.workspace_packages) do
    local key = scan_key(package.manifest_path, options)
    if scans[key] == nil then
      scans[key] = scan
    end
  end
  local workspace_key = scan_key(scan.index.workspace_manifest, options)
  if scans[workspace_key] == nil then
    scans[workspace_key] = scan
  end
end

local function remove_scan(scan)
  for key, candidate in pairs(scans) do
    if candidate == scan then
      scans[key] = nil
    end
  end
end

local function cancel_scan(scan)
  if scan.ready or scan.cancelled then
    return
  end
  scan.cancelled = true
  scan.subscribers = {}
  remove_scan(scan)
  if scan.cancel_process then
    pcall(scan.cancel_process)
    scan.cancel_process = nil
  end
end

local function start_scan(cache_key, manifest, options)
  local scan = { ready = false, subscribers = {} }
  scans[cache_key] = scan

  local function finish(index, outcome)
    if scan.cancelled then
      return
    end
    scan.ready = true
    scan.cancel_process = nil
    scan.index = index
    scan.outcome = outcome
    if outcome and scans[cache_key] == scan then
      scans[cache_key] = nil
    elseif index then
      alias_workspace_scan(scan, options)
    end
    vim.schedule(function()
      notify(scan)
    end)
  end

  local function decode_or_finish(stdout, mode, limitation)
    local index, decode_error = decode_index(stdout, manifest, options, mode, limitation)
    if not index then
      finish(nil, { state = "failed", message = decode_error })
      return
    end
    finish(index)
  end

  local function begin_run(mode, callback)
    scan.run_generation = (scan.run_generation or 0) + 1
    local generation = scan.run_generation
    local cancel = run_metadata(manifest, options, mode, function(stdout, outcome)
      if scan.cancelled or scan.run_generation ~= generation then
        return
      end
      scan.cancel_process = nil
      callback(stdout, outcome)
    end)
    if not scan.ready and not scan.cancelled and scan.run_generation == generation then
      scan.cancel_process = cancel
    end
  end

  local mode = locked_mode(manifest)
  begin_run(mode, function(stdout, outcome)
    if not outcome then
      decode_or_finish(stdout, mode)
      return
    end
    if mode ~= "resolved" or outcome.state ~= "failed" then
      finish(nil, outcome)
      return
    end
    local limitation = outcome.message
      .. " ArchLens used dependency declarations without resolving features or target filters."
    begin_run("declared", function(fallback_stdout, fallback_outcome)
      if fallback_outcome then
        finish(nil, fallback_outcome)
        return
      end
      decode_or_finish(fallback_stdout, "declared", limitation)
    end)
  end)
  return scan
end

local function scan(manifest, options, callback)
  options = normalized_options(options)
  if options.enabled == false then
    callback(nil)
    return function() end
  end
  if not manifest or not vim.uv.fs_stat(manifest) then
    callback(nil, { state = "failed", message = "Cargo manifest could not be resolved." })
    return function() end
  end
  if vim.fn.executable(options.command) ~= 1 then
    callback(nil, {
      state = "unavailable",
      message = options.command .. " is unavailable; Cargo analysis was skipped.",
    })
    return function() end
  end

  local key = scan_key(manifest, options)
  local current = scans[key] or start_scan(key, manifest, options)
  if current.ready then
    callback(current.index, current.outcome)
    return function() end
  end
  local subscriber = { callback = callback, cancelled = false }
  current.subscribers[#current.subscribers + 1] = subscriber
  return function()
    subscriber.cancelled = true
    local active = vim.iter(current.subscribers):any(function(candidate)
      return not candidate.cancelled
    end)
    if not active then
      cancel_scan(current)
    end
  end
end

local function package_id(package)
  return "cargo-package:" .. package.manifest_path
end

local function workspace_id(index)
  return "cargo-workspace:" .. index.workspace_root
end

local function package_descriptor(package)
  return {
    id = package_id(package),
    class = "build",
    level = "package",
    kind_name = "Cargo package",
    name = package.name,
    path = package.directory,
    representative_path = package.manifest_path,
    import_keys = { package_id(package) },
    evidence = {
      provider = "Cargo",
      method = "cargo metadata/packages",
      class = "semantic",
    },
  }
end

local function workspace_descriptor(index)
  return {
    id = workspace_id(index),
    class = "build",
    level = "workspace",
    kind_name = "Cargo workspace",
    name = vim.fs.basename(index.workspace_root),
    path = index.workspace_root,
    representative_path = index.workspace_manifest,
    evidence = {
      provider = "Cargo",
      method = "cargo metadata/workspace_root",
      class = "semantic",
    },
  }
end

local function meaningful_workspace(index, package)
  return #index.workspace_packages > 1 or package.directory ~= index.workspace_root
end

local function focused_package(index, manifest, path)
  local package = index.by_manifest[manifest]
  if package then
    return package
  end
  package = index.by_target_path[normalized(path)]
  if package then
    return package
  end
  local best
  for _, candidate in ipairs(index.workspace_packages) do
    if
      within(candidate.directory, path) and (not best or #candidate.directory > #best.directory)
    then
      best = candidate
    end
  end
  return best
end

function M.discover(path, _, _, done, options)
  options = options or {}
  if options.enabled == false then
    done(nil)
    return function() end
  end
  local manifest = manifest_for(path)
  return scan(manifest, options, function(index, outcome)
    if outcome or not index then
      done(nil, outcome)
      return
    end
    local package = focused_package(index, manifest, path)
    if not package then
      done(nil, {
        state = "failed",
        message = "cargo metadata did not associate the source with a Cargo package.",
      })
      return
    end
    local descriptors = { package_descriptor(package) }
    if package.workspace_member and meaningful_workspace(index, package) then
      descriptors[#descriptors + 1] = workspace_descriptor(index)
    end
    done(descriptors)
  end)
end

local function context_source(focus, path)
  return {
    root_dir = focus.root_dir or vim.fs.dirname(path),
    path = path,
    language = "rust",
  }
end

local function package_context(index, package, focus)
  if focus.boundary_id == package_id(package) then
    return focus
  end
  local source = context_source(focus, package.manifest_path)
  local boundary_module = require("archlens.boundaries")
  local enclosing = {}
  if package.workspace_member and meaningful_workspace(index, package) then
    enclosing[1] = boundary_module.context(source, workspace_descriptor(index))
  end
  local context = boundary_module.context(source, package_descriptor(package), enclosing)
  context.detail = package.version
  return context
end

local function add_scan_notes(result, index)
  if index.limitation then
    graph.add_note(result, index.limitation, {
      summary = "Cargo dependency resolution limited",
      severity = "warn",
    })
  elseif index.mode == "declared" then
    graph.add_note(
      result,
      "No Cargo.lock was found. ArchLens used non-optional local dependency declarations without resolving features or target filters.",
      { summary = "Cargo dependencies not resolved", severity = "info" }
    )
  end
  if index.optional_dependencies > 0 and index.mode == "declared" then
    graph.add_note(
      result,
      string.format(
        "%d optional dependenc%s omitted because Cargo features were not resolved.",
        index.optional_dependencies,
        index.optional_dependencies == 1 and "y was" or "ies were"
      ),
      { summary = "optional Cargo dependencies omitted", severity = "info" }
    )
  end
  if index.omitted_packages > 0 then
    graph.add_note(
      result,
      string.format(
        "%d Cargo package%s omitted by the package limit.",
        index.omitted_packages,
        index.omitted_packages == 1 and " was" or "s were"
      ),
      { summary = "Cargo package scan limited", severity = "warn" }
    )
  end
  if index.unresolved_dependencies > 0 then
    graph.add_note(
      result,
      string.format(
        "%d Cargo dependency reference%s could not be mapped to the packages included in metadata.",
        index.unresolved_dependencies,
        index.unresolved_dependencies == 1 and "" or "s"
      ),
      { summary = "Cargo dependencies outside scan", severity = "info" }
    )
  end
end

local kind_rank = { normal = 1, build = 2, dev = 3 }

local function relation_kind(kind, incoming)
  if kind == "build" then
    return incoming and "build_dependents" or "build_dependencies"
  elseif kind == "dev" then
    return incoming and "test_dependents" or "test_dependencies"
  end
  return incoming and "module_importers" or "module_imports"
end

local function connection_entries(index, focus_id, incoming)
  local entries = {}
  if incoming then
    for source_id, targets in pairs(index.connections) do
      for kind, record in pairs(targets[focus_id] or {}) do
        entries[#entries + 1] = {
          source = index.by_id[source_id],
          target = index.by_id[focus_id],
          related = index.by_id[source_id],
          kind = kind,
          record = record,
        }
      end
    end
  else
    for target_id, kinds in pairs(index.connections[focus_id] or {}) do
      for kind, record in pairs(kinds) do
        entries[#entries + 1] = {
          source = index.by_id[focus_id],
          target = index.by_id[target_id],
          related = index.by_id[target_id],
          kind = kind,
          record = record,
        }
      end
    end
  end
  table.sort(entries, function(left, right)
    if kind_rank[left.kind] ~= kind_rank[right.kind] then
      return kind_rank[left.kind] < kind_rank[right.kind]
    elseif left.related.name ~= right.related.name then
      return left.related.name < right.related.name
    end
    return left.related.manifest_path < right.related.manifest_path
  end)
  return entries
end

local function add_package_edge(result, index, focus, entry, incoming)
  local source_context = package_context(index, entry.source, focus)
  local target_context = package_context(index, entry.target, focus)
  local source = graph.node_from_context(source_context)
  local target = graph.node_from_context(target_context)
  local related = incoming and source or target
  related.visibility_scope = entry.related.workspace_member and "project" or "external"
  local detail = entry.related.version
  if #entry.record.aliases > 0 and not incoming then
    detail = table
      .concat({ detail or "", "as " .. table.concat(entry.record.aliases, ", ") }, " · ")
      :gsub("^ · ", "")
  elseif #entry.record.aliases > 0 then
    detail = table
      .concat({ detail or "", "uses as " .. table.concat(entry.record.aliases, ", ") }, " · ")
      :gsub("^ · ", "")
  end
  related.detail = detail
  graph.add_edge(
    result,
    graph.edge(relation_kind(entry.kind, incoming), source, target, {
      provider = "Cargo",
      method = string.format("cargo metadata/%s/%s", index.mode, entry.kind),
      class = "semantic",
    })
  )
end

local function package_relationships(context, index, options)
  local result = graph.delta()
  local manifest = context.boundary_id and context.boundary_id:match("^cargo%-package:(.+)$")
  local package = manifest and index.by_manifest[normalized(manifest)] or nil
  if not package then
    return nil, "Focused Cargo package was not returned by cargo metadata."
  end
  local outgoing = connection_entries(index, package.id, false)
  local incoming = options.include_dependents == false and {}
    or connection_entries(index, package.id, true)
  local max_outgoing = math.max(1, math.floor(tonumber(options.max_imports) or 24))
  local max_incoming = math.max(1, math.floor(tonumber(options.max_importers) or 24))
  local omitted = math.max(0, #outgoing - max_outgoing) + math.max(0, #incoming - max_incoming)
  while #outgoing > max_outgoing do
    table.remove(outgoing)
  end
  while #incoming > max_incoming do
    table.remove(incoming)
  end
  for _, entry in ipairs(outgoing) do
    add_package_edge(result, index, context, entry, false)
  end
  for _, entry in ipairs(incoming) do
    add_package_edge(result, index, context, entry, true)
  end
  if omitted > 0 then
    graph.add_note(
      result,
      string.format(
        "%d Cargo relationship%s omitted by the relationship limits.",
        omitted,
        omitted == 1 and " was" or "s were"
      ),
      { summary = "Cargo relationship results limited", severity = "warn" }
    )
  end
  add_scan_notes(result, index)
  graph.add_contributor(result, "cargo", "Cargo")
  return result
end

local function workspace_relationships(context, index)
  local result = graph.delta()
  local source = graph.node_from_context(context)
  for _, package in ipairs(index.workspace_packages) do
    local target = graph.node_from_context(package_context(index, package, context))
    target.visibility_scope = "project"
    local relative = vim.fs.relpath(index.workspace_root, package.directory)
    if relative and relative ~= "." then
      target.detail = relative
    end
    graph.add_edge(
      result,
      graph.edge("workspace_members", source, target, {
        provider = "Cargo",
        method = "cargo metadata/workspace_members",
        class = "semantic",
      })
    )
  end
  add_scan_notes(result, index)
  graph.add_contributor(result, "cargo", "Cargo")
  return result
end

function M.supports(context)
  return context
    and context.is_boundary == true
    and context.language == "rust"
    and (context.boundary_level == "package" or context.boundary_level == "workspace")
end

function M.relationships(context, _, options, callback)
  options = options or {}
  local manifest = manifest_for(context.path or context.boundary_path)
  return scan(manifest, options.build, function(index, outcome)
    if outcome or not index then
      local result = graph.delta()
      if outcome and outcome.message then
        graph.add_note(result, outcome.message, {
          summary = "Cargo analysis unavailable",
          severity = outcome.state == "unavailable" and "info" or "warn",
        })
      end
      callback(result, outcome)
      return
    end
    if context.boundary_level == "workspace" then
      callback(workspace_relationships(context, index))
      return
    end
    local result, relationship_error = package_relationships(context, index, options)
    if not result then
      local failed = { state = "failed", message = relationship_error }
      local empty = graph.delta()
      graph.add_note(empty, failed.message, {
        summary = "Cargo analysis unavailable",
        severity = "warn",
      })
      callback(empty, failed)
      return
    end
    callback(result)
  end)
end

function M.clear_cache(_)
  local pending = {}
  for _, scan_state in pairs(scans) do
    pending[scan_state] = true
  end
  for scan_state in pairs(pending) do
    cancel_scan(scan_state)
  end
  scans = {}
end

M._build_index = build_index
M._manifest_for = manifest_for
M._package_descriptor = package_descriptor
M._workspace_descriptor = workspace_descriptor

return M

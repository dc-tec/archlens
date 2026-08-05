local adapters = require("archlens.adapters")
local boundaries = require("archlens.boundaries")
local graph = require("archlens.graph")
local import_index = require("archlens.import_index")
local test_paths = require("archlens.test_paths")

local M = {}
local scans = {}

local defaults = {
  command = "go",
  timeout_ms = 8000,
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

local function package_root(context)
  for _, boundary in ipairs(context.enclosing_boundaries or {}) do
    if boundary.boundary_level == "module" then
      return normalized(boundary.boundary_path)
    end
  end
  return context.path and vim.fs.root(context.path, "go.mod") or normalized(context.root_dir)
end

local function package_key(context)
  for _, key in ipairs(context.boundary_keys or {}) do
    local import_path = key:match("^go%-package:(.+)$")
    if import_path then
      return import_path
    end
  end
  return context.boundary_id and context.boundary_id:match("^go%-package:(.+)$") or nil
end

local function normalized_options(options)
  local result = vim.tbl_extend("force", vim.deepcopy(defaults), options or {})
  for _, field in ipairs({ "timeout_ms", "max_packages", "max_output_bytes" }) do
    local fallback = assert(tonumber(defaults[field]))
    result[field] = math.max(1, math.floor(tonumber(result[field]) or fallback))
  end
  return result
end

local function scan_key(root, options)
  return table.concat({
    root,
    tostring(options.command),
    tostring(options.timeout_ms),
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
          return values, "go list returned malformed JSON"
        end
        values[#values + 1] = value
        start = nil
      end
    end
  end
  if quoted or depth ~= 0 then
    return values, "go list returned incomplete JSON"
  end
  return values
end

local function package_files(package)
  local files = {}
  local seen = {}
  for _, field in ipairs({ "GoFiles", "CgoFiles" }) do
    for _, name in ipairs(package[field] or {}) do
      local path = vim.fs.normalize(vim.fs.joinpath(package.Dir, name))
      if not seen[path] then
        seen[path] = true
        files[#files + 1] = path
      end
    end
  end
  table.sort(files)
  local test_files = {}
  local test_seen = {}
  for _, field in ipairs({ "TestGoFiles", "XTestGoFiles" }) do
    for _, name in ipairs(package[field] or {}) do
      local path = vim.fs.normalize(vim.fs.joinpath(package.Dir, name))
      if not test_seen[path] then
        test_seen[path] = true
        test_files[#test_files + 1] = path
      end
    end
  end
  table.sort(test_files)
  return files, seen, test_files, test_seen
end

local function build_index(packages, maximum)
  local index = {
    packages = {},
    by_import = {},
    omitted = math.max(0, #packages - maximum),
    errors = 0,
  }
  for package_index = 1, math.min(#packages, maximum) do
    local package = packages[package_index]
    if
      type(package.ImportPath) == "string"
      and package.ImportPath ~= ""
      and type(package.Dir) == "string"
      and package.Dir ~= ""
    then
      package.Dir = normalized(package.Dir)
      package.files, package.active_files, package.test_files, package.active_test_files =
        package_files(package)
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
      subscriber.callback(scan.index, scan.outcome)
    end
  end
end

local function start_scan(cache_key, root, options)
  local scan = {
    root = root,
    ready = false,
    subscribers = {},
  }
  scans[cache_key] = scan

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

  local function finish(index, outcome)
    if completed then
      return
    end
    completed = true
    if timer and not timer:is_closing() then
      timer:stop()
      timer:close()
    end
    scan.ready = true
    scan.index = index
    scan.outcome = outcome
    if outcome and scans[cache_key] == scan then
      scans[cache_key] = nil
    end
    vim.schedule(function()
      notify(scan)
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

  local fields = table.concat({
    "Dir",
    "ImportPath",
    "Name",
    "GoFiles",
    "CgoFiles",
    "IgnoredGoFiles",
    "TestGoFiles",
    "XTestGoFiles",
    "Imports",
    "ImportMap",
    "TestImports",
    "XTestImports",
    "Module",
    "Error",
    "DepsErrors",
  }, ",")
  process = vim.system({ options.command, "list", "-e", "-json=" .. fields, "./..." }, {
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
  }, function(result)
    if completed then
      return
    end
    local stderr = diagnostic_text(table.concat(stderr_chunks))
    local packages, decode_error = decode_json_stream(table.concat(stdout_chunks))
    local index = build_index(packages, options.max_packages)
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
      finish(index, { state = "failed", message = "go list failed: " .. failure })
      return
    end
    finish(index)
  end)

  timer = vim.defer_fn(function()
    if completed then
      return
    end
    if process then
      pcall(process.kill, process, 15)
    end
    finish(nil, {
      state = "timed_out",
      message = string.format("go list exceeded %d ms and was stopped.", options.timeout_ms),
    })
  end, options.timeout_ms)
  return scan
end

local function scan(context, options, callback)
  options = normalized_options(options)
  local root = package_root(context)
  if not root or not vim.uv.fs_stat(root) then
    callback(nil, { state = "failed", message = "Go module root could not be resolved." })
    return function() end
  end
  if vim.fn.executable(options.command) ~= 1 then
    callback(nil, {
      state = "unavailable",
      message = options.command .. " is unavailable; Go build-aware package analysis was skipped.",
    })
    return function() end
  end

  local cache_key = scan_key(root, options)
  local current = scans[cache_key] or start_scan(cache_key, root, options)
  if current.ready then
    callback(current.index, current.outcome)
    return function() end
  end
  local subscriber = { callback = callback, cancelled = false }
  current.subscribers[#current.subscribers + 1] = subscriber
  return function()
    subscriber.cancelled = true
  end
end

local function package_context(package, focus)
  if package.context then
    return vim.deepcopy(package.context)
  end
  local path = package.files[1] or package.test_files[1]
  local module_root = package.Module and normalized(package.Module.Dir) or nil
  if not path or not module_root then
    return nil
  end
  local resolved = adapters.resolve_boundaries("go", path, module_root, focus)
  if not resolved then
    return nil
  end
  local contexts = boundaries.contexts({
    root_dir = focus.root_dir,
    path = path,
    language = "go",
  }, resolved)
  for _, context in ipairs(contexts) do
    if context.boundary_id == "go-package:" .. package.ImportPath then
      package.context = context
      return vim.deepcopy(context)
    end
  end
  return nil
end

local function mapped_import(package, import_path)
  return (package.ImportMap or {})[import_path] or import_path
end

local function add_build_edge(result, kind, source_context, target_context, methods)
  methods = type(methods) == "table" and methods or { methods or "go list/Imports" }
  local source = graph.node_from_context(source_context)
  local target = graph.node_from_context(target_context)
  local edge = graph.edge(kind, source, target, {
    provider = "Go tool",
    method = methods[1],
    class = "semantic",
  })
  for method_index = 2, #methods do
    edge.evidence_records[#edge.evidence_records + 1] = {
      provider = "Go tool",
      method = methods[method_index],
      class = "semantic",
    }
  end
  graph.add_edge(result, edge)
  return edge
end

local function occurrence_count(occurrences)
  local count = 0
  for _, occurrence in ipairs(occurrences or {}) do
    count = count + #(occurrence.ranges or {})
  end
  return count
end

local function matching_occurrences(edge, files)
  local occurrences = {}
  for _, occurrence in ipairs(edge.occurrences or {}) do
    local path = occurrence.uri
        and occurrence.uri:match("^file:")
        and normalized(vim.uri_to_fname(occurrence.uri))
      or nil
    if path and files[path] then
      occurrences[#occurrences + 1] = vim.deepcopy(occurrence)
    end
  end
  return occurrences
end

local function related_id(edge)
  local node = graph.related_node(edge)
  return node and node.id or nil
end

local function merge_syntax_evidence(edges, syntax_delta, build_kind, files_by_edge)
  local merged = false
  for _, syntax_edge in ipairs(syntax_delta.edges or {}) do
    local key = build_kind .. "\0" .. tostring(related_id(syntax_edge))
    local build_edge = edges[key]
    local files = files_by_edge[key]
    if build_edge and files then
      local occurrences = matching_occurrences(syntax_edge, files)
      if occurrence_count(occurrences) > 0 then
        build_edge.evidence_records = graph.merge_evidence(
          graph.evidence_records(build_edge),
          graph.evidence_records(syntax_edge)
        )
        build_edge.evidence = graph.evidence_summary(build_edge.evidence_records)
        build_edge.occurrences = occurrences
        merged = true
      end
    end
  end
  return merged
end

local function copy_scan_notes(result, delta)
  for note_index, note in ipairs(delta.notes or {}) do
    local record = delta.note_records and delta.note_records[note_index]
    local summary = record and record.summary or ""
    if not summary:match("external package") and summary ~= "package results limited" then
      graph.add_note(result, note, record)
    end
  end
  for _, message in ipairs(delta.errors or {}) do
    graph.add_error(result, message)
  end
end

local function build_relationships(context, index, dependencies, dependents, options)
  local result = graph.delta()
  local focus_key = package_key(context)
  local focus_package = focus_key and index.by_import[focus_key] or nil
  if not focus_package or focus_package.Error then
    return nil, "Focused package was not loaded by go list."
  end

  local dependency_paths = {}
  local production_dependencies = {}
  for _, import_path in ipairs(focus_package.Imports or {}) do
    import_path = mapped_import(focus_package, import_path)
    if index.by_import[import_path] and import_path ~= focus_key then
      if not production_dependencies[import_path] then
        production_dependencies[import_path] = true
        dependency_paths[#dependency_paths + 1] = import_path
      end
    end
  end
  table.sort(dependency_paths)

  local test_dependency_methods = {}
  for _, field in ipairs({ "TestImports", "XTestImports" }) do
    for _, import_path in ipairs(focus_package[field] or {}) do
      import_path = mapped_import(focus_package, import_path)
      if
        index.by_import[import_path]
        and import_path ~= focus_key
        and not production_dependencies[import_path]
      then
        test_dependency_methods[import_path] = test_dependency_methods[import_path] or {}
        local method = "go list/" .. field
        if not vim.tbl_contains(test_dependency_methods[import_path], method) then
          test_dependency_methods[import_path][#test_dependency_methods[import_path] + 1] = method
        end
      end
    end
  end
  local test_dependency_paths = vim.tbl_keys(test_dependency_methods)
  table.sort(test_dependency_paths)

  local dependent_packages = {}
  local test_dependent_methods = {}
  for _, candidate in ipairs(index.packages) do
    if candidate.ImportPath ~= focus_key then
      local production = false
      for _, import_path in ipairs(candidate.Imports or {}) do
        if mapped_import(candidate, import_path) == focus_key then
          dependent_packages[#dependent_packages + 1] = candidate
          production = true
          break
        end
      end
      if not production then
        for _, field in ipairs({ "TestImports", "XTestImports" }) do
          for _, import_path in ipairs(candidate[field] or {}) do
            if mapped_import(candidate, import_path) == focus_key then
              local methods = test_dependent_methods[candidate.ImportPath] or {}
              local method = "go list/" .. field
              if not vim.tbl_contains(methods, method) then
                methods[#methods + 1] = method
              end
              test_dependent_methods[candidate.ImportPath] = methods
              break
            end
          end
        end
      end
    end
  end
  table.sort(dependent_packages, function(left, right)
    return left.ImportPath < right.ImportPath
  end)
  local test_dependent_paths = vim.tbl_keys(test_dependent_methods)
  table.sort(test_dependent_paths)

  local max_imports = math.max(1, math.floor(tonumber(options.max_imports) or 24))
  local max_importers = math.max(1, math.floor(tonumber(options.max_importers) or 24))
  local dependency_omitted = math.max(0, #dependency_paths + #test_dependency_paths - max_imports)
  local dependent_omitted = math.max(0, #dependent_packages + #test_dependent_paths - max_importers)
  while #dependency_paths > max_imports do
    table.remove(dependency_paths)
  end
  while #test_dependency_paths > math.max(0, max_imports - #dependency_paths) do
    table.remove(test_dependency_paths)
  end
  while #dependent_packages > max_importers do
    table.remove(dependent_packages)
  end
  while #test_dependent_paths > math.max(0, max_importers - #dependent_packages) do
    table.remove(test_dependent_paths)
  end

  local edges = {}
  local files_by_edge = {}
  for _, import_path in ipairs(dependency_paths) do
    local package = index.by_import[import_path]
    local target = package_context(package, context)
    if target then
      local edge = add_build_edge(result, "module_imports", context, target)
      local key = edge.kind .. "\0" .. target.boundary_id
      edges[key] = edge
      files_by_edge[key] = focus_package.active_files
    end
  end
  for _, import_path in ipairs(test_dependency_paths) do
    local package = index.by_import[import_path]
    local target = package_context(package, context)
    if target then
      local edge = add_build_edge(
        result,
        "test_dependencies",
        context,
        target,
        test_dependency_methods[import_path]
      )
      local key = edge.kind .. "\0" .. target.boundary_id
      edges[key] = edge
      files_by_edge[key] = focus_package.active_test_files
    end
  end
  for _, package in ipairs(dependent_packages) do
    local source = package_context(package, context)
    if source then
      local edge = add_build_edge(result, "module_importers", source, context)
      local key = edge.kind .. "\0" .. source.boundary_id
      edges[key] = edge
      files_by_edge[key] = package.active_files
    end
  end
  for _, import_path in ipairs(test_dependent_paths) do
    local package = index.by_import[import_path]
    local source = package_context(package, context)
    if source then
      local edge = add_build_edge(
        result,
        "test_dependents",
        source,
        context,
        test_dependent_methods[import_path]
      )
      local key = edge.kind .. "\0" .. source.boundary_id
      edges[key] = edge
      files_by_edge[key] = package.active_test_files
    end
  end

  local dependency_syntax =
    merge_syntax_evidence(edges, dependencies, "module_imports", files_by_edge)
  local test_dependency_syntax =
    merge_syntax_evidence(edges, dependencies, "test_dependencies", files_by_edge)
  local dependent_syntax =
    merge_syntax_evidence(edges, dependents, "module_importers", files_by_edge)
  local test_dependent_syntax =
    merge_syntax_evidence(edges, dependents, "test_dependents", files_by_edge)
  copy_scan_notes(result, dependencies)
  copy_scan_notes(result, dependents)
  graph.add_contributor(result, "go_build", "Go tool")
  if dependency_syntax or test_dependency_syntax or dependent_syntax or test_dependent_syntax then
    graph.add_contributor(result, "syntax", "Tree-sitter")
  end
  if index.omitted > 0 then
    graph.add_note(
      result,
      string.format(
        "%d Go package%s omitted by the build package limit.",
        index.omitted,
        index.omitted == 1 and " was" or "s were"
      ),
      { summary = "Go build scan limited", severity = "warn" }
    )
  end
  if index.errors > 0 then
    graph.add_note(
      result,
      string.format(
        "%d Go package%s reported build-loading errors; relationships may be incomplete.",
        index.errors,
        index.errors == 1 and "" or "s"
      ),
      { summary = "Go build scan incomplete", severity = "warn" }
    )
  end
  if dependency_omitted > 0 then
    graph.add_note(
      result,
      string.format(
        "%d package dependenc%s omitted by the dependency limit.",
        dependency_omitted,
        dependency_omitted == 1 and "y was" or "ies were"
      ),
      { summary = "package results limited", severity = "warn" }
    )
  end
  if dependent_omitted > 0 then
    graph.add_note(
      result,
      string.format(
        "%d package dependent%s omitted by the dependent limit.",
        dependent_omitted,
        dependent_omitted == 1 and " was" or "s were"
      ),
      { summary = "package results limited", severity = "warn" }
    )
  end
  return result
end

local function reclassified_edge(edge, kind, occurrences)
  local copy = vim.deepcopy(edge)
  copy.kind = kind
  copy.id = table.concat({ kind, copy.source.id, copy.target.id }, ":")
  copy.occurrences = occurrences
  return copy
end

local function classified_fallback(delta, context)
  local result = graph.delta()
  for _, edge in ipairs(delta.edges or {}) do
    local test_kind = edge.kind == "module_imports" and "test_dependencies"
      or edge.kind == "module_importers" and "test_dependents"
      or nil
    if not test_kind then
      graph.add_edge(result, vim.deepcopy(edge))
    else
      local production_occurrences = {}
      local test_occurrences = {}
      for _, occurrence in ipairs(edge.occurrences or {}) do
        local path = occurrence.uri
            and occurrence.uri:match("^file:")
            and normalized(vim.uri_to_fname(occurrence.uri))
          or nil
        local first_range = occurrence.ranges and occurrence.ranges[1]
        local line = first_range and first_range.start and first_range.start.line or nil
        local target = path
            and test_paths.is_test("go", path, context.root_dir, line)
            and test_occurrences
          or production_occurrences
        target[#target + 1] = vim.deepcopy(occurrence)
      end
      if #production_occurrences > 0 or #(edge.occurrences or {}) == 0 then
        graph.add_edge(result, reclassified_edge(edge, edge.kind, production_occurrences))
      elseif #test_occurrences > 0 then
        graph.add_edge(result, reclassified_edge(edge, test_kind, test_occurrences))
      end
    end
  end
  for _, message in ipairs(delta.errors or {}) do
    graph.add_error(result, message)
  end
  for note_index, note in ipairs(delta.notes or {}) do
    local record = delta.note_records and delta.note_records[note_index]
    graph.add_note(result, note, record)
  end
  for kind, count in pairs(delta.omitted or {}) do
    graph.add_omitted(result, kind, count)
  end
  for _, contributor in ipairs(delta.contributors or {}) do
    graph.add_contributor(result, contributor.id, contributor.label)
  end
  return result
end

local function fallback_result(context, dependencies, dependents, outcome)
  local result = graph.delta()
  graph.merge(result, classified_fallback(dependencies, context))
  graph.merge(result, classified_fallback(dependents, context))
  if outcome and outcome.message then
    graph.add_note(result, outcome.message, {
      summary = "Go build analysis unavailable",
      severity = outcome.state == "unavailable" and "info" or "warn",
    })
  end
  return result
end

function M.supports(context)
  return context
    and context.is_boundary == true
    and context.boundary_level == "package"
    and context.language == "go"
end

function M.relationships(context, bufnr, options, callback)
  options = options or {}
  local pending = 3
  local cancelled = false
  local values = {}
  local cancellations = {}

  local function finish_one(key, value, outcome)
    if cancelled then
      return
    end
    values[key] = value
    values[key .. "_outcome"] = outcome
    pending = pending - 1
    if pending ~= 0 then
      return
    end
    local build_outcome = values.build_outcome
    if build_outcome or not values.build then
      callback(
        fallback_result(context, values.dependencies, values.dependents, build_outcome),
        build_outcome
      )
      return
    end
    local result, build_error =
      build_relationships(context, values.build, values.dependencies, values.dependents, options)
    if not result then
      local outcome = { state = "failed", message = build_error }
      callback(fallback_result(context, values.dependencies, values.dependents, outcome), outcome)
      return
    end
    callback(result)
  end

  cancellations[#cancellations + 1] = scan(context, options.build, function(value, outcome)
    finish_one("build", value, outcome)
  end)
  cancellations[#cancellations + 1] = import_index.dependencies(
    context,
    bufnr,
    options.imports,
    function(value, outcome)
      finish_one("dependencies", value, outcome)
    end
  )
  if options.include_dependents == false then
    finish_one("dependents", graph.delta())
  else
    cancellations[#cancellations + 1] = import_index.dependents(
      context,
      bufnr,
      options.imports,
      function(value, outcome)
        finish_one("dependents", value, outcome)
      end
    )
  end

  return function()
    cancelled = true
    for _, cancel in ipairs(cancellations) do
      pcall(cancel)
    end
  end
end

function M.clear_cache(root)
  root = normalized(root)
  for key, scan in pairs(scans) do
    if not root or scan.root == root then
      scans[key] = nil
    end
  end
end

M._decode_json_stream = decode_json_stream
M._build_index = build_index

return M

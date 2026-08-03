local adapters = require("archlens.adapters")
local graph = require("archlens.graph")
local model = require("archlens.model")
local scope = require("archlens.scope")
local treesitter = require("archlens.treesitter")

local M = {}
local indexes = {}
local file_cache = {}

local function normalized(path)
  return path and vim.fs.normalize(path) or nil
end

local function file_key(path)
  return "file:" .. normalized(path)
end

local function zero_range()
  return {
    start = { line = 0, character = 0 },
    ["end"] = { line = 0, character = 0 },
  }
end

local function extension(path)
  return vim.fs.basename(path):match("(%.[^%.]+)$")
end

local function scan_specs(filetype, path)
  local specs = adapters.import_scan_specs(filetype, path)
  local by_extension = {}
  for _, spec in ipairs(specs) do
    for _, suffix in ipairs(spec.extensions or {}) do
      by_extension[suffix] = spec
    end
  end
  return specs, by_extension
end

local function key_for(root, specs, filters, options)
  local languages = {}
  for _, spec in ipairs(specs) do
    languages[#languages + 1] = spec.language
  end
  table.sort(languages)
  local excluded = vim.deepcopy(filters.exclude or {})
  table.sort(excluded)
  return table.concat({
    normalized(root),
    table.concat(languages, ","),
    filters.include_generated == true and "generated" or "",
    filters.include_vendored == true and "vendored" or "",
    table.concat(excluded, ","),
    tostring(options.command),
    tostring(options.timeout_ms),
    tostring(options.max_index_files),
    tostring(options.max_candidate_files),
    tostring(options.max_file_bytes),
    tostring(options.batch_size),
  }, "|")
end

local function target_keys(imports, path, root)
  if imports.target_keys then
    local ok, keys, err = pcall(imports.target_keys, path, root)
    if not ok then
      return {}, tostring(keys)
    end
    return keys or {}, err
  end
  return { file_key(path) }
end

local function target_label(imports, context, path, root)
  if imports.target_label then
    local ok, label = pcall(imports.target_label, path, root, context)
    if ok and type(label) == "string" and label ~= "" then
      return label
    end
  end
  if context.module_context and type(context.name) == "string" and context.name ~= "" then
    return context.name
  end
  return (root and vim.fs.relpath(root, path)) or vim.fs.basename(path)
end

local function site_keys(imports, site, path, root)
  if imports.site_keys then
    local ok, keys = pcall(imports.site_keys, site, path, root)
    return ok and keys or {}
  end
  local keys = {}
  for _, location in ipairs(site.target_locations or {}) do
    if location.uri and location.uri:match("^file:") then
      keys[#keys + 1] = file_key(vim.uri_to_fname(location.uri))
    end
  end
  return keys
end

local function file_stamp(path)
  local stat = vim.uv.fs_stat(path)
  if not stat or stat.type ~= "file" then
    return nil, stat
  end
  return table.concat({ stat.size or 0, stat.mtime.sec or 0, stat.mtime.nsec or 0 }, ":"), stat
end

local function import_sites(path, spec)
  local stamp = file_stamp(path)
  local cached = stamp and file_cache[path]
  if cached and cached.stamp == stamp and cached.language == spec.language then
    return vim.deepcopy(cached.sites), cached.error
  end
  local sites, err = treesitter.import_sites_from_path(path, spec.language)
  if stamp then
    file_cache[path] = {
      stamp = stamp,
      language = spec.language,
      sites = vim.deepcopy(sites or {}),
      error = err,
    }
  end
  return sites or {}, err
end

local function add_site(index, key, path, site, language)
  index.reverse[key] = index.reverse[key] or {}
  local importer = index.reverse[key][path]
  if not importer then
    importer = {
      path = path,
      language = language,
      sites = {},
      provider = site.resolution_provider or "Tree-sitter",
      method = site.resolution_method or "adapter/moduleTarget",
    }
    index.reverse[key][path] = importer
  end
  importer.sites[#importer.sites + 1] = vim.deepcopy(site)
end

local function visible_files(root, paths, by_extension, filters, options)
  local files = {}
  local oversized = 0
  local scope_cache = {}
  local candidate_limit = math.min(#paths, options.max_candidate_files)
  for candidate_index = 1, candidate_limit do
    local candidate = paths[candidate_index]
    local path = candidate
    if not vim.startswith(path, "/") then
      path = vim.fs.joinpath(root, path)
    end
    path = normalized(path)
    local spec = by_extension[extension(path)]
    if spec and scope.visible(scope.classify(root, path, filters, scope_cache), filters) then
      local stat = vim.uv.fs_stat(path)
      if stat and stat.type == "file" then
        if (stat.size or 0) <= options.max_file_bytes then
          files[#files + 1] = { path = path, spec = spec }
        else
          oversized = oversized + 1
        end
      end
    end
  end
  table.sort(files, function(left, right)
    return left.path < right.path
  end)
  local omitted = math.max(0, #files - options.max_index_files)
  while #files > options.max_index_files do
    table.remove(files)
  end
  return files, omitted, oversized, math.max(0, #paths - candidate_limit)
end

local function language_globs(specs)
  local globs = {}
  local seen = {}
  for _, spec in ipairs(specs) do
    for _, suffix in ipairs(spec.extensions or {}) do
      if not seen[suffix] then
        seen[suffix] = true
        globs[#globs + 1] = "*" .. suffix
      end
    end
  end
  return globs
end

local function run_rg(root, args, limit, callback)
  if limit <= 0 then
    vim.schedule(function()
      callback({}, nil, true)
    end)
    return function() end
  end
  local paths = {}
  local pending = ""
  local truncated = false
  local stream_error
  local process

  local function stop()
    if process then
      pcall(process.kill, process, 15)
    end
  end

  local function admit(line)
    if line == "" or truncated then
      return
    end
    if #paths >= limit then
      truncated = true
      stop()
      return
    end
    paths[#paths + 1] = line
  end

  local function consume(data)
    if data then
      pending = pending .. data
      while true do
        local newline = pending:find("\n", 1, true)
        if not newline then
          break
        end
        admit(pending:sub(1, newline - 1))
        pending = pending:sub(newline + 1)
      end
    elseif pending ~= "" then
      admit(pending)
      pending = ""
    end
  end

  local started, start_error = pcall(function()
    process = vim.system(args, {
      cwd = root,
      text = true,
      stdout = function(err, data)
        stream_error = stream_error or err
        consume(data)
      end,
    }, function(result)
      consume(nil)
      vim.schedule(function()
        local stderr = vim.trim(result.stderr or "")
        if
          not truncated
          and (stream_error or (result.code ~= 0 and not (result.code == 1 and stderr == "")))
        then
          callback(
            {},
            stream_error and tostring(stream_error)
              or (
                stderr ~= "" and stderr
                or string.format("%s exited with code %d", args[1], result.code)
              ),
            false
          )
          return
        end
        callback(paths, nil, truncated)
      end)
    end)
  end)
  if not started then
    vim.schedule(function()
      callback({}, tostring(start_error), false)
    end)
  end
  return stop
end

local function enumerate(root, specs, _, filters, options, callback)
  local command = options.command or "rg"
  if vim.fn.executable(command) ~= 1 then
    vim.schedule(function()
      callback({}, command .. " is unavailable; install ripgrep or disable reverse module analysis")
    end)
    return function() end
  end
  local globs = language_globs(specs)
  local base = { command, "--files", "--hidden", "--glob", "!.git/**" }
  for _, glob in ipairs(globs) do
    vim.list_extend(base, { "--glob", glob })
  end
  local cancelled = false
  local cancel_current = function() end
  cancel_current = run_rg(
    root,
    base,
    options.max_candidate_files,
    function(base_paths, err, truncated)
      if cancelled or err or truncated then
        if not cancelled then
          callback(base_paths, err, truncated)
        end
        return
      end
      if filters.include_vendored ~= true and filters.include_generated ~= true then
        callback(base_paths, nil, false)
        return
      end

      local extra = { command, "--files", "--hidden", "--no-ignore", "--glob", "!.git/**" }
      local category_globs = {}
      if filters.include_vendored == true then
        vim.list_extend(category_globs, {
          "**/.venv/**",
          "**/_opam/**",
          "**/node_modules/**",
          "**/vendor/**",
          "**/venv/**",
        })
      end
      if filters.include_generated == true then
        vim.list_extend(category_globs, {
          "**/.direnv/**",
          "**/_build/**",
          "**/generated/**",
          "**/target/**",
          "**/zz_generated*",
          "**/*_generated_*",
          "**/*.generated_*",
          "**/*.gen.*",
          "**/*.pb.go",
        })
      end
      for _, glob in ipairs(category_globs) do
        vim.list_extend(extra, { "--glob", glob })
      end
      cancel_current = run_rg(
        root,
        extra,
        options.max_candidate_files - #base_paths,
        function(extra_paths, extra_error, extra_truncated)
          if cancelled then
            return
          end
          local seen = {}
          local paths = {}
          for _, path in ipairs(base_paths) do
            if not seen[path] then
              seen[path] = true
              paths[#paths + 1] = path
            end
          end
          for _, path in ipairs(extra_paths) do
            if not seen[path] then
              seen[path] = true
              paths[#paths + 1] = path
            end
          end
          callback(paths, extra_error, extra_truncated)
        end
      )
    end
  )
  return function()
    cancelled = true
    cancel_current()
  end
end

local function notify(index)
  local subscribers = index.subscribers
  index.subscribers = {}
  for _, subscriber in ipairs(subscribers) do
    if not subscriber.cancelled then
      subscriber.callback(index)
    end
  end
end

local function build_index(cache_key, root, specs, by_extension, filters, options)
  local index = {
    root = root,
    ready = false,
    reverse = {},
    notes = {},
    subscribers = {},
  }
  indexes[cache_key] = index
  local finished = false
  local cancel_enumeration = function() end
  local timer

  local function finish()
    if finished then
      return
    end
    finished = true
    index.ready = true
    if timer and not timer:is_closing() then
      timer:stop()
      timer:close()
    end
    notify(index)
  end

  local function timed_out()
    if finished then
      return
    end
    cancel_enumeration()
    index.notes[#index.notes + 1] = string.format(
      "Project module scan stopped after %d ms; module-dependent results may be incomplete.",
      options.timeout_ms
    )
    finish()
  end

  timer = vim.defer_fn(timed_out, options.timeout_ms)
  cancel_enumeration = enumerate(
    root,
    specs,
    by_extension,
    filters,
    options,
    function(paths, err, enumeration_limited)
      if finished then
        return
      end
      if err then
        index.notes[#index.notes + 1] = "Project module scan failed: " .. err
        finish()
        return
      end
      local files, omitted, oversized, unexamined =
        visible_files(root, paths, by_extension, filters, options)
      if enumeration_limited then
        index.notes[#index.notes + 1] = string.format(
          "Project module discovery reached the %d-candidate limit; module-dependent results may be incomplete.",
          options.max_candidate_files
        )
      end
      if unexamined > 0 then
        index.notes[#index.notes + 1] = string.format(
          "%d module source candidate%s not examined by the discovery limit.",
          unexamined,
          unexamined == 1 and " was" or "s were"
        )
      end
      if omitted > 0 then
        index.notes[#index.notes + 1] = string.format(
          "%d module source file%s omitted by the project module scan limit.",
          omitted,
          omitted == 1 and "" or "s"
        )
      end
      if oversized > 0 then
        index.notes[#index.notes + 1] = string.format(
          "%d oversized module source file%s skipped.",
          oversized,
          oversized == 1 and "" or "s"
        )
      end

      local cursor = 1
      local parse_errors = 0
      local function parse_batch()
        if finished then
          return
        end
        local last = math.min(#files, cursor + options.batch_size - 1)
        for file_index = cursor, last do
          local file = files[file_index]
          local sites, parse_error = import_sites(file.path, file.spec)
          if parse_error then
            parse_errors = parse_errors + 1
          end
          for _, site in ipairs(sites) do
            for _, key in ipairs(site_keys(file.spec.imports, site, file.path, root)) do
              add_site(index, key, file.path, site, file.spec.language)
            end
          end
        end
        cursor = last + 1
        if cursor <= #files then
          vim.schedule(parse_batch)
        else
          if parse_errors > 0 then
            index.notes[#index.notes + 1] = string.format(
              "%d module source file%s could not be parsed.",
              parse_errors,
              parse_errors == 1 and "" or "s"
            )
          end
          finish()
        end
      end
      vim.schedule(parse_batch)
    end
  )
  return index
end

local function importer_edge(context, target_path, importer, anchor_label)
  table.sort(importer.sites, function(left, right)
    return graph.location_key(left.location) < graph.location_key(right.location)
  end)
  local first = importer.sites[1]
  local item = {
    name = vim.fs.basename(importer.path),
    kind = vim.lsp.protocol.SymbolKind.File,
    uri = first.location.uri,
    range = first.location.range,
    selectionRange = first.location.range,
  }
  local source_context = model.context_from_item(item, {
    name = "Tree-sitter",
    offset_encoding = "utf-8",
    root_dir = context.root_dir,
    supports_calls = false,
  })
  source_context.scope = "file"
  source_context.kind_name = "File"
  source_context.module_context = true
  source_context.preserve_file_identity = true
  source_context.language = importer.language
  source_context.import_filetype = importer.language
  local source = graph.node_from_context(source_context, { scope = "file" })
  local target_uri = vim.uri_from_fname(target_path)
  local target = graph.node({
    name = vim.fs.basename(target_path),
    kind = vim.lsp.protocol.SymbolKind.File,
    kind_name = "File",
    scope = "file",
    path = target_path,
    path_label = context.root_dir and vim.fs.relpath(context.root_dir, target_path) or target_path,
    location = { uri = target_uri, range = zero_range() },
  })
  local ranges = {}
  for _, site in ipairs(importer.sites) do
    ranges[#ranges + 1] = vim.deepcopy(site.location.range)
  end
  return graph.edge("module_importers", source, target, {
    provider = importer.provider,
    method = importer.method,
    class = "semantic",
  }, {
    occurrences = { { uri = first.location.uri, ranges = ranges } },
    presentation = {
      section_anchor = {
        prefix = "for",
        label = anchor_label,
      },
    },
  })
end

local function materialize(index, context, target_path, keys, anchor_label, options)
  local result = graph.delta()
  for _, note in ipairs(index.notes) do
    graph.add_note(result, note)
  end
  local importers = {}
  for _, key in ipairs(keys) do
    for path, importer in pairs(index.reverse[key] or {}) do
      if normalized(path) ~= target_path then
        local existing = importers[path]
        if existing then
          for _, site in ipairs(importer.sites) do
            existing.sites[#existing.sites + 1] = vim.deepcopy(site)
          end
        else
          importers[path] = vim.deepcopy(importer)
        end
      end
    end
  end
  local paths = vim.tbl_keys(importers)
  table.sort(paths)
  local omitted = math.max(0, #paths - options.max_importers)
  while #paths > options.max_importers do
    table.remove(paths)
  end
  for _, path in ipairs(paths) do
    graph.add_edge(result, importer_edge(context, target_path, importers[path], anchor_label))
  end
  if omitted > 0 then
    graph.add_note(
      result,
      string.format(
        "%d module dependent%s omitted by the dependent limit.",
        omitted,
        omitted == 1 and "" or "s"
      )
    )
  end
  return result
end

function M.relationships(context, bufnr, options, callback)
  options = options or {}
  local target_path = context.location
      and context.location.uri
      and context.location.uri:match("^file:")
      and normalized(vim.uri_to_fname(context.location.uri))
    or nil
  local root = normalized(context.root_dir)
  if not target_path or not root or not vim.uv.fs_stat(root) then
    callback(graph.delta())
    return function() end
  end

  local filetype = options.filetype or vim.bo[bufnr].filetype
  local specs, by_extension = scan_specs(filetype, target_path)
  local target_imports = adapters.imports_for_filetype(filetype, target_path)
  if #specs == 0 or not target_imports then
    callback(graph.delta())
    return function() end
  end

  options = vim.tbl_extend("force", {
    command = "rg",
    timeout_ms = 8000,
    max_index_files = 1000,
    max_candidate_files = 2000,
    max_file_bytes = 1024 * 1024,
    batch_size = 16,
    max_importers = 24,
  }, options)
  for _, field in ipairs({
    "timeout_ms",
    "max_index_files",
    "max_candidate_files",
    "max_file_bytes",
    "batch_size",
    "max_importers",
  }) do
    options[field] = math.max(1, math.floor(tonumber(options[field]) or 1))
  end
  local filters = options.filters or {}
  local keys, key_error = target_keys(target_imports, target_path, root)
  if #keys == 0 then
    local result = graph.delta()
    if key_error then
      graph.add_note(result, "Reverse module matching unavailable: " .. key_error .. ".")
    end
    callback(result)
    return function() end
  end
  local anchor_label = target_label(target_imports, context, target_path, root)

  local cache_key = key_for(root, specs, filters, options)
  local index = indexes[cache_key]
    or build_index(cache_key, root, specs, by_extension, filters, options)
  if index.ready then
    callback(materialize(index, context, target_path, keys, anchor_label, options))
    return function() end
  end

  local subscriber = {
    callback = function(value)
      callback(materialize(value, context, target_path, keys, anchor_label, options))
    end,
    cancelled = false,
  }
  index.subscribers[#index.subscribers + 1] = subscriber
  return function()
    subscriber.cancelled = true
  end
end

function M.clear_cache(root)
  root = normalized(root)
  for key, index in pairs(indexes) do
    if not root or index.root == root then
      indexes[key] = nil
    end
  end
  file_cache = {}
end

return M

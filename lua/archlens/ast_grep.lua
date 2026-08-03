local adapters = require("archlens.adapters")
local graph = require("archlens.graph")
local scope = require("archlens.scope")
local test_paths = require("archlens.test_paths")

local M = {}

M.default_globs = {}

local function empty(note, summary, severity)
  local result = graph.delta()
  graph.add_note(result, note, summary and { summary = summary, severity = severity } or nil)
  return result
end

local function executable(command)
  return command and command ~= "" and vim.fn.executable(command) == 1
end

local function usable_name(name, minimum)
  return type(name) == "string"
    and #name >= (minimum or 5)
    and #name <= 120
    and name:match("^[%a_][%w_%.']*$") ~= nil
end

local function absolute_path(root, path)
  if vim.startswith(path, "/") then
    return vim.fs.normalize(path)
  end
  return vim.fs.normalize(root .. "/" .. path)
end

local function decode_matches(stdout, root, maximum, filters)
  local matches = {}
  local seen = {}
  local total = 0
  for line in (stdout or ""):gmatch("[^\r\n]+") do
    local ok, decoded = pcall(vim.json.decode, line)
    if ok and type(decoded) == "table" and decoded.file and decoded.range then
      local path = absolute_path(root, decoded.file)
      local range = decoded.range
      local start = range.start or {}
      local key = table.concat({ path, start.line or 0, start.column or 0 }, ":")
      local kind = scope.classify(root, path, filters)
      if not seen[key] and scope.visible(kind, filters) then
        seen[key] = true
        total = total + 1
        if #matches < maximum then
          matches[#matches + 1] = {
            uri = vim.uri_from_fname(path),
            range = {
              start = { line = start.line or 0, character = start.column or 0 },
              ["end"] = {
                line = (range["end"] or {}).line or start.line or 0,
                character = (range["end"] or {}).column or start.column or 0,
              },
            },
            text = vim.trim((decoded.lines or decoded.text or ""):gsub("%s+", " ")),
            provider = "ast-grep",
          }
        end
      end
    end
  end
  return matches, math.max(0, total - #matches)
end

local function query_for(context, language)
  return adapters.ast_grep_query(context, context.language or language)
end

local function command_args(command, context, language, root, options)
  local pattern, selector = query_for(context, language)
  local args = {
    command,
    "run",
    "--pattern",
    pattern,
  }
  if selector then
    vim.list_extend(args, { "--selector", selector })
  end
  vim.list_extend(args, {
    "--lang",
    language,
    "--json=stream",
    "--color",
    "never",
    "--threads",
    tostring(options.threads or 1),
  })
  for _, glob in ipairs(options.globs or M.default_globs) do
    vim.list_extend(args, { "--globs", glob })
  end
  local filters = options.filters or {}
  local filter_globs = {}
  if not filters.include_vendored then
    vim.list_extend(filter_globs, {
      "!**/vendor/**",
      "!**/node_modules/**",
      "!**/.venv/**",
      "!**/venv/**",
      "!**/_opam/**",
    })
  end
  if not filters.include_generated then
    vim.list_extend(filter_globs, {
      "!**/.direnv/**",
      "!**/_build/**",
      "!**/generated/**",
      "!**/target/**",
      "!**/zz_generated.*",
      "!**/zz_generated_*",
      "!**/*_generated.*",
      "!**/*_generated_*",
      "!**/*.generated.*",
      "!**/*.generated_*",
      "!**/*.gen.*",
      "!**/*.pb.go",
    })
  end
  for _, prefix in ipairs(filters.exclude or {}) do
    if type(prefix) == "string" and prefix ~= "" then
      filter_globs[#filter_globs + 1] = "!" .. prefix:gsub("^%./", ""):gsub("/$", "") .. "/**"
    end
  end
  for _, glob in ipairs(filter_globs) do
    vim.list_extend(args, { "--globs", glob })
  end
  args[#args + 1] = root
  return args
end

function M.relationships(context, options, callback)
  options = options or {}
  local adapter = adapters.get(context.language)
  local provider = adapter and adapter.ast_grep
  local language = provider and provider.language
  if not language then
    callback(empty(provider and provider.unsupported_note, "structural search unavailable", "info"))
    return function() end
  end
  if not usable_name(context.name, options.min_name_length) then
    callback(empty())
    return function() end
  end

  local command = options.command or "ast-grep"
  if not executable(command) then
    callback(empty(), {
      state = "unavailable",
      message = "ast-grep is unavailable; structural project matches were skipped.",
    })
    return function() end
  end
  local root = context.root_dir or (context.path and vim.fs.dirname(context.path))
  if not root then
    callback(empty())
    return function() end
  end

  local cancelled = false
  local completed = false
  local timeout_ms = options.timeout_ms or 15000
  local maximum = options.max_results or 80
  local process
  local timer

  local function finish(result, outcome)
    if completed or cancelled then
      return
    end
    completed = true
    if timer and not timer:is_closing() then
      timer:stop()
      timer:close()
    end
    vim.schedule(function()
      if not cancelled then
        callback(result, outcome)
      end
    end)
  end

  local args = command_args(command, context, language, root, options)

  process = vim.system(args, { text = true, cwd = root }, function(result)
    if
      result.code ~= 0
      and (result.stdout or "") == ""
      and (result.code ~= 1 or vim.trim(result.stderr or "") ~= "")
    then
      finish(
        empty(
          string.format("ast-grep search failed: %s", vim.trim(result.stderr or "unknown error")),
          "structural search failed",
          "error"
        )
      )
      return
    end
    local matches, omitted = decode_matches(result.stdout, root, maximum, options.filters or {})
    local delta = graph.delta()
    local focus = graph.node_from_context(context)
    for _, match in ipairs(matches) do
      local path = vim.uri_to_fname(match.uri)
      local kind = test_paths.is_test(
        context.language,
        path,
        context.root_dir,
        match.range.start.line
      ) and "test_structural" or "structural"
      local related = graph.node_from_location({ uri = match.uri, range = match.range }, {
        name = match.text,
        kind_name = kind == "test_structural" and "Test match" or "Structural match",
        position_encoding = "utf-8",
      })
      graph.add_edge(
        delta,
        graph.edge(kind, related, focus, {
          provider = match.provider or "ast-grep",
          method = "structural",
          class = "structural",
        })
      )
    end
    graph.add_omitted(delta, "structural", omitted)
    graph.add_contributor(delta, "ast_grep", "ast-grep")
    finish(delta)
  end)

  timer = vim.defer_fn(function()
    if completed or cancelled then
      return
    end
    pcall(process.kill, process, 15)
    finish(empty(), {
      state = "timed_out",
      message = string.format("ast-grep search exceeded %d ms and was stopped.", timeout_ms),
    })
  end, timeout_ms)

  return function()
    cancelled = true
    if timer and not timer:is_closing() then
      timer:stop()
      timer:close()
    end
    if process and not completed then
      pcall(process.kill, process, 15)
    end
  end
end

M._decode_matches = decode_matches
M._query_for = query_for
M._command_args = command_args

return M

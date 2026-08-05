local M = {}
local member_cache = {}
local known_workspaces = {}

local function normalized(path)
  return path and vim.fs.normalize(path) or nil
end

local function file_exists(path)
  local stat = path and vim.uv.fs_stat(path) or nil
  return stat and stat.type == "file"
end

local function starting_directory(path)
  path = normalized(path)
  local stat = path and vim.uv.fs_stat(path) or nil
  if stat and stat.type == "directory" then
    return path
  end
  return path and vim.fs.dirname(path) or nil
end

local function path_token(value)
  value = vim.trim(value or "")
  local first = value:sub(1, 1)
  if first == '"' then
    local escaped = false
    for index = 2, #value do
      local character = value:sub(index, index)
      if escaped then
        escaped = false
      elseif character == "\\" then
        escaped = true
      elseif character == '"' then
        local ok, decoded = pcall(vim.json.decode, value:sub(1, index))
        return ok and decoded or nil
      end
    end
    return nil
  end
  if first == "`" then
    return value:match("^`([^`]*)`")
  end
  return value:match("^([^%s%)]+)")
end

local function add_member(members, seen, workspace_root, value)
  local path = path_token(value)
  if not path or path == "" then
    return
  end
  if not vim.startswith(path, "/") then
    path = vim.fs.joinpath(workspace_root, path)
  end
  path = assert(normalized(path))
  if not seen[path] then
    seen[path] = true
    members[#members + 1] = path
  end
end

local function parse_members(work_file)
  local stat = vim.uv.fs_stat(work_file)
  if not stat or stat.type ~= "file" then
    return nil, "go.work could not be read"
  end
  local fingerprint = table.concat({
    tostring(stat.size or 0),
    tostring(stat.mtime and stat.mtime.sec or 0),
    tostring(stat.mtime and stat.mtime.nsec or 0),
  }, ":")
  local cached = member_cache[work_file]
  if cached and cached.fingerprint == fingerprint then
    return vim.deepcopy(cached.members)
  end

  local ok, lines = pcall(vim.fn.readfile, work_file)
  if not ok then
    return nil, "go.work could not be read"
  end
  local workspace_root = vim.fs.dirname(work_file)
  local members = {}
  local seen = {}
  local in_block = false
  for _, raw_line in ipairs(lines) do
    local line = vim.trim(raw_line:gsub("//.*$", ""))
    if in_block then
      local before_close = line:match("^(.-)%)%s*$")
      if before_close then
        add_member(members, seen, workspace_root, before_close)
        in_block = false
      elseif line ~= "" then
        add_member(members, seen, workspace_root, line)
      end
    else
      local value = line:match("^use%s+(.+)$")
      if value then
        value = vim.trim(value)
        if value:sub(1, 1) == "(" then
          in_block = true
          value = vim.trim(value:sub(2))
          local before_close = value:match("^(.-)%)%s*$")
          if before_close then
            add_member(members, seen, workspace_root, before_close)
            in_block = false
          elseif value ~= "" then
            add_member(members, seen, workspace_root, value)
          end
        else
          add_member(members, seen, workspace_root, value)
        end
      end
    end
  end
  table.sort(members)
  member_cache[work_file] = { fingerprint = fingerprint, members = vim.deepcopy(members) }
  known_workspaces[work_file] = vim.deepcopy(members)
  return members
end

local function known_workspace(path)
  local module_root = normalized(vim.fs.root(path, "go.mod"))
  if not module_root then
    return nil
  end
  local match
  for work_file, members in pairs(known_workspaces) do
    if file_exists(work_file) and vim.list_contains(members, module_root) then
      if match and match ~= work_file then
        return nil
      end
      match = work_file
    end
  end
  return match
end

---@param path string
---@param configured? string
---@return string?
function M.find(path, configured)
  if vim.env.GOWORK == "off" then
    return nil
  end
  configured = normalized(configured)
  if file_exists(configured) then
    return configured
  end
  local environment = vim.env.GOWORK
  if environment and environment ~= "" and environment ~= "auto" then
    environment = normalized(environment)
    return file_exists(environment) and environment or nil
  end
  local start = starting_directory(path)
  local found = start
      and vim.fs.find("go.work", { path = start, upward = true, type = "file", limit = 1 })[1]
    or nil
  return normalized(found) or known_workspace(path)
end

---@param work_file string
---@return string[]?
---@return string? error
function M.members(work_file)
  local normalized_work_file = normalized(work_file)
  if not normalized_work_file then
    return nil, "go.work could not be resolved"
  end
  return parse_members(normalized_work_file)
end

---@param path string
---@param configured? string
---@return table?
function M.resolve(path, configured)
  local work_file = M.find(path, configured)
  if not work_file then
    return nil
  end
  local members = M.members(work_file)
  local module_root = vim.fs.root(path, "go.mod")
  module_root = normalized(module_root)
  if not members or not module_root or not vim.list_contains(members, module_root) then
    return nil
  end
  return {
    file = work_file,
    root = vim.fs.dirname(work_file),
    name = vim.fs.basename(vim.fs.dirname(work_file)),
    members = members,
  }
end

---@param work_file string
---@return table
function M.boundary(work_file)
  work_file = assert(normalized(work_file))
  local root = vim.fs.dirname(work_file)
  return {
    id = "go-workspace:" .. vim.uri_from_fname(work_file),
    class = "build",
    level = "workspace",
    kind_name = "Go workspace",
    name = vim.fs.basename(root),
    path = root,
    representative_path = work_file,
    evidence = {
      provider = "Go adapter",
      method = "go.work/use",
      class = "semantic",
    },
  }
end

function M.clear_cache()
  member_cache = {}
  known_workspaces = {}
end

return M

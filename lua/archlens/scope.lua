local M = {}
local header_cache = {}

local vendored_segments = {
  [".venv"] = true,
  ["_opam"] = true,
  node_modules = true,
  vendor = true,
  venv = true,
}

local generated_segments = {
  [".direnv"] = true,
  ["_build"] = true,
  generated = true,
  target = true,
}

local function normalized(path)
  return path and vim.fs.normalize(path) or nil
end

local function within(root, path)
  root = normalized(root)
  path = normalized(path)
  if not root or not path then
    return true
  end
  return path == root or path:sub(1, #root + 1) == root .. "/"
end

local function relative(root, path)
  root = normalized(root)
  path = normalized(path)
  if not root or not path then
    return path
  end
  return vim.fs.relpath(root, path) or path
end

local function segment_kinds(path)
  local kinds = {}
  for segment in path:gmatch("[^/]+") do
    if vendored_segments[segment] then
      kinds.vendored = true
    end
    if generated_segments[segment] then
      kinds.generated = true
    end
  end
  return kinds
end

local function generated_name(path)
  local name = vim.fs.basename(path):lower()
  return name:match("^zz_generated[%._]") ~= nil
    or name:match("[_%.]generated[%._]") ~= nil
    or name:match("%.gen%.[^%.]+$") ~= nil
    or name:match("%.pb%.go$") ~= nil
end

local function generated_header(path, cache)
  if cache.headers and cache.headers[path] ~= nil then
    return cache.headers[path]
  end
  local stat = vim.uv.fs_stat(path)
  local stamp = stat
      and table.concat({ stat.size or 0, stat.mtime.sec or 0, stat.mtime.nsec or 0 }, ":")
    or "missing"
  local cached = header_cache[path]
  if cached and cached.stamp == stamp then
    cache.headers = cache.headers or {}
    cache.headers[path] = cached.generated
    return cached.generated
  end
  local ok, lines = pcall(vim.fn.readfile, path, "", 5)
  local generated = false
  for _, line in ipairs(ok and lines or {}) do
    if
      line:match("^%s*[/#;*%-]*%s*[Cc]ode generated .- DO NOT EDIT%.?%s*$")
      or line:match("^%s*[/#;*%-]*%s*@generated[%s:]?.*$")
    then
      generated = true
      break
    end
  end
  header_cache[path] = { stamp = stamp, generated = generated }
  cache.headers = cache.headers or {}
  cache.headers[path] = generated
  return generated
end

function M.clear_cache()
  header_cache = {}
end

local function excluded(relative_path, prefixes)
  for _, prefix in ipairs(prefixes or {}) do
    if type(prefix) == "string" and prefix ~= "" then
      prefix = normalized(prefix):gsub("^%./", ""):gsub("/$", "")
      if relative_path == prefix or vim.startswith(relative_path, prefix .. "/") then
        return true
      end
    end
  end
  return false
end

function M.classify(root, path, filters, cache)
  filters = filters or {}
  cache = cache or {}
  root = normalized(root)
  path = normalized(path)
  if not path or not within(root, path) then
    return "external"
  end

  local relative_path = relative(root, path)
  if excluded(relative_path, filters.exclude) then
    return "excluded"
  end
  local kinds = segment_kinds(relative_path)
  if kinds.vendored and filters.include_vendored ~= true then
    return "vendored"
  end
  if
    not kinds.generated
    and (not kinds.vendored or filters.include_vendored == true)
    and (generated_name(relative_path) or generated_header(path, cache))
  then
    kinds.generated = true
  end
  if kinds.generated and filters.include_generated ~= true then
    return "generated"
  end
  if kinds.vendored then
    return "vendored"
  elseif kinds.generated then
    return "generated"
  end
  return "project"
end

function M.visible(kind, filters)
  filters = filters or {}
  if kind == "project" then
    return true
  elseif kind == "external" then
    return filters.include_external == true
  elseif kind == "vendored" then
    return filters.include_vendored == true
  elseif kind == "generated" then
    return filters.include_generated == true
  end
  return false
end

return M

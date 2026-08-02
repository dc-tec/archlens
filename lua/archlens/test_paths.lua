local M = {}
local rust_range_cache = {}
local rust_range_order = {}
local rust_range_cache_limit = 256

local function has_segment(path, expected)
  for segment in path:gmatch("[^/]+") do
    if segment == expected then
      return true
    end
  end
  return false
end

local function project_relative(root, path)
  if not root or root == "" then
    return nil
  end
  local relative = vim.fs.relpath(vim.fs.normalize(root), vim.fs.normalize(path))
  if not relative or relative == ".." or vim.startswith(relative, "../") then
    return nil
  end
  return relative:gsub("\\", "/")
end

local function rust_test_ranges(path)
  local stat = vim.uv.fs_stat(path)
  local stamp = stat
      and table.concat({ stat.size or 0, stat.mtime.sec or 0, stat.mtime.nsec or 0 }, ":")
    or "missing"
  local cached = rust_range_cache[path]
  if cached and cached.stamp == stamp then
    return cached.ranges
  end

  local read_ok, lines = pcall(vim.fn.readfile, path)
  local source = read_ok and table.concat(lines, "\n") or ""
  local ranges = {}
  if source ~= "" then
    local parser_ok, parser = pcall(vim.treesitter.get_string_parser, source, "rust")
    local trees
    if parser_ok then
      local tree_ok, parsed = pcall(parser.parse, parser)
      if tree_ok then
        trees = parsed
      end
    end
    local root = trees and trees[1] and trees[1]:root() or nil
    local function visit(node)
      if node:type() == "mod_item" then
        local previous = node:prev_named_sibling()
        while previous and previous:type() == "attribute_item" do
          local text_ok, text = pcall(vim.treesitter.get_node_text, previous, source)
          if text_ok and text:match("cfg%s*%(%s*test%s*%)") then
            local start_row, _, end_row = node:range()
            ranges[#ranges + 1] = { start_line = start_row, end_line = end_row }
            break
          end
          previous = previous:prev_named_sibling()
        end
      end
      for index = 0, node:named_child_count() - 1 do
        visit(node:named_child(index))
      end
    end
    if root then
      visit(root)
    end
  end

  if not rust_range_cache[path] then
    rust_range_order[#rust_range_order + 1] = path
  end
  rust_range_cache[path] = { stamp = stamp, ranges = ranges }
  while #rust_range_order > rust_range_cache_limit do
    rust_range_cache[table.remove(rust_range_order, 1)] = nil
  end
  return ranges
end

local function rust_inline_test(path, line)
  if type(line) ~= "number" then
    return false
  end
  for _, range in ipairs(rust_test_ranges(path)) do
    if line >= range.start_line and line <= range.end_line then
      return true
    end
  end
  return false
end

function M.clear_cache()
  rust_range_cache = {}
  rust_range_order = {}
end

function M.is_test(language, path, root, line)
  path = path and vim.fs.normalize(path):gsub("\\", "/") or ""
  local name = vim.fs.basename(path)
  if language == "go" then
    return name:match("_test%.go$") ~= nil
  elseif language == "rust" then
    local relative = project_relative(root, path)
    return (relative and has_segment(relative, "tests")) == true
      or name == "tests.rs"
      or name:match("_test%.rs$") ~= nil
      or rust_inline_test(path, line)
  end
  return false
end

return M

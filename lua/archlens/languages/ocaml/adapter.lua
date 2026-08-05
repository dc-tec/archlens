local common = require("archlens.adapter_support")

local M = {}

local dune_library_cache = {}
local dune_skip_directories = {
  [".git"] = true,
  [".opam"] = true,
  ["_build"] = true,
  ["_opam"] = true,
  ["node_modules"] = true,
  ["target"] = true,
  ["vendor"] = true,
  ["venv"] = true,
}

local function library_names(contents)
  local names = {}
  local cursor = 1
  while true do
    local start = contents:find("%(%s*library[%s%(]", cursor)
    if not start then
      break
    end
    local depth = 0
    local in_string = false
    local escaped = false
    local comment = false
    local finish
    for index = start, #contents do
      local character = contents:sub(index, index)
      if comment then
        comment = character ~= "\n"
      elseif in_string then
        if escaped then
          escaped = false
        elseif character == "\\" then
          escaped = true
        elseif character == '"' then
          in_string = false
        end
      elseif character == ";" then
        comment = true
      elseif character == '"' then
        in_string = true
      elseif character == "(" then
        depth = depth + 1
      elseif character == ")" then
        depth = depth - 1
        if depth == 0 then
          finish = index
          break
        end
      end
    end
    if not finish then
      break
    end
    local stanza = contents:sub(start, finish)
    local name = stanza:match("%(%s*name%s+([%w_%-%.]+)")
    if name then
      names[#names + 1] = name
    end
    cursor = finish + 1
  end
  return names
end

local function read_dune_library(path, libraries)
  local read_ok, lines = pcall(vim.fn.readfile, path)
  local contents = read_ok and table.concat(lines, "\n") or ""
  for _, name in ipairs(library_names(contents)) do
    libraries[name] = libraries[name] or path
  end
end

local function dune_libraries(root, requested_name)
  local cached = dune_library_cache[root] or { libraries = {}, complete = false }
  dune_library_cache[root] = cached
  if cached.libraries[requested_name] then
    return cached.libraries
  end

  local suffix = requested_name:match("^[^_]+_(.+)$")
  for _, path in ipairs({
    vim.fs.joinpath(root, "lib", requested_name, "dune"),
    vim.fs.joinpath(root, "src", requested_name, "dune"),
    suffix and vim.fs.joinpath(root, "lib", suffix, "dune") or "",
    suffix and vim.fs.joinpath(root, "src", suffix, "dune") or "",
  }) do
    if path ~= "" and vim.uv.fs_stat(path) then
      read_dune_library(path, cached.libraries)
      if cached.libraries[requested_name] then
        return cached.libraries
      end
    end
  end
  if cached.complete then
    return cached.libraries
  end

  local visited = 0
  local function walk(directory)
    if visited >= 1000 then
      return
    end
    local ok, entries = pcall(function()
      local values = {}
      for name, kind in vim.fs.dir(directory) do
        values[#values + 1] = { name = name, kind = kind }
        if visited + #values >= 1000 then
          break
        end
      end
      return values
    end)
    if not ok then
      return
    end
    for _, entry in ipairs(entries) do
      visited = visited + 1
      if visited >= 1000 then
        break
      end
      local path = vim.fs.joinpath(directory, entry.name)
      if entry.kind == "directory" and not dune_skip_directories[entry.name] then
        walk(path)
      elseif entry.kind == "file" and entry.name == "dune" then
        read_dune_library(path, cached.libraries)
      end
    end
  end
  walk(root)
  cached.complete = visited < 1000
  return cached.libraries
end

function M.clear_cache()
  dune_library_cache = {}
end

function M.section_presentation(context, relation)
  return common.member_section(context, relation)
end

function M.normalize_import(_, text, source, metadata)
  local name = vim.trim(text:gsub("%s+", " "))
  name = name:match("^module%s+type%s+of%s+(.+)$") or name
  local source_file = common.source_path(source, metadata)
  if not source_file or source_file == "" then
    return { name = name }
  end
  local module_name = name:match("^([%w_']+)")
  if not module_name then
    return { name = name }
  end
  local basename = module_name:sub(1, 1):lower() .. module_name:sub(2)
  local directory = vim.fs.dirname(source_file)
  local targets = common.existing_paths({
    vim.fs.joinpath(directory, basename .. ".ml"),
    vim.fs.joinpath(directory, basename .. ".mli"),
  })
  if #targets == 0 then
    local root = vim.fs.root(source_file, { "dune-project", ".git" })
    local dune = root and dune_libraries(root, basename)[basename]
    if dune then
      targets[1] = dune
      return {
        name = name,
        target_paths = targets,
        resolution_provider = "Tree-sitter+Dune",
        resolution_method = "dune/library",
      }
    end
  end
  return { name = name, target_paths = targets }
end

M.name_node_types = common.name_node_types({
  constructor_name = true,
  field_name = true,
  tag = true,
})

M.unsupported_note =
  "ast-grep has no OCaml parser; semantic references and Tree-sitter context remain available."

M.spec = {
  presentation = { section = M.section_presentation },
  treesitter = {
    focus_wrappers = { type_definition = true },
    name_node_types = M.name_node_types,
    symbol_types = {
      class_definition = "Class",
      constructor_declaration = "EnumMember",
      field_declaration = "Field",
      let_binding = "Value",
      method_definition = "Method",
      module_definition = "Module",
      module_type_definition = "Module",
      tag_specification = "EnumMember",
      type_binding = "Type",
    },
    imports = {
      extensions = { ".ml" },
      scan_languages = { "ocaml", "ocaml_interface" },
      query = [[
        [
          (open_module module: (_) @import)
          (include_module module: (_) @import)
        ]
      ]],
      normalize = M.normalize_import,
    },
  },
  ast_grep = { unsupported_note = M.unsupported_note },
}

return M

local common = require("archlens.adapters.common")

local M = {}
---@type table<string, { name?: string, root?: string }>
local module_cache = {}

local function section_presentation(context, relation, row)
  local member = common.member_section(context, relation)
  if member then
    return member
  end
  if context.kind ~= vim.lsp.protocol.SymbolKind.Interface then
    return nil
  end
  if relation.id == "supertypes" then
    return { key = "satisfies", label = "Satisfies", order = 10 }
  end
  if relation.id == "subtypes" then
    if row.kind == vim.lsp.protocol.SymbolKind.Interface then
      return { key = "extended", label = "Extended by", order = 10, show_kind = true }
    end
    if
      row.kind == vim.lsp.protocol.SymbolKind.Class
      or row.kind == vim.lsp.protocol.SymbolKind.Enum
      or row.kind == vim.lsp.protocol.SymbolKind.Object
      or row.kind == vim.lsp.protocol.SymbolKind.Struct
    then
      return { key = "implemented", label = "Implemented by", order = 20, show_kind = true }
    end
    return {
      key = "related",
      label = "Implemented or extended by",
      order = 30,
      show_kind = true,
    }
  end
end

local function row_presentation(_, relation, row)
  if relation.id == "subtypes" and row.kind == vim.lsp.protocol.SymbolKind.Class then
    return { kind_name = "Type" }
  end
  if relation.id ~= "implementations" then
    return nil
  end
  local name = row.name:match("^type%s+([%w_]+)")
  if not name then
    return nil
  end
  local declaration = row.name:match("%s(struct)%s*[{%[]")
    or row.name:match("%s(interface)%s*[{%[]")
  return {
    name = name,
    kind_name = declaration == "struct" and "Struct"
      or declaration == "interface" and "Interface"
      or "Type",
  }
end

local function query(context)
  if context.syntax_node_type == "method_declaration" then
    return "var _ = $RECEIVER." .. context.name, "selector_expression"
  end
  return "func _() { " .. context.name .. "($$$ARGS) }", "call_expression"
end

local function unquote(text)
  if not text or #text < 2 then
    return text
  end
  local first = text:sub(1, 1)
  local last = text:sub(-1)
  if (first == '"' and last == '"') or (first == "`" and last == "`") then
    return text:sub(2, -2)
  end
  return text
end

local function normalize_import(_, text)
  return { name = unquote(text), position_offset = 1 }
end

local function module(path, root)
  local directory = vim.fs.normalize(vim.fs.dirname(path))
  local cached = module_cache[directory]
  if cached == nil then
    local module_root = vim.fs.root(path, "go.mod")
    if module_root then
      module_root = vim.fs.normalize(module_root)
      local module_file = vim.fs.joinpath(module_root, "go.mod")
      local ok, lines = pcall(vim.fn.readfile, module_file, "", 32)
      if ok then
        for _, line in ipairs(lines) do
          local name = line:match("^%s*module%s+([^%s]+)")
          if name then
            cached = { name = name, root = module_root }
            break
          end
        end
      end
    end
    cached = cached or {}
    module_cache[directory] = cached
  end
  if not cached.name or not cached.root then
    return nil
  end
  root = root and vim.fs.normalize(root) or nil
  if root and cached.root ~= root and not vim.startswith(cached.root, root .. "/") then
    return nil
  end
  return cached.name, cached.root
end

local function target_keys(path, root)
  local module_name, module_root = module(path, root)
  if not module_name then
    return {}, "no go.mod module found"
  end
  local relative = vim.fs.relpath(module_root, vim.fs.dirname(path))
  if relative and relative ~= "." then
    module_name = module_name .. "/" .. relative:gsub("\\", "/")
  end
  return { "go-package:" .. module_name }
end

local function target_label(path, root)
  local directory = vim.fs.normalize(vim.fs.dirname(path))
  root = root and vim.fs.normalize(root) or nil
  local relative = root and vim.fs.relpath(root, directory) or nil
  if relative and relative ~= "." then
    return relative:gsub("\\", "/")
  end
  return vim.fs.basename(root or directory)
end

local function site_keys(site)
  return { "go-package:" .. site.name }
end

local function resolve_boundaries(path, root)
  local module_name, module_root = module(path, root)
  if not module_name then
    return nil
  end
  local directory = vim.fs.normalize(vim.fs.dirname(path))
  local relative = vim.fs.relpath(module_root, directory)
  local import_path = module_name
  if relative and relative ~= "." then
    import_path = import_path .. "/" .. relative:gsub("\\", "/")
  end
  local name = relative and relative ~= "." and relative:gsub("\\", "/")
    or vim.fs.basename(module_name)
  return {
    {
      id = "go-package:" .. import_path,
      class = "language",
      level = "package",
      kind_name = "Go package",
      name = name,
      path = directory,
      representative_path = path,
      import_keys = { "go-package:" .. import_path },
      evidence = {
        provider = "Go adapter",
        method = "go.mod/package",
        class = "semantic",
      },
    },
    {
      id = "go-module:" .. module_name,
      class = "build",
      level = "module",
      kind_name = "Go module",
      name = module_name,
      path = module_root,
      representative_path = vim.fs.joinpath(module_root, "go.mod"),
      evidence = {
        provider = "Go adapter",
        method = "go.mod/module",
        class = "semantic",
      },
    },
  }
end

local configuration_tags = {
  env = true,
  envconfig = true,
  json = true,
  mapstructure = true,
  toml = true,
  yaml = true,
}

local function configuration(bufnr, context, syntax_context)
  if context.kind ~= vim.lsp.protocol.SymbolKind.Field then
    return nil
  end
  local container = syntax_context and syntax_context.name or ""
  if
    not container:match("Config$")
    and not container:match("Options$")
    and not container:match("Settings$")
    and not container:match("Spec$")
  then
    return nil
  end
  local location = context.location
  local line = location
      and location.range
      and vim.api.nvim_buf_get_lines(
        bufnr,
        location.range.start.line,
        location.range.start.line + 1,
        false
      )[1]
    or ""
  local tag = line:match("`([^`]*)`") or ""
  local recognized = false
  for name in tag:gmatch("([%w_]+):") do
    recognized = recognized or configuration_tags[name] == true
  end
  if not recognized then
    return nil
  end
  return { key = context.name, container = container, source = "field" }
end

function M.clear_cache()
  module_cache = {}
end

M.spec = {
  boundaries = { resolve = resolve_boundaries },
  configuration = configuration,
  presentation = {
    row = row_presentation,
    section = section_presentation,
  },
  treesitter = {
    focus_wrappers = { type_declaration = true },
    name_fields = { "name", "pattern", "attrpath", "type" },
    symbol_types = {
      field_declaration = "Field",
      function_declaration = "Function",
      method_elem = "Method",
      method_declaration = "Method",
      type_spec = "Type",
    },
    imports = {
      extensions = { ".go" },
      query = [[
          (import_spec
            path: [
              (interpreted_string_literal)
              (raw_string_literal)
            ] @import)
        ]],
      normalize = normalize_import,
      site_keys = site_keys,
      target_keys = target_keys,
      target_label = target_label,
    },
  },
  ast_grep = {
    language = "go",
    query = query,
  },
}

return M

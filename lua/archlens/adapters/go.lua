local common = require("archlens.adapters.common")

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
  local module_root = vim.fs.root(path, "go.mod")
  if not module_root then
    return nil
  end
  module_root = vim.fs.normalize(module_root)
  root = root and vim.fs.normalize(root) or nil
  if root and module_root ~= root and not vim.startswith(module_root, root .. "/") then
    return nil
  end
  local module_file = vim.fs.joinpath(module_root, "go.mod")
  local ok, lines = pcall(vim.fn.readfile, module_file, "", 32)
  if not ok then
    return nil
  end
  for _, line in ipairs(lines) do
    local name = line:match("^%s*module%s+([^%s]+)")
    if name then
      return name, module_root
    end
  end
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

return {
  spec = {
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
  },
}

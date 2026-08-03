local common = require("archlens.adapters.common")

local function section_presentation(context, relation)
  local member = common.member_section(context, relation)
  if member then
    return member
  end
  if context.kind == vim.lsp.protocol.SymbolKind.Interface and relation.id == "implementations" then
    return { label = "Implemented by" }
  end
end

local function row_presentation(_, relation, row)
  if relation.id ~= "implementations" then
    return nil
  end
  local opens_body = row.name:match("{%s*$") ~= nil
  local header = row.name:gsub("%s*{%s*$", "")
  local name = header:match("^impl.-%sfor%s+(.+)$")
  if name then
    name = name:gsub("%s+where%s+.*$", "")
  elseif opens_body then
    name = header:match("^impl%s+(.+)$")
  end
  if not name or name == "" then
    return nil
  end
  return { name = vim.trim(name), kind_name = "Implementation" }
end

local function configuration(bufnr, context, syntax_context)
  if context.kind ~= vim.lsp.protocol.SymbolKind.Field then
    return nil
  end
  local container = syntax_context and syntax_context.name or ""
  if
    not container:match("Config$")
    and not container:match("Options$")
    and not container:match("Settings$")
  then
    return nil
  end
  local path = vim.api.nvim_buf_get_name(bufnr)
  local explicit_file = vim.fs.basename(path) == "config.rs"
  local container_line = syntax_context
      and syntax_context.location
      and syntax_context.location.full_range
      and syntax_context.location.full_range.start.line
    or 0
  local start_line = math.max(0, container_line - 3)
  local prefix =
    table.concat(vim.api.nvim_buf_get_lines(bufnr, start_line, container_line + 1, false), "\n")
  if not explicit_file and not prefix:match("derive[^\n]*Deserialize") then
    return nil
  end
  return { key = context.name, container = container, source = "field" }
end

local function normalize_import(node, text, source, metadata)
  local parent = node:parent()
  if parent and #(parent:field("body") or {}) > 0 then
    return nil
  end
  local path = common.source_path(source, metadata)
  if not path or path == "" then
    return nil
  end
  local directory = vim.fs.dirname(path)
  local filename = vim.fs.basename(path)
  local stem = filename:match("^(.*)%.rs$")
  if stem and stem ~= "main" and stem ~= "lib" and stem ~= "mod" then
    directory = vim.fs.joinpath(directory, stem)
  end
  local module_path = {}
  local ancestor = parent and parent:parent() or nil
  while ancestor do
    if ancestor:type() == "mod_item" and #(ancestor:field("body") or {}) > 0 then
      local names = ancestor:field("name") or {}
      if names[1] then
        table.insert(module_path, 1, common.node_text(names[1], source))
      end
    end
    ancestor = ancestor:parent()
  end
  for _, module in ipairs(module_path) do
    directory = vim.fs.joinpath(directory, module)
  end
  local candidates
  local previous = parent and parent:prev_named_sibling() or nil
  local explicit_path
  while previous and previous:type() == "attribute_item" do
    explicit_path = common.node_text(previous, source):match('path%s*=%s*"([^"]+)"')
      or explicit_path
    previous = previous:prev_named_sibling()
  end
  if explicit_path then
    candidates = {
      vim.fs.joinpath(vim.fs.dirname(path), explicit_path),
      vim.fs.joinpath(directory, explicit_path),
    }
  else
    candidates = {
      vim.fs.joinpath(directory, text .. ".rs"),
      vim.fs.joinpath(directory, text, "mod.rs"),
    }
  end
  local qualified = vim.deepcopy(module_path)
  qualified[#qualified + 1] = text
  return {
    name = "crate::" .. table.concat(qualified, "::"),
    target_paths = common.existing_paths(candidates),
  }
end

return {
  spec = {
    configuration = configuration,
    presentation = {
      row = row_presentation,
      section = section_presentation,
    },
    treesitter = {
      symbol_types = {
        const_item = "Constant",
        enum_item = "Enum",
        enum_variant = "EnumMember",
        field_declaration = "Field",
        function_item = "Function",
        function_signature_item = "Method",
        impl_item = "Implementation",
        mod_item = "Module",
        static_item = "Constant",
        struct_item = "Struct",
        trait_item = "Interface",
        associated_type = "Type",
        type_item = "Type",
      },
      imports = {
        extensions = { ".rs" },
        query = [[
          (mod_item name: (identifier) @import)
        ]],
        normalize = normalize_import,
      },
    },
    ast_grep = { language = "rust" },
  },
}

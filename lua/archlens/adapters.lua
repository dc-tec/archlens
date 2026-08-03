local M = {}

local registry = {}
local filetypes = {}

local default_root_markers = {
  ".git",
  "flake.nix",
  "go.mod",
  "Cargo.toml",
  "dune-project",
  "package.json",
  "pyproject.toml",
}

local default_name_fields = {
  "name",
  "pattern",
  "attrpath",
}

local default_name_node_types = {
  attrpath = true,
  field_identifier = true,
  identifier = true,
  module_name = true,
  type_constructor = true,
  type_identifier = true,
  value_name = true,
}

local function declaration_name(node_type, text)
  if node_type == "impl_item" then
    return text:match("^%s*impl%s+(.+)$")
  end
  return text:match("^%s*module%s+([%w_']+)")
    or text:match("^%s*module%s+type%s+([%w_']+)")
    or text:match("^%s*type%s+([%w_']+)")
end

local function go_query(context)
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

local function go_import(_, text)
  return { name = unquote(text), position_offset = 1 }
end

local function go_module(path, root)
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

local function go_target_keys(path, root)
  local module, module_root = go_module(path, root)
  if not module then
    return {}, "no go.mod module found"
  end
  local relative = vim.fs.relpath(module_root, vim.fs.dirname(path))
  if relative and relative ~= "." then
    module = module .. "/" .. relative:gsub("\\", "/")
  end
  return { "go-package:" .. module }
end

local function go_target_label(path, root)
  local directory = vim.fs.normalize(vim.fs.dirname(path))
  root = root and vim.fs.normalize(root) or nil
  local relative = root and vim.fs.relpath(root, directory) or nil
  if relative and relative ~= "." then
    return relative:gsub("\\", "/")
  end
  return vim.fs.basename(root or directory)
end

local function go_site_keys(site)
  return { "go-package:" .. site.name }
end

local go_configuration_tags = {
  env = true,
  envconfig = true,
  json = true,
  mapstructure = true,
  toml = true,
  yaml = true,
}

local function go_configuration(bufnr, context, syntax_context)
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
    recognized = recognized or go_configuration_tags[name] == true
  end
  if not recognized then
    return nil
  end
  return { key = context.name, container = container, source = "field" }
end

local function rust_configuration(bufnr, context, syntax_context)
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

local function existing_paths(paths)
  local targets = {}
  for _, path in ipairs(paths) do
    local stat = vim.uv.fs_stat(path)
    if stat and stat.type == "file" then
      targets[#targets + 1] = vim.fs.normalize(path)
    end
  end
  return targets
end

local function node_text(node, bufnr)
  local ok, text = pcall(vim.treesitter.get_node_text, node, bufnr)
  return ok and text or ""
end

local function source_path(source, metadata)
  if metadata and metadata.path then
    return metadata.path
  end
  if type(source) == "number" then
    return vim.api.nvim_buf_get_name(source)
  end
end

local function rust_module(node, text, source, metadata)
  local parent = node:parent()
  if parent and #(parent:field("body") or {}) > 0 then
    return nil
  end
  local path = source_path(source, metadata)
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
        table.insert(module_path, 1, node_text(names[1], source))
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
    explicit_path = node_text(previous, source):match('path%s*=%s*"([^"]+)"') or explicit_path
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
    target_paths = existing_paths(candidates),
  }
end

local function nix_import(_, text, source, metadata)
  local source_file = source_path(source, metadata)
  if not source_file or source_file == "" then
    return { name = text }
  end
  local path = text:sub(1, 1) == "/" and text or vim.fs.joinpath(vim.fs.dirname(source_file), text)
  local stat = vim.uv.fs_stat(path)
  if stat and stat.type == "directory" then
    path = vim.fs.joinpath(path, "default.nix")
  end
  return { name = text, target_paths = existing_paths({ path }) }
end

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

local function ocaml_import(_, text, source, metadata)
  local name = vim.trim(text:gsub("%s+", " "))
  local source_file = source_path(source, metadata)
  if not source_file or source_file == "" then
    return { name = name }
  end
  local module_name = name:match("^([%w_']+)")
  if not module_name then
    return { name = name }
  end
  local basename = module_name:sub(1, 1):lower() .. module_name:sub(2)
  local directory = vim.fs.dirname(source_file)
  local targets = existing_paths({
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

local function normalize(language, adapter)
  assert(type(language) == "string" and language ~= "", "adapter language must be a string")
  assert(type(adapter) == "table", "adapter must be a table")

  local normalized = vim.deepcopy(adapter)
  normalized.language = language
  normalized.filetypes = normalized.filetypes or { language }

  if normalized.treesitter then
    assert(
      type(normalized.treesitter.symbol_types) == "table",
      "Tree-sitter adapters require symbol_types"
    )
    normalized.treesitter.root_markers = normalized.treesitter.root_markers
      or vim.deepcopy(default_root_markers)
    normalized.treesitter.name_fields = normalized.treesitter.name_fields
      or vim.deepcopy(default_name_fields)
    normalized.treesitter.name_node_types = normalized.treesitter.name_node_types
      or vim.deepcopy(default_name_node_types)
    normalized.treesitter.synthetic_name = normalized.treesitter.synthetic_name or declaration_name
    if normalized.treesitter.imports then
      assert(
        type(normalized.treesitter.imports.query) == "string"
          and normalized.treesitter.imports.query ~= "",
        "Tree-sitter import adapters require a query"
      )
      normalized.treesitter.imports.capture = normalized.treesitter.imports.capture or "import"
      assert(
        type(normalized.treesitter.imports.capture) == "string"
          and normalized.treesitter.imports.capture ~= "",
        "Tree-sitter import adapters require a capture"
      )
      if normalized.treesitter.imports.normalize ~= nil then
        assert(
          type(normalized.treesitter.imports.normalize) == "function",
          "Tree-sitter import adapter normalize must be a function"
        )
      end
      local extensions = normalized.treesitter.imports.extensions or {}
      assert(type(extensions) == "table", "Tree-sitter import extensions must be a table")
      for _, extension in ipairs(extensions) do
        assert(
          type(extension) == "string" and extension:match("^%."),
          "Tree-sitter import extensions must start with a dot"
        )
      end
      normalized.treesitter.imports.extensions = extensions
      local scan_languages = normalized.treesitter.imports.scan_languages or { language }
      assert(type(scan_languages) == "table", "Tree-sitter import scan languages must be a table")
      normalized.treesitter.imports.scan_languages = scan_languages
      for _, field in ipairs({ "site_keys", "target_keys", "target_label" }) do
        if normalized.treesitter.imports[field] ~= nil then
          assert(
            type(normalized.treesitter.imports[field]) == "function",
            "Tree-sitter import adapter " .. field .. " must be a function"
          )
        end
      end
    end
  end
  if normalized.configuration ~= nil then
    assert(type(normalized.configuration) == "function", "adapter configuration must be a function")
  end

  return normalized
end

function M.register(language, adapter)
  assert(registry[language] == nil, string.format("adapter already registered: %s", language))
  local normalized = normalize(language, adapter)

  for _, filetype in ipairs(normalized.filetypes) do
    assert(filetypes[filetype] == nil, string.format("filetype already registered: %s", filetype))
  end

  registry[language] = normalized
  for _, filetype in ipairs(normalized.filetypes) do
    filetypes[filetype] = language
  end
  return vim.deepcopy(normalized)
end

function M.get(language)
  return vim.deepcopy(registry[language])
end

function M.for_filetype(filetype)
  return M.get(filetypes[filetype] or filetype)
end

function M.language_for_filetype(filetype)
  return filetypes[filetype] or filetype
end

function M.root_markers(filetype)
  local adapter = M.for_filetype(filetype)
  local treesitter = adapter and adapter.treesitter
  return vim.deepcopy(treesitter and treesitter.root_markers or default_root_markers)
end

function M.imports_for_filetype(filetype)
  local adapter = M.for_filetype(filetype)
  return vim.deepcopy(adapter and adapter.treesitter and adapter.treesitter.imports or nil)
end

function M.import_scan_specs(filetype)
  local language = filetypes[filetype] or filetype
  local adapter = registry[language]
  local imports = adapter and adapter.treesitter and adapter.treesitter.imports
  local specs = {}
  for _, scan_language in ipairs(imports and imports.scan_languages or {}) do
    local scan_adapter = registry[scan_language]
    local scan_imports = scan_adapter
      and scan_adapter.treesitter
      and scan_adapter.treesitter.imports
    if scan_imports then
      specs[#specs + 1] = {
        language = scan_language,
        extensions = vim.deepcopy(scan_imports.extensions),
        imports = vim.deepcopy(scan_imports),
      }
    end
  end
  return specs
end

function M.ast_grep_query(context, language)
  local adapter = registry[language]
  local provider = adapter and adapter.ast_grep
  if provider and provider.query then
    return provider.query(context)
  end
  return context.name, nil
end

M.register("go", {
  configuration = go_configuration,
  treesitter = {
    symbol_types = {
      function_declaration = "Function",
      method_declaration = "Method",
      type_declaration = "Type",
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
      normalize = go_import,
      site_keys = go_site_keys,
      target_keys = go_target_keys,
      target_label = go_target_label,
    },
  },
  ast_grep = {
    language = "go",
    query = go_query,
  },
})

M.register("nix", {
  treesitter = {
    symbol_types = {
      binding = "Binding",
      inherit = "Binding",
    },
    imports = {
      extensions = { ".nix" },
      query = [[
        ((apply_expression
          function: (variable_expression
            name: (identifier) @_function)
          argument: (path_expression) @import)
          (#eq? @_function "import"))

        ((binding
          attrpath: (attrpath) @_imports
          expression: (list_expression
            element: (path_expression) @import))
          (#eq? @_imports "imports"))
      ]],
      normalize = nix_import,
    },
  },
  ast_grep = { language = "nix" },
})

M.register("ocaml", {
  treesitter = {
    symbol_types = {
      class_definition = "Class",
      let_binding = "Value",
      method_definition = "Method",
      module_definition = "Module",
      module_type_definition = "Module",
      type_definition = "Type",
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
      normalize = ocaml_import,
    },
  },
  ast_grep = {
    unsupported_note = "ast-grep has no OCaml parser; semantic references and Tree-sitter context remain available.",
  },
})

M.register("ocaml_interface", {
  filetypes = { "ocamlinterface" },
  treesitter = {
    symbol_types = {
      class_specification = "Class",
      module_specification = "Module",
      module_type_definition = "Module",
      type_definition = "Type",
      value_specification = "Value",
    },
    imports = {
      extensions = { ".mli" },
      scan_languages = { "ocaml", "ocaml_interface" },
      query = [[
        [
          (open_module_signature module: (extended_module_path) @import)
          (include_module_type module_type: (_) @import)
        ]
      ]],
      normalize = ocaml_import,
    },
  },
  ast_grep = {
    unsupported_note = "ast-grep has no OCaml parser; semantic references and Tree-sitter context remain available.",
  },
})

M.register("rust", {
  configuration = rust_configuration,
  treesitter = {
    symbol_types = {
      const_item = "Constant",
      enum_item = "Enum",
      field_declaration = "Field",
      function_item = "Function",
      impl_item = "Implementation",
      mod_item = "Module",
      static_item = "Constant",
      struct_item = "Struct",
      trait_item = "Interface",
      type_item = "Type",
    },
    imports = {
      extensions = { ".rs" },
      query = [[
        (mod_item name: (identifier) @import)
      ]],
      normalize = rust_module,
    },
  },
  ast_grep = { language = "rust" },
})

M.register("javascript", {
  filetypes = { "javascript", "javascriptreact" },
  ast_grep = { language = "javascript" },
})
M.register("lua", { ast_grep = { language = "lua" } })
M.register("python", { ast_grep = { language = "python" } })
M.register("tsx", {
  filetypes = { "tsx", "typescriptreact" },
  ast_grep = { language = "tsx" },
})
M.register("typescript", { ast_grep = { language = "typescript" } })

return M

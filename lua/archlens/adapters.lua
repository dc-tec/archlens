local common = require("archlens.adapters.common")

local M = {}

---@class ArchLensImportAdapter
---@field query string
---@field capture? string
---@field extensions? string[]
---@field scan_languages? string[]
---@field normalize? function
---@field site_keys? function
---@field target_keys? function
---@field target_label? function

---@class ArchLensTreeSitterAdapter
---@field symbol_types table<string, string>
---@field root_markers? string[]
---@field focus_wrappers? table<string, boolean>
---@field name_fields? string[]
---@field name_node_types? table<string, boolean>
---@field synthetic_name? function
---@field imports? ArchLensImportAdapter

---@class ArchLensAstGrepAdapter
---@field language? string
---@field query? function
---@field unsupported_note? string

---@class ArchLensAdapterSpec
---@field filetypes? string[]
---@field filename_extensions? string[]
---@field treesitter? ArchLensTreeSitterAdapter
---@field ast_grep? ArchLensAstGrepAdapter
---@field configuration? function
---@field presentation? { row?: function, section?: function }

---@class ArchLensAdapter: ArchLensAdapterSpec
---@field language string
---@field filetypes string[]
---@field filename_extensions string[]

---@class ArchLensBuiltinAdapter
---@field spec ArchLensAdapterSpec
---@field clear_cache? function

---@type table<string, ArchLensAdapter>
local registry = {}
local filetypes = {}
local filename_extensions = {}
local cache_clearers = {}

local function call_hook(language, hook, callback, ...)
  local ok, value = pcall(callback, ...)
  if not ok then
    return nil,
      string.format(
        "%s adapter %s failed: %s",
        tostring(language or "unknown"),
        hook,
        tostring(value)
      )
  end
  return value
end

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

local default_name_node_types = common.name_node_types()

local adapter_fields = {
  ast_grep = true,
  configuration = true,
  filename_extensions = true,
  filetypes = true,
  presentation = true,
  treesitter = true,
}

local treesitter_fields = {
  focus_wrappers = true,
  imports = true,
  name_fields = true,
  name_node_types = true,
  root_markers = true,
  symbol_types = true,
  synthetic_name = true,
}

local import_fields = {
  capture = true,
  extensions = true,
  normalize = true,
  query = true,
  scan_languages = true,
  site_keys = true,
  target_keys = true,
  target_label = true,
}

local ast_grep_fields = {
  language = true,
  query = true,
  unsupported_note = true,
}

local presentation_fields = {
  row = true,
  section = true,
}

local function nonempty_string(value)
  return type(value) == "string" and value:match("%S") ~= nil
end

local function validate_fields(value, allowed, label)
  for field in pairs(value) do
    assert(allowed[field], string.format("unsupported %s field: %s", label, tostring(field)))
  end
end

local function validate_string_list(value, label, validate_item)
  assert(type(value) == "table" and vim.islist(value), label .. " must be a list")
  local seen = {}
  for index, item in ipairs(value) do
    assert(
      nonempty_string(item) and (not validate_item or validate_item(item)),
      string.format("%s[%d] is invalid", label, index)
    )
    assert(not seen[item], string.format("%s contains duplicate value: %s", label, item))
    seen[item] = true
  end
end

local function validate_string_map(value, label, validate_value)
  assert(
    type(value) == "table" and (next(value) == nil or not vim.islist(value)),
    label .. " must be a map"
  )
  for key, item in pairs(value) do
    assert(nonempty_string(key), label .. " keys must be non-empty strings")
    assert(validate_value(item), label .. " contains an invalid value for " .. key)
  end
end

local function declaration_name(node_type, text)
  if node_type == "impl_item" then
    return text:gsub("%s*{%s*$", ""):match("^%s*impl%s+(.+)$")
  end
  return text:match("^%s*module%s+([%w_']+)")
    or text:match("^%s*module%s+type%s+([%w_']+)")
    or text:match("^%s*type%s+([%w_']+)")
end

---@param language string
---@param adapter ArchLensAdapterSpec
---@return ArchLensAdapter
local function normalize(language, adapter)
  assert(nonempty_string(language), "adapter language must be a non-empty string")
  assert(type(adapter) == "table", "adapter must be a table")
  validate_fields(adapter, adapter_fields, "adapter")

  local normalized = vim.deepcopy(adapter)
  normalized.language = language
  if normalized.filetypes == nil then
    normalized.filetypes = { language }
  end
  if normalized.filename_extensions == nil then
    normalized.filename_extensions = {}
  end
  validate_string_list(normalized.filetypes, "adapter filetypes")
  validate_string_list(
    normalized.filename_extensions,
    "adapter filename_extensions",
    function(value)
      return value:match("^%..+") ~= nil
    end
  )

  if normalized.treesitter ~= nil then
    assert(type(normalized.treesitter) == "table", "adapter treesitter must be a table")
    validate_fields(normalized.treesitter, treesitter_fields, "Tree-sitter adapter")
    validate_string_map(
      normalized.treesitter.symbol_types,
      "Tree-sitter symbol_types",
      function(value)
        return nonempty_string(value)
      end
    )
    if normalized.treesitter.root_markers == nil then
      normalized.treesitter.root_markers = vim.deepcopy(default_root_markers)
    end
    validate_string_list(normalized.treesitter.root_markers, "Tree-sitter root_markers")
    if normalized.treesitter.focus_wrappers == nil then
      normalized.treesitter.focus_wrappers = {}
    end
    validate_string_map(
      normalized.treesitter.focus_wrappers,
      "Tree-sitter focus_wrappers",
      function(value)
        return value == true
      end
    )
    if normalized.treesitter.name_fields == nil then
      normalized.treesitter.name_fields = vim.deepcopy(default_name_fields)
    end
    validate_string_list(normalized.treesitter.name_fields, "Tree-sitter name_fields")
    if normalized.treesitter.name_node_types == nil then
      normalized.treesitter.name_node_types = vim.deepcopy(default_name_node_types)
    end
    validate_string_map(
      normalized.treesitter.name_node_types,
      "Tree-sitter name_node_types",
      function(value)
        return value == true
      end
    )
    if normalized.treesitter.synthetic_name == nil then
      normalized.treesitter.synthetic_name = declaration_name
    end
    assert(
      type(normalized.treesitter.synthetic_name) == "function",
      "Tree-sitter synthetic_name must be a function"
    )
    if normalized.treesitter.imports ~= nil then
      assert(type(normalized.treesitter.imports) == "table", "Tree-sitter imports must be a table")
      validate_fields(normalized.treesitter.imports, import_fields, "Tree-sitter import adapter")
      assert(
        nonempty_string(normalized.treesitter.imports.query),
        "Tree-sitter import adapters require a query"
      )
      normalized.treesitter.imports.capture = normalized.treesitter.imports.capture or "import"
      assert(
        nonempty_string(normalized.treesitter.imports.capture),
        "Tree-sitter import adapters require a capture"
      )
      if normalized.treesitter.imports.normalize ~= nil then
        assert(
          type(normalized.treesitter.imports.normalize) == "function",
          "Tree-sitter import adapter normalize must be a function"
        )
      end
      local extensions = normalized.treesitter.imports.extensions
      if extensions == nil then
        extensions = {}
      end
      validate_string_list(extensions, "Tree-sitter import extensions", function(value)
        return value:match("^%..+") ~= nil
      end)
      normalized.treesitter.imports.extensions = extensions
      local scan_languages = normalized.treesitter.imports.scan_languages
      if scan_languages == nil then
        scan_languages = { language }
      end
      validate_string_list(scan_languages, "Tree-sitter import scan languages")
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
  if normalized.ast_grep ~= nil then
    assert(type(normalized.ast_grep) == "table", "adapter ast_grep must be a table")
    validate_fields(normalized.ast_grep, ast_grep_fields, "ast-grep adapter")
    if normalized.ast_grep.language ~= nil then
      assert(
        nonempty_string(normalized.ast_grep.language),
        "ast-grep adapter language must be a non-empty string"
      )
    end
    if normalized.ast_grep.query ~= nil then
      assert(
        type(normalized.ast_grep.query) == "function",
        "ast-grep adapter query must be a function"
      )
      assert(normalized.ast_grep.language ~= nil, "ast-grep adapter query requires a language")
    end
    if normalized.ast_grep.unsupported_note ~= nil then
      assert(
        nonempty_string(normalized.ast_grep.unsupported_note),
        "ast-grep adapter unsupported_note must be a non-empty string"
      )
    end
  end
  if normalized.configuration ~= nil then
    assert(type(normalized.configuration) == "function", "adapter configuration must be a function")
  end
  if normalized.presentation ~= nil then
    assert(type(normalized.presentation) == "table", "adapter presentation must be a table")
    validate_fields(normalized.presentation, presentation_fields, "adapter presentation")
    for _, field in ipairs({ "row", "section" }) do
      if normalized.presentation[field] ~= nil then
        assert(
          type(normalized.presentation[field]) == "function",
          "adapter presentation " .. field .. " must be a function"
        )
      end
    end
  end

  return normalized
end

---@param language string
---@param adapter ArchLensAdapterSpec
---@return ArchLensAdapter
function M.register(language, adapter)
  assert(registry[language] == nil, string.format("adapter already registered: %s", language))
  local normalized = normalize(language, adapter)

  for _, filetype in ipairs(normalized.filetypes) do
    assert(filetypes[filetype] == nil, string.format("filetype already registered: %s", filetype))
  end
  for _, extension in ipairs(normalized.filename_extensions) do
    assert(
      filename_extensions[extension] == nil,
      string.format("filename extension already registered: %s", extension)
    )
  end

  registry[language] = normalized
  for _, filetype in ipairs(normalized.filetypes) do
    filetypes[filetype] = language
  end
  for _, extension in ipairs(normalized.filename_extensions) do
    filename_extensions[extension] = language
  end
  return vim.deepcopy(normalized)
end

---@param language string
---@return ArchLensAdapter?
function M.get(language)
  return vim.deepcopy(registry[language])
end

local function path_extension(path)
  if type(path) ~= "string" or path == "" then
    return nil
  end
  return vim.fs.basename(path):match("(%.[^%.]+)$")
end

---@param filetype string
---@param path? string
---@return string
function M.language_for_filetype(filetype, path)
  return filename_extensions[path_extension(path)] or filetypes[filetype] or filetype
end

---@param filetype string
---@param path? string
---@return ArchLensAdapter?
function M.for_filetype(filetype, path)
  return M.get(M.language_for_filetype(filetype, path))
end

---@param filetype string
---@param path? string
---@return string[]
function M.root_markers(filetype, path)
  local adapter = M.for_filetype(filetype, path)
  local treesitter = adapter and adapter.treesitter
  return vim.deepcopy(treesitter and treesitter.root_markers or default_root_markers)
end

---@param filetype string
---@param path? string
---@return ArchLensImportAdapter?
function M.imports_for_filetype(filetype, path)
  local adapter = M.for_filetype(filetype, path)
  return vim.deepcopy(adapter and adapter.treesitter and adapter.treesitter.imports or nil)
end

---@param filetype string
---@param path? string
---@return { language: string, extensions: string[], imports: ArchLensImportAdapter }[]
function M.import_scan_specs(filetype, path)
  local language = M.language_for_filetype(filetype, path)
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

function M.configuration(language, bufnr, context, syntax_context)
  local adapter = registry[language]
  local callback = adapter and adapter.configuration
  if not callback then
    return nil
  end
  return call_hook(language, "configuration", function()
    local value = callback(bufnr, context, syntax_context)
    assert(value == nil or type(value) == "table", "configuration must return a table or nil")
    return value
  end)
end

---@param language string
---@param spec ArchLensImportAdapter
---@param node any
---@param text string
---@param source any
---@param metadata? table
---@return table?
---@return string? error
function M.normalize_import(language, spec, node, text, source, metadata)
  if not spec.normalize then
    return { name = text }
  end
  return call_hook(language, "import normalization", function()
    local value = spec.normalize(node, text, source, metadata)
    assert(
      value == nil or type(value) == "table",
      "import normalization must return a table or nil"
    )
    return value
  end)
end

function M.row_presentation(context, relation, row)
  local adapter = registry[context.language]
  local project = adapter and adapter.presentation and adapter.presentation.row
  if not project then
    return nil
  end
  return call_hook(context.language, "row presentation", function()
    local presentation = project(context, relation, row)
    if presentation == nil then
      return nil
    end
    assert(type(presentation) == "table", "row presentation must return a table")
    for _, field in ipairs({ "kind_name", "name" }) do
      if presentation[field] ~= nil then
        assert(
          type(presentation[field]) == "string" and presentation[field] ~= "",
          "row presentation " .. field .. " must be a non-empty string"
        )
      end
    end
    return presentation
  end)
end

function M.section_presentation(context, relation, row)
  local adapter = registry[context.language]
  local project = adapter and adapter.presentation and adapter.presentation.section
  if not project then
    return nil
  end
  return call_hook(context.language, "section presentation", function()
    local presentation = project(context, relation, row)
    if presentation == nil then
      return nil
    end
    assert(type(presentation) == "table", "section presentation must return a table")
    for _, field in ipairs({ "key", "label" }) do
      if presentation[field] ~= nil then
        assert(
          type(presentation[field]) == "string" and presentation[field] ~= "",
          "section presentation " .. field .. " must be a non-empty string"
        )
      end
    end
    if presentation.order ~= nil then
      assert(type(presentation.order) == "number", "section presentation order must be a number")
    end
    if presentation.show_kind ~= nil then
      assert(
        type(presentation.show_kind) == "boolean",
        "section presentation show_kind must be boolean"
      )
    end
    return presentation
  end)
end

function M.ast_grep_query(context, language)
  local adapter = registry[language]
  local provider = adapter and adapter.ast_grep
  if provider and provider.query then
    local query, query_error = call_hook(language, "ast-grep query", function()
      local pattern, selector = provider.query(context)
      assert(
        type(pattern) == "string" and pattern ~= "",
        "ast-grep query pattern must be a non-empty string"
      )
      assert(
        selector == nil or (type(selector) == "string" and selector ~= ""),
        "ast-grep query selector must be a non-empty string or nil"
      )
      return { pattern = pattern, selector = selector }
    end)
    if query_error then
      return nil, nil, query_error
    end
    assert(query, "validated ast-grep query must return a result")
    return query.pattern, query.selector
  end
  return context.name, nil
end

function M.clear_cache()
  for _, clear_cache in ipairs(cache_clearers) do
    clear_cache()
  end
end

local builtin_languages = {
  "go",
  "nix",
  "ocaml",
  "ocaml_interface",
  "rust",
  "javascript",
  "lua",
  "python",
  "tsx",
  "typescript",
}

for _, language in ipairs(builtin_languages) do
  ---@type ArchLensBuiltinAdapter
  local builtin = require("archlens.adapters." .. language)
  assert(
    type(builtin) == "table" and type(builtin.spec) == "table",
    string.format("built-in adapter must provide a spec: %s", language)
  )
  M.register(language, builtin.spec)
  if builtin.clear_cache then
    assert(
      type(builtin.clear_cache) == "function",
      string.format("built-in adapter clear_cache must be a function: %s", language)
    )
    cache_clearers[#cache_clearers + 1] = builtin.clear_cache
  end
end

return M

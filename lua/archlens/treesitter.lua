local adapters = require("archlens.adapters")
local model = require("archlens.model")

local M = {}

local kind_by_label = {
  Binding = vim.lsp.protocol.SymbolKind.Property,
  Class = vim.lsp.protocol.SymbolKind.Class,
  Constant = vim.lsp.protocol.SymbolKind.Constant,
  Enum = vim.lsp.protocol.SymbolKind.Enum,
  EnumMember = vim.lsp.protocol.SymbolKind.EnumMember,
  Field = vim.lsp.protocol.SymbolKind.Field,
  Function = vim.lsp.protocol.SymbolKind.Function,
  Implementation = vim.lsp.protocol.SymbolKind.Namespace,
  Interface = vim.lsp.protocol.SymbolKind.Interface,
  Method = vim.lsp.protocol.SymbolKind.Method,
  Module = vim.lsp.protocol.SymbolKind.Module,
  Struct = vim.lsp.protocol.SymbolKind.Struct,
  Type = vim.lsp.protocol.SymbolKind.TypeParameter,
  Value = vim.lsp.protocol.SymbolKind.Variable,
}

local function node_text(node, bufnr)
  if not node then
    return nil
  end
  local ok, text = pcall(vim.treesitter.get_node_text, node, bufnr)
  if not ok or type(text) ~= "string" then
    return nil
  end
  return vim.trim(text:gsub("%s+", " "))
end

local function first_line(text)
  return text and text:match("^[^\n{]+") or nil
end

local function synthetic_name(node, bufnr, adapter)
  local text = first_line(node_text(node, bufnr))
  if not text then
    return nil
  end
  return adapter.treesitter.synthetic_name(node:type(), text)
end

local function name_candidates(node, bufnr, adapter)
  for _, field in ipairs(adapter.treesitter.name_fields) do
    local nodes = node:field(field)
    local candidates = {}
    for _, target in ipairs(nodes or {}) do
      local name = node_text(target, bufnr)
      if name and name ~= "" then
        candidates[#candidates + 1] = { target = target, name = name }
      end
    end
    if #candidates > 0 then
      return candidates
    end
  end
  local candidates = {}
  for index = 0, node:named_child_count() - 1 do
    local child = node:named_child(index)
    if adapter.treesitter.name_node_types[child:type()] then
      local name = node_text(child, bufnr)
      if name and name ~= "" then
        candidates[#candidates + 1] = { target = child, name = name }
      end
    end
  end
  if #candidates > 0 then
    return candidates
  end
  for index = 0, node:named_child_count() - 1 do
    local child = node:named_child(index)
    if adapter.treesitter.symbol_types[child:type()] then
      local nested = name_candidates(child, bufnr, adapter)
      if #nested > 0 then
        return nested
      end
    end
  end
  local name = synthetic_name(node, bufnr, adapter)
  return name and { { name = name } } or {}
end

local function node_range(node)
  local start_row, start_col, end_row, end_col = node:range()
  return {
    start = { line = start_row, character = start_col },
    ["end"] = { line = end_row, character = end_col },
  }
end

local function name_candidate(node, bufnr, adapter, position)
  local candidates = name_candidates(node, bufnr, adapter)
  if position then
    for _, candidate in ipairs(candidates) do
      if candidate.target and model.range_contains(node_range(candidate.target), position) then
        return candidate
      end
    end
  end
  return candidates[1]
end

local function root_for(bufnr, adapter)
  local path = vim.api.nvim_buf_get_name(bufnr)
  if path == "" then
    return nil
  end
  return vim.fs.root(path, adapter.treesitter.root_markers) or vim.fs.dirname(path)
end

local function language_for(bufnr)
  local filetype = vim.bo[bufnr].filetype
  local path = vim.api.nvim_buf_get_name(bufnr)
  return adapters.language_for_filetype(filetype, path)
end

local function label_for(adapter, node)
  return adapter.treesitter.symbol_types[node:type()]
end

local function is_symbol(adapter, node, bufnr)
  if not label_for(adapter, node) then
    return false
  end
  return #name_candidates(node, bufnr, adapter) > 0
end

local function item_from_node(node, bufnr, adapter, candidate)
  candidate = candidate or name_candidate(node, bufnr, adapter)
  local name_target = candidate and candidate.target
  local name = candidate and candidate.name
  local range = node_range(node)
  return {
    name = name,
    kind = kind_by_label[label_for(adapter, node)] or vim.lsp.protocol.SymbolKind.Variable,
    uri = vim.uri_from_bufnr(bufnr),
    range = range,
    selectionRange = name_target and node_range(name_target) or range,
  }
end

local function context_from_node(node, bufnr, adapter, provider, candidate)
  local context = model.context_from_item(item_from_node(node, bufnr, adapter, candidate), provider)
  context.language = adapter.language
  context.syntax_node_type = node:type()
  context.kind_name = label_for(adapter, node) or context.kind_name
  return context
end

local function same_location(left, right)
  local left_location = left and left.location
  local right_location = right and right.location
  local left_range = left_location and left_location.range
  local right_range = right_location and right_location.range
  return left_location
    and right_location
    and left_location.uri == right_location.uri
    and left_range
    and right_range
    and vim.deep_equal(left_range, right_range)
end

local function same_symbol_identity(left, right)
  local left_location = left and left.location
  local right_location = right and right.location
  local left_range = left_location and left_location.range
  local right_range = right_location and right_location.range
  return left
    and right
    and left.name == right.name
    and left_location
    and right_location
    and left_location.uri == right_location.uri
    and left_range
    and right_range
    and (
      same_location(left, right)
      or model.range_contains(left_range, right_range.start)
      or model.range_contains(right_range, left_range.start)
    )
end

local function direct_symbols(container, current, bufnr, adapter, provider)
  local rows = {}
  local function visit(node)
    for index = 0, node:named_child_count() - 1 do
      local child = node:named_child(index)
      if child:id() ~= current:id() and is_symbol(adapter, child, bufnr) then
        for _, candidate in ipairs(name_candidates(child, bufnr, adapter)) do
          rows[#rows + 1] = context_from_node(child, bufnr, adapter, provider, candidate)
        end
      elseif child:id() ~= current:id() then
        visit(child)
      end
    end
  end
  visit(container)
  return rows
end

local function first_symbol_descendant(node, bufnr, adapter)
  for index = 0, node:named_child_count() - 1 do
    local child = node:named_child(index)
    if is_symbol(adapter, child, bufnr) then
      return child
    end
    local nested = first_symbol_descendant(child, bufnr, adapter)
    if nested then
      return nested
    end
  end
end

local function symbol_parent(node, bufnr, adapter)
  local parent = node:parent()
  while parent do
    if is_symbol(adapter, parent, bufnr) then
      return parent
    end
    parent = parent:parent()
  end
  return nil
end

local function range_span(range)
  if not range or not range.start or not range["end"] then
    return math.huge
  end
  return (range["end"].line - range.start.line) * 100000
    + range["end"].character
    - range.start.character
end

local function merge_base(syntax_context, base_context)
  if not base_context then
    return syntax_context
  end

  local use_syntax_identity = base_context.preserve_file_identity ~= true
    and (
      base_context.file_fallback == true
      or (
        not base_context.supports_calls
        and range_span(syntax_context.location and syntax_context.location.full_range)
          <= range_span(base_context.location and base_context.location.full_range)
      )
    )
  local merged = use_syntax_identity and syntax_context or vim.deepcopy(base_context)
  if
    use_syntax_identity
    and not base_context.file_fallback
    and base_context.kind
    and base_context.kind ~= syntax_context.kind
    and same_symbol_identity(syntax_context, base_context)
  then
    merged.kind = base_context.kind
    merged.kind_name = base_context.kind_name
    merged.detail = base_context.detail or merged.detail
  end
  merged.client_id = base_context.client_id
  merged.client_name = base_context.client_name
  merged.position_encoding = base_context.position_encoding
  merged.root_dir = base_context.root_dir or syntax_context.root_dir
  merged.supports_calls = base_context.supports_calls
  merged.call_item = base_context.supports_calls and base_context.item or nil
  merged.wire_call_item = base_context.wire_call_item
  merged.wire_type_item = base_context.wire_type_item
  merged.module_context = base_context.module_context
  merged.preserve_file_identity = base_context.preserve_file_identity
  merged.configuration = base_context.configuration
  merged.language = syntax_context.language
  merged.syntax_node_type = syntax_context.syntax_node_type
  if merged.configuration then
    merged.scope = "configuration"
  end
  return merged
end

function M.resolve(bufnr, position, base_context)
  local language = language_for(bufnr)
  local fallback_context
  if base_context then
    fallback_context = vim.deepcopy(base_context)
    fallback_context.language = language
  end
  local adapter = adapters.get(language)
  if not adapter or not adapter.treesitter then
    return fallback_context
  end

  local ok, parser = pcall(vim.treesitter.get_parser, bufnr, language, { error = false })
  if not ok or not parser then
    return fallback_context
  end
  local trees = parser:parse()
  local root = trees and trees[1] and trees[1]:root()
  if not root then
    return fallback_context
  end

  local node = root:named_descendant_for_range(
    position.line,
    position.character,
    position.line,
    position.character
  )
  while node and not is_symbol(adapter, node, bufnr) do
    if adapter.treesitter.focus_wrappers[node:type()] then
      node = first_symbol_descendant(node, bufnr, adapter)
      break
    end
    node = node:parent()
  end
  if not node then
    return fallback_context
  end

  local provider = {
    id = base_context and base_context.client_id or nil,
    name = base_context and base_context.client_name or "Tree-sitter",
    offset_encoding = base_context and base_context.position_encoding or "utf-8",
    root_dir = base_context and base_context.root_dir or root_for(bufnr, adapter),
    supports_calls = false,
  }
  local candidate = name_candidate(node, bufnr, adapter, position)
  local syntax_context = context_from_node(node, bufnr, adapter, provider, candidate)
  local context = merge_base(syntax_context, fallback_context)

  local ancestors = {}
  local parent = symbol_parent(node, bufnr, adapter)
  while parent do
    local ancestor = context_from_node(parent, bufnr, adapter, provider)
    if not same_location(ancestor, syntax_context) then
      table.insert(ancestors, 1, ancestor)
    end
    parent = symbol_parent(parent, bufnr, adapter)
  end

  local child_contexts = {}
  for _, child in ipairs(direct_symbols(node, node, bufnr, adapter, provider)) do
    if not same_location(child, syntax_context) then
      child_contexts[#child_contexts + 1] = child
    end
  end
  local container = symbol_parent(node, bufnr, adapter) or root
  local sibling_contexts = direct_symbols(container, node, bufnr, adapter, provider)
  local siblings = {}
  for _, sibling in ipairs(sibling_contexts) do
    if not same_location(sibling, syntax_context) then
      siblings[#siblings + 1] = sibling
    end
  end

  context.syntax = {
    provider = "Tree-sitter",
    ancestors = ancestors,
    children = child_contexts,
    siblings = siblings,
  }
  if not context.configuration and adapter.configuration then
    local container_context = ancestors[#ancestors] or syntax_context
    local configuration, configuration_error =
      adapters.configuration(adapter.language, bufnr, context, container_context)
    if configuration_error then
      context.adapter_issues = context.adapter_issues or {}
      context.adapter_issues[#context.adapter_issues + 1] = configuration_error
    elseif configuration then
      context.configuration = configuration
      context.scope = "configuration"
    end
  end
  return context
end

function M.supports(bufnr)
  local adapter = adapters.get(language_for(bufnr))
  return adapter ~= nil and adapter.treesitter ~= nil
end

function M.supports_imports(bufnr)
  local adapter = adapters.get(language_for(bufnr))
  return adapter ~= nil and adapter.treesitter ~= nil and adapter.treesitter.imports ~= nil
end

local function loaded_buffer_for_path(path)
  for _, candidate in ipairs(vim.api.nvim_list_bufs()) do
    if
      vim.api.nvim_buf_is_loaded(candidate)
      and vim.fs.normalize(vim.api.nvim_buf_get_name(candidate)) == path
    then
      return candidate
    end
  end
end

local function parser_for_path(path, language)
  path = vim.fs.normalize(path)
  local bufnr = loaded_buffer_for_path(path)
  if bufnr then
    local parser_ok, parser = pcall(vim.treesitter.get_parser, bufnr, language, { error = false })
    if not parser_ok or not parser then
      return nil, nil, parser_ok and "Tree-sitter parser unavailable" or tostring(parser)
    end
    return parser, bufnr
  end

  local read_ok, lines = pcall(vim.fn.readfile, path, "b")
  if not read_ok then
    return nil, nil, tostring(lines)
  end
  local contents = table.concat(lines, "\n")
  local parser_ok, parser =
    pcall(vim.treesitter.get_string_parser, contents, language, { error = false })
  if not parser_ok or not parser then
    return nil, nil, parser_ok and "Tree-sitter parser unavailable" or tostring(parser)
  end
  return parser, contents
end

local function source_root(parser)
  local trees = parser:parse()
  return trees and trees[1] and trees[1]:root() or nil
end

local function extract_import_sites(language, spec, parser, source, uri, metadata)
  local query_ok, query = pcall(vim.treesitter.query.parse, language, spec.query)
  if not query_ok then
    return {}, tostring(query)
  end
  local trees = parser:parse()
  local root = trees and trees[1] and trees[1]:root()
  if not root then
    return {}, "Tree-sitter returned no syntax tree"
  end

  local sites = {}
  local seen = {}
  local iter_ok, iter_error = pcall(function()
    for capture_id, node in query:iter_captures(root, source, 0, -1) do
      if query.captures[capture_id] == spec.capture then
        local range = node_range(node)
        local text = node_text(node, source)
        if text then
          local normalized, normalization_error =
            adapters.normalize_import(language, spec, node, text, source, metadata)
          if normalization_error then
            error(normalization_error, 0)
          end
          if normalized and type(normalized.name) == "string" and normalized.name ~= "" then
            local position = vim.deepcopy(range.start)
            position.character = position.character + (normalized.position_offset or 0)
            local key = table.concat({
              normalized.name,
              range.start.line,
              range.start.character,
              range["end"].line,
              range["end"].character,
            }, ":")
            if not seen[key] then
              seen[key] = true
              local target_locations = {}
              for _, path in ipairs(normalized.target_paths or {}) do
                target_locations[#target_locations + 1] = {
                  uri = vim.uri_from_fname(path),
                  range = {
                    start = { line = 0, character = 0 },
                    ["end"] = { line = 0, character = 0 },
                  },
                }
              end
              sites[#sites + 1] = {
                name = normalized.name,
                location = { uri = uri, range = range, full_range = range },
                position = position,
                target_locations = target_locations,
                resolution_provider = normalized.resolution_provider,
                resolution_method = normalized.resolution_method,
              }
            end
          end
        end
      end
    end
  end)
  if not iter_ok then
    return {}, tostring(iter_error)
  end
  return sites
end

function M.import_sites(bufnr)
  local language = language_for(bufnr)
  local adapter = adapters.get(language)
  local spec = adapter and adapter.treesitter and adapter.treesitter.imports
  if not spec then
    return {}
  end

  local parser_ok, parser = pcall(vim.treesitter.get_parser, bufnr, language, { error = false })
  if not parser_ok or not parser then
    return {}, parser_ok and "Tree-sitter parser unavailable" or tostring(parser)
  end
  local path = vim.api.nvim_buf_get_name(bufnr)
  return extract_import_sites(language, spec, parser, bufnr, vim.uri_from_bufnr(bufnr), {
    path = path,
  })
end

function M.import_sites_from_path(path, language)
  path = vim.fs.normalize(path)
  local adapter = adapters.get(language)
  local spec = adapter and adapter.treesitter and adapter.treesitter.imports
  if not spec then
    return {}
  end

  local parser, parser_source, parser_error = parser_for_path(path, language)
  if not parser then
    return {}, parser_error
  end
  return extract_import_sites(language, spec, parser, parser_source, vim.uri_from_fname(path), {
    path = path,
  })
end

function M.enclosing_containers(path, positions)
  path = vim.fs.normalize(path)
  local bufnr = loaded_buffer_for_path(path)
  local filetype = bufnr and vim.bo[bufnr].filetype or vim.filetype.match({ filename = path })
  local language = adapters.language_for_filetype(filetype or "", path)
  local adapter = adapters.get(language)
  if not adapter or not adapter.treesitter then
    return {}, "Tree-sitter adapter unavailable"
  end
  local parser, parser_source, parser_error = parser_for_path(path, language)
  if not parser then
    return {}, parser_error
  end
  local root = source_root(parser)
  if not root then
    return {}, "Tree-sitter returned no syntax tree"
  end

  local containers = {}
  for index, position in ipairs(positions or {}) do
    local node = root:named_descendant_for_range(
      position.line,
      position.character,
      position.line,
      position.character
    )
    local function_node
    local module_node
    local current = node
    while current do
      local label = label_for(adapter, current)
      if not function_node and (label == "Function" or label == "Method") then
        function_node = current
      elseif not module_node and label == "Module" then
        module_node = current
      end
      current = current:parent()
    end
    local container = function_node or module_node
    if container then
      local candidate = name_candidate(container, parser_source, adapter, position)
      local name_target = candidate and candidate.target
      local name = candidate and candidate.name
      if name and name ~= "" then
        local trail = {}
        current = container:parent()
        while current do
          if label_for(adapter, current) == "Module" then
            local module_candidate = name_candidate(current, parser_source, adapter)
            local module_name = module_candidate and module_candidate.name
            if module_name and module_name ~= "" then
              table.insert(trail, 1, module_name)
            end
          end
          current = current:parent()
        end
        containers[index] = {
          name = name,
          kind_name = label_for(adapter, container),
          location = {
            uri = vim.uri_from_fname(path),
            range = name_target and node_range(name_target) or node_range(container),
            full_range = node_range(container),
          },
          trail = trail,
        }
      end
    end
  end
  return containers
end

return M

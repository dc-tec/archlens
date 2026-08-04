local adapters = require("archlens.adapters")

local M = {}

local function zero_range()
  return {
    start = { line = 0, character = 0 },
    ["end"] = { line = 0, character = 0 },
  }
end

local function add_issue(context, issue)
  context.adapter_issues = context.adapter_issues or {}
  context.adapter_issues[#context.adapter_issues + 1] = issue
end

local symbol_kinds = {
  module = vim.lsp.protocol.SymbolKind.Module,
  package = vim.lsp.protocol.SymbolKind.Package,
  workspace = vim.lsp.protocol.SymbolKind.Namespace,
}

function M.context(source, boundary, enclosing_boundaries)
  local representative = boundary.representative_path or source.path or boundary.path
  local location = {
    uri = vim.uri_from_fname(representative),
    range = zero_range(),
  }
  local path_label = source.root_dir and vim.fs.relpath(source.root_dir, representative)
    or representative
  return {
    id = boundary.id,
    name = boundary.name,
    kind = symbol_kinds[boundary.level] or vim.lsp.protocol.SymbolKind.Namespace,
    kind_name = boundary.kind_name,
    scope = "boundary",
    root_dir = source.root_dir,
    supports_calls = false,
    location = location,
    path = representative,
    path_label = path_label,
    line = location.range and location.range.start.line + 1 or nil,
    language = source.language,
    import_filetype = source.language,
    is_boundary = true,
    module_context = true,
    preserve_file_identity = true,
    enclosing_boundaries = vim.deepcopy(enclosing_boundaries or {}),
    boundary_id = boundary.id,
    boundary_class = boundary.class,
    boundary_level = boundary.level,
    boundary_path = vim.fs.normalize(boundary.path),
    boundary_keys = vim.deepcopy(boundary.import_keys or {}),
    boundary_evidence = vim.deepcopy(boundary.evidence),
  }
end

---@param source table
---@param resolved table[]
---@return table[]
function M.contexts(source, resolved)
  local contexts = {}
  for index = #resolved, 1, -1 do
    local enclosing = {}
    for outer = index + 1, #resolved do
      enclosing[#enclosing + 1] = contexts[outer]
    end
    contexts[index] = M.context(source, resolved[index], enclosing)
  end
  return contexts
end

---@param context table
---@return table
function M.attach(context)
  if not context or context.is_boundary or context.enclosing_boundaries then
    return context
  end
  local path = context.path
    or (context.location and context.location.uri and context.location.uri:match("^file:") and vim.uri_to_fname(
      context.location.uri
    ))
    or nil
  if not path or not context.language then
    return context
  end

  local resolved, err =
    adapters.resolve_boundaries(context.language, vim.fs.normalize(path), context.root_dir, context)
  if err then
    add_issue(context, err)
  elseif resolved then
    context.enclosing_boundaries = M.contexts(context, resolved)
  end
  return context
end

return M

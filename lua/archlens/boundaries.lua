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

function M.context(source, boundary)
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
    kind = vim.lsp.protocol.SymbolKind.Package,
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
    boundary_id = boundary.id,
    boundary_class = boundary.class,
    boundary_path = vim.fs.normalize(boundary.path),
    boundary_keys = vim.deepcopy(boundary.import_keys or {}),
    boundary_evidence = vim.deepcopy(boundary.evidence),
  }
end

---@param context table
---@return table
function M.attach(context)
  if not context or context.is_boundary or context.enclosing_boundary then
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

  local boundary, err =
    adapters.resolve_boundary(context.language, vim.fs.normalize(path), context.root_dir, context)
  if err then
    add_issue(context, err)
  elseif boundary then
    context.enclosing_boundary = M.context(context, boundary)
  end
  return context
end

return M

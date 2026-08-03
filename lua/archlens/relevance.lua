local graph = require("archlens.graph")

local M = {}

local function evidence_tier(row)
  local seen = {}
  local count = 0
  local exact = false
  local structural_only = true
  for _, evidence in ipairs(graph.evidence_records(row)) do
    local key = table.concat({ evidence.provider, evidence.method, evidence.class }, "\0")
    if not seen[key] then
      seen[key] = true
      count = count + 1
    end
    if evidence.class == "semantic" or evidence.class == "syntax" then
      exact = true
    end
    if evidence.class ~= "structural" then
      structural_only = false
    end
  end
  if exact then
    return count > 1 and 1 or 2
  end
  if structural_only and count > 0 then
    return 5
  end
  return count > 1 and 3 or 4
end

local function path_segments(path)
  local result = {}
  path = (path or ""):gsub("\\", "/")
  for segment in path:gmatch("[^/]+") do
    result[#result + 1] = segment
  end
  return result
end

local function location_path(uri)
  if not uri then
    return ""
  end
  if uri:match("^file:") then
    return vim.fs.normalize(vim.uri_to_fname(uri))
  end
  return uri
end

local function directory_distance(left_uri, right_uri)
  local left = path_segments(vim.fs.dirname(location_path(left_uri)))
  local right = path_segments(vim.fs.dirname(location_path(right_uri)))
  local common = 0
  while left[common + 1] and left[common + 1] == right[common + 1] do
    common = common + 1
  end
  return (#left - common) + (#right - common)
end

local function legacy_order(left, right, style)
  if style == "name" and left.name ~= right.name then
    return (left.name or "") < (right.name or "")
  end
  if left.path_label ~= right.path_label then
    return (left.path_label or "") < (right.path_label or "")
  end
  if left.line ~= right.line then
    return (left.line or 0) < (right.line or 0)
  end
  if left.name ~= right.name then
    return (left.name or "") < (right.name or "")
  end
  return nil
end

function M.sort(rows, relation, context)
  local focus_uri = context.location and context.location.uri or ""
  local ranks = {}
  for _, row in ipairs(rows) do
    local uri = row.location and row.location.uri or ""
    local start = row.location and row.location.range and row.location.range.start or {}
    ranks[row] = {
      tier = evidence_tier(row),
      same_file = uri == focus_uri,
      distance = directory_distance(focus_uri, uri),
      uri = uri,
      line = start.line or 0,
      character = start.character or 0,
    }
  end
  table.sort(rows, function(left, right)
    local left_rank = ranks[left]
    local right_rank = ranks[right]
    if left_rank.tier ~= right_rank.tier then
      return left_rank.tier < right_rank.tier
    end

    if left_rank.same_file ~= right_rank.same_file then
      return left_rank.same_file
    end

    if left_rank.distance ~= right_rank.distance then
      return left_rank.distance < right_rank.distance
    end

    local legacy = legacy_order(left, right, relation.sort)
    if legacy ~= nil then
      return legacy
    end

    if left_rank.uri ~= right_rank.uri then
      return left_rank.uri < right_rank.uri
    end
    if left_rank.line ~= right_rank.line then
      return left_rank.line < right_rank.line
    end
    if left_rank.character ~= right_rank.character then
      return left_rank.character < right_rank.character
    end
    return (left.id or "") < (right.id or "")
  end)
  return rows
end

return M

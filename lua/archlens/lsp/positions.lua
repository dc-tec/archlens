local M = {}

local internal_position_encoding = "utf-8"

local function buffer_line(bufnr, line)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) or not vim.api.nvim_buf_is_loaded(bufnr) then
    return nil
  end
  return vim.api.nvim_buf_get_lines(bufnr, line, line + 1, false)[1]
end

local function buffer_matches_uri(bufnr, uri)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return false
  end
  if vim.api.nvim_buf_get_name(bufnr) == uri then
    return true
  end
  local ok, buffer_uri = pcall(vim.uri_from_bufnr, bufnr)
  return ok and buffer_uri == uri
end

local function loaded_buffer_for_uri(uri, fallback_bufnr)
  if buffer_matches_uri(fallback_bufnr, uri) and vim.api.nvim_buf_is_loaded(fallback_bufnr) then
    return fallback_bufnr
  end
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) and buffer_matches_uri(bufnr, uri) then
      return bufnr
    end
  end
  return nil
end

local function uri_line(uri, line, fallback_bufnr)
  local loaded_bufnr = loaded_buffer_for_uri(uri, fallback_bufnr)
  if loaded_bufnr then
    return buffer_line(loaded_bufnr, line)
  end
  if type(uri) ~= "string" or not uri:match("^file:") then
    return nil
  end
  local ok, path = pcall(vim.uri_to_fname, uri)
  if not ok then
    return nil
  end
  local read_ok, lines = pcall(vim.fn.readfile, path, "", line + 1)
  return read_ok and lines[line + 1] or nil
end

local function converted_character(text, character, from_encoding, to_encoding)
  if character == nil then
    return nil
  end
  if character == 0 or from_encoding == to_encoding then
    return character
  end
  if not text then
    return nil
  end

  local byte_character = character
  if from_encoding ~= internal_position_encoding then
    local ok, converted = pcall(vim.str_byteindex, text, from_encoding, character, false)
    if not ok then
      return nil
    end
    byte_character = converted
  end
  if to_encoding == internal_position_encoding then
    return byte_character
  end

  local ok, converted = pcall(vim.str_utfindex, text, to_encoding, byte_character, false)
  return ok and converted or nil
end

function M.to_client(bufnr, position, encoding)
  if not position then
    return nil
  end
  local text = buffer_line(bufnr, position.line)
  local character =
    converted_character(text, position.character, internal_position_encoding, encoding or "utf-16")
  return character ~= nil and { line = position.line, character = character } or nil
end

function M.to_client_uri(uri, position, encoding, fallback_bufnr)
  if not position then
    return nil
  end
  local text = uri_line(uri, position.line, fallback_bufnr)
  local character =
    converted_character(text, position.character, internal_position_encoding, encoding or "utf-16")
  return character ~= nil and { line = position.line, character = character } or nil
end

function M.from_client(uri, position, encoding, fallback_bufnr)
  if not position then
    return nil
  end
  local text = uri_line(uri, position.line, fallback_bufnr)
  local character =
    converted_character(text, position.character, encoding or "utf-16", internal_position_encoding)
  return character ~= nil and { line = position.line, character = character } or nil
end

function M.range_from_client(uri, range, encoding, fallback_bufnr)
  if not range then
    return nil
  end
  local start = M.from_client(uri, range.start, encoding, fallback_bufnr)
  local finish = M.from_client(uri, range["end"], encoding, fallback_bufnr)
  return start and finish and { start = start, ["end"] = finish } or nil
end

function M.normalize_location(location, encoding, fallback_bufnr, origin_uri)
  if not location then
    return nil
  end
  if location.targetUri then
    local target_range =
      M.range_from_client(location.targetUri, location.targetRange, encoding, fallback_bufnr)
    local target_selection_range = M.range_from_client(
      location.targetUri,
      location.targetSelectionRange,
      encoding,
      fallback_bufnr
    )
    if not target_range or not target_selection_range then
      return nil
    end
    local normalized = {
      uri = location.targetUri,
      range = target_selection_range,
      full_range = target_range,
    }
    if location.originSelectionRange then
      normalized.origin_range = M.range_from_client(
        origin_uri or location.targetUri,
        location.originSelectionRange,
        encoding,
        fallback_bufnr
      )
    end
    return normalized
  end

  local range = M.range_from_client(location.uri, location.range, encoding, fallback_bufnr)
  if not range then
    return nil
  end
  return { uri = location.uri, range = range, full_range = range }
end

function M.location_list(value)
  if not value then
    return {}
  end
  if value.uri or value.targetUri then
    return { value }
  end
  return value
end

local function normalize_document_symbol(symbol, uri, encoding, fallback_bufnr)
  local normalized = vim.deepcopy(symbol)
  if symbol.location then
    normalized.location = M.normalize_location(symbol.location, encoding, fallback_bufnr)
    if not normalized.location then
      return nil
    end
  else
    normalized.range = M.range_from_client(uri, symbol.range, encoding, fallback_bufnr)
    normalized.selectionRange =
      M.range_from_client(uri, symbol.selectionRange, encoding, fallback_bufnr)
    if not normalized.range or not normalized.selectionRange then
      return nil
    end
  end
  normalized.children = nil
  if symbol.children then
    normalized.children = {}
    for _, child in ipairs(symbol.children) do
      local normalized_child = normalize_document_symbol(child, uri, encoding, fallback_bufnr)
      if normalized_child then
        normalized.children[#normalized.children + 1] = normalized_child
      end
    end
  end
  return normalized
end

function M.normalize_document_symbols(symbols, uri, encoding, fallback_bufnr)
  local normalized = {}
  for _, symbol in ipairs(symbols or {}) do
    local normalized_symbol = normalize_document_symbol(symbol, uri, encoding, fallback_bufnr)
    if normalized_symbol then
      normalized[#normalized + 1] = normalized_symbol
    end
  end
  return normalized
end

function M.normalize_hierarchy_item(item, encoding, fallback_bufnr)
  if not item then
    return nil
  end
  local normalized = vim.deepcopy(item)
  normalized.data = nil
  normalized.range = M.range_from_client(item.uri, item.range, encoding, fallback_bufnr)
  normalized.selectionRange =
    M.range_from_client(item.uri, item.selectionRange, encoding, fallback_bufnr)
  if not normalized.range or not normalized.selectionRange then
    return nil
  end
  return normalized
end

M.internal_encoding = internal_position_encoding

return M

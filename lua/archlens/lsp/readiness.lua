local M = {}

local attached_at = {}

local function now_ms()
  return vim.uv.hrtime() / 1000000
end

function M.record(client_id, timestamp_ms)
  if type(client_id) ~= "number" then
    return
  end
  attached_at[client_id] = timestamp_ms or now_ms()
end

function M.age(client_id, timestamp_ms)
  local attached = attached_at[client_id]
  if not attached then
    return nil
  end
  return math.max(0, (timestamp_ms or now_ms()) - attached)
end

function M.recent(client_id, window_ms, timestamp_ms)
  local age = M.age(client_id, timestamp_ms)
  return age ~= nil and age <= window_ms
end

function M.clear()
  attached_at = {}
end

return M

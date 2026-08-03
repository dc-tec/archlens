local M = {}

local function monotonic_ms()
  return vim.uv.hrtime() / 1000000
end

local function has_relationship(model)
  for _, section in ipairs(model and model.sections or {}) do
    if section.rows and #section.rows > 0 then
      return true
    end
  end
  return false
end

---@class ArchLensPerformanceRun
---@field started_at_ms number
---@field first_result_ms? number
---@field clock fun(): number

---@param clock? fun(): number
---@return ArchLensPerformanceRun
function M.start(clock)
  clock = clock or monotonic_ms
  return {
    started_at_ms = clock(),
    clock = clock,
  }
end

---@param run? ArchLensPerformanceRun
---@param model table
function M.observe(run, model)
  if run and run.first_result_ms == nil and has_relationship(model) then
    run.first_result_ms = math.max(0, run.clock() - run.started_at_ms)
  end
end

---@param run? ArchLensPerformanceRun
---@return { first_result_ms?: number }
function M.snapshot(run)
  if not run then
    return {}
  end
  return { first_result_ms = run.first_result_ms }
end

return M

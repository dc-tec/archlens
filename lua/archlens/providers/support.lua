local M = {}

function M.options(options, config)
  options = vim.deepcopy(options)
  options.filters = vim.deepcopy(config.filters)
  options.filters.include_external = config.include_external
  return options
end

return M

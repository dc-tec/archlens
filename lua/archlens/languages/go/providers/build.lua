local go_modules = require("archlens.languages.go.modules")
local go_packages = require("archlens.languages.go.packages")

local function import_options(context, config)
  local options = vim.deepcopy(config.imports.inbound)
  options.filters = vim.deepcopy(config.filters)
  options.filters.include_external = config.include_external
  options.filetype = context.import_filetype
  options.max_imports = config.imports.max_imports
  return options
end

return {
  id = "go",
  spec = {
    order = 19,
    label = "Go build",
    replaces = function(context)
      return go_packages.supports(context) and { "imports", "importers" } or {}
    end,
    enabled = function(context, _, config)
      local options = config.providers.go or {}
      return (go_packages.supports(context) or go_modules.supports(context))
        and options.enabled ~= false
        and config.imports.enabled
    end,
    tools = function(buffer, config)
      if buffer.language ~= "go" then
        return {}
      end
      local options = (config.providers and config.providers.go) or {}
      local import_config = config.imports or {}
      return {
        {
          id = "go",
          label = "Go tool",
          command = options.command or "go",
          enabled = options.enabled ~= false and import_config.enabled ~= false,
          disabled_message = "Go build-aware package analysis is disabled by the ArchLens configuration.",
          unavailable_message = "Go package relationships will fall back to Tree-sitter evidence.",
          version_label = "Go",
        },
      }
    end,
    start = function(context, source_buffer, config, done)
      local options = {
        build = config.providers.go or {},
        include_dependents = config.imports.inbound.enabled,
        max_imports = config.imports.max_imports,
        max_importers = config.imports.inbound.max_importers,
      }
      if go_modules.supports(context) then
        return go_modules.relationships(context, source_buffer, options, done)
      end
      options.imports = import_options(context, config)
      return go_packages.relationships(context, source_buffer, options, done)
    end,
    clear_cache = function(root)
      go_packages.clear_cache(root)
      go_modules.clear_cache(root)
    end,
  },
}

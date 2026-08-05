local import_index = require("archlens.import_index")
local support = require("archlens.providers.support")
local treesitter = require("archlens.treesitter")

return {
  id = "importers",
  spec = {
    order = 30,
    label = function(context)
      return context.is_boundary and "Package dependents" or "Module dependents"
    end,
    enabled = function(context, source_buffer, config)
      if context.is_boundary then
        return context.boundary_level == "package"
          and config.imports.enabled
          and config.imports.inbound.enabled
          and (treesitter.supports_imports(source_buffer) or context.import_filetype)
      end
      return config.imports.enabled
        and config.imports.inbound.enabled
        and (treesitter.supports_imports(source_buffer) or context.import_filetype)
        and (
          not context.enclosing_boundaries
          or #context.enclosing_boundaries == 0
          or config.imports.show_on_symbols == true
        )
    end,
    start = function(context, source_buffer, config, done)
      local options = support.options(config.imports.inbound, config)
      options.filetype = context.import_filetype
      if context.is_boundary and context.boundary_level == "package" then
        return import_index.dependents(context, source_buffer, options, done)
      end
      return import_index.relationships(context, source_buffer, options, done)
    end,
  },
}

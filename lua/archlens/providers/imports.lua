local import_index = require("archlens.import_index")
local imports = require("archlens.imports")
local support = require("archlens.providers.support")
local treesitter = require("archlens.treesitter")

return {
  id = "imports",
  spec = {
    order = 20,
    label = function(context)
      return context.is_boundary and "Package dependencies" or "Module dependencies"
    end,
    enabled = function(context, source_buffer, config)
      if context.is_boundary then
        return context.boundary_level == "package"
          and config.imports.enabled
          and treesitter.supports_imports(source_buffer)
      end
      return config.imports.enabled
        and treesitter.supports_imports(source_buffer)
        and (
          not context.enclosing_boundaries
          or #context.enclosing_boundaries == 0
          or config.imports.show_on_symbols == true
        )
    end,
    start = function(context, source_buffer, config, done)
      if context.is_boundary and context.boundary_level == "package" then
        local options = support.options(config.imports.inbound, config)
        options.filetype = context.import_filetype
        options.max_imports = config.imports.max_imports
        return import_index.dependencies(context, source_buffer, options, done)
      end
      return imports.relationships(
        context,
        source_buffer,
        support.options(config.imports, config),
        done
      )
    end,
    clear_cache = imports.clear_cache,
  },
}

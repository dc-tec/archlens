local cargo = require("archlens.languages.rust.cargo")

return {
  id = "rust",
  spec = {
    order = 19,
    label = "Cargo",
    replaces = function(context)
      return cargo.supports(context)
          and context.boundary_level == "package"
          and { "imports", "importers" }
        or {}
    end,
    enabled = function(context, _, config)
      local options = config.providers.rust or {}
      return cargo.supports(context) and options.enabled ~= false and config.imports.enabled
    end,
    tools = function(buffer, config)
      if buffer.language ~= "rust" then
        return {}
      end
      local options = (config.providers and config.providers.rust) or {}
      return {
        {
          id = "cargo",
          label = "Cargo",
          command = options.command or "cargo",
          enabled = options.enabled ~= false,
          disabled_message = "Cargo package and workspace analysis is disabled by the ArchLens configuration.",
          unavailable_message = "Cargo package and workspace relationships are unavailable.",
          version_label = "Cargo",
        },
      }
    end,
    start = function(context, source_buffer, config, done)
      return cargo.relationships(context, source_buffer, {
        build = config.providers.rust or {},
        include_dependents = config.imports.inbound.enabled,
        max_imports = config.imports.max_imports,
        max_importers = config.imports.inbound.max_importers,
      }, done)
    end,
    clear_cache = cargo.clear_cache,
  },
}

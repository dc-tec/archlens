local ast_grep = require("archlens.ast_grep")
local support = require("archlens.providers.support")

return {
  id = "ast_grep",
  spec = {
    order = 40,
    label = "ast-grep",
    queued = function(config)
      return config.ast_grep.enabled
    end,
    enabled = function(context, _, config)
      return config.ast_grep.enabled and not context.module_context and not context.configuration
    end,
    start = function(context, _, config, done)
      return ast_grep.relationships(context, support.options(config.ast_grep, config), done)
    end,
  },
}

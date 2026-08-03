local ast_grep = require("archlens.ast_grep")
local containers = require("archlens.containers")
local graph = require("archlens.graph")
local import_index = require("archlens.import_index")
local imports = require("archlens.imports")
local lsp = require("archlens.lsp")
local treesitter = require("archlens.treesitter")

local M = {}

local function provider_options(options, config)
  options = vim.deepcopy(options)
  options.filters = vim.deepcopy(config.filters)
  options.filters.include_external = config.include_external
  return options
end

function M.local_pending(config)
  local pending = { { id = "lsp", label = "LSP" } }
  if config.ast_grep.enabled then
    pending[#pending + 1] = { id = "ast_grep", label = "ast-grep" }
  end
  return pending
end

local function tasks_for(context, source_buffer, config)
  local tasks = {}

  if context.client_id and not context.module_context then
    tasks[#tasks + 1] = {
      id = "lsp",
      label = context.client_name or "LSP",
      start = function(done)
        local grouping_cancel = function() end
        local lsp_cancel = lsp.relationships(context, source_buffer, function(result)
          if not config.grouping.enabled then
            done(result)
            return
          end
          grouping_cancel =
            containers.enrich(result, context, provider_options(config.grouping, config), done)
        end, {
          timeout_ms = config.lsp.relationship_timeout_ms,
        })
        return function()
          pcall(lsp_cancel)
          pcall(grouping_cancel)
        end
      end,
    }
  end

  local local_imports = treesitter.supports_imports(source_buffer)
  if config.imports.enabled and local_imports then
    tasks[#tasks + 1] = {
      id = "imports",
      label = "Module dependencies",
      start = function(done)
        return imports.relationships(
          context,
          source_buffer,
          provider_options(config.imports, config),
          done
        )
      end,
    }
  end

  if
    config.imports.enabled
    and config.imports.inbound.enabled
    and (local_imports or context.import_filetype)
  then
    tasks[#tasks + 1] = {
      id = "importers",
      label = "Module dependents",
      start = function(done)
        local options = provider_options(config.imports.inbound, config)
        options.filetype = context.import_filetype
        return import_index.relationships(context, source_buffer, options, done)
      end,
    }
  end

  if config.ast_grep.enabled and not context.module_context and not context.configuration then
    tasks[#tasks + 1] = {
      id = "ast_grep",
      label = "ast-grep",
      start = function(done)
        return ast_grep.relationships(context, provider_options(config.ast_grep, config), done)
      end,
    }
  end

  return tasks
end

function M.run(context, source_buffer, config, controls)
  local relationships = graph.new(context)
  local tasks = tasks_for(context, source_buffer, config)
  local pending = {}
  for _, task in ipairs(tasks) do
    pending[task.id] = true
  end

  local function update()
    if not controls.is_current() then
      return
    end
    local pending_providers = {}
    for _, task in ipairs(tasks) do
      if pending[task.id] then
        pending_providers[#pending_providers + 1] = { id = task.id, label = task.label }
      end
    end
    graph.set_pending(relationships, pending_providers)
    controls.on_update(relationships)
  end

  -- Local Tree-sitter context is already available. Publish it before any
  -- project-wide provider can complete synchronously.
  update()

  for _, task in ipairs(tasks) do
    local completed = false
    local function done(result)
      if completed or not controls.is_current() then
        return
      end
      completed = true
      graph.merge(relationships, result or graph.delta())
      pending[task.id] = nil
      update()
    end

    local ok, cancel_or_error = pcall(task.start, done)
    if ok then
      controls.register_cancel(cancel_or_error)
    elseif not completed and controls.is_current() then
      completed = true
      pending[task.id] = nil
      graph.add_error(
        relationships,
        string.format("%s failed to start: %s", task.label, tostring(cancel_or_error))
      )
      update()
    end
  end

  return relationships
end

function M.clear_cache(root)
  imports.clear_cache(root)
  containers.clear_cache()
end

return M

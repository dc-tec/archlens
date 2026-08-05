local modules = {
  "archlens.providers.lsp",
}

for _, language in ipairs(require("archlens.languages.builtins")) do
  vim.list_extend(modules, language.providers or {})
end

vim.list_extend(modules, {
  "archlens.providers.imports",
  "archlens.providers.importers",
  "archlens.providers.ast_grep",
})

return modules

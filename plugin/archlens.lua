if vim.g.loaded_archlens == 1 then
  return
end
vim.g.loaded_archlens = 1

local bootstrap_group = vim.api.nvim_create_augroup("archlens_bootstrap", { clear = true })

vim.api.nvim_create_autocmd("LspAttach", {
  group = bootstrap_group,
  callback = function(event)
    if event.data and event.data.client_id then
      require("archlens.lsp.readiness").record(event.data.client_id)
    end
  end,
})

vim.api.nvim_create_user_command("ArchLensHere", function()
  require("archlens").show_here()
end, { desc = "Explore relationships around the symbol under the cursor" })

vim.api.nvim_create_user_command("ArchLensRefresh", function()
  require("archlens").refresh()
end, { desc = "Refresh the current ArchLens focus" })

vim.api.nvim_create_user_command("ArchLensClose", function()
  require("archlens").close()
end, { desc = "Close the ArchLens pane" })

if vim.g.loaded_archlens == 1 then
  return
end
vim.g.loaded_archlens = 1

local archlens = require("archlens")
archlens.setup()

vim.api.nvim_create_user_command("ArchLensHere", function()
  archlens.show_here()
end, { desc = "Explore relationships around the symbol under the cursor" })

vim.api.nvim_create_user_command("ArchLensRefresh", function()
  archlens.refresh()
end, { desc = "Refresh the current ArchLens" })

vim.api.nvim_create_user_command("ArchLensClose", function()
  archlens.close()
end, { desc = "Close the current ArchLens" })

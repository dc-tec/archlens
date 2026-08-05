local common = require("archlens.adapter_support")

local function normalize_import(_, text, source, metadata)
  local source_file = common.source_path(source, metadata)
  if not source_file or source_file == "" then
    return { name = text }
  end
  local path = text:sub(1, 1) == "/" and text or vim.fs.joinpath(vim.fs.dirname(source_file), text)
  local stat = vim.uv.fs_stat(path)
  if stat and stat.type == "directory" then
    path = vim.fs.joinpath(path, "default.nix")
  end
  return { name = text, target_paths = common.existing_paths({ path }) }
end

return {
  spec = {
    treesitter = {
      symbol_types = {
        binding = "Binding",
        inherit = "Binding",
      },
      imports = {
        extensions = { ".nix" },
        query = [[
          ((apply_expression
            function: (variable_expression
              name: (identifier) @_function)
            argument: (path_expression) @import)
            (#eq? @_function "import"))

          ((binding
            attrpath: (attrpath) @_imports
            expression: (list_expression
              element: (path_expression) @import))
            (#eq? @_imports "imports"))
        ]],
        normalize = normalize_import,
      },
    },
    ast_grep = { language = "nix" },
  },
}

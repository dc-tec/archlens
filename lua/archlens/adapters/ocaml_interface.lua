local ocaml = require("archlens.adapters.ocaml")

return {
  spec = {
    filetypes = { "ocamlinterface" },
    filename_extensions = { ".mli" },
    presentation = { section = ocaml.section_presentation },
    treesitter = {
      focus_wrappers = { type_definition = true },
      name_node_types = ocaml.name_node_types,
      symbol_types = {
        class_specification = "Class",
        constructor_declaration = "EnumMember",
        field_declaration = "Field",
        module_specification = "Module",
        module_type_definition = "Module",
        tag_specification = "EnumMember",
        type_binding = "Type",
        value_specification = "Value",
      },
      imports = {
        extensions = { ".mli" },
        scan_languages = { "ocaml", "ocaml_interface" },
        query = [[
          [
            (open_module module: (_) @import)
            (include_module_type module_type: (_) @import)
          ]
        ]],
        normalize = ocaml.normalize_import,
      },
    },
    ast_grep = { unsupported_note = ocaml.unsupported_note },
  },
}

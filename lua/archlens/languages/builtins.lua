return {
  {
    id = "go",
    adapter = "archlens.languages.go.adapter",
    providers = { "archlens.languages.go.providers.build" },
  },
  { id = "nix", adapter = "archlens.languages.nix.adapter" },
  { id = "ocaml", adapter = "archlens.languages.ocaml.adapter" },
  { id = "ocaml_interface", adapter = "archlens.languages.ocaml.interface" },
  { id = "rust", adapter = "archlens.languages.rust.adapter" },
  { id = "javascript", adapter = "archlens.languages.javascript.adapter" },
  { id = "lua", adapter = "archlens.languages.lua.adapter" },
  { id = "python", adapter = "archlens.languages.python.adapter" },
  { id = "tsx", adapter = "archlens.languages.typescript.tsx" },
  { id = "typescript", adapter = "archlens.languages.typescript.adapter" },
}

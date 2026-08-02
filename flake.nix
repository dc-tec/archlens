{
  description = "Human-first architectural relationship lens for Neovim";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    flake-parts.url = "github:hercules-ci/flake-parts";

    nixvim = {
      url = "github:nix-community/nixvim";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    inputs@{
      flake-parts,
      nixvim,
      ...
    }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [
        "aarch64-darwin"
        "aarch64-linux"
        "x86_64-darwin"
        "x86_64-linux"
      ];

      perSystem =
        {
          lib,
          pkgs,
          system,
          ...
        }:
        let
          archlens = pkgs.vimUtils.buildVimPlugin {
            pname = "archlens.nvim";
            version = "0.1.0-dev";
            src = ./.;
          };

          nixvim' = nixvim.legacyPackages.${system};
          testNeovim = nixvim'.makeNixvimWithModule {
            inherit pkgs;
            module = {
              extraPlugins = [ archlens ];
              extraPackagesAfter = [ pkgs.ast-grep ];

              plugins.treesitter = {
                enable = true;
                grammarPackages = with pkgs.vimPlugins.nvim-treesitter.builtGrammars; [
                  go
                  nix
                  ocaml
                  ocaml_interface
                  rust
                ];
              };

              extraConfigLua = ''
                require("archlens").setup({
                  ast_grep = {
                    command = "${lib.getExe pkgs.ast-grep}",
                  },
                })
              '';
            };
          };
        in
        {
          packages = {
            default = archlens;
            test-neovim = testNeovim;
          };

          checks = {
            package = archlens;

            unit = pkgs.runCommand "archlens-unit-tests" { nativeBuildInputs = [ pkgs.neovim-unwrapped ]; } ''
              export HOME="$TMPDIR/home"
              mkdir -p "$HOME"
              ${lib.getExe pkgs.neovim-unwrapped} --headless -u NONE --noplugin -i NONE \
                --cmd 'set runtimepath^=${./.}' \
                -l ${./tests/run.lua}
              touch "$out"
            '';

            integration =
              pkgs.runCommand "archlens-integration-tests"
                {
                  nativeBuildInputs = [
                    pkgs.ast-grep
                    testNeovim
                  ];
                }
                ''
                  export HOME="$TMPDIR/home"
                  export XDG_CACHE_HOME="$TMPDIR/cache"
                  export XDG_CONFIG_HOME="$TMPDIR/config"
                  export XDG_DATA_HOME="$TMPDIR/data"
                  export XDG_STATE_HOME="$TMPDIR/state"
                  mkdir -p "$HOME" "$XDG_CACHE_HOME" "$XDG_CONFIG_HOME" "$XDG_DATA_HOME" "$XDG_STATE_HOME"

                  nvim --headless -i NONE \
                    '+lua assert(require("archlens")); assert(vim.fn.exists(":ArchLensHere") == 2)' \
                    +qa

                  ARCHLENS_FIXTURE_ROOT=${./tests/fixtures/project} \
                    ARCHLENS_AST_GREP=${lib.getExe pkgs.ast-grep} \
                    nvim --headless -i NONE -l ${./tests/integration.lua}

                  touch "$out"
                '';

            formatting = pkgs.runCommand "archlens-formatting" { nativeBuildInputs = [ pkgs.stylua ]; } ''
              cd ${./.}
              stylua --check lua plugin tests
              touch "$out"
            '';
          };

          formatter = pkgs.nixfmt-tree;

          devShells.default = pkgs.mkShell {
            packages = [
              pkgs.ast-grep
              pkgs.lua-language-server
              pkgs.nixfmt-tree
              pkgs.stylua
              testNeovim
            ];
          };
        };
    };
}

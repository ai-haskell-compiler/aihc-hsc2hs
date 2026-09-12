{
  description = "Clang/object-file hsc2hs replacement: reproducible Stackage compatibility infrastructure";
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
  inputs.darwinCrossNixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-26.05-darwin";
  outputs =
    { nixpkgs, darwinCrossNixpkgs, ... }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
      ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
      projectFor =
        system:
        import ./nix {
          pkgs = import nixpkgs { inherit system; };
          inherit darwinCrossNixpkgs;
        };
    in
    {
      packages = forAllSystems (
        system:
        let
          project = projectFor system;
        in
        {
          default = project.candidate;
          aihc-hsc2hs = project.candidate;
          mvp-tests = project.mvpTests;
          stackage-hsc = project.corpus;
          corpus-context-inputs = project.corpusContexts.inputs;
          corpus-context-info = project.corpusContexts.infoTool;
          corpus-native-toolchain = project.nativeCorpusToolchain;
          comparison-runner = project.comparisonRunner;
          reference-modes = project.referenceModes;
        }
        // nixpkgs.lib.optionalAttrs (system != "x86_64-linux") {
          stackage-native = project.corpusComparison "native";
          stackage-native-report = project.corpusReport "native";
        }
        // nixpkgs.lib.optionalAttrs (system == "aarch64-darwin") {
          corpus-cross-context-inputs = project.crossCorpusContexts.inputs;
          corpus-cross-ghc = project.crossPkgs.haskellPackages.ghc;
          corpus-cross-toolchain = project.crossCorpusToolchain;
          stackage-cross = project.corpusComparison "cross";
          stackage-cross-report = project.corpusReport "cross";
        }
      );
      checks = forAllSystems (
        system:
        let
          project = projectFor system;
        in
        {
          harness = project.harnessTests;
          candidate = project.candidate;
          mvp = project.mvpTests;
          reference-modes = project.referenceModes;
          stackage-hsc = project.corpus;
        }
        // nixpkgs.lib.optionalAttrs (system != "x86_64-linux") {
          stackage-native = project.corpusComparison "native";
        }
        // nixpkgs.lib.optionalAttrs (system == "aarch64-darwin") {
          stackage-cross = project.corpusComparison "cross";
        }
      );
      lib.mkComparison =
        { system, ... }@args: (projectFor system).mkComparison (builtins.removeAttrs args [ "system" ]);
      devShells = forAllSystems (
        system:
        let
          pkgs = import nixpkgs { inherit system; };
        in
        {
          default = pkgs.mkShell {
            packages = [
              pkgs.llvmPackages.clang
              pkgs.llvmPackages.llvm
              (pkgs.haskellPackages.ghcWithPackages (p: [ p.temporary ]))
              pkgs.haskellPackages.hsc2hs
              pkgs.cabal-install
              pkgs.python3
              pkgs.nixfmt
              pkgs.pkg-config
              pkgs.autoconf
              pkgs.automake
            ];
          };
        }
      );
      formatter = forAllSystems (system: (import nixpkgs { inherit system; }).nixfmt);
    };
}

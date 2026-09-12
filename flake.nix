{
  description = "Clang/object-file hsc2hs replacement: reproducible Stackage compatibility infrastructure";
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
  outputs =
    { nixpkgs, ... }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
      ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
      projectFor = system: import ./nix { pkgs = import nixpkgs { inherit system; }; };
    in
    {
      packages = forAllSystems (
        system:
        let
          project = projectFor system;
        in
        {
          default = project.corpus;
          stackage-hsc = project.corpus;
          comparison-runner = project.comparisonRunner;
          reference-modes = project.referenceModes;
        }
      );
      checks = forAllSystems (
        system:
        let
          project = projectFor system;
        in
        {
          harness = project.harnessTests;
          reference-modes = project.referenceModes;
          stackage-hsc = project.corpus;
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
              pkgs.haskellPackages.ghc
              pkgs.haskellPackages.hsc2hs
              pkgs.cabal-install
              pkgs.python3
              pkgs.nixfmt
            ];
          };
        }
      );
      formatter = forAllSystems (system: (import nixpkgs { inherit system; }).nixfmt);
    };
}

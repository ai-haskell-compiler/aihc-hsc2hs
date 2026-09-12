{ pkgs }:
let
  lib = pkgs.lib;
  source = lib.cleanSource ../.;
  manifest = builtins.fromJSON (builtins.readFile ../data/stackage.json);
  archives = builtins.listToAttrs (
    map (package: {
      name = package.name;
      value = pkgs.fetchurl {
        inherit (package) url sha256;
        name = "${package.name}.tar.gz";
      };
    }) manifest.packages
  );
  archivePaths = pkgs.writeText "stackage-archive-paths.json" (builtins.toJSON archives);
  corpus =
    pkgs.runCommand "stackage-hsc-${manifest.snapshot}"
      {
        nativeBuildInputs = [ pkgs.python3 ];
      }
      ''
        python ${../tools/corpus.py} ${../data/stackage.json} ${archivePaths} "$out"
      '';
  comparisonRunner = pkgs.writeShellApplication {
    name = "hsc2hs-compare";
    runtimeInputs = [ pkgs.python3 ];
    text = ''exec python ${../tools/compare.py} "$@"'';
  };
  # Context paths, sysroots and tool commands in config retain their Nix closure
  # through builtins.toJSON. No network or package configuration is done here.
  mkComparison =
    {
      name,
      config,
      expected,
      nativeBuildInputs ? [ ],
    }:
    let
      configFile = pkgs.writeText "${name}-config.json" (builtins.toJSON config);
    in
    pkgs.runCommand name
      {
        nativeBuildInputs = [ comparisonRunner ] ++ nativeBuildInputs;
      }
      ''
        hsc2hs-compare --config ${configFile} --expected ${expected} --output "$out"
      '';
  harnessTests =
    pkgs.runCommand "hsc2hs-comparison-harness-tests"
      {
        nativeBuildInputs = [ pkgs.python3 ];
      }
      ''
        export PYTHONDONTWRITEBYTECODE=1
        cd ${source}
        python -m unittest discover -s tests -v
        touch "$out"
      '';
  referenceModes =
    pkgs.runCommand "hsc2hs-upstream-mode-contract"
      {
        nativeBuildInputs = [
          pkgs.python3
          pkgs.haskellPackages.hsc2hs
          pkgs.stdenv.cc
        ];
      }
      ''
        python ${../tests/reference_modes.py} ${../tests/fixtures} "$out"
      '';
in
{
  inherit
    corpus
    comparisonRunner
    mkComparison
    harnessTests
    referenceModes
    ;
}

{ pkgs }:
let
  lib = pkgs.lib;
  source = lib.cleanSourceWith {
    src = ../.;
    filter =
      path: type:
      lib.cleanSourceFilter path type
      && !(builtins.elem (baseNameOf path) [
        "dist-newstyle"
        ".direnv"
        "__pycache__"
      ]);
  };
  candidate = pkgs.haskellPackages.mkDerivation {
    pname = "aihc-hsc2hs";
    version = "0.1.0.0";
    src = source;
    isLibrary = true;
    isExecutable = true;
    libraryHaskellDepends = with pkgs.haskellPackages; [
      base
      bytestring
      containers
      directory
      filepath
      process
      temporary
    ];
    executableHaskellDepends = with pkgs.haskellPackages; [
      base
      directory
      filepath
    ];
    testHaskellDepends = with pkgs.haskellPackages; [
      base
      bytestring
      containers
      directory
      filepath
      process
      temporary
    ];
    license = lib.licenses.unlicense;
  };
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
  mvpTests =
    pkgs.runCommand "aihc-hsc2hs-mvp-tests"
      {
        nativeBuildInputs = [
          pkgs.python3
          pkgs.llvmPackages.clang
          pkgs.haskellPackages.hsc2hs
        ];
      }
      ''
        export PYTHONDONTWRITEBYTECODE=1
        python ${source}/tests/mvp.py \
          --candidate ${candidate}/bin/aihc-hsc2hs \
          --reference ${pkgs.haskellPackages.hsc2hs}/bin/hsc2hs \
          --clang ${pkgs.llvmPackages.clang}/bin/clang \
          --target ${pkgs.stdenv.hostPlatform.config} \
          ${lib.optionalString pkgs.stdenv.isDarwin "--cross-target x86_64-apple-darwin"} \
          --sysroot ${
            if pkgs.stdenv.isDarwin then
              "${pkgs.apple-sdk}/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"
            else
              lib.getDev pkgs.stdenv.cc.libc
          } \
          --output "$out"
      '';
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
    candidate
    mvpTests
    corpus
    comparisonRunner
    mkComparison
    harnessTests
    referenceModes
    ;
}

{ pkgs, darwinCrossNixpkgs }:
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
  candidateSource = lib.fileset.toSource {
    root = ../.;
    fileset = lib.fileset.unions [
      ../src
      ../app
      ../test
      ../aihc-hsc2hs.cabal
      ../LICENSE
      ../README.md
    ];
  };
  runnerSource = lib.fileset.toSource {
    root = ../.;
    fileset = lib.fileset.unions [
      ../tools/stackage.py
      ../tools/compare.py
      ../data/corpus-platforms.json
    ];
  };
  candidate = pkgs.haskellPackages.mkDerivation {
    pname = "aihc-hsc2hs";
    version = "0.1.0.0";
    src = candidateSource;
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
  corpusContexts = import ./corpus-contexts.nix { inherit pkgs corpus source; };
  crossPkgs =
    if pkgs.stdenv.isDarwin then
      import darwinCrossNixpkgs { system = "x86_64-darwin"; }
    else
      throw "The measured corpus cross toolchain currently requires an aarch64-darwin host";
  crossCorpusContexts = import ./corpus-contexts.nix {
    pkgs = crossPkgs;
    buildPkgs = pkgs;
    inherit corpus source;
  };
  toolchain =
    targetPkgs:
    pkgs.writeText "stackage-toolchain.json" (
      builtins.toJSON {
        corpus = toString corpus;
        info = "${corpusContexts.infoTool}/bin/context-info";
        candidate = "${candidate}/bin/aihc-hsc2hs";
        reference = "${pkgs.haskellPackages.hsc2hs}/bin/hsc2hs";
        clang = "${
          if
            targetPkgs.stdenv.isDarwin
            && targetPkgs.stdenv.hostPlatform.config != pkgs.stdenv.hostPlatform.config
          then
            pkgs.llvmPackages.clang-unwrapped
          else
            pkgs.llvmPackages.clang
        }/bin/clang";
        configure_clang = "${pkgs.llvmPackages.clang}/bin/clang";
        target = targetPkgs.stdenv.hostPlatform.config;
        arch = targetPkgs.stdenv.hostPlatform.parsed.cpu.name;
        abi_flags =
          if targetPkgs.stdenv.hostPlatform.parsed.cpu.name == "aarch64" then
            [ (if targetPkgs.stdenv.isDarwin then "-mabi=darwinpcs" else "-mabi=aapcs") ]
          else
            [ "-m64" ];
        os = if targetPkgs.stdenv.isDarwin then "osx" else "linux";
        build_triple = pkgs.stdenv.hostPlatform.config;
        ghc_libdir = "${targetPkgs.haskellPackages.ghc}/lib/ghc-${targetPkgs.haskellPackages.ghc.version}";
        sysroot =
          if targetPkgs.stdenv.isDarwin then
            "${pkgs.apple-sdk}/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"
          else
            toString (lib.getDev targetPkgs.stdenv.cc.libc);
      }
    );
  nativeCorpusToolchain = toolchain pkgs;
  crossCorpusToolchain = toolchain crossPkgs;
  corpusReport =
    mode:
    let
      cross = mode == "cross";
      inputs = if cross then crossCorpusContexts.inputs else corpusContexts.inputs;
      chain = if cross then crossCorpusToolchain else nativeCorpusToolchain;
    in
    pkgs.runCommand "stackage-hsc-${mode}-report"
      {
        nativeBuildInputs = [
          pkgs.python3
          pkgs.pkg-config
          pkgs.autoconf
          pkgs.automake
          pkgs.haskellPackages.ghc
          pkgs.llvmPackages.clang
        ];
      }
      ''
        export PYTHONDONTWRITEBYTECODE=1
        python ${runnerSource}/tools/stackage.py --toolchain ${chain} --inputs ${inputs} \
          --mode ${mode} --workers 6 --timeout 1800 --report-only --output "$out"
      '';
  corpusComparison =
    mode:
    let
      report = corpusReport mode;
      baseline = ../data/baselines + "/${pkgs.stdenv.hostPlatform.system}-${mode}.json";
    in
    pkgs.runCommand "stackage-hsc-${mode}-comparison" { nativeBuildInputs = [ pkgs.python3 ]; } ''
      export PYTHONPATH=${runnerSource}/tools
      export PYTHONDONTWRITEBYTECODE=1
      python - ${report}/report/summary.json ${baseline} <<'PY'
      import compare, json, sys
      with open(sys.argv[1]) as actual, open(sys.argv[2]) as expected:
          compare.assert_expected(json.load(actual), json.load(expected))
      PY
      ln -s ${report} "$out"
    '';
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
        python tests/context_info.py ${corpusContexts.infoTool}/bin/context-info
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
    corpusContexts
    crossCorpusContexts
    crossPkgs
    nativeCorpusToolchain
    crossCorpusToolchain
    corpusComparison
    corpusReport
    mvpTests
    corpus
    comparisonRunner
    mkComparison
    harnessTests
    referenceModes
    ;
}

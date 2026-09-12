{
  pkgs,
  corpus,
  source,
  buildPkgs ? pkgs,
}:
let
  lib = pkgs.lib;
  pins = builtins.fromJSON (builtins.readFile ../data/corpus-cabal.json);
  discount2 = pkgs.discount.overrideAttrs (old: {
    version = "2.2.7";
    src = pkgs.fetchurl {
      url = "https://github.com/Orc/discount/archive/refs/tags/v2.2.7.tar.gz";
      hash = "sha256-csEyXd/ECHHWgQ8eJyzy1Fs2HyY1frOPFw/QTXN7ufI=";
    };
    enableParallelBuilding = false;
    env = (old.env or { }) // {
      NIX_CFLAGS_COMPILE =
        (old.env.NIX_CFLAGS_COMPILE or "")
        + " -std=gnu99 -Wno-error=implicit-function-declaration -Wno-error=incompatible-pointer-types"
        + lib.optionalString pkgs.stdenv.isDarwin " -Wno-error=incompatible-function-pointer-types";
    };
  });
  # C interfaces used through Haskell dependencies or compiler packages are
  # not always listed in the direct Nixpkgs dependency record.
  additional = {
    check-email = lib.optionals pkgs.stdenv.isDarwin [ pkgs.darwin.libresolv ];
    hasql = [ pkgs.libpq ];
    postgresql-libpq = [ pkgs.libpq ];
    hmatrix-special = [ pkgs.gsl ];
    x11-xim = [ pkgs.xorg.libX11 ];
    libffi = [ pkgs.libffi ];
    ghc-lib-parser = [ pkgs.libffi ];
    ghc-internal = lib.optionals pkgs.stdenv.isDarwin [ pkgs.libiconv ];
    coinor-clp = [
      pkgs.clp
      pkgs.coin-utils
    ];
    alsa-pcm = [ pkgs.alsa-lib ];
    alsa-seq = [ pkgs.alsa-lib ];
  };
  infoTool =
    pkgs.runCommand "hsc-cabal-context-info"
      {
        nativeBuildInputs = [ pkgs.haskellPackages.ghc ];
      }
      ''
        mkdir -p "$out/bin"
        ghc -package-env - -package Cabal ${../tools/context-info.hs} -o "$out/bin/context-info"
      '';
  describe =
    pin:
    let
      name = lib.removeSuffix ".cabal" pin.file;
      attempt = builtins.tryEval (
        let
          package = pkgs.haskellPackages.${name};
          deps = package.getCabalDeps;
          providers =
            if name == "discount" then
              [ discount2 ]
            else
              lib.unique (
                (additional.${name} or [ ])
                ++ lib.concatLists (
                  builtins.attrValues (
                    lib.filterAttrs (
                      n: _:
                      lib.hasInfix "System" n
                      || lib.hasInfix "Pkgconfig" n
                      || n == "extraLibraries"
                      || n == "pkg-configDepends"
                    ) deps
                  )
                )
              );
          result = {
            available =
              lib.meta.availableOn pkgs.stdenv.hostPlatform package
              && builtins.all (lib.meta.availableOn pkgs.stdenv.hostPlatform) providers;
            paths = map (d: toString (lib.getDev d)) providers;
            libraries = map (d: toString (lib.getLib d)) providers;
            names = map (d: d.name) providers;
            inherit providers;
          };
        in
        assert builtins.isAttrs package && package ? getCabalDeps;
        assert builtins.all builtins.isAttrs providers;
        builtins.deepSeq (builtins.removeAttrs result [ "providers" ]) result
      );
    in
    if attempt.success then
      attempt.value
    else
      let
        providers = additional.${name} or [ ];
      in
      {
        available = builtins.all (lib.meta.availableOn pkgs.stdenv.hostPlatform) providers;
        paths = map (d: toString (lib.getDev d)) providers;
        libraries = map (d: toString (lib.getLib d)) providers;
        names = map (d: d.name) providers;
        inherit providers;
        providerError = "Nixpkgs package dependency metadata could not be evaluated";
      };
  metadata = map (
    pin:
    let
      d = describe pin;
    in
    pin
    // (
      if d.available then
        builtins.removeAttrs d [ "providers" ]
      else
        {
          available = false;
          paths = [ ];
          libraries = [ ];
          names = [ ];
        }
    )
    // {
      link_closure =
        if d.available && pkgs.stdenv.isLinux then
          "${buildPkgs.closureInfo { rootPaths = d.providers ++ [ pkgs.stdenv.cc.libc ]; }}/store-paths"
        else
          null;
      cabal =
        if pin.archive or false then
          "${corpus}/sources/${pin.package}/${pin.file}"
        else
          toString (pkgs.fetchurl { inherit (pin) url sha256; });
    }
  ) pins;
in
{
  inherit infoTool;
  inputs = buildPkgs.writeText "stackage-c-context-inputs.json" (builtins.toJSON metadata);
}

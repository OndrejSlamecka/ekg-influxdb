{ nixpkgs ? import <nixpkgs> {}, compiler ? "default" }:

let

  inherit (nixpkgs) pkgs;

  f = { mkDerivation, base, ekg-core, libinfluxdb, stdenv }:
      mkDerivation {
        pname = "ekg-influxdb";
        version = "0.1.0.0";
        src = ./.;
        libraryHaskellDepends = [ base ekg-core libinfluxdb ];
        homepage = "https://github.com/angerman/ekg-influxdb";
        description = "An EKG backend to send statistics to influxdb";
        license = stdenv.lib.licenses.bsd3;
      };

  haskellPackages = if compiler == "default"
                       then pkgs.haskellPackages
                       else pkgs.haskell.packages.${compiler};

  drv = haskellPackages.callPackage f {};

in

  if pkgs.lib.inNixShell then drv.env else drv

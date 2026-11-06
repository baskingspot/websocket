{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    flake-parts.follows = "baskingspot/flake-parts";
    baskingspot = {
      url = "github:baskingspot/nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    inputs@{ flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      # imports and inputsFrom below mirror each other, including the
      # toolchain version: pick that once, in the import.
      imports = with inputs.baskingspot.flakeModules; [
        base
        docs
        zig."0.16"
      ];

      perSystem =
        { pkgs, config, ... }:
        let
          # The Autobahn TestSuite is Python 2 and abandoned upstream. It runs
          # on PyPy from a pinned source checkout, and the sdist lock in
          # test/autobahn/requirements.txt compiles its dependencies here.
          autobahn-testsuite = pkgs.fetchFromGitHub {
            owner = "crossbario";
            repo = "autobahn-testsuite";
            rev = "v25.10.1";
            hash = "sha256-TtSlwSgVQMhZSLnFjB93ku1WZp3CGSE77mUJNjDZNbI=";
          };

          # The lock builds cryptography 3.3.2, which refuses OpenSSL 3, and
          # nixpkgs removed openssl_1_1 as end-of-life on 2026-09-17. This is
          # the last 1.1.1 release, built for that one sdist and nothing else.
          # test/autobahn/requirements.txt pins cryptography's hash, so the
          # version here cannot drift without the lock changing too.
          openssl_1_1_1w = pkgs.stdenv.mkDerivation (finalAttrs: {
            pname = "openssl";
            version = "1.1.1w";

            src = pkgs.fetchurl {
              url = "https://www.openssl.org/source/old/1.1.1/openssl-${finalAttrs.version}.tar.gz";
              hash = "sha256-zzCYlQy02FOtlcCEHx+cbT3BAtzPys1SHZOSUgi3asg=";
            };

            nativeBuildInputs = [ pkgs.perl ];

            # ./config and Configure start with /usr/bin/env perl, and both
            # run /usr/bin/env again to set the configuration variables. The
            # sandbox has no /usr/bin.
            preConfigure = "patchShebangs .";
            postPatch = ''
              substituteInPlace Configure config --replace-fail "/usr/bin/env" "env"
            '';

            configureScript = "./config";
            setOutputFlags = false;
            configureFlags = [
              "--prefix=${placeholder "out"}"
              "--openssldir=${placeholder "out"}/etc/ssl"
              "--libdir=lib"
              "shared"
              "no-tests"
            ];
            installFlags = [ "install_sw" ];
            enableParallelBuilding = true;
            doCheck = false;
          });
        in
        {
          devShells.default = pkgs.mkShell {
            inputsFrom = [
              config.devShells.base
              config.devShells.docs
              config.devShells."zig-0-16"
            ];

            # Project-specific tools. `just conformance` drives wstest through
            # nushell scripts; the test scaffolding cImports zlib.h for
            # permessage-deflate, and the sdist builds in the lock need
            # pkg-config and libffi.
            packages = with pkgs; [
              coreutils
              libffi
              nufmt
              nushell
              openssl_1_1_1w
              pkg-config
              pypy
              python3
              zlib
              # ziglint with the target std's doc comments, so the deprecation
              # rule checks the oldest API surface this repo supports.
              config.packages."ziglint-0-16"
            ];

            shellHook = ''
              export AUTOBAHN_CHECKOUT_DIR="${autobahn-testsuite}"
              # pypy's sdist builds read these instead of the shell's flags.
              unset NIX_CFLAGS_COMPILE
            '';
          };
        };
    };
}

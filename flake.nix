{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    rust-overlay = {
      url = "https://flakehub.com/f/oxalica/rust-overlay/0.1.1342.tar.gz";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    crane = {
      url = "https://flakehub.com/f/ipetkov/crane/0.16.3.tar.gz";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    cargo-leptos-src = { url = "github:leptos-rs/cargo-leptos?tag=v0.2.16"; flake = false; };
    nix-filter.url = "github:numtide/nix-filter";
  };

  outputs = { self, nixpkgs, rust-overlay, crane, cargo-leptos-src, nix-filter, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        overlays = [ (import rust-overlay) ];
        pkgs = (import nixpkgs) {
          inherit system overlays;
          config.allowUnfree = true;
        };
        
        toolchain = pkgs.rust-bin.selectLatestNightlyWith (toolchain: toolchain.default.override {
          extensions = [ "rust-src" "rust-analyzer" ];
          targets = [ "wasm32-unknown-unknown" ];
        });
        
        craneLib = (crane.mkLib pkgs).overrideToolchain toolchain;

        src = nix-filter {
          root = ./.;
          include = [
            ./Cargo.toml
            ./Cargo.lock
            ./crates
            (nix-filter.lib.matchExt "toml")
          ];
        };

        cargo-leptos = (import ./nix/cargo-leptos.nix) {
          inherit pkgs craneLib;
          cargo-leptos = cargo-leptos-src;
        };

        style-js-deps = (import ./nix/style-js-deps.nix) {
          inherit pkgs nix-filter;

          source-root = ./.;
        };

        common_args = {
          inherit src;

          pname = "site-server";
          version = "0.1.0";

          doCheck = false;

          nativeBuildInputs = [
            # Add additional build inputs here
            cargo-leptos
            pkgs.cargo-generate
            pkgs.binaryen
            pkgs.clang
            pkgs.mold

            # for styling
            pkgs.dart-sass
            pkgs.tailwindcss
            pkgs.yarn
            pkgs.yarn2nix-moretea.fixup_yarn_lock
          ] ++ pkgs.lib.optionals (system == "x86_64-linux") [
            # extra packages only for x86_64-linux
            pkgs.nasm
          ] ++ pkgs.lib.optionals pkgs.stdenv.isDarwin [
            # Additional darwin specific inputs can be set here
            pkgs.libiconv
          ];

          buildInputs = [
            pkgs.pkg-config
            pkgs.openssl
          ];

        };

        # Build *just* the cargo dependencies, so we can reuse
        # all of that work (e.g. via cachix) when running in CI
        site-server-deps = craneLib.buildDepsOnly (common_args // {
          # if work is duplicated by the `server-site` package, update these
          # commands from the logs of `cargo leptos build --release -vvv`
          buildPhaseCargoCommand = ''
            # build the frontend dependencies
            cargo build --package=site-frontend --lib --target-dir=/build/source/target/front --target=wasm32-unknown-unknown --no-default-features --profile=wasm-release
            # build the server dependencies
            cargo build --package=site-server --no-default-features --release
          '';
        });

        # Build the actual crate itself, reusing the dependency
        # artifacts from above.
        site-server = craneLib.buildPackage (common_args // {
          # link the style packages node_modules into the build directory
          preBuild = ''
            ln -s ${style-js-deps}/node_modules \
              ./crates/site-app/style/tailwind/node_modules
          '';
          
          buildPhaseCargoCommand = ''
            cargo leptos build --release -vvv
          '';

          installPhaseCommand = ''
            mkdir -p $out/bin
            cp target/release/site-server $out/bin/
            cp target/release/hash.txt $out/bin/
            cp -r target/site $out/bin/
          '';

          doCheck = false;
          cargoArtifacts = site-server-deps;
        });

        site-server-container = pkgs.dockerTools.buildLayeredImage {
          name = "site-server";
          tag = "latest";
          contents = [ site-server pkgs.cacert ];
          config = {
            # runs the executable with tini: https://github.com/krallin/tini
            # this does signal forwarding and zombie process reaping
            Entrypoint = [ "${pkgs.tini}/bin/tini" "site-server" "--" ];
            WorkingDir = "${site-server}/bin";
            # we provide the env variables that we get from Cargo.toml during development
            # these can be overridden when the container is run, but defaults are needed
            Env = [
              "LEPTOS_OUTPUT_NAME=site"
              "LEPTOS_SITE_ROOT=site"
              "LEPTOS_SITE_PKG_DIR=pkg"
              "LEPTOS_SITE_ADDR=0.0.0.0:3000"
              "LEPTOS_RELOAD_PORT=3001"
              "LEPTOS_ENV=PROD"
              "LEPTOS_HASH_FILES=true"
            ];
          };
        };
      
      in {
        checks = {
          # lint packages
          app-hydrate-clippy = craneLib.cargoClippy (common_args // {
            cargoArtifacts = site-server-deps;
            cargoClippyExtraArgs = "-p site-app --features hydrate -- --deny warnings";
          });
          app-ssr-clippy = craneLib.cargoClippy (common_args // {
            cargoArtifacts = site-server-deps;
            cargoClippyExtraArgs = "-p site-app --features ssr -- --deny warnings";
          });
          site-server-clippy = craneLib.cargoClippy (common_args // {
            cargoArtifacts = site-server-deps;
            cargoClippyExtraArgs = "-p site-server -- --deny warnings";
          });
          site-frontend-clippy = craneLib.cargoClippy (common_args // {
            cargoArtifacts = site-server-deps;
            cargoClippyExtraArgs = "-p site-frontend -- --deny warnings";
          });

          # make sure the docs build
          site-server-doc = craneLib.cargoDoc (common_args // {
            cargoArtifacts = site-server-deps;
          });

          # check formatting
          site-server-fmt = craneLib.cargoFmt {
            pname = common_args.pname;
            version = common_args.version;
            
            inherit src;
          };

          # # audit licenses
          # site-server-deny = craneLib.cargoDeny {
          #   pname = common_args.pname;
          #   version = common_args.version;
          #   inherit src;
          # };

          # run tests
          site-server-nextest = craneLib.cargoNextest (common_args // {
            cargoArtifacts = site-server-deps;
            partitions = 1;
            partitionType = "count";
          });
        };

        packages = {
          default = site-server;
          server = site-server;
          container = site-server-container;
        };
        
        devShells.default = pkgs.mkShell {
          nativeBuildInputs = (with pkgs; [
            toolchain # cargo and such from crane
            just # command recipes
            dive # docker images
            cargo-leptos # main leptos build tool
            flyctl # fly.io
            bacon # cargo check w/ hot reload
            cargo-deny # license checking
          ])
            ++ common_args.buildInputs
            ++ common_args.nativeBuildInputs
            ++ pkgs.lib.optionals pkgs.stdenv.isDarwin [
              pkgs.darwin.Security
            ];
        };
      }
    );
}

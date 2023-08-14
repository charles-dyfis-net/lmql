{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/release-23.05";
    poetry2nix.url = "github:nix-community/poetry2nix";
    poetry2nix.inputs.nixpkgs.follows = "nixpkgs";
    llamaDotCpp.url = "github:ggerganov/llama.cpp";
    flake-utils.url = "github:numtide/flake-utils";
  };
  outputs = { self, nixpkgs, flake-utils, llamaDotCpp, poetry2nix }: let
    llamaDotCppFlake = llamaDotCpp;
    poetry2nixFlake = poetry2nix;
    nonSystemSpecificOutputs = {
      overlays = {
        noSentencePieceCustomMallocOnDarwin = (final: prev: {
          sentencepiece = if prev.stdenv.isDarwin then prev.sentencepiece.override { withGPerfTools = false; } else prev.sentencepiece;
        });
      };
    };
  in nonSystemSpecificOutputs // flake-utils.lib.eachSystem [ "aarch64-darwin" "x86_64-linux" ] (system: let
    version =
      if self.sourceInfo ? "rev"
      then "${self.sourceInfo.lastModifiedDate}-${self.sourceInfo.shortRev}"
      else "dirty";
    pkgs = import nixpkgs {
      inherit system;
      overlays = [
        nonSystemSpecificOutputs.overlays.noSentencePieceCustomMallocOnDarwin
        poetry2nixFlake.overlay
      ];
    };
    poetryEnv = pkgs.poetry2nix.mkPoetryEnv {
      python = pkgs.python310;
      projectDir = "${self}/flake.d";
      # projectDir = "${self}/src";
      overrides = import ./flake.d/overrides.nix { inherit (pkgs) poetry2nix; inherit llamaDotCpp; };
      editablePackageSources = {
        lmql = self;
      };
    };
  in rec {
    legacyPackages = pkgs;
    apps = {
      lmtp-server = {
        type = "app";
        program = "${pkgs.writeShellScript "run-lmtp-server" ''
          set -a
          PATH=${packages.llamaDotCpp}/bin:$PATH
          PYTHONPATH=${self}/src
          exec ${poetryEnv}/bin/python -m lmql.cli serve-model "$@"
        ''}";
      };
    };
    packages = {
      llamaDotCpp = llamaDotCppFlake.packages.${system}.default;
      python = poetryEnv;
      lmql-docs = pkgs.runCommand "lmql-docs" {
        python = pkgs.python310.withPackages (p: [p.myst-parser p.pydata-sphinx-theme p.sphinx-book-theme p.nbsphinx]);
        docSource = ./docs/source;
      } ''
        PATH=${pkgs.pandoc}/bin:$PATH ${poetryEnv}/bin/sphinx-build "$docSource" "$out"
      '';
      playground = pkgs.mkYarnPackage rec {
        pname = "lmql-playground-live";
        inherit version;
        src = ./src/lmql/ui/live;
        yarnLock = "${src}/yarn.lock";
        yarnNix = "${src}/yarn.nix";
        packageJSON = "${src}/package.json";
        dontStrip = true;

        buildPhase = ''
          true
        '';

        distPhase = ''
          # We need a Python interpreter with all the dependencies
          mkdir -p -- $out/bin $out/libexec
          ln -s ${packages.python}/bin/python "$out/bin/python"
          ln -s ${pkgs.nodejs}/bin/node "$out/bin/node"

          ln -s ${pkgs.writeShellScript "lmql-live-run" ''
            bindir=''${BASH_SOURCE%/*}
            : addr=''${addr:=127.0.0.1} port=''${port:=3000}
            cd "$bindir/../libexec/liveserve/deps/liveserve" || exit
            export PATH=$bindir:$PATH
            export PYTHONPATH=${self}/src:$PYTHONPATH
            export NODE_PATH=$out/libexec/node_modules
            export PORT=$port
            export content_dir=${packages.playground-static-content}/content
            exec "$bindir/node" "live.js"
          ''} "$out/bin/run"
        '';

        meta.mainProgram = "run";
      };
      # static content 
      playground-static-content = pkgs.mkYarnPackage rec {
        pname = "web";
        inherit version;
        src = ./src/lmql/ui/playground;
        yarnLock = "${src}/yarn.lock";
        yarnNix = "${src}/yarn.nix";
        packageJSON = "${src}/package.json";
        dontStrip = true;

        patchPhase  = ''
          find . -type d -name browser-build -exec rm -rf -- {} +
          rm -f -- public/doc-snippets
        '';

        DISABLE_ESLINT_PLUGIN = "true";

        buildPhase = ''
          HOME=$(mktemp -d) yarn --offline build
        '';

        distPhase = ''
          shopt -s extglob
          mv "$out"/libexec/web/deps/web/build "$out/content"
          rm -rf -- "$out"/!(content)

          mkdir -p -- "$out/bin"
          ln -s ${pkgs.writeShellScript "lmql-playground-run" ''
            bindir=''${BASH_SOURCE%/*}
            : addr=''${addr:=127.0.0.1} port=''${port:=3000}
            echo "Starting web server on $addr:$port..." >&2
            exec ${packages.python}/bin/python -m http.server --bind "$addr" --directory "$bindir/../content" "$port"
          ''} "$out/bin/run" 
        '';

        meta.mainProgram = "run";
      };
      # TODO: Add at entrypoint to run a LMTP server
      # TODO: Add an entrypoint to run a Python interpreter with LMQL and dependencies
    };
    devShells = let
      jsDevPackages = [
        pkgs.yarn
        pkgs.yarn2nix
      ];
      pythonDevPackages = [
        pkgs.pandoc # not python-specific, but used in building docs
        pkgs.poetry
        pkgs.poetry2nix.cli
        (pkgs.python310.withPackages (p: [p.poetry-core]))
      ];
      runtimePackages = [
        llamaDotCppFlake.packages.${system}.default
        pkgs.nodejs
      ];
    in {
      # python interpreter able to import lmql successfully
      default = poetryEnv.env.overrideAttrs (oldAttrs: {
        shellHook = ''
          PS1='[lmql] '"$PS1"
          lmql() { python -m lmql.cli "$@"; }
        '';
        PYTHONPATH = "${builtins.toString ./src}";
        buildInputs = jsDevPackages ++ pythonDevPackages ++ runtimePackages;
      });
      # tools to run poetry and yarn2nix, and nothing else
      minimal = pkgs.mkShell {
        name = "minimal-dev-shell";
        buildInputs = jsDevPackages ++ pythonDevPackages;
      };
    };
  });
}

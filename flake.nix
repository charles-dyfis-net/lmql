{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/release-23.05";
    llamaDotCpp.url = "github:ggerganov/llama.cpp";
    flake-utils.url = "github:numtide/flake-utils";
  };
  outputs = { self, nixpkgs, flake-utils, llamaDotCpp }: let
    llamaDotCppFlake = llamaDotCpp;
    nonSystemSpecificOutputs = {
      overlays = {
        noSentencePieceCustomMallocOnDarwin = (final: prev: {
          sentencepiece = if prev.stdenv.isDarwin then prev.sentencepiece.override { withGPerfTools = false; } else prev.sentencepiece;
        });
      };
    };
    # Wrap source-tree content in a fixed-output derivation to allow dependencies on files without bringing the entire source tree hash into the hash of the derivation
    makeFOD = pkgs: smallSourceFile: pkgs.runCommand (builtins.baseNameOf smallSourceFile) {
      outputHashMode = "flat";
      outputHashAlgo = "sha256";
      outputHash = builtins.hashFile "sha256" smallSourceFile;
      inherit smallSourceFile;
    } ''
      rmdir -- "$out" ||:
      cp -- "$smallSourceFile" "$out"
    '';
    poetryOverrides = final: prev: {
      accelerate = prev.accelerate.overridePythonAttrs (old: { buildInputs = (old.buildInputs or []) ++ [ final.filelock final.jinja2 final.networkx final.setuptools final.sympy ]; });
      attrs = prev.attrs.overridePythonAttrs (old: { buildInputs = (old.buildInputs or []) ++ [ final.hatchling final.hatch-fancy-pypi-readme final.hatch-vcs ]; });
      llama-cpp-python = prev.llama-cpp-python.overridePythonAttrs (old: {
        buildInputs = (old.buildInputs or []) ++ [ final.setuptools ];
        prePatch = (old.prePatch or "") + "\n" + ''
          ${final.pkgs.gnused}/bin/sed -i -e 's@from skbuild import setup@from setuptools import setup@' setup.py
        '';
        postInstall = ''
          oldWD=$PWD
          ln -s -- ${llamaDotCpp.packages.${final.pkgs.system}.default}/lib/libllama.* "$out"/lib/*/site-packages/llama_cpp/ || exit
          cd "$oldWD" || exit
        '';
      });
      safetensors = prev.safetensors.overridePythonAttrs (old: let lockFile = makeFOD final.pkgs (./flake.d/cargo-deps/. + "/${old.pname}-${old.version}-Cargo.lock"); in {
        buildInputs = (old.buildInputs or []) ++ [ final.setuptools final.setuptools-rust final.pkgs.iconv ];
        nativeBuildInputs = (old.nativeBuildInputs or []) ++ [ final.pkgs.cargo final.pkgs.rustc final.pkgs.rustPlatform.cargoSetupHook ];
        cargoDeps = final.pkgs.rustPlatform.importCargoLock { inherit lockFile; };
        prePatch = ''
          cp -- ${lockFile} ./Cargo.lock
          ${old.patchPhase or ""}
        '';
      });
      tiktoken = prev.tiktoken.overridePythonAttrs (old: let lockFile = makeFOD final.pkgs (./flake.d/cargo-deps/. + "/${old.pname}-${old.version}-Cargo.lock"); in {
        buildInputs = (old.buildInputs or []) ++ [ final.setuptools final.setuptools-rust final.pkgs.iconv ];
        nativeBuildInputs = (old.nativeBuildInputs or []) ++ [ final.pkgs.cargo final.pkgs.rustc final.pkgs.rustPlatform.cargoSetupHook ];
        cargoDeps = final.pkgs.rustPlatform.importCargoLock { inherit lockFile; };
        prePatch = ''
          cp -- ${lockFile} ./Cargo.lock
          ${old.patchPhase or ""}
        '';
      });
      torch = prev.torch.overridePythonAttrs (old: { buildInputs = (old.buildInputs or []) ++ [ final.filelock final.jinja2 final.networkx final.sympy ]; });
      tokenizers = prev.tokenizers.overridePythonAttrs (old: let lockFile = makeFOD final.pkgs (./flake.d/cargo-deps/. + "/${old.pname}-${old.version}-Cargo.lock"); in {
        buildInputs = (old.buildInputs or []) ++ [ final.setuptools final.setuptools-rust final.pkgs.iconv ] ++ final.pkgs.lib.optional final.pkgs.stdenv.isDarwin final.pkgs.darwin.apple_sdk.frameworks.Security;
        nativeBuildInputs = (old.nativeBuildInputs or []) ++ [ final.pkgs.cargo final.pkgs.rustc final.pkgs.rustPlatform.cargoSetupHook ];
        cargoDeps = final.pkgs.rustPlatform.importCargoLock { inherit lockFile; };
        prePatch = ''
          cp -- ${lockFile} ./Cargo.lock
          ${old.patchPhase or ""}
        '';
      });
      urllib3 = prev.urllib3.overridePythonAttrs (old: { buildInputs = (old.buildInputs or []) ++ [ final.hatchling ]; });
    };
  in nonSystemSpecificOutputs // flake-utils.lib.eachSystem [ "aarch64-darwin" "x86_64-linux" ] (system: let
    version =
      if self.sourceInfo ? "rev"
      then "${self.sourceInfo.lastModifiedDate}-${builtins.toString self.sourceInfo.revCount}-${self.sourceInfo.shortRev}"
      else "dirty";
    pkgs = import nixpkgs {
      inherit system;
      overlays = [
        nonSystemSpecificOutputs.overlays.noSentencePieceCustomMallocOnDarwin
      ];
    };
    poetryEnv = pkgs.poetry2nix.mkPoetryEnv {
      python = pkgs.python310;
      projectDir = self;
      overrides = pkgs.poetry2nix.overrides.withDefaults poetryOverrides;
      editablePackageSources = {
        lmql = self;
      };
    };
  in {
    legacyPackages = pkgs;
    packages = {
      llamaDotCpp = llamaDotCppFlake.packages.${system}.default;
      live = pkgs.mkYarnPackage rec {
        pname = "lmql-playground-live";
        inherit version;
        src = ./src/lmql/ui/live;
        yarnLock = "${src}/yarn.lock";
        yarnNix = "${src}/yarn.nix";
        packageJSON = "${src}/package.json";
        dontStrip = true;
      };
      playground-web = pkgs.mkYarnPackage rec {
        pname = "lmql-playground-web";
        inherit version;
        src = ./src/lmql/ui/playground;
        yarnLock = "${src}/yarn.lock";
        yarnNix = "${src}/yarn.nix";
        packageJSON = "${src}/package.json";
        dontStrip = true;

        distPhase = ''
          cd "$out/libexec/lmql-playground-web" || exit
          for f in "$out"/libexec/lmql-playground-web/deps/lmql-playground-web/*; do
            fb=''${f##*/}; src="deps/lmql-playground-web/$fb"; dest="$out/libexec/lmql-playground-web/$fb"
            [[ -e $dest || -L $dest ]] || ln -s "$src" "$dest"
          done

          # FIXME: Before this works, we need to build the documentation as a separate derivation, and make doc-snippets point to it
          ./node_modules/.bin/react-scripts build || exit
        
          mkdir -p -- "$out/bin"
          ln -s ${pkgs.writeShellScript "start-lqml-playground-web" ''
            bin_script=$BASH_SOURCE
            [ -s "$bin_script" ] || { echo "ERROR: Could not find running script" >&2; exit 1; }
            bin_dir=''${bin_script%/*}
            exec "$bin_dir/../libexec/lmql-playground-web/node_modules/.bin/react-scripts" start "$@"
          ''} "$out/bin/start-lqml-playground-web"
        '';
      };
      # TODO: Add at entrypoint to run a LMTP server
      # TODO: Add an entrypoint to run a Python interpreter with LMQL and dependencies
    };
    devShells = {
      # python interpreter able to import lmql successfully
      default = poetryEnv.env.overrideAttrs (oldAttrs: {
        shellHook = ''
          PS1='[lmql] '"$PS1"
        '';
        PYTHONPATH = "${builtins.toString ./src}";
        buildInputs = [
          llamaDotCppFlake.packages.${system}.default
          pkgs.poetry
          pkgs.poetry2nix.cli
        ];
      });
      poetryMinimal = pkgs.mkShell {
        name = "minimal-poetry-shell";
        buildInputs = [
          pkgs.poetry
          pkgs.poetry2nix.cli
          (pkgs.python310.withPackages (p: [p.poetry-core]))
        ];

      };
    };
  });
}

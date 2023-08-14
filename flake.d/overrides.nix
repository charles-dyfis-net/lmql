{ llamaDotCpp, poetry2nix }:
let
  # Make a fixed-output derivation with a file's contents; can be used to avoid making something depend on the entire
  # lmql source tree when it only needs one file.
  makeFOD = pkgs: smallSourceFile: pkgs.runCommand (builtins.baseNameOf smallSourceFile) {
        outputHashMode = "flat";
        outputHashAlgo = "sha256";
        outputHash = builtins.hashFile "sha256" smallSourceFile;
        inherit smallSourceFile;
      } ''
        rmdir -- "$out" ||:
        cp -- "$smallSourceFile" "$out"
      '';
  # Some prebuilt operations we often need to do to make Python packages build

  # The lazy version: Give up on building it from source altogether and use a binary
  preferWheel = { name, final, prev, pkg }: pkg.override { preferWheel = true; };

  # Add extra inputs needed to build from source; often things like setuptools or hatchling not included upstream
  addBuildInputs = extraBuildInputs: { name, final, prev, pkg }:
    pkg.overridePythonAttrs (old: {
      buildInputs = (old.buildInputs or []) ++ (builtins.map (dep: if builtins.isString dep then builtins.getAttr dep final else dep) extraBuildInputs);
    });

  # Rust packages need extra build-time dependencies; and if the upstream repo didn't package a Cargo.lock file we need to add one for them
  asRustBuild = { name, final, prev, pkg }:
    let
      lockFilePath = ./cargo-deps/. + "/${pkg.pname}-${pkg.version}-Cargo.lock";
      lockFile = makeFOD prev.pkgs lockFilePath;
      haveLockFileOverride = builtins.pathExists lockFilePath;
    in pkg.overridePythonAttrs (old: {
      buildInputs = (old.buildInputs or []) ++ [ final.setuptools final.setuptools-rust final.pkgs.iconv ] ++
        final.pkgs.lib.optional final.pkgs.stdenv.isDarwin final.pkgs.darwin.apple_sdk.frameworks.Security;
      nativeBuildInputs = (old.nativeBuildInputs or []) ++ [ final.pkgs.cargo final.pkgs.rustc final.pkgs.rustPlatform.cargoSetupHook ];
    } // (if haveLockFileOverride then {
      cargoDeps = final.pkgs.rustPlatform.importCargoLock { inherit lockFile; };
      prePatch = ''
        cp -- ${lockFile} ./Cargo.lock
        ${old.prePatch or ""}
      '';
    } else {}));

  # Use the libllama.dylib or libllama.so from llamaDotCpp instead of letting the package build its own
  llamaCppUseLlamaBuild = { name, final, prev, pkg }: pkg.overridePythonAttrs (old: {
    prePatch = (old.prePatch or "") + "\n" + ''
      ${final.pkgs.gnused}/bin/sed -i -e 's@from skbuild import setup@from setuptools import setup@' setup.py
    '';
    postInstall = ''
      oldWD=$PWD
      ln -s -- ${llamaDotCpp.packages.${final.pkgs.system}.default}/lib/libllama.* "$out"/lib/*/site-packages/llama_cpp/ || exit
      cd "$oldWD" || exit
    '';
  });

  composeOps = opLeft: opRight:
    { name, final, prev, pkg } @ argsIn:
      let firstResult = (opLeft argsIn);
      in opRight { inherit name final; prev = prev // { "${name}" = firstResult; }; pkg = firstResult; };

  # Python eggs only record runtime dependencies, not build dependencies; so we record build deps that aren't autodetected here.
  buildOps = {
    accelerate           = addBuildInputs [ "filelock" "jinja2" "networkx" "setuptools" "sympy" ];
    accessible-pygments  = addBuildInputs [ "setuptools" ];
    aiohttp-sse-client   = addBuildInputs [ "setuptools" ];
    llama-cpp-python     = composeOps (addBuildInputs [ "setuptools" ]) llamaCppUseLlamaBuild;
    pandoc               = addBuildInputs [ "setuptools" ];
    pydata-sphinx-theme  = preferWheel;
    safetensors          = asRustBuild;
    shibuya              = addBuildInputs [ "setuptools" ];
    sphinx-book-theme    = preferWheel;
    sphinx-theme-builder = addBuildInputs [ "filit-core" ];
    tiktoken             = asRustBuild;
    tokenizers           = asRustBuild;
    torch                = addBuildInputs [ "filelock" "jinja2" "networkx" "sympy" ];    
    urllib3              = addBuildInputs [ "hatchling" ];
  };
  buildOpsOverlay = (final: prev: builtins.mapAttrs (package: op: (op { inherit final prev; name = package; pkg = builtins.getAttr package prev; })) buildOps);
in poetry2nix.overrides.withDefaults buildOpsOverlay

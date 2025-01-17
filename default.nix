{ pkgs ? import nix/nixpkgs.nix {}, gitDescribe ? null, nanoXSdk ? throw "No NanoX SDK", ... }:
let

  fetchThunk = p:
    if builtins.pathExists (p + /git.json)
      then pkgs.fetchgit { inherit (builtins.fromJSON (builtins.readFile (p + /git.json))) url rev sha256; }
    else if builtins.pathExists (p + /github.json)
      then pkgs.fetchFromGitHub { inherit (builtins.fromJSON (builtins.readFile (p + /github.json))) owner repo rev sha256; }
    else p;

  devGitDescribe = "TEST-dirty";

  targets =
    let
      fhs = extraPkgs: runScript: pkgs.callPackage nix/fhs.nix { inherit runScript extraPkgs; };
    in {
      s = rec {
        name = "s";
        sdk = fetchThunk nix/dep/nanos-secure-sdk;
        env = pkgs.callPackage nix/bolos-env.nix { clangVersion = 4; };
        target = "TARGET_NANOS";
        fhsWith = fhs (_: [env.clang]);
      };
      x = rec {
        name = "x";
        sdk = nanoXSdk;
        env = pkgs.callPackage nix/bolos-env.nix { clangVersion = 7; };
        target = "TARGET_NANOX";
        fhsWith = fhs (_: [env.clang]);
      };
    };

  src = pkgs.lib.sources.sourceFilesBySuffices (pkgs.lib.sources.cleanSource ./.) [".c" ".h" ".gif" "Makefile"];

  build = gitDescribe: bolos:
    let
      app = bakingApp: pkgs.runCommand "ledger-app-tezos-nano-${bolos.name}-${if bakingApp then "baking" else "wallet"}" {} ''
        set -Eeuo pipefail

        cp -a '${src}'/* .
        chmod -R u+w .
        '${bolos.fhsWith "bash"}' <<EOF
        set -Eeuxo pipefail

        export BOLOS_SDK='${bolos.sdk}'
        export BOLOS_ENV='${bolos.env}'
        export APP='${if bakingApp then "tezos_baking" else "tezos_wallet"}'
        export GIT_DESCRIBE='${gitDescribe}'
        make clean
        make all
        EOF

        mkdir -p "$out"
        cp -R bin "$out"
        cp -R debug "$out"

        echo
        echo ">>>> Application size: <<<<"
        '${pkgs.binutils-unwrapped}/bin/size' "$out/bin/app.elf"
      '';

      mkRelease = short_name: name: appDir: pkgs.runCommand "${short_name}-nano-${bolos.name}-release-dir" {} ''
        mkdir -p "$out"

        cp '${appDir + /bin/app.hex}' "$out/app.hex"

        cat > "$out/app.manifest" <<EOF
        name='${name}'
        nvram_size=$(grep _nvram_data_size '${appDir + /debug/app.map}' | tr -s ' ' | cut -f2 -d' ')
        target='nano_${bolos.name}'
        target_id=0x31100004
        version=$(echo '${gitDescribe}' | cut -f1 -d- | cut -f2 -dv)
        EOF

        cp '${dist/icon.hex}' "$out/icon.hex"
      '';

      walletApp = app false;
      bakingApp = app true;
    in {
      wallet = walletApp;
      baking = if bolos.name == "x" then null else bakingApp;

      release = rec {
        wallet = mkRelease "wallet" "Tezos Wallet" walletApp;
        baking = if bolos.name == "x" then null else mkRelease "baking" "Tezos Baking" bakingApp;
        all = if bolos.name == "x" then null else pkgs.runCommand "release.tar.gz" {} ''
          cp -r '${wallet}' wallet
          cp -r '${baking}' baking
          cp '${./release-installer.sh}' install.sh
          chmod +x install.sh
          tar czf "$out" install.sh wallet baking
        '';
      };
    };

  buildResult = if gitDescribe == null
    then throw "Set 'gitDescribe' attribute to result of 'git describe' or use nix/build.sh instead"
    else build gitDescribe;

  # The package clang-analyzer comes with a perl script `scan-build` that seems
  # to get quickly lost with the cross-compiler of the SDK if run by itself.
  # So this script reproduces what it does with fewer magic attempts:
  # * It prepares the SDK like for a normal build.
  # * It intercepts the calls to the compiler with the `CC` make-variable
  #   (pointing at `.../libexec/scan-build/ccc-analyzer`).
  # * The `CCC_*` variables are used to configure `ccc-analyzer`: output directory
  #   and which *real* compiler to call after doing the analysis.
  # * After the build an `index.html` file is created to point to the individual
  #   result pages.
  #
  # See
  # https://clang-analyzer.llvm.org/alpha_checks.html#clone_alpha_checkers
  # for the list of extra analyzers that are run.
  #
  runClangStaticAnalyzer =
     let
       interestingExtrasAnalyzers = [
         # "alpha.clone.CloneChecker" # this one is waaay too verbose
         "alpha.security.ArrayBound"
         "alpha.security.ArrayBoundV2"
         "alpha.security.MallocOverflow"
         # "alpha.security.MmapWriteExec" # errors as “not found” by ccc-analyzer
         "alpha.security.ReturnPtrRange"
         "alpha.security.taint.TaintPropagation"
         "alpha.deadcode.UnreachableCode"
         "alpha.core.CallAndMessageUnInitRefArg"
         "alpha.core.CastSize"
         "alpha.core.CastToStruct"
         "alpha.core.Conversion"
         # "alpha.core.FixedAddr" # Seems noisy, and about portability.
         "alpha.core.IdenticalExpr"
         "alpha.core.PointerArithm"
         "alpha.core.PointerSub"
         "alpha.core.SizeofPtr"
         # "alpha.core.StackAddressAsyncEscape" # Also not found
         "alpha.core.TestAfterDivZero"
         "alpha.unix.cstring.BufferOverlap"
         "alpha.unix.cstring.NotNullTerminated"
         "alpha.unix.cstring.OutOfBounds"
       ];
       analysisOptions =
          pkgs.lib.strings.concatMapStringsSep
             " "
             (x: "-analyzer-checker " + x)
             interestingExtrasAnalyzers;
     in bakingApp: bolos: pkgs.runCommand "static-analysis-html-${if bakingApp then "baking" else "wallet"}" {} ''
        set -Eeuo pipefail
        cp -a '${src}'/* .
        chmod -R u+w .
        '${bolos.fhsWith "bash"}' <<EOF
        set -Eeuxo pipefail
        export BOLOS_SDK='${bolos.sdk}'
        export BOLOS_ENV='${bolos.env}'
        export GIT_DESCRIBE='${if gitDescribe == null then devGitDescribe else gitDescribe}'
        export CCC_ANALYZER_HTML="$out"
        export CCC_ANALYZER_OUTPUT_FORMAT=html
        export CCC_ANALYZER_ANALYSIS="${analysisOptions}"
        export CCC_CC='${bolos.env}/clang-arm-fropi/bin/clang'
        export CLANG='${bolos.env}/clang-arm-fropi/bin/clang'
        export TARGET='${bolos.target}'
        export APP='${if bakingApp then "tezos_baking" else "tezos_wallet"}'

        mkdir -p "$out"
        make clean
        make all CC='${pkgs.clangAnalyzer}/libexec/scan-build/ccc-analyzer'
        EOF

        {
          echo "<html><title>Analyzer Report</title><body><h1>Clang Static Analyzer Results</h1>"
          printf "<p>App: <code>${if bakingApp then "tezos_baking" else "tezos_wallet"}</code></p>"
          printf "<h2>File-results:</h2>"
          for html in "$out"/report*.html ; do
            echo "<p>"
            printf "<code>"
            grep BUGFILE "$html" | sed 's/^<!-- [A-Z]* \(.*\) -->$/\1/'
            printf "</code>"
            printf "<code style=\"color: green\">+"
            grep BUGLINE "$html" | sed 's/^<!-- [A-Z]* \(.*\) -->$/\1/'
            printf "</code><br/>"
            grep BUGDESC "$html" | sed 's/^<!-- [A-Z]* \(.*\) -->$/\1/'
            printf " → <a href=\"./%s\">full-report</a>" "$(basename "$html")"
            echo "</p>"
          done
          echo "</body></html>"
        } > "$out/index.html"
      '';

  mkTargets = mk: {
    s = mk targets.s;
    x = mk targets.x;
  };
in rec {
  nano = mkTargets buildResult;

  wallet = {
    s = nano.s.wallet;
    x = nano.x.wallet;
  };
  baking = {
    s = nano.s.baking;
    x = nano.x.baking;
  };

  clangAnalysis = mkTargets (bolos: {
    baking = if bolos.name == "x" then null else runClangStaticAnalyzer true bolos;
    wallet = runClangStaticAnalyzer false bolos;
  });

  env = mkTargets (bolos: {
    # Script that places you in the environment to run `make`, etc.
    shell = pkgs.writeScriptBin "env-shell" ''
      #!${pkgs.stdenv.shell}
      export BOLOS_SDK='${bolos.sdk}'
      export BOLOS_ENV='${bolos.env}'
      export TARGET='${bolos.target}'
      exec '${bolos.fhsWith "bash"}'
    '';

    ide = {
      config = {
        vscode = pkgs.writeText "vscode-nano-${bolos.name}.code-workspace" (builtins.toJSON {
          folders = [ { path = "."; } ];
          settings = {
            "clangd.path" = bolos.fhsWith (pkgs.llvmPackages.clang-unwrapped + /bin/clangd);
          };
        });
      };
    };

    inherit (bolos.env) clang gcc;
    inherit (bolos) sdk;
  });
}

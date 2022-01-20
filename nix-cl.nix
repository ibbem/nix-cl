# TODO:
# - faster build by using lisp with preloaded asdf?
# - dont include java libs unless abcl?
# - dont use build-asdf-system to build lispWithPackages?
# - make the lisp packages overridable? (e.g. buildInputs glibc->musl)
# - build asdf with nix and use that instead of one shipped with impls
#   (e.g. to fix build with clisp - does anyone use clisp?)
# - claspPackages ? (gotta package clasp with nix first)
# - hard one: remove unrelated sources ( of systems not being built)
# - figure out a less awkward way to patch sources
#   (have to build from src directly for SLIME to work, so can't just patch sources in place)

{ pkgs, lib, stdenv, ... }:

with lib.lists;
with lib.strings;

let

  # Returns a flattened dependency tree without duplicates
  flattenedDeps = lispLibs:
    let
      walk = acc: node:
        if length node.lispLibs == 0
        then acc
        else foldl walk (acc ++ node.lispLibs) node.lispLibs;
    in unique (walk [] { inherit lispLibs; });

  #
  # Wrapper around stdenv.mkDerivation for building ASDF systems.
  #
  build-asdf-system =
    { pname,
      version,
      src ? null,

      # Native libraries, will be appended to the library path
      nativeLibs ? [],

      # Java libraries for ABCL, will be appended to the class path
      javaLibs ? [],

      # Lisp dependencies
      # these should be packages built with `build-asdf-system`
      lispLibs ? [],

      # Lisp command to run buildScript
      lisp,

      # Some libraries have multiple systems under one project, for
      # example, cffi has cffi-grovel, cffi-toolchain etc.  By
      # default, only the `pname` system is build.
      #
      # .asd's not listed in `systems` are removed in
      # installPhase. This prevents asdf from referring to uncompiled
      # systems on run time.
      #
      # Also useful when the pname is differrent than the system name,
      # such as when using reverse domain naming.
      systems ? [ pname ],

      # Other args to mkDerivation
      ...
    } @ args:

    stdenv.mkDerivation (rec {
      inherit pname version src nativeLibs javaLibs lispLibs lisp systems;

      # When src is null, we are building a lispWithPackages and only
      # want to make use of the dependency environment variables
      # generated by build-asdf-system
      dontUnpack = src == null;

      # Tell asdf where to find system definitions of lisp dependencies.
      #
      # The "//" ending is important as it makes asdf recurse into
      # subdirectories when searching for .asd's. This is to support
      # projects where .asd's aren't in the root directory.
      CL_SOURCE_REGISTRY = makeSearchPath "/" (flattenedDeps lispLibs);

      # Tell lisp where to find native dependencies
      #
      # Normally generated from lispLibs, but LD_LIBRARY_PATH as a
      # derivation attr itself can be used as an extension point when
      # the libs are not in a '/lib' subdirectory
      LD_LIBRARY_PATH =
        let
          deps = flattenedDeps lispLibs;
          nativeLibs = concatMap (x: x.nativeLibs) deps;
          libpaths = filter (x: x != "") (map (x: x.LD_LIBRARY_PATH) deps);
        in
          makeLibraryPath nativeLibs
          + optionalString (length libpaths != 0) ":"
          + concatStringsSep ":" libpaths;

      # Java libraries For ABCL
      CLASSPATH = makeSearchPath "share/java/*" (concatMap (x: x.javaLibs) (flattenedDeps lispLibs));

      # Portable script to build the systems.
      #
      # `lisp` must evaluate this file then exit immediately. For
      # example, SBCL's --script flag does just that.
      buildScript = pkgs.writeText "build-${pname}.lisp" ''
        (require :asdf)
        (dolist (s '(${concatStringsSep " " systems}))
          (asdf:compile-system s))
      '';

      buildPhase = optionalString (src != null) ''
        # In addition to lisp dependencies, make asdf see the .asd's
        # of the systems being built
        #
        # *Append* src since `lispLibs` can provide .asd's that are
        # also in `src` but are not in `systems` (that is, the .asd's
        # that will be deleted in installPhase). We don't want to
        # rebuild them, but to load them from lispLibs.
        #
        # NOTE: It's important to read files from `src` instead of
        # from pwd to get go-to-definition working with SLIME
        export CL_SOURCE_REGISTRY=$CL_SOURCE_REGISTRY:${src}//

        # Similiarily for native deps
        export LD_LIBRARY_PATH=${makeLibraryPath nativeLibs}:$LD_LIBRARY_PATH
        export CLASSPATH=${makeSearchPath "share/java/*" javaLibs}:$CLASSPATH

        # Make asdf compile from `src` to pwd and load `lispLibs`
        # from storeDir. Otherwise it could try to recompile lisp deps.
        export ASDF_OUTPUT_TRANSLATIONS="${src}:$(pwd):${storeDir}:${storeDir}"

        # Finally, compile the systems
        ${lisp} ${buildScript}
      '';

      # Copy compiled files to store
      installPhase =
        let
          mkSystemsRegex = systems:
            concatMapStringsSep "|"
              # Make sure to include $ in regex to prevent skipping
              # stuff like 'system.asdf.asd' - such as in `iolib.asdf`
              (x: (removeSuffix "\"" (escapeNixString (x + ".asd"))) + "$\"")
              systems;
        in
      ''
        mkdir -pv $out
        cp -r * $out

        # Remove all .asd files except for those in `systems`.
        find $out -name "*.asd" \
        | grep -v "${escapeRegex (mkSystemsRegex systems)}"\
        | xargs rm -fv || true
      '';

      # Not sure if it's needed, but caused problems with SBCL
      # save-lisp-and-die binaries in the past
      dontStrip = true;
      dontFixup = true;

    } // args);


  # Build the set of lisp packages using `lisp`
  commonLispPackagesFor = lisp:
    let
      build-asdf-system' = body: build-asdf-system (body // { inherit lisp; });
    in import ./packages.nix {
      inherit pkgs;
      build-asdf-system = build-asdf-system';
    };

  # Build the set of packages imported from quicklisp using `lisp`
  quicklispPackagesFor = lisp:
    let
      manualPackages = commonLispPackagesFor lisp;
      build-asdf-system' = body: build-asdf-system (body // {
        inherit lisp;

        # Rewrite dependencies of imported packages to use the manually
        # defined ones instead
        lispLibs = map
          (pkg:
            if (lib.hasAttr pkg.pname manualPackages)
            then manualPackages.${pkg.pname}
            else pkg
          )
          body.lispLibs;
      });
    in import ./ql.nix {
      inherit pkgs;
      inherit flattenedDeps;
      build-asdf-system = build-asdf-system';
    };

  # Creates a lisp wrapper with `packages` installed
  #
  # `packages` is a function that takes `clpkgs` - a set of lisp
  # packages - as argument and returns the list of packages to be
  # installed
  #
  # Example:
  #
  # sbclPackages = commonLispPackagesFor sbcl;
  # sbclWithPackages = lispWithPackages sbclPackages;
  # sbclWithPackages (clpkgs: with clpkgs; [ alexandria cffi str ]);
  lispWithPackages = clpkgs: packages:
    # FIXME just use flattenedDeps instead
    (build-asdf-system rec {
      lisp = (head (lib.attrValues clpkgs)).lisp;
      pname = baseNameOf (head (split " " lisp));
      version = "with-packages";
      lispLibs = packages clpkgs;
      buildInputs = with pkgs; [ makeWrapper ];
      systems = [];
    }).overrideAttrs(o: {
      installPhase = ''
        mkdir -pv $out/bin
        makeWrapper \
          ${head (split " " o.lisp)} \
          $out/bin/${baseNameOf (head (split " " o.lisp))} \
          --prefix CL_SOURCE_REGISTRY : "${o.CL_SOURCE_REGISTRY}" \
          --prefix ASDF_OUTPUT_TRANSLATIONS : ${concatStringsSep "::" (flattenedDeps o.lispLibs)}: \
          --prefix LD_LIBRARY_PATH : "${o.LD_LIBRARY_PATH}" \
          --prefix LD_LIBRARY_PATH : "${makeLibraryPath o.nativeLibs}" \
          --prefix CLASSPATH : "${o.CLASSPATH}" \
          --prefix CLASSPATH : "${makeSearchPath "share/java/*" o.javaLibs}"
      '';
    });


  commonLispPackages = rec {
    inherit commonLispPackagesFor build-asdf-system lispWithPackages;

    sbcl  = "${pkgs.sbcl}/bin/sbcl --script";
    ecl   = "${pkgs.ecl}/bin/ecl --shell";
    abcl  = ''${pkgs.abcl}/bin/abcl --batch --eval "(load \"$buildScript\")"'';
    ccl   = ''${pkgs.ccl}/bin/ccl --batch --eval "(load \"$buildScript\")" --'';
    clasp = ''${pkgs.clasp}/bin/clasp --non-interactive --quit --load'';

    sbclManualPackages  = commonLispPackagesFor sbcl;
    eclManualPackages   = commonLispPackagesFor ecl;
    abclManualPackages  = commonLispPackagesFor abcl;
    cclManualPackages   = commonLispPackagesFor ccl;
    claspManualPackages = commonLispPackagesFor clasp;

    sbclQlPackages  = quicklispPackagesFor sbcl;
    eclQlPackages   = quicklispPackagesFor ecl;
    abclQlPackages  = quicklispPackagesFor abcl;
    cclQlPackages   = quicklispPackagesFor ccl;
    claspQlPackages = quicklispPackagesFor clasp;

    # Manually defined packages shadow the ones imported from quicklisp

    sbclPackages  = (sbclQlPackages  // sbclManualPackages);
    eclPackages   = (eclQlPackages   // eclManualPackages);
    abclPackages  = (abclQlPackages  // abclManualPackages);
    cclPackages   = (cclQlPackages   // cclManualPackages);
    claspPackages = (claspQlPackages // claspManualPackages);

    sbclWithPackages  = lispWithPackages sbclPackages;
    eclWithPackages   = lispWithPackages eclPackages;
    abclWithPackages  = lispWithPackages abclPackages;
    cclWithPackages   = lispWithPackages cclPackages;
    claspWithPackages = lispWithPackages claspPackages;
  };

in commonLispPackages

inputs:
inputs.flake-parts.lib.mkFlake { inherit inputs; } (
  {
    withSystem,
    flake-parts-lib,
    lib,
    config,
    ...
  }:
  {
    systems = import inputs.systems.outPath;

    imports = [
      inputs.flake-file.flakeModules.default
    ];

    flake-file = {
      nixConfig = {
        commit-lockfile-summary = "chore(flake): update `flake.lock`";
        extra-experimental-features = [
          "pipe-operators"
        ];
      };

      inputs = {
        systems = {
          url = "github:nix-systems/default";
        };

        nixpkgs = {
          url = "github:nixos/nixpkgs/nixos-unstable";
        };

        flake-file = {
          url = "github:vic/flake-file";
        };

        flake-parts = {
          url = "github:hercules-ci/flake-parts";
          inputs.nixpkgs-lib.follows = "nixpkgs";
        };

        zig-flake = {
          url = "github:silversquirl/zig-flake";
          inputs.nixpkgs.follows = "nixpkgs";
        };

        zls = {
          url = "github:zigtools/zls/0.16.0";
          inputs.nixpkgs.follows = "nixpkgs";
          inputs.zig-flake.follows = "zig-flake";
        };
      };
    };

    perSystem =
      {
        pkgs,
        system,
        inputs',
        self',
        ...
      }:
      let
        fs = lib.fileset;
      in
      {
        packages.default = self'.packages.otzade;
        packages.otzade = pkgs.stdenvNoCC.mkDerivation {
          name = "otzade";
          version = "0.1.0";

          src = fs.toSource {
            root = ./.;
            fileset = fs.unions [
              ./build.zig
              ./src
            ];
          };

          __structuredAttrs = true;

          nativeBuildInputs = [
            inputs'.zig-flake.packages.zig_0_16_0
          ];

          zigReleaseMode = "fast";

          setupHook = pkgs.writeShellScript "otzade-setup-hook.sh" ''
            otzadeSign() {
              local filesDecl
              filesDecl=$(declare -p otzadeFiles 2>/dev/null || true)

              if [[ -z "''${otzadeMessage+x}" && -z "$filesDecl" ]]; then
                return 0
              fi

              if [[ -z "''${otzadeMessage+x}" || -z "$filesDecl" ]]; then
                echo 1>&2 'otzade hook: set both otzadeMessage and otzadeFiles'
                return 1
              fi

              if [[ "$filesDecl" =~ ^'declare -a otzadeFiles=' ]]; then
                local -a files=("''${otzadeFiles[@]}")
              else
                local -a files
                # NOTE: `otzadeFiles` is trusted build input
                eval "files=($otzadeFiles)"
              fi

              otzadeSignature=$(printf '%s' "$otzadeMessage" | otzade "''${files[@]}")
              export otzadeSignature
            }

            preFixupPhases+=(otzadeSign)
          '';

          meta.mainProgram = "otzade";
        };

        devShells.default = pkgs.mkShell {
          packages = [
            inputs'.zig-flake.packages.zig_0_16_0
            inputs'.zls.packages.default
          ];
        };
      };
  }
)

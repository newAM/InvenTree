{
  description = "InvenTree - Open Source Inventory Management System";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = {
    self,
    nixpkgs,
  }: let
    systems = [
      "x86_64-linux"
      "aarch64-linux"
    ];
    forEachSystem = nixpkgs.lib.genAttrs systems;

    # Parse the version out of the backend source
    inventreeVersion =
      nixpkgs.lib.strings.replaceStrings [" "] ["-"]
      (nixpkgs.lib.strings.removeSuffix ""
        (builtins.head (builtins.match ".*INVENTREE_SW_VERSION = '([^']+)'.*"
          (builtins.readFile ./src/backend/InvenTree/InvenTree/version.py))));

    commitHash =
      if self ? rev
      then self.rev
      else "unknown";

    # self.lastModifiedDate is "YYYYMMDDHHMMSS"; version.py wants a date
    commitDate = let
      lmd = self.lastModifiedDate or "19700101000000";
      substring = builtins.substring;
    in "${substring 0 4 lmd}-${substring 4 2 lmd}-${substring 6 2 lmd}";

    backendSrc = nixpkgs.lib.fileset.toSource {
      root = ./.;
      fileset = ./src/backend/InvenTree;
    };

    frontendSrc = nixpkgs.lib.fileset.toSource {
      root = ./src/frontend;
      fileset = nixpkgs.lib.fileset.unions [
        ./src/frontend/.babelrc
        ./src/frontend/.linguirc
        ./src/frontend/index.html
        ./src/frontend/lib
        ./src/frontend/package.json
        ./src/frontend/public
        ./src/frontend/src
        ./src/frontend/tsconfig.json
        ./src/frontend/tsconfig.lib.json
        ./src/frontend/tsconfig.node.json
        ./src/frontend/version-info.ts
        ./src/frontend/vite-env.d.ts
        ./src/frontend/vite.config.ts
        ./src/frontend/yarn.lock
      ];
    };

    overlay = final: prev: {
      inventree = prev.callPackage ./nix/package.nix {
        inherit
          backendSrc
          frontendSrc
          inventreeVersion
          commitHash
          commitDate
          ;
        # Substitute the real hashes from failed builds
        yarnDepsHash = "sha256-4jNo6YxHXJhSNhsgTMbYNhMgnHFc0n7Pd7bXvTVpvEY=";
        fsmPypiHash = "sha256-Djla/QP/UEr9R26FaMohOq/DMkvU5UJ+WzKH97Hn2Xk=";
      };
    };

    importPkgs = system:
      import nixpkgs {
        inherit system;
        overlays = [overlay];
      };
  in {
    overlays.default = overlay;

    packages = forEachSystem (
      system: let
        pkgs = importPkgs system;
      in
        nixpkgs.lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
          default = pkgs.inventree;
          inherit (pkgs) inventree;
        }
    );

    checks = forEachSystem (
      system: let
        pkgs = importPkgs system;
      in
        nixpkgs.lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
          inventree = pkgs.inventree;

          # Kanidm (IdP) + InvenTree (SP) SSO integration test
          sso = pkgs.callPackage ./nixos/tests/sso.nix {inherit self;};
        }
    );

    # Drop into an interactive NixOS VM (python driver REPL) with both
    # services running, for manual browser testing of the SSO flow:
    #
    #   nix run .#sso-vm
    #   > start()
    #
    # then open https://homeshare.home.arpa:10443 on the host (with
    # kanidm.home.arpa / homeshare.home.arpa pointing at 127.0.0.1).
    apps = forEachSystem (
      system: let
        pkgs = importPkgs system;
      in
        nixpkgs.lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
          sso-vm = {
            type = "app";
            program = "${self.checks.${system}.sso.driverInteractive}/bin/nixos-test-driver";
          };
        }
    );
  };
}

{
  description = "Reading list — read.jamesst.one and api-read.jamesst.one";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable";
    systems.url = "github:nix-systems/default";
  };

  nixConfig = {
    extra-substituters = [
      "https://cache.nixos.org"
      "https://nix-community.cachix.org"
    ];
    extra-trusted-public-keys = [
      "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
      "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
    ];
  };

  outputs =
    inputs:
    let
      eachSystem = inputs.nixpkgs.lib.genAttrs (import inputs.systems);
      pkgsFor = eachSystem (system: import inputs.nixpkgs { inherit system; });
    in
    {
      packages = eachSystem (system: rec {
        readinglist = pkgsFor.${system}.callPackage ./default.nix { };
        database = pkgsFor.${system}.callPackage ./database.nix { };
        default = readinglist;
      });

      checks = eachSystem (system: {
        readinglist = inputs.self.packages.${system}.readinglist;
        database = inputs.self.packages.${system}.database;
      });

      devShells = eachSystem (system: {
        default = pkgsFor.${system}.mkShell {
          packages = [
            inputs.self.packages.${system}.readinglist
          ]
          ++ (with pkgsFor.${system}; [
            git
            go
            jq
            shot-scraper
            sqlite-utils
          ]);

          # shot-scraper's playwright refuses to fetch its own browsers, so
          # point it at the ones nixpkgs already built.
          PLAYWRIGHT_BROWSERS_PATH = pkgsFor.${system}.playwright-driver.browsers;
          PLAYWRIGHT_SKIP_VALIDATE_HOST_REQUIREMENTS = "true";
        };
      });
    };
}

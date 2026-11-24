{
  description = "graf: an always-on temporal knowledge graph for coding agents";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    zig-overlay = {
      url = "github:mitchellh/zig-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      zig-overlay,
    }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      forAllSystems =
        f:
        nixpkgs.lib.genAttrs systems (
          system:
          f {
            pkgs = nixpkgs.legacyPackages.${system};
            zig = zig-overlay.packages.${system}."0.17.1";
          }
        );
      postgresFor = pkgs: pkgs.postgresql_17.withPackages (p: [ p.pgvector ]);
      devdbFor =
        pkgs:
        pkgs.writeShellApplication {
          name = "graf-devdb";
          runtimeInputs = [ (postgresFor pkgs) ];
          text = builtins.readFile ./scripts/devdb.sh;
        };
    in
    {
      devShells = forAllSystems (
        { pkgs, zig }:
        {
          default = pkgs.mkShell {
            packages = [
              zig
              (postgresFor pkgs)
              (devdbFor pkgs)
            ];
          };
        }
      );

      apps = forAllSystems (
        { pkgs, ... }:
        {
          devdb = {
            type = "app";
            program = "${devdbFor pkgs}/bin/graf-devdb";
          };
        }
      );

      formatter = forAllSystems ({ pkgs, ... }: pkgs.nixfmt-rfc-style);
    };
}

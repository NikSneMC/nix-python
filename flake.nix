{
  description = "An attempt to make python service creation easier";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    flake-compat = { url = "github:edolstra/flake-compat"; flake = false; };
  };

  outputs =
    { self
    , nixpkgs
    , flake-utils
    , ...
    }@inputs:
    let
      mkLib = pkgs: pkgs.lib.extend (_: _: { our = self.lib; });
    in
    {
      lib = import ./lib { lib = flake-utils.lib // nixpkgs.lib; };

      nixosModules = self.lib.rakeLeaves ./modules;

      hydraJobs = {
        checks = { inherit (self.checks) x86_64-linux; };
        packages = { inherit (self.packages) x86_64-linux; };
      };
    } // flake-utils.lib.eachDefaultSystem (system:
    let
      pkgs = import nixpkgs {
        inherit system;
        config = { allowUnfree = true; };
      };
    in
    rec {
      formatter = pkgs.nixpkgs-fmt;
    });
}
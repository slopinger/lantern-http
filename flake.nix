{
  description = "Lantern's independent incremental HTTP/1 library";
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  outputs = { self, nixpkgs }: let
    systems = [ "x86_64-linux" "aarch64-linux" ];
    each = nixpkgs.lib.genAttrs systems;
  in {
    packages = each (system: let pkgs = nixpkgs.legacyPackages.${system}; in {
      default = pkgs.haskellPackages.callCabal2nix "lantern-http" self {};
    });
    checks = each (system: { package = self.packages.${system}.default; });
    devShells = each (system: let pkgs = nixpkgs.legacyPackages.${system}; in {
      default = pkgs.haskellPackages.shellFor {
        packages = _: [ self.packages.${system}.default ];
        nativeBuildInputs = [ pkgs.cabal-install ];
      };
    });
  };
}

{
  description = "zigdoc";
  inputs = {
    nixpkgs = {
      url = "https://channels.nixos.org/nixos-unstable/nixexprs.tar.xz";
    };
  };
  outputs =
    {
      self,
      nixpkgs,
      ...
    }:
    let
      makePackages =
        system:
        import nixpkgs {
          inherit system;
        };
      forAllSystems = (
        function:
        nixpkgs.lib.genAttrs [
          "aarch64-darwin"
          "aarch64-linux"
          "x86_64-darwin"
          "x86_64-linux"
        ] (system: function (makePackages system))
      );
    in
    {
      devShells = forAllSystems (pkgs: {
        zig_0_15 = pkgs.mkShell {
          nativeBuildInputs = [
            pkgs.zig_0_15
          ];
        };
        default = self.devShells.${pkgs.system}.zig_0_15;
      });
      packages = forAllSystems (pkgs: {
        zigdoc =
          let
            zig_hook = pkgs.zig_0_15.hook.overrideAttrs {
              zig_default_flags = "-Dcpu=baseline -Doptimize=ReleaseFast --color off";
            };
          in
          pkgs.stdenv.mkDerivation (finalAttrs: {
            pname = "zigdoc";
            version = "0.0.0";
            src = ./.;
            nativeBuildInputs = [
              zig_hook
            ];
          });
        default = self.packages.${pkgs.system}.zigdoc;
      });
    };
}

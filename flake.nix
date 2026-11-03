{
  description = "envsafe: secret-safe .env editing for people and AI agents (release binaries)";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      sources = builtins.fromJSON (builtins.readFile ./packaging/nix/sources.json);
      systems = [ "x86_64-linux" "aarch64-linux" "aarch64-darwin" "x86_64-darwin" ];
      forAll = f: nixpkgs.lib.genAttrs systems (system: f system nixpkgs.legacyPackages.${system});
    in {
      packages = forAll (system: pkgs:
        let src = sources.${system}; in {
          default = pkgs.stdenv.mkDerivation {
            pname = "envsafe";
            version = sources.version;
            src = pkgs.fetchurl { inherit (src) url sha256; };
            sourceRoot = ".";
            nativeBuildInputs = pkgs.lib.optionals pkgs.stdenv.isLinux [ pkgs.autoPatchelfHook ];
            buildInputs = pkgs.lib.optionals pkgs.stdenv.isLinux [ pkgs.stdenv.cc.cc.lib pkgs.zlib ];
            dontBuild = true;
            installPhase = ''
              install -Dm755 envsafe $out/bin/envsafe
              install -Dm644 LICENSE $out/share/licenses/envsafe/LICENSE
            '';
            meta = {
              description = "Secret-safe .env editing for people and AI agents";
              homepage = "https://github.com/dev-centr/envsafe";
              license = pkgs.lib.licenses.mit;
              mainProgram = "envsafe";
              platforms = systems;
            };
          };
        });

      apps = forAll (system: pkgs: {
        default = { type = "app"; program = "${self.packages.${system}.default}/bin/envsafe"; };
      });
    };
}

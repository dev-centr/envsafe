# AUR and Nix

These files are generated from each release's `SHA256SUMS.txt` by `packaging/aur/render.sh`. The release
workflow runs the script on every tag and commits the result to `main`.

- `packaging/aur/PKGBUILD` and `.SRCINFO` define `envsafe-bin`, built from the Linux x64 and arm64 tarballs.
- `packaging/nix/sources.json` feeds `flake.nix` at the repo root.

Nothing is submitted automatically.

## Use without submitting

```sh
# Nix (any flake-enabled system)
nix run github:dev-centr/envsafe -- --version
nix profile install github:dev-centr/envsafe

# Arch: build the PKGBUILD locally
git clone https://github.com/dev-centr/envsafe && cd envsafe/packaging/aur && makepkg -si
```

## Publish to the AUR (manual; ask the maintainer first)

1. Add an SSH key to an AUR account.
2. Run `git clone ssh://aur@aur.archlinux.org/envsafe-bin.git`. Cloning a name that does not exist yet creates the package on the first push.
3. Copy `PKGBUILD` and `.SRCINFO` into that clone. Run `namcap PKGBUILD`, then `makepkg -si` in a clean Arch chroot or container.
4. Commit and `git push`. For each later release, repeat step 3 with the regenerated files.

## Submit to nixpkgs (manual; ask first)

The flake is enough for `nix run`. Adding envsafe to nixpkgs means a source build, with LDC and dub from
nixpkgs (`buildDubPackage`), under `pkgs/by-name/en/envsafe/package.nix`. The PR follows the nixpkgs
CONTRIBUTING guide. This has not been started.

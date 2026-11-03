#!/usr/bin/env bash
# Build an unsigned macOS .pkg that installs envsafe to /usr/local/bin.
# Usage: build-pkg.sh <binary> <version> <out.pkg>
set -euo pipefail
bin="$1"; ver="$2"; out="$3"
work="$(mktemp -d)"
mkdir -p "$work/root/usr/local/bin" "$work/root/usr/local/share/doc/envsafe"
install -m 0755 "$bin" "$work/root/usr/local/bin/envsafe"
cp README.md CHANGELOG.adoc LICENSE "$work/root/usr/local/share/doc/envsafe/"
pkgbuild --root "$work/root" --identifier org.devcentr.envsafe --version "$ver" \
  --install-location / "$work/envsafe-component.pkg"
productbuild --package "$work/envsafe-component.pkg" --identifier org.devcentr.envsafe \
  --version "$ver" "$out"
rm -rf "$work"

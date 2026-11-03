#!/usr/bin/env bash
# Print Formula/envsafe.rb for dev-centr/homebrew-tap from a release's SHA256SUMS.txt.
# Usage: render-formula.sh <version> <SHA256SUMS.txt>
set -euo pipefail
v="$1"; sums="$2"
sha() { awk -v f="$1" '$2==f {print $1}' "$sums"; }
mac="envsafe-$v-macos-universal.tar.gz"
[ -n "$(sha "$mac")" ] || mac="envsafe-$v-macos-arm64.tar.gz"
base="https://github.com/dev-centr/envsafe/releases/download/v$v"
for f in "$mac" "envsafe-$v-linux-x64.tar.gz" "envsafe-$v-linux-arm64.tar.gz"; do
  [ -n "$(sha "$f")" ] || { echo "missing checksum for $f" >&2; exit 1; }
done
cat <<RB
class Envsafe < Formula
  desc "Secret-safe .env editing for people and AI agents"
  homepage "https://github.com/dev-centr/envsafe"
  version "$v"
  license "MIT"

  on_macos do
    url "$base/$mac"
    sha256 "$(sha "$mac")"
  end

  on_linux do
    on_intel do
      url "$base/envsafe-$v-linux-x64.tar.gz"
      sha256 "$(sha "envsafe-$v-linux-x64.tar.gz")"
    end
    on_arm do
      url "$base/envsafe-$v-linux-arm64.tar.gz"
      sha256 "$(sha "envsafe-$v-linux-arm64.tar.gz")"
    end
  end

  def install
    bin.install "envsafe"
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/envsafe --version")
  end
end
RB

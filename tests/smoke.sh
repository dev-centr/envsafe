#!/usr/bin/env bash
# End-to-end check of the built binary: secrets go through a pipe, land in the
# file, and never appear on stdout or stderr. Usage: tests/smoke.sh [path-to-binary]
set -euo pipefail
BIN="${1:-./bin/envsafe}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
f="$work/.env"
printf '# app settings\r\n\r\nexport MODE="dev" # keep\r\n' > "$f"
secret="smoke-secret-$RANDOM-$RANDOM"
log="$work/log"

fail() { echo "FAIL: $*" >&2; exit 1; }

printf '%s\n' "$secret" | "$BIN" set API_KEY --stdin -f "$f" --dry-run >>"$log" 2>&1
grep -q API_KEY "$f" && fail "dry run wrote the file"
printf '%s\n' "$secret" | "$BIN" set API_KEY --stdin -f "$f" >>"$log" 2>&1
SRC_SECRET="$secret" "$BIN" set FROM_ENV --from-env SRC_SECRET -f "$f" >>"$log" 2>&1
"$BIN" list -f "$f" >>"$log" 2>&1
"$BIN" list -f "$f" --show-masked --json >>"$log" 2>&1
"$BIN" validate -f "$f" >>"$log" 2>&1
"$BIN" set X "$secret" -f "$f" >>"$log" 2>&1 && fail "argv value accepted"

grep -q -- "$secret" "$log" && fail "secret appeared in output"
grep -q -- "API_KEY=$secret" "$f" || fail "value not written"
[ "$(grep -c $'\r$' "$f")" = "5" ] || fail "CRLF line endings not preserved"
head -c 3 "$f" | grep -q $'\xEF\xBB\xBF' && fail "BOM written"
grep -q '^export MODE="dev" # keep' "$f" || fail "existing line changed"
ls "$work" | grep -q '\.tmp$' && fail "temp file left behind"
echo "smoke ok"

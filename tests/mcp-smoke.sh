#!/usr/bin/env bash
# Drives `envsafe mcp` over stdio and checks a secret set via from_env never shows in responses.
set -euo pipefail
BIN="${1:-./bin/envsafe}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
f="$work/.env"
printf '# c\nA=1\n' > "$f"
export MCP_SMOKE_SECRET="mcp-smoke-$RANDOM-$RANDOM"
if command -v cygpath >/dev/null; then fj="$(cygpath -m "$f")"; else fj="$f"; fi
out="$(printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"smoke","version":"0"}}}' \
  '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
  "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"envsafe_set\",\"arguments\":{\"key\":\"TOKEN\",\"from_env\":\"MCP_SMOKE_SECRET\",\"file\":\"$fj\"}}}" \
  "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"tools/call\",\"params\":{\"name\":\"envsafe_list\",\"arguments\":{\"file\":\"$fj\",\"show_masked\":true}}}" \
  | "$BIN" mcp)"
[ "$(printf '%s\n' "$out" | wc -l)" -eq 4 ] || { echo "FAIL: expected 4 responses"; echo "$out"; exit 1; }
printf '%s' "$out" | grep -q envsafe_validate || { echo "FAIL: tools/list"; exit 1; }
printf '%s' "$out" | grep -q 'TOKEN=\*\*\*\*' || { echo "FAIL: list"; exit 1; }
printf '%s' "$out" | grep -q -- "$MCP_SMOKE_SECRET" && { echo "FAIL: secret in MCP output"; exit 1; }
grep -q -- "TOKEN=$MCP_SMOKE_SECRET" "$f" || { echo "FAIL: value not written"; exit 1; }
echo "mcp smoke ok"

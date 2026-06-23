#!/bin/bash
# Differential harness: run a Lua file under golua and reference lua5.5.0,
# normalize program-name/temp-paths/hex-pointers, diff stdout+stderr+exit.
# Resource-limited: 30s wall, 32GB virtual memory. Concurrency-safe (mktemp).
# Usage: diff.sh <file.lua>  -> prints DIFF block + exits 1 if outputs differ.
GOLUA=${GOLUA:-/tmp/golua}
REF=${REF:-lua5.5.0}
f="$1"
dir=$(dirname "$f")
og=$(mktemp); rf=$(mktemp)
run() {
  local bin="$1"; local out="$2"
  ( ulimit -v 33554432; timeout 30 "$bin" "$f" ) >"$out" 2>&1
  echo "exit=$?" >> "$out"
  sed -i -E -e 's#^(golua|lua5\.5\.0):#PROG:#' \
            -e "s#${dir}/##g" \
            -e 's#0x[0-9a-fA-F]+#0xPTR#g' "$out"
}
run "$GOLUA" "$og"
run "$REF" "$rf"
rc=0
if ! diff -q "$og" "$rf" >/dev/null; then
  echo "=== DIFF for $f ==="
  echo "--- golua ---"; cat "$og"
  echo "--- ref ---";   cat "$rf"
  echo "=== END DIFF ==="
  rc=1
fi
rm -f "$og" "$rf"
exit $rc

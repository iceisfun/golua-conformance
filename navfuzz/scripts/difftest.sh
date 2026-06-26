#!/usr/bin/env bash
# difftest.sh : run one navfuzz Lua program under the golua runtime AND the
# PUC-Rio lua5.5.0 oracle, normalize, and diff stdout+stderr. The whole
# pipeline is integer-exact / IEEE-deterministic, so a PASS means golua and
# lua5.5.0 agree byte-for-byte; a FAIL is a real golua divergence (or a host
# crash — both runs are bounded by ulimit + timeout).
#
#   scripts/difftest.sh [-q] FILE.lua
#
# Env:
#   REFLUA     reference interpreter           (default lua5.5.0)
#   GOLUA      golua binary; if unset it is built from $GOLUA_REPO/cmd/lua
#   GOLUA_REPO golua checkout                  (default ~/work/golua)
#   TIMEOUT    per-process wall-clock cap, sec (default 1200)

set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAVDIR="$(dirname "$HERE")"
REFLUA="${REFLUA:-lua5.5.0}"
GOLUA_REPO="${GOLUA_REPO:-$HOME/work/golua}"
GOLUA="${GOLUA:-}"
TIMEOUT="${TIMEOUT:-1200}"

if [ -z "$GOLUA" ]; then
  GOLUA="$NAVDIR/golua"   # matches the repo-wide **/golua gitignore
  if [ ! -x "$GOLUA" ] || [ "$GOLUA_REPO/cmd/lua/main.go" -nt "$GOLUA" ]; then
    (cd "$GOLUA_REPO" && go build -o "$GOLUA" ./cmd/lua) \
      || { echo "difftest: golua build failed (set GOLUA or GOLUA_REPO)"; exit 2; }
  fi
fi

QUIET=0
if [ "${1:-}" = "-q" ]; then QUIET=1; shift; fi
FILE="${1:?usage: difftest.sh [-q] FILE.lua}"

norm() { sed -E -e 's/0x[0-9a-fA-F]+/0xADDR/g'; }

TMPO="$(mktemp)"; TMPG="$(mktemp)"
trap 'rm -f "$TMPO" "$TMPG"' EXIT

( cd "$NAVDIR" && ulimit -v 4000000 2>/dev/null; timeout "$TIMEOUT" "$REFLUA" "$FILE" ) >"$TMPO" 2>&1
RC_REF=$?
( cd "$NAVDIR" && ulimit -v 4000000 2>/dev/null; timeout "$TIMEOUT" "$GOLUA" "$FILE" ) >"$TMPG" 2>&1
RC_GO=$?

if diff <(norm <"$TMPO") <(norm <"$TMPG") >/dev/null && [ "$RC_REF" = "$RC_GO" ]; then
  [ "$QUIET" = 1 ] || echo "PASS $FILE"
  exit 0
fi

echo "FAIL $FILE (ref rc=$RC_REF golua rc=$RC_GO)"
diff <(norm <"$TMPO") <(norm <"$TMPG") | head -60
exit 1

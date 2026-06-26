#!/usr/bin/env bash
# difftest.sh : run a Lua program through the guest interpreter and the
# reference oracle, then compare stdout and the error message (tracebacks
# ignored).
#
#   difftest.sh FILE.lua            # diff one file (verbose)
#   difftest.sh -q FILE.lua         # quiet: only PASS/FAIL line
#
# Env:
#   ORACLE   reference interpreter (default /usr/bin/lua5.5.0; falls back to
#            $GOLUA then /tmp/golua for back-compat)
#   HOSTLUA  host Lua used to run the guest interpreter (default lua)

set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VMDIR="$(dirname "$HERE")"
GOLUA="${ORACLE:-${GOLUA:-/usr/bin/lua5.5.0}}"
HOSTLUA="${HOSTLUA:-lua}"

QUIET=0
if [ "${1:-}" = "-q" ]; then QUIET=1; shift; fi
FILE="$1"

norm() {
  sed -E \
    -e 's/0x[0-9a-fA-F]+/0xADDR/g' \
    -e 's/(table|function|thread|userdata|builtin): [0-9a-fA-Fxp]+/\1: 0xADDR/g'
}

# extract a single comparable error message from stderr: take the first line,
# strip the leading "prog: " prefix, drop traceback noise.
errmsg() {
  grep -v -E '^(stack traceback:|[[:space:]])' \
    | sed -E 's#^([^:]*/)?(lua5\.5\.0|lua5\.4|golua|lua55vm|lua):[[:space:]]*##' \
    | head -1
}

TMPO="$(mktemp)"; TMPE="$(mktemp)"
TMPO2="$(mktemp)"; TMPE2="$(mktemp)"
trap 'rm -f "$TMPO" "$TMPE" "$TMPO2" "$TMPE2"' EXIT

(cd "$VMDIR" && timeout 30 "$HOSTLUA" run.lua "$FILE" >"$TMPO" 2>"$TMPE")
OUR_RC=$?
timeout 30 "$GOLUA" "$FILE" >"$TMPO2" 2>"$TMPE2"
ORC_RC=$?

OUR_OUT="$(norm <"$TMPO")"
ORC_OUT="$(norm <"$TMPO2")"
OUR_ERR="$(errmsg <"$TMPE" | norm)"
ORC_ERR="$(errmsg <"$TMPE2" | norm)"

ok=1
[ "$OUR_OUT" = "$ORC_OUT" ] || ok=0
[ "$OUR_ERR" = "$ORC_ERR" ] || ok=0
# both should agree on whether an error occurred
if { [ "$OUR_RC" = 0 ] && [ "$ORC_RC" != 0 ]; } || { [ "$OUR_RC" != 0 ] && [ "$ORC_RC" = 0 ]; }; then
  ok=0
fi

if [ "$ok" -eq 1 ]; then
  echo "PASS $FILE"
  exit 0
fi

echo "FAIL $FILE"
if [ "$QUIET" -eq 0 ]; then
  if [ "$OUR_OUT" != "$ORC_OUT" ]; then
    echo "--- stdout diff (guest < / golua >) ---"
    diff <(printf '%s\n' "$OUR_OUT") <(printf '%s\n' "$ORC_OUT") | head -40
  fi
  if [ "$OUR_ERR" != "$ORC_ERR" ]; then
    echo "--- error diff ---"
    echo "guest: $OUR_ERR"
    echo "golua: $ORC_ERR"
  fi
  echo "--- exit: guest rc=$OUR_RC golua rc=$ORC_RC ---"
fi
exit 1

#!/usr/bin/env bash
# run_corpus.sh : difftest every tests/*.lua and the main.lua demo through
# golua vs lua5.5.0. Exits non-zero if any program diverges. Env is the same
# as difftest.sh (REFLUA / GOLUA / GOLUA_REPO / TIMEOUT).

set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAVDIR="$(dirname "$HERE")"

fail=0
run() {
  if ! "$HERE/difftest.sh" -q "$1" >/tmp/navfuzz_dt.$$ 2>&1; then
    fail=1
    echo "FAIL $1"
    cat /tmp/navfuzz_dt.$$
  else
    echo "PASS $1"
  fi
  rm -f /tmp/navfuzz_dt.$$
}

run "main.lua"
for t in "$NAVDIR"/tests/*.lua; do
  run "tests/$(basename "$t")"
done

if [ "$fail" = 0 ]; then
  echo "ALL PASS"
else
  echo "SOME FAILED"
fi
exit $fail

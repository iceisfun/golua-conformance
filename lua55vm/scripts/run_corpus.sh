#!/usr/bin/env bash
# run_corpus.sh : run difftest over a directory of .lua files, summarize.
#   run_corpus.sh [DIR]   (default: ../tests)
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIR="${1:-$HERE/../tests}"
DIFF="$HERE/difftest.sh"

pass=0; fail=0; failed=()
for f in "$DIR"/*.lua; do
  [ -e "$f" ] || continue
  if "$DIFF" -q "$f" >/dev/null 2>&1; then
    pass=$((pass+1))
  else
    fail=$((fail+1))
    failed+=("$f")
  fi
done
echo "PASS=$pass FAIL=$fail"
if [ "$fail" -gt 0 ]; then
  echo "failed:"
  for f in "${failed[@]}"; do echo "  $f"; done
fi

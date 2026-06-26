#!/usr/bin/env bash
# failing.sh : list golua tests that currently FAIL the differential check.
#   failing.sh [DIR]   (default: golua tests dir)
# Writes paths to stdout. Use to build a pinpoint worklist.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIR="${1:-/home/iceisfun/work/golua/tests}"
DIFF="$HERE/difftest.sh"
for f in "$DIR"/*.lua; do
  [ -e "$f" ] || continue
  "$DIFF" -q "$f" >/dev/null 2>&1 || echo "$f"
done

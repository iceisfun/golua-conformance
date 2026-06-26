#!/usr/bin/env bash
# golua_diff_via_vm.sh — hunt golua bugs via the DEEP execution path.
#
# Runs each guest as:  golua -> lua55vm -> guest   vs   REF -> lua55vm -> guest
# The SAME lua55vm runs on both hosts, so lua55vm's own incompleteness cancels
# and any divergence is golua running lua55vm differently than the reference —
# i.e. a golua bug surfaced only through the deep path. (Contrast difftest.sh,
# which validates lua55vm itself: lua55vm-on-host vs golua-direct.)
#
#   GOLUA=/tmp/golua REF=lua5.5.0 ./golua_diff_via_vm.sh GUEST.lua ...
#
# Hard-won caveats baked in (each caused false positives during bring-up):
#   * Compare stdout and stderr SEPARATELY — merged 2>&1 interleaves differently
#     because golua buffers stdout and flushes at exit (print-buffering tradeoff).
#   * Put guests in a golua-io-ALLOWED dir (CWD-relative or /tmp). golua's CLI io
#     provider denies reading e.g. ~/work/... ("access denied") -> empty output.
#   * Per-guest timeout: lua55vm is ~5x slower, so deep-recursion / heavy-churn
#     guests (call_chain_limit, table_move, sieves) time out — a perf artifact,
#     not a bug. Cross-check a suspected diff with golua-direct vs ref-direct.
#   * Cap output: a builder/`rep` guest can emit >2GB through lua55vm; skip those.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; VMDIR="$(dirname "$HERE")"
GOLUA="${GOLUA:-/tmp/golua}"; REF="${REF:-lua5.5.0}"; T="${T:-15}"; CAP="${CAP:-1000000}"
norm(){ head -c "$CAP" | sed -E -e 's/0x[0-9a-fA-F]+/0xADDR/g' \
  -e 's/(table|function|thread|userdata|builtin): [^ ]+/\1: 0xADDR/g' \
  -e 's#[^ :]*/([^/ :]+\.lua)#\1#g'; }
runvm(){ (cd "$VMDIR" && timeout "$T" "$1" run.lua "$2"); }
pass=0; diff=0; failed=()
for f in "$@"; do
  [ -e "$f" ] || continue
  go_o=$(runvm "$GOLUA" "$f" 2>/dev/null | norm); rf_o=$(runvm "$REF" "$f" 2>/dev/null | norm)
  go_e=$(runvm "$GOLUA" "$f" 2>&1 >/dev/null | norm); rf_e=$(runvm "$REF" "$f" 2>&1 >/dev/null | norm)
  if [ "$go_o" = "$rf_o" ] && [ "$go_e" = "$rf_e" ]; then pass=$((pass+1));
  else diff=$((diff+1)); failed+=("$f"); fi
done
echo "MATCH=$pass DIFF=$diff (golua->lua55vm vs $REF->lua55vm)"
for f in "${failed[@]:-}"; do [ -n "$f" ] && echo "  DIFF: $f  (verify vs golua-direct; may be a 5x-timeout or lua55vm gap)"; done
exit $([ "$diff" -gt 0 ] && echo 1 || echo 0)

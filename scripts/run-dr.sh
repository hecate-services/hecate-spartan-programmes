#!/usr/bin/env bash
#
# The within-slice REMOVE CONTROL (insight 019, Fable r16).
#
# This exists so the ladder stops comparing across slices.
#
# Every comparison so far has measured D0 and D1 on the CALIBRATION slice and set
# them against 018's 0.532 grounded drop, which was measured on the CONFIRMATORY
# slice. That mixing was flagged each time and never repaired, and it cannot be
# repaired from retained data: M1's per-item raw was never persisted, which is the
# defect fix 2 exists to stop recurring.
#
# So this runs the FROZEN verify prompt, verbatim and unmodified, over the same 35
# calibration items D0 and D1 used, with the same within-item pairing. Afterwards
# all three rungs sit on one slice and the comparison is exact.
#
# It is also the only observation that could put the capability floor back on the
# table. Fable r16 named the condition: a within-slice remove drop near 0.5,
# together with a salvage-corrected D1 still showing per-field anti-discrimination,
# would restore it. Anything else settles the mixing and leaves the withdrawal
# standing.
#
# NOTHING about the instrument is changed for this run. Not the prompt, not the
# parser, not the checker. A control that runs a different instrument than the one
# it is a control for is not a control.
#
# NOT SIGNABLE, as with every rung. Calibration slice, diagnostic only, no verdict.
#
# 35 items, two calls each, expect 30-90 minutes on the pinned local endpoint.

set -euo pipefail

CORPUS="${CORPUS:-corpora/m1/corpus.jsonl}"
PROVIDER="${PROVIDER:-local}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OUT="${OUT:-corpora/m1/dr-remove-control-${STAMP}-NOT-SIGNABLE.txt}"
RECORDS="${RECORDS:-corpora/m1/dr-records-${STAMP}-NOT-SIGNABLE.jsonl}"

[ -f "$CORPUS" ] || { echo "no corpus at $CORPUS" >&2; exit 1; }

echo "DR remove control: provider=$PROVIDER corpus=$CORPUS" >&2
echo "     url=${HECATE_LOCAL_URL:-<default>}" >&2
echo "     model=${HECATE_LOCAL_MODEL:-<default>}" >&2
echo "     raw feed -> $OUT" >&2
echo "     records  -> $RECORDS" >&2
echo "     NOT SIGNABLE: diagnostic only, calibration slice, no verdict" >&2
echo >&2

rebar3 compile >/dev/null

PA=$(printf ' -pa %s' _build/default/lib/*/ebin)

# shellcheck disable=SC2086
erl -noshell $PA -eval "
    _ = application:ensure_all_started(inets),
    _ = application:ensure_all_started(ssl),
    V = self_audit_ladder:dr(\"$PROVIDER\", \"$CORPUS\", \"$RECORDS\"),
    self_audit_ladder:summary(V),
    io:format(\"~n%% DR report term, for the record (NOT SIGNABLE):~n~p~n\", [V]),
    halt(0)
" 2>&1 | tee "$OUT"

echo >&2
echo "raw feed  -> $OUT" >&2
echo "records   -> $RECORDS" >&2
echo "Both are NOT SIGNABLE. They select the next rung; they decide nothing." >&2

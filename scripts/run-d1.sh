#!/usr/bin/env bash
#
# Ladder rung D1: the keep-instruction (insight 019).
#
# This exists so we can tell whether the self-audit destroyed good facts because
# of the POLARITY of its instruction, or because the model cannot confirm a long
# verbatim span at all.
#
# D0 established that the model re-emits a document losing nothing: zero items in
# thirty-five lost a grounded field to being retyped. So the 0.532 grounded fields
# per item that draft-then-verify destroyed were destroyed by the INSTRUCTION.
# D1 flips exactly one variable in that instruction, its default under doubt.
# The frozen prompt drops a field unless it can be confirmed; this one keeps a
# field unless it has been disconfirmed. Same task, same correction affordance,
# same message shape, same model, same slice.
#
#   If it discriminates (drops more ungrounded than grounded), mechanism (b) was
#   the channel: the deployable repair is one sentence of prompt and no second
#   engine is ever needed.
#
#   If it still destroys grounded material, mechanism (c) is live: confirming a
#   field means re-establishing a long verbatim substring by generation, and this
#   model class cannot. That survives an engine swap, and D2 would then be
#   measuring the task rather than the reviewer.
#
# NOT SIGNABLE, exactly as D0. Calibration slice, diagnostic only, no verdict, no
# pass, no fail. Artefacts carry NOT SIGNABLE in the filename so a later note
# quoting these numbers can be refused at the CLAIM gate.
#
# The endpoint is PINNED. 35 items, two calls each, expect 30-90 minutes.

set -euo pipefail

CORPUS="${CORPUS:-corpora/m1/corpus.jsonl}"
PROVIDER="${PROVIDER:-local}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OUT="${OUT:-corpora/m1/d1-keep-instruction-${STAMP}-NOT-SIGNABLE.txt}"
RECORDS="${RECORDS:-corpora/m1/d1-records-${STAMP}-NOT-SIGNABLE.jsonl}"

[ -f "$CORPUS" ] || { echo "no corpus at $CORPUS" >&2; exit 1; }

echo "D1 keep-instruction: provider=$PROVIDER corpus=$CORPUS" >&2
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
    V = self_audit_ladder:d1(\"$PROVIDER\", \"$CORPUS\", \"$RECORDS\"),
    self_audit_ladder:summary(V),
    io:format(\"~n%% D1 report term, for the record (NOT SIGNABLE):~n~p~n\", [V]),
    halt(0)
" 2>&1 | tee "$OUT"

echo >&2
echo "raw feed  -> $OUT" >&2
echo "records   -> $RECORDS" >&2
echo "Both are NOT SIGNABLE. They select the next rung; they decide nothing." >&2

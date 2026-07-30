#!/usr/bin/env bash
#
# Ladder rung D0: the copy control (insight 019).
#
# This exists so we can tell whether the self-audit's destruction of good facts is
# verification failing, or just the model retyping badly.
#
# NOT SIGNABLE. This is a diagnostic, and it is pre-registered as one. It runs on
# the CALIBRATION slice, which was spent on the frozen token ceiling and the base
# ungrounded rate and never contributed to a verdict, so it consumes nothing that
# a future experiment needs. Insight 017 licenses a quantity learned from run 1 to
# inform SIZING AND DESIGN, never SELECTION. Accordingly D0 emits no pass, no fail
# and no verdict: its only outputs are a design decision (which rung runs next) and
# an effect size for sizing. Its raw feed and its record store are committed with
# NOT SIGNABLE in the filename so a later note quoting their numbers can be refused
# at the CLAIM gate.
#
# What it measures: one draft, then a second pass whose ONLY difference from the
# verify pass 018 signed is the system prompt. Same article, same draft, same
# message shape, but the instruction is "reproduce exactly" rather than "remove
# what you cannot confirm". Any field lost between the two was lost by
# REGENERATING the document, with no verification decision taken at all. That is
# mechanism (d) in insight 019, and it survives an engine swap, so it is worth
# knowing before anything larger is built.
#
# The endpoint is PINNED: one model, one version, no rotation, no rate limit. See
# experiments/m1_self_audit/pinned_provider.erl.
#
# 35 items, two calls each. CPU inference is 25-80s per call, so expect 30-90
# minutes. Free, unmetered, offline.

set -euo pipefail

CORPUS="${CORPUS:-corpora/m1/corpus.jsonl}"
PROVIDER="${PROVIDER:-local}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OUT="${OUT:-corpora/m1/d0-copy-control-${STAMP}-NOT-SIGNABLE.txt}"
RECORDS="${RECORDS:-corpora/m1/d0-records-${STAMP}-NOT-SIGNABLE.jsonl}"

[ -f "$CORPUS" ] || { echo "no corpus at $CORPUS" >&2; exit 1; }

echo "D0 copy control: provider=$PROVIDER corpus=$CORPUS" >&2
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
    V = self_audit_ladder:d0(\"$PROVIDER\", \"$CORPUS\", \"$RECORDS\"),
    self_audit_ladder:summary(V),
    io:format(\"~n%% D0 report term, for the record (NOT SIGNABLE):~n~p~n\", [V]),
    halt(0)
" 2>&1 | tee "$OUT"

echo >&2
echo "raw feed  -> $OUT" >&2
echo "records   -> $RECORDS" >&2
echo "Both are NOT SIGNABLE. They select the next rung; they decide nothing." >&2

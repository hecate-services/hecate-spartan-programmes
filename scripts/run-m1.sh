#!/usr/bin/env bash
#
# Run experiment M1 (insight 014): self-audit economics.
#
# THIS SCORES THE CONFIRMATORY SLICE, AND IT IS SCORED ONCE.
# `self_audit_assay:run/2` performs calibration and confirmatory scoring in a
# single pass, freezing the token ceiling and the base ungrounded rate from the
# calibration slice BEFORE it scores anything. There is no way to "just calibrate".
# Running this is a decision, not a build step.
#
# The endpoint must be PINNED: one model, one version, no rotation, no rate limit.
# See experiments/m1_self_audit/pinned_provider.erl for why, and for how the model
# was chosen (on JSON reliability, before any scoring).
#
# Expect a few hours. CPU inference is 25-80s per call and the run makes three
# calls per item across the corpus. Free, unmetered, offline.

set -euo pipefail

CORPUS="${CORPUS:-corpora/m1/corpus.jsonl}"
PROVIDER="${PROVIDER:-local}"
OUT="${OUT:-corpora/m1/raw-feed-$(date -u +%Y%m%dT%H%M%SZ).txt}"

[ -f "$CORPUS" ] || { echo "no corpus at $CORPUS" >&2; exit 1; }

echo "M1: provider=$PROVIDER corpus=$CORPUS" >&2
echo "     url=${HECATE_LOCAL_URL:-<default>}" >&2
echo "     model=${HECATE_LOCAL_MODEL:-<default>}" >&2
echo "     raw feed -> $OUT" >&2
echo >&2

rebar3 compile >/dev/null

PA=$(printf ' -pa %s' _build/default/lib/*/ebin)

# The raw feed is part of the record, so it is captured rather than watched.
# shellcheck disable=SC2086
erl -noshell $PA -eval "
    _ = application:ensure_all_started(inets),
    _ = application:ensure_all_started(ssl),
    V = self_audit_assay:run(\"$PROVIDER\", \"$CORPUS\"),
    self_audit_assay:summary(V),
    io:format(\"~n%% verdict term, for the record:~n~p~n\", [V]),
    halt(0)
" 2>&1 | tee "$OUT"

echo >&2
echo "raw feed written to $OUT" >&2
echo "commit it beside the corpus: it is one of the four artefacts." >&2

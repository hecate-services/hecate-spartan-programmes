%%% @doc The 019 diagnostic ladder, rung D0: the copy control.
%%%
%%% This exists so we can tell whether the self-audit's destruction of good facts
%%% is verification failing, or just the model retyping badly.
%%%
%%% 018 signed that draft-then-verify deletes grounded material over ungrounded.
%%% 019 then found, from arithmetic already in the record, that it deletes grounded
%%% fields at a HIGHER PER-FIELD RATE than ungrounded ones, so it is not merely
%%% blind, it is anti-discriminating. Four mechanisms could do that and only one of
%%% them, self-blindness, makes a second engine worth paying for. Two of the other
%%% three survive an engine swap entirely:
%%%
%%%   (c) capability floor: confirming a field means re-establishing a long
%%%       verbatim substring by generation, which this model class cannot do, so
%%%       "remove what you cannot confirm" removes the best-cited material;
%%%   (d) regeneration loss: the verify pass re-emits the WHOLE document, so fields
%%%       die by rewrite attrition with no verification decision taken at all.
%%%
%%% D0 measures (d) alone, and it is the cheapest decisive run available: the copy
%%% pass is byte-identical to the verify pass except for its system prompt, so any
%%% field lost was lost by regenerating rather than by judging.
%%%
%%% NOT SIGNABLE, by construction and by pre-registration. This runs on the
%%% CALIBRATION slice, which was spent on the frozen token ceiling and the base
%%% rate and never contributed to a verdict. 017 licenses a quantity learned from
%%% run 1 to inform SIZING AND DESIGN, never SELECTION. So D0 emits no verdict, no
%%% pass, no fail. Its only outputs are a design decision and an effect size. The
%%% report says so on every line that could be mistaken for a result.
-module(self_audit_ladder).

-export([d0/2, d0/3, d1/2, d1/3, dr/2, dr/3, summary/1]).
%% Pure arithmetic, exported so the report can be tested without a backend.
-export([report/3]).

%% 018's per-item deletions on the 79 cleanly-scored confirmatory items, quoted
%% for orientation only. D0 runs a different slice and a different arm, so these
%% are a reference point and NOT a comparator.
-define(DV_DROP_GROUNDED, 0.532).
-define(DV_DROP_UNGROUNDED, 0.063).

-spec d0(string(), file:name_all()) -> map() | {error, term()}.
d0(Provider, CorpusPath) ->
    d0(Provider, CorpusPath, none).

%% @doc Run D0 over the calibration slice, writing every pass and every paired
%% count to `RecordPath' (FIX 2). Pass `none' to run without a store.
-spec d0(string(), file:name_all(), file:name_all() | none) -> map() | {error, term()}.
d0(Provider, CorpusPath, RecordPath) ->
    run(copy, Provider, CorpusPath, RecordPath).

-spec d1(string(), file:name_all()) -> map() | {error, term()}.
d1(Provider, CorpusPath) ->
    d1(Provider, CorpusPath, none).

%% @doc Rung D1, the keep-instruction. Same slice, same model, same message shape
%% as D0 and as the arm 018 signed; the only difference is the polarity of the
%% verify prompt's default. D0 established that the model can re-emit a document
%% losing nothing, so whatever destroyed 0.532 grounded fields per item was the
%% instruction. D1 asks whether it was the instruction's DEFAULT.
%%
%% Reading, pre-committed in insight 019: if the keep-framing discriminates where
%% the remove-framing did not, mechanism (b) was the channel and the deployable
%% repair is one sentence of prompt. If it also destroys grounded material, the
%% capability floor (c) is live, which survives an engine swap and would make D2 a
%% measurement of the task rather than of the reviewer.
-spec d1(string(), file:name_all(), file:name_all() | none) -> map() | {error, term()}.
d1(Provider, CorpusPath, RecordPath) ->
    run(keep, Provider, CorpusPath, RecordPath).

%% @doc The remove control: the FROZEN verify prompt over the same calibration
%% slice D0 and D1 used, with the same within-item pairing.
%%
%% This is a denominator, not a rung. Every comparison the ladder has made against
%% 018's 0.532 grounded drop has mixed slices, because 018 measured the
%% confirmatory slice and the ladder runs calibration. Fable r16 named this as the
%% cheapest missing observation and as the only one that could put the capability
%% floor back on the table: a within-slice remove drop near 0.5, together with a
%% salvage-corrected D1 still showing per-field anti-discrimination, would restore
%% it. Anything else settles the mixing and leaves the withdrawal standing.
-spec dr(string(), file:name_all()) -> map() | {error, term()}.
dr(Provider, CorpusPath) ->
    dr(Provider, CorpusPath, none).

-spec dr(string(), file:name_all(), file:name_all() | none) -> map() | {error, term()}.
dr(Provider, CorpusPath, RecordPath) ->
    run(remove, Provider, CorpusPath, RecordPath).

run(Variant, Provider, CorpusPath, RecordPath) ->
    with_corpus(self_audit_corpus:load(CorpusPath), Variant, Provider, RecordPath).

with_corpus({error, R}, _Variant, _Provider, _RecordPath) ->
    {error, R};
with_corpus({ok, Items}, Variant, Provider, RecordPath) ->
    ensure_started(),
    {Calib, _Confirm} = self_audit_corpus:split(Items, calib_n(length(Items))),
    Store = self_audit_record:open(RecordPath),
    Scored = [score(Variant, Provider, I, Store) || I <- Calib],
    ok = self_audit_record:close(Store),
    report(rung_of(Variant), Scored, length(Calib)).

rung_of(copy)   -> d0;
rung_of(keep)   -> d1;
rung_of(remove) -> dr.

%% The same split the M1 assay uses, so "the calibration slice" means one thing.
calib_n(N) -> max(1, N div 4).

%% --- one item ---

score(Variant, Provider, #{id := Id, text := Text}, Store) ->
    Emit = fun(Row) -> self_audit_record:emit(Store, Row#{item => Id}) end,
    tally(self_audit_extract:paired(Variant, Provider, Text, Emit), Text, Id, Store).

tally({error, Reason}, _Text, Id, Store) ->
    ok = self_audit_record:emit(Store, #{kind => item, item => Id, outcome => failed,
                                         error => fmt(Reason)}),
    {fail, Reason};
tally({ok, DraftFields, SecondFields, U, _Calls}, Text, Id, Store) ->
    Draft = self_audit_checker:tally(Text, DraftFields),
    Copy = self_audit_checker:tally(Text, SecondFields),
    ok = self_audit_record:emit(Store, #{kind => item, item => Id, outcome => ok,
                                         draft => Draft, copy => Copy,
                                         tokens => maps:get(total, U),
                                         elapsed_ms => maps:get(elapsed_ms, U),
                                         truncated => maps:get(truncated, U, false),
                                         model => maps:get(model, U)}),
    {ok, #{draft => Draft, copy => Copy, usage => U}}.

fmt(Reason) -> iolist_to_binary(io_lib:format("~p", [Reason])).

%% --- the report: an effect size, never a verdict ---

-spec report(d0 | d1 | dr, [{ok, map()} | {fail, term()}], non_neg_integer()) -> map().
report(Rung, Scored, NItems) ->
    Rows = [R || {ok, R} <- Scored],
    DraftG = [count(draft, grounded, R) || R <- Rows],
    DraftU = [count(draft, ungrounded, R) || R <- Rows],
    CopyG  = [count(copy, grounded, R) || R <- Rows],
    CopyU  = [count(copy, ungrounded, R) || R <- Rows],
    DropG = self_audit_referee:mean(DraftG) - self_audit_referee:mean(CopyG),
    DropU = self_audit_referee:mean(DraftU) - self_audit_referee:mean(CopyU),
    #{rung => Rung, signable => false, items => NItems, scored => length(Rows),
      %% D1's headline: did the keep-framing DISCRIMINATE, i.e. drop more
      %% ungrounded than grounded? That is the direction 018's remove-framing
      %% failed. Reported for D0 too, where it is expected to be ~0 either way.
      discriminates => DropU > DropG,
      items_losing_grounded => length([1 || R <- Rows, delta(grounded, R) < 0]),
      items_losing_ungrounded => length([1 || R <- Rows, delta(ungrounded, R) < 0]),
      failed => length(Scored) - length(Rows),
      mean_draft_grounded => self_audit_referee:mean(DraftG),
      mean_copy_grounded => self_audit_referee:mean(CopyG),
      mean_draft_ungrounded => self_audit_referee:mean(DraftU),
      mean_copy_ungrounded => self_audit_referee:mean(CopyU),
      attrition_grounded => DropG,
      attrition_ungrounded => DropU,
      %% What fraction of the grounded destruction 018 signed could be pure
      %% regeneration attrition, if this slice behaves like that one. Orientation,
      %% not inference: different slice, different arm, no pairing between them.
      share_of_dv_grounded_drop => share(DropG, ?DV_DROP_GROUNDED),
      %% INSTRUMENT DEFECT 3, found 2026-07-31 by running D0's smoke item.
      %% `self_audit_extract:to_field/1' guards on `is_binary(V)', but a model
      %% asked for a `number' field naturally emits a JSON NUMBER, and that field
      %% is then dropped into neither grounded, nor ungrounded, nor excluded. It
      %% vanishes without trace. An item whose extraction was all numeric scores
      %% zero fields and contributes nothing to either mean, so the effective n is
      %% smaller than the slice and nothing in the summary said so.
      %%
      %% NOT silently repaired: 014 froze the checker and requires a signed
      %% amendment rather than a quiet retune, and the repair is not cosmetic
      %% (a bare 100000 does not occur inside "up to 100,000 jobs", so coercing
      %% numerics to binary would newly mark them UNGROUNDED and move the base
      %% rate). Counted and reported instead, so the cost is visible in the run
      %% that pays it.
      zero_field_items => length([1 || R <- Rows, fields_in(draft, R) =:= 0]),
      mean_draft_excluded => self_audit_referee:mean([count(draft, excluded, R) || R <- Rows]),
      truncated_items => length([1 || R <- Rows, maps:get(truncated, maps:get(usage, R), false)]),
      total_tokens => lists:sum([maps:get(total, maps:get(usage, R)) || R <- Rows]),
      model => model_of(Rows)}.

count(Arm, Key, Row) -> maps:get(Key, maps:get(Arm, Row)).

%% Every field the checker actually saw, on one arm of one item.
fields_in(Arm, Row) ->
    count(Arm, grounded, Row) + count(Arm, ungrounded, Row) + count(Arm, excluded, Row).

%% Signed per-item change, second pass minus draft. Negative means the pass
%% removed fields of that kind.
delta(Key, Row) -> count(copy, Key, Row) - count(draft, Key, Row).

share(_Drop, +0.0) -> 0.0;
share(Drop, Ref)   -> Drop / Ref.

model_of([])            -> undefined;
model_of([R | _Rest])   -> maps:get(model, maps:get(usage, R)).

%% --- runtime + readable summary ---

ensure_started() ->
    _ = application:ensure_all_started(inets),
    _ = application:ensure_all_started(ssl),
    ok.

-spec summary(map() | {error, term()}) -> ok.
summary({error, R}) ->
    io:format("D0 error: ~p~n", [R]);
summary(V) ->
    Rung = maps:get(rung, V),
    io:format("~n~s (insight 019) -- NOT SIGNABLE, diagnostic only~n", [title(Rung)]),
    io:format("  calibration slice: scored ~b/~b items (~b failed), model=~s~n",
              [maps:get(scored, V), maps:get(items, V), maps:get(failed, V),
               model_str(maps:get(model, V))]),
    io:format("  grounded/item:   draft=~.3f  after ~s=~.3f~n",
              [maps:get(mean_draft_grounded, V), second_of(Rung),
               maps:get(mean_copy_grounded, V)]),
    io:format("  ungrounded/item: draft=~.3f  after ~s=~.3f~n",
              [maps:get(mean_draft_ungrounded, V), second_of(Rung),
               maps:get(mean_copy_ungrounded, V)]),
    io:format("  ~s:  grounded=~.3f  ungrounded=~.3f~n",
              [drop_label(Rung), maps:get(attrition_grounded, V),
               maps:get(attrition_ungrounded, V)]),
    io:format("  DISCRIMINATES (dropped more ungrounded than grounded)? ~w   "
              "items losing grounded=~b  losing ungrounded=~b~n",
              [maps:get(discriminates, V), maps:get(items_losing_grounded, V),
               maps:get(items_losing_ungrounded, V)]),
    io:format("  for orientation only, 018 signed draft_verify dropping "
              "grounded=~.3f ungrounded=~.3f~n",
              [?DV_DROP_GROUNDED, ?DV_DROP_UNGROUNDED]),
    io:format("  so ~s accounts for ~.1f percent of that grounded drop~n",
              [share_label(Rung), 100.0 * maps:get(share_of_dv_grounded_drop, V)]),
    io:format("  INSTRUMENT: ~b/~b items scored ZERO fields (numeric-valued fields are "
              "dropped untraced)~n",
              [maps:get(zero_field_items, V), maps:get(scored, V)]),
    io:format("  excluded/item=~.3f  truncated items=~b  total tokens=~b~n",
              [maps:get(mean_draft_excluded, V), maps:get(truncated_items, V),
               maps:get(total_tokens, V)]),
    io:format("  ==> NO VERDICT. This selects the next rung, nothing else.~n~n"),
    ok.

model_str(undefined)           -> "?";
model_str(M) when is_binary(M) -> M;
model_str(M)                   -> io_lib:format("~p", [M]).

title(d0) -> "D0 copy control";
title(d1) -> "D1 keep-instruction";
title(dr) -> "DR remove control (the FROZEN verify prompt, within-slice)".

second_of(d0) -> "copy";
second_of(d1) -> "keep";
second_of(dr) -> "remove".

drop_label(d0) -> "ATTRITION (lost with no verification asked)";
drop_label(d1) -> "DROPPED by the keep-framed verifier";
drop_label(dr) -> "DROPPED by the frozen remove-framed verifier".

share_label(d0) -> "pure regeneration";
share_label(d1) -> "the keep-framing";
share_label(dr) -> "this slice's own remove-framing".

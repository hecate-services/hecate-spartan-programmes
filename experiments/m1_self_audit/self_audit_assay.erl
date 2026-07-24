%%% @doc Experiment M1's orchestrator (insight 014). Loads the frozen corpus, splits
%%% it into a calibration slice and a disjoint confirmatory slice, FREEZES the token
%%% ceiling and the base ungrounded rate from calibration BEFORE scoring, then runs
%%% both arms paired (interleaved per item, same pinned provider, temperature 0) over
%%% the confirmatory slice and hands the paired tallies to the referee.
%%%
%%% Local, single process, deterministic given a fixed corpus and a temperature-0
%%% provider — the same discipline as the arena harness.
-module(self_audit_assay).

-export([run/2, run/3, summary/1]).
%% Run-validity predicate, exported for testing: 014's mid-run model change.
-export([model_stable/1]).

-spec run(string(), file:name_all()) -> map() | {error, term()}.
run(Provider, CorpusPath) ->
    with_corpus(self_audit_corpus:load(CorpusPath), Provider, default_calib).

-spec run(string(), file:name_all(), non_neg_integer()) -> map() | {error, term()}.
run(Provider, CorpusPath, NCalib) ->
    with_corpus(self_audit_corpus:load(CorpusPath), Provider, NCalib).

with_corpus({error, R}, _Provider, _NCalib) -> {error, R};
with_corpus({ok, Items}, Provider, NCalibArg) ->
    ensure_started(),
    NCalib = calib_n(NCalibArg, length(Items)),
    {Calib, Confirm} = self_audit_corpus:split(Items, NCalib),
    CalibScored = score_all(Provider, Calib),
    {Ceiling, Base} = calibrate(CalibScored),
    ConfirmScored = score_all(Provider, Confirm),
    Rows = [Row || {ok, Row} <- ConfirmScored],
    Verdict = self_audit_referee:verdict(Rows, Ceiling, Base),
    finalize(Verdict, ConfirmScored, CalibScored).

%% Insight 014: "model/stack version change mid-run -> void". The model travels on
%% every ledger row, so a run that silently changed engine mid-flight cannot
%% adjudicate. Checked across calibration AND confirmatory rows, because a change
%% between the two slices invalidates the frozen ceiling just as badly.
model_stable(Scored) ->
    length(lists:usort([maps:get(model, R) || {ok, R} <- Scored])) =< 1.

calib_n(default_calib, N) -> max(1, N div 4);
calib_n(NCalib, N)        -> min(NCalib, N).

%% --- scoring one item on both arms (interleaved) ---

score_all(Provider, Items) -> [score_item(Provider, I) || I <- Items].

score_item(Provider, #{text := Text}) ->
    Sp = self_audit_extract:extract(single_pass, Provider, Text),
    Dv = self_audit_extract:extract(draft_verify, Provider, Text),
    combine(Sp, Dv, Text).

combine({ok, SpF, SpU, _}, {ok, DvF, DvU, _}, Text) ->
    {ok, #{sp => self_audit_checker:tally(Text, SpF),
           dv => self_audit_checker:tally(Text, DvF),
           sp_tokens => maps:get(total, SpU),
           dv_tokens => maps:get(total, DvU),
           %% the rest of the ledger: wall-clock and retries per arm (014), plus
           %% cached tokens (observational, adjudicates nothing) and the model
           %% the row was produced by (feeds the mid-run-change void).
           sp_ms => maps:get(elapsed_ms, SpU),
           dv_ms => maps:get(elapsed_ms, DvU),
           retries => maps:get(retries, SpU) + maps:get(retries, DvU),
           cached => maps:get(cached, SpU) + maps:get(cached, DvU),
           model => maps:get(model, SpU)}};
combine({ok, _, _, _}, _DvErr, _Text) -> {fail, dv};
combine(_SpErr, {ok, _, _, _}, _Text) -> {fail, sp};
combine(_SpErr, _DvErr, _Text)        -> {fail, both}.

%% --- calibration: freeze ceiling and base rate from the calib slice ---

calibrate(Scored) ->
    Rows = [R || {ok, R} <- Scored],
    {ceiling_from(Rows), base_rate(Rows)}.

ceiling_from([]) -> 3.0;
ceiling_from(Rows) ->
    SpTok = self_audit_referee:mean([maps:get(sp_tokens, R) || R <- Rows]),
    DvTok = self_audit_referee:mean([maps:get(dv_tokens, R) || R <- Rows]),
    ratio(DvTok, SpTok) * 1.1.

ratio(_D, +0.0) -> 3.0;
ratio(D, S)     -> D / S.

base_rate([]) -> 0.0;
base_rate(Rows) ->
    G = lists:sum([g(grounded, R) || R <- Rows]),
    U = lists:sum([g(ungrounded, R) || R <- Rows]),
    rate(U, G + U).

g(Key, Row) -> maps:get(Key, maps:get(sp, Row)).

rate(_U, 0) -> 0.0;
rate(U, T)  -> U / T.

%% --- assemble the report (verdict + parse-failure gap + slice sizes) ---

finalize(Verdict, ConfirmScored, CalibScored) ->
    SpFail = fail_rate(sp, ConfirmScored),
    DvFail = fail_rate(dv, ConfirmScored),
    All = ConfirmScored ++ CalibScored,
    Stable = model_stable(All),
    Rows = [R || {ok, R} <- ConfirmScored],
    Verdict#{confirm_items => length(ConfirmScored),
             confirm_scored => length(Rows),
             sp_parse_fail => SpFail, dv_parse_fail => DvFail,
             parse_fail_gap_ok => abs(SpFail - DvFail) =< 0.05,
             calib_items => length(CalibScored),
             calib_scored => length([1 || {ok, _} <- CalibScored]),
             model => run_model(All), model_stable => Stable,
             mean_sp_ms => self_audit_referee:mean(ledger(sp_ms, Rows)),
             mean_dv_ms => self_audit_referee:mean(ledger(dv_ms, Rows)),
             total_retries => lists:sum(ledger(retries, Rows)),
             total_cached => lists:sum(ledger(cached, Rows)),
             void := maps:get(void, Verdict) orelse not Stable,
             pass := maps:get(pass, Verdict) andalso Stable}.

ledger(Key, Rows) -> [maps:get(Key, R) || R <- Rows].

run_model(Scored) -> first_model(lists:usort([maps:get(model, R) || {ok, R} <- Scored])).

first_model([])      -> undefined;
first_model([M | _]) -> M.

fail_rate(_Arm, []) -> 0.0;
fail_rate(Arm, Scored) ->
    length([1 || S <- Scored, failed(Arm, S)]) / length(Scored).

failed(sp, {fail, sp})   -> true;
failed(dv, {fail, dv})   -> true;
failed(_Arm, {fail, both}) -> true;
failed(_Arm, _Other)     -> false.

%% --- runtime + readable summary ---

ensure_started() ->
    _ = application:ensure_all_started(inets),
    _ = application:ensure_all_started(ssl),
    ok.

-spec summary(map()) -> ok.
summary({error, R}) ->
    io:format("M1 error: ~p~n", [R]);
summary(V) ->
    io:format("M1 self-audit economics  n=~b (scored ~b/~b confirm; ~b/~b calib)~n",
              [maps:get(n, V), maps:get(confirm_scored, V), maps:get(confirm_items, V),
               maps:get(calib_scored, V), maps:get(calib_items, V)]),
    io:format("  ungrounded/item: single_pass=~.3f draft_verify=~.3f  (rel reduction ~.1f%%)~n",
              [maps:get(mean_sp_ungrounded, V), maps:get(mean_dv_ungrounded, V),
               100.0 * maps:get(rel_reduction, V)]),
    io:format("  grounded/item:   single_pass=~.3f draft_verify=~.3f~n",
              [maps:get(mean_sp_grounded, V), maps:get(mean_dv_grounded, V)]),
    io:format("  drop grounded=~.3f  drop ungrounded=~.3f  (L2 wants grounded<ungrounded)~n",
              [maps:get(drop_grounded, V), maps:get(drop_ungrounded, V)]),
    io:format("  token ratio=~.3fx  ceiling=~.3fx  base ungrounded rate=~.3f~n",
              [maps:get(token_ratio, V), maps:get(ceiling, V),
               maps:get(base_ungrounded_rate, V)]),
    %% Milliseconds are rounded to integers rather than printed with `~.0f':
    %% Erlang's float precision must be > 0, so `~.0f' raises badarg. It did, in
    %% the summary path, which runs AFTER scoring — a long run would have
    %% completed and then died before recording its verdict.
    io:format("  ledger: wall-clock/item single_pass=~bms draft_verify=~bms  "
              "retries=~b cached_tokens=~b~n",
              [round(maps:get(mean_sp_ms, V)), round(maps:get(mean_dv_ms, V)),
               maps:get(total_retries, V), maps:get(total_cached, V)]),
    io:format("  model=~s stable=~w~n", [model_str(maps:get(model, V)), maps:get(model_stable, V)]),
    io:format("  L1=~w L2=~w ceiling_ok=~w above_noise=~w void=~w parse_gap_ok=~w~n",
              [maps:get(l1, V), maps:get(l2, V), maps:get(ceiling_ok, V),
               maps:get(above_noise, V), maps:get(void, V), maps:get(parse_fail_gap_ok, V)]),
    io:format("  ==> ~s~n", [verdict_line(V)]),
    ok.

model_str(undefined)              -> "?";
model_str(M) when is_binary(M)    -> M;
model_str(M)                      -> io_lib:format("~p", [M]).

verdict_line(#{model_stable := false}) -> "VOID (model changed mid-run)";
verdict_line(#{void := true})  -> "VOID (cannot adjudicate)";
verdict_line(#{pass := true})  -> "PASS: self-audit earns its compute on attributed extraction";
verdict_line(#{pass := false}) -> "FAIL: self-audit does not earn its compute on this workload".

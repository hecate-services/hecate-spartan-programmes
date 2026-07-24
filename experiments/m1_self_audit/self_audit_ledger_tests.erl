%%% @doc Tests for M1's cost ledger (insight 014).
%%%
%%% 014 names three ledger requirements: prompt + completion tokens, WALL-CLOCK
%%% per item, and RETRIES counted. Before this, only the three token counts were
%%% captured, so a retry loop (real seconds, zero tokens on a 429) was invisible
%%% and 014's "model/stack version change mid-run -> void" could never fire
%%% because no row carried the model.
%%%
%%% Fixtures are recorded provider usage shapes, so the contract is checked with
%%% no live backend.
-module(self_audit_ledger_tests).

-include_lib("eunit/include/eunit.hrl").

-define(MODEL, <<"openai/gpt-oss-20b">>).

usage(Json) -> self_audit_extract:usage(Json, ?MODEL).

json(Usage) -> #{<<"usage">> => Usage}.

%% --- token capture ---

full_usage_test() ->
    U = usage(json(#{<<"prompt_tokens">> => 1200, <<"completion_tokens">> => 300,
                     <<"total_tokens">> => 1500})),
    ?assertEqual(1200, maps:get(prompt, U)),
    ?assertEqual(300, maps:get(completion, U)),
    ?assertEqual(1500, maps:get(total, U)).

%% A provider that reports the parts but not the sum used to ledger a zero-cost
%% call, which flatters the token ratio the ceiling is computed from.
total_falls_back_to_parts_test() ->
    U = usage(json(#{<<"prompt_tokens">> => 900, <<"completion_tokens">> => 100})),
    ?assertEqual(1000, maps:get(total, U)).

absent_usage_is_zero_not_crash_test() ->
    U = usage(#{}),
    ?assertEqual(0, maps:get(total, U)),
    ?assertEqual(0, maps:get(prompt, U)).

non_integer_usage_is_zero_test() ->
    U = usage(json(#{<<"prompt_tokens">> => null, <<"total_tokens">> => <<"lots">>})),
    ?assertEqual(0, maps:get(prompt, U)),
    ?assertEqual(0, maps:get(total, U)).

%% --- cached tokens (observational; adjudicates nothing) ---

cached_openai_nested_test() ->
    U = usage(json(#{<<"prompt_tokens">> => 500, <<"completion_tokens">> => 50,
                     <<"total_tokens">> => 550,
                     <<"prompt_tokens_details">> => #{<<"cached_tokens">> => 384}})),
    ?assertEqual(384, maps:get(cached, U)).

cached_top_level_test() ->
    U = usage(json(#{<<"prompt_tokens">> => 2218, <<"completion_tokens">> => 12,
                     <<"total_tokens">> => 2230, <<"cached_tokens">> => 0})),
    ?assertEqual(0, maps:get(cached, U)).

cached_absent_defaults_zero_test() ->
    ?assertEqual(0, maps:get(cached, usage(json(#{<<"total_tokens">> => 10})))).

%% --- model travels on the row, so the mid-run-change void can fire ---

model_recorded_test() ->
    ?assertEqual(?MODEL, maps:get(model, usage(json(#{<<"total_tokens">> => 10})))).

%% elapsed_ms and retries span attempts, so a single response cannot know them;
%% the shape is seeded here and filled by the call loop.
span_fields_seeded_test() ->
    U = usage(json(#{<<"total_tokens">> => 10})),
    ?assertEqual(0, maps:get(elapsed_ms, U)),
    ?assertEqual(0, maps:get(retries, U)).

%% --- draft_verify pays for BOTH calls, on every ledger axis ---

sum_usage_adds_every_axis_test() ->
    A = #{prompt => 100, completion => 20, total => 120, cached => 10,
          elapsed_ms => 900, retries => 1, model => ?MODEL},
    B = #{prompt => 400, completion => 30, total => 430, cached => 0,
          elapsed_ms => 1500, retries => 2, model => ?MODEL},
    S = self_audit_extract:sum_usage(A, B),
    ?assertEqual(500, maps:get(prompt, S)),
    ?assertEqual(50, maps:get(completion, S)),
    ?assertEqual(550, maps:get(total, S)),
    ?assertEqual(10, maps:get(cached, S)),
    ?assertEqual(2400, maps:get(elapsed_ms, S)),
    ?assertEqual(3, maps:get(retries, S)),
    ?assertEqual(?MODEL, maps:get(model, S)).

%% --- 014 void: model/stack version change mid-run ---

row(Model) -> {ok, #{model => Model}}.

one_model_is_stable_test() ->
    ?assert(self_audit_assay:model_stable([row(?MODEL), row(?MODEL), row(?MODEL)])).

changed_model_is_unstable_test() ->
    ?assertNot(self_audit_assay:model_stable([row(?MODEL), row(<<"other-model">>)])).

%% Unscored items carry no model and must not be mistaken for a change.
failed_items_ignored_test() ->
    ?assert(self_audit_assay:model_stable([row(?MODEL), {fail, dv}, row(?MODEL)])).

empty_run_is_stable_test() ->
    ?assert(self_audit_assay:model_stable([])).

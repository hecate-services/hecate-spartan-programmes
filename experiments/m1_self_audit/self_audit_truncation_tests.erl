%%% @doc Tests for FIX 1 and FIX 2 (insight 017), built for the 019 ladder.
%%%
%%% These exist so the failure that voided M1 cannot recur silently.
%%%
%%% FIX 1: 014 froze "any output hitting the token limit is a parse-class failure".
%%% The M1 run did not implement it, so truncation and malformed format were the
%%% same event to the referee, and because the verify pass writes the longer body,
%%% truncation is concentrated in the arm under test. That manufactured the
%%% 15.7-point parse gap which blocked signing (016 defect 1).
%%%
%%% FIX 2: raw outputs were discarded, so the gap could not be attributed after
%%% the fact (016 defect 2).
-module(self_audit_truncation_tests).

-include_lib("eunit/include/eunit.hrl").

-define(MODEL, <<"qwen2.5:7b-instruct-q4_K_M">>).
-define(CAP, 2000).

json(Choice, Usage) ->
    #{<<"choices">> => [Choice], <<"usage">> => Usage}.

choice(Finish) ->
    #{<<"finish_reason">> => Finish, <<"message">> => #{<<"content">> => <<"{}">>}}.

usage(Finish, Completion) ->
    self_audit_extract:usage(
      json(choice(Finish), #{<<"prompt_tokens">> => 100,
                             <<"completion_tokens">> => Completion,
                             <<"total_tokens">> => 100 + Completion}),
      ?MODEL, ?CAP).

good_json() ->
    <<"{\"fields\":[{\"class\":\"entity\",\"value\":\"Reuters\","
      "\"snippet\":\"told Reuters today\"}]}">>.

%% --- FIX 1: the two detection paths ---

finish_reason_length_is_truncated_test() ->
    ?assert(maps:get(truncated, usage(<<"length">>, 12))).

completion_at_cap_is_truncated_test() ->
    ?assert(maps:get(truncated, usage(<<"stop">>, ?CAP))).

completion_over_cap_is_truncated_test() ->
    ?assert(maps:get(truncated, usage(<<"stop">>, ?CAP + 5))).

normal_stop_is_not_truncated_test() ->
    ?assertNot(maps:get(truncated, usage(<<"stop">>, 300))).

finish_reason_is_recorded_test() ->
    ?assertEqual(<<"stop">>, maps:get(finish_reason, usage(<<"stop">>, 300))).

missing_finish_reason_is_empty_not_crash_test() ->
    U = self_audit_extract:usage(#{<<"usage">> => #{<<"total_tokens">> => 10}}, ?MODEL, ?CAP),
    ?assertEqual(<<>>, maps:get(finish_reason, U)),
    ?assertNot(maps:get(truncated, U)).

%% --- FIX 1: truncation is its OWN class, and it wins over parseability ---

%% The whole point. A truncated body that happens to parse is still a failure,
%% because 014 says so, and because a body cut mid-document has silently lost
%% fields that the checker would otherwise have counted as deletions.
truncated_but_parseable_is_still_truncated_test() ->
    ?assertEqual({truncated, []},
                 self_audit_extract:classify(good_json(), usage(<<"length">>, 12))).

clean_parse_is_ok_test() ->
    {Outcome, Fields} = self_audit_extract:classify(good_json(), usage(<<"stop">>, 300)),
    ?assertEqual(ok, Outcome),
    ?assertEqual(1, length(Fields)).

unparseable_is_malformed_not_truncated_test() ->
    ?assertEqual({malformed, []},
                 self_audit_extract:classify(<<"I found no facts.">>, usage(<<"stop">>, 300))).

%% --- FIX 1: both passes count, so the asymmetry 016 suspected becomes visible ---

sum_usage_truncation_is_sticky_test() ->
    Clean = usage(<<"stop">>, 300),
    Cut = usage(<<"length">>, 12),
    ?assert(maps:get(truncated, self_audit_extract:sum_usage(Clean, Cut))),
    ?assert(maps:get(truncated, self_audit_extract:sum_usage(Cut, Clean))),
    ?assertNot(maps:get(truncated, self_audit_extract:sum_usage(Clean, Clean))).

%% Ledger rows recorded before FIX 1 carry neither key; summing them must not
%% crash, and must not invent a truncation.
sum_usage_tolerates_legacy_rows_test() ->
    Legacy = #{prompt => 1, completion => 1, total => 2, cached => 0,
               elapsed_ms => 10, retries => 0, model => ?MODEL},
    S = self_audit_extract:sum_usage(Legacy, Legacy),
    ?assertNot(maps:get(truncated, S)),
    ?assertEqual(<<>>, maps:get(finish_reason, S)).

%% --- FIX 2: the record store ---

encodes_a_pass_row_test() ->
    Row = #{kind => pass, arm => copy_control, pass => copy, outcome => ok,
            raw => good_json(), usage => usage(<<"stop">>, 300)},
    Decoded = jsx:decode(self_audit_record:encode(Row), [return_maps]),
    ?assertEqual(<<"copy_control">>, maps:get(<<"arm">>, Decoded)),
    ?assertEqual(<<"ok">>, maps:get(<<"outcome">>, Decoded)),
    ?assertEqual(good_json(), maps:get(<<"raw">>, Decoded)).

%% A store that dies on the row it exists to preserve is worse than no store.
%% The salvage must therefore be BUILT from scalars, not patched from the broken
%% row: patching leaves whatever broke the encode still in the map, and the
%% fallback raises in its turn. This test fails against a patching salvage.
unencodable_row_degrades_rather_than_raises_test() ->
    Row = #{kind => pass, arm => copy_control, raw => good_json(),
            usage => {not_a, jsx, term}},
    Decoded = jsx:decode(self_audit_record:encode(Row), [return_maps]),
    ?assertEqual(true, maps:get(<<"encode_error">>, Decoded)),
    ?assertEqual(byte_size(good_json()), maps:get(<<"raw_bytes">>, Decoded)),
    ?assertEqual(<<"copy_control">>, maps:get(<<"arm">>, Decoded)).

invalid_utf8_in_salvage_does_not_escape_test() ->
    Row = #{kind => pass, item => <<255, 254, 253>>, raw => <<"x">>,
            usage => {not_a, jsx, term}},
    Decoded = jsx:decode(self_audit_record:encode(Row), [return_maps]),
    ?assertEqual(true, maps:get(<<"encode_error">>, Decoded)).

none_sink_is_a_no_op_test() ->
    ?assertEqual(ok, self_audit_record:emit(none, #{kind => pass})),
    ?assertEqual(ok, self_audit_record:close(none)),
    ?assertEqual(none, self_audit_record:open(none)).

writes_json_lines_test() ->
    Path = filename:join(["/tmp", "m1-record-test", "records.jsonl"]),
    _ = file:delete(Path),
    Fd = self_audit_record:open(Path),
    ok = self_audit_record:emit(Fd, #{kind => item, item => <<"a">>}),
    ok = self_audit_record:emit(Fd, #{kind => item, item => <<"b">>}),
    ok = self_audit_record:close(Fd),
    {ok, Bin} = file:read_file(Path),
    Lines = [L || L <- binary:split(Bin, <<"\n">>, [global]), L =/= <<>>],
    ?assertEqual(2, length(Lines)),
    ?assertEqual(<<"a">>, maps:get(<<"item">>, jsx:decode(hd(Lines), [return_maps]))).

%% --- D0's report arithmetic, without a backend ---

row(DraftG, DraftU, CopyG, CopyU) ->
    {ok, #{draft => #{grounded => DraftG, ungrounded => DraftU, excluded => 0},
           copy => #{grounded => CopyG, ungrounded => CopyU, excluded => 0},
           usage => #{total => 100, elapsed_ms => 10, model => ?MODEL, truncated => false}}}.

%% draft grounded 10 and 10 (mean 10); copy grounded 8 and 6 (mean 7); so 3.0 lost
%% per item with no verification asked. Ungrounded 2 and 2 against 2 and 1: 0.5.
d0_measures_attrition_test() ->
    R = self_audit_ladder:report(d0, [row(10, 2, 8, 2), row(10, 2, 6, 1)], 2),
    ?assertEqual(3.0, maps:get(attrition_grounded, R)),
    ?assertEqual(0.5, maps:get(attrition_ungrounded, R)),
    ?assertEqual(2, maps:get(scored, R)).

d0_never_signs_test() ->
    R = self_audit_ladder:report(d0, [row(10, 2, 10, 2)], 1),
    ?assertEqual(false, maps:get(signable, R)),
    ?assertNot(maps:is_key(pass, R)),
    ?assertNot(maps:is_key(verdict, R)).

d0_counts_failures_test() ->
    R = self_audit_ladder:report(d0, [row(5, 1, 5, 1), {fail, {parse, truncated}}], 2),
    ?assertEqual(1, maps:get(scored, R)),
    ?assertEqual(1, maps:get(failed, R)).

no_attrition_reads_as_zero_test() ->
    R = self_audit_ladder:report(d0, [row(7, 3, 7, 3)], 1),
    ?assertEqual(0.0, maps:get(attrition_grounded, R)),
    ?assertEqual(0.0, maps:get(share_of_dv_grounded_drop, R)).

%% --- D1: the report must show discrimination, which is the whole readout ---

%% A keep-framed verifier that drops garbage and leaves good material alone is
%% mechanism (b): the remove-framing's DEFAULT was the channel, and the repair is
%% one sentence of prompt.
d1_discriminating_pass_test() ->
    R = self_audit_ladder:report(d1, [row(10, 4, 10, 1), row(8, 2, 8, 0)], 2),
    ?assertEqual(d1, maps:get(rung, R)),
    ?assert(maps:get(discriminates, R)),
    ?assertEqual(0, maps:get(items_losing_grounded, R)),
    ?assertEqual(2, maps:get(items_losing_ungrounded, R)).

%% A keep-framed verifier that still destroys good material is mechanism (c), the
%% capability floor, which no engine swap escapes.
d1_still_destroying_test() ->
    R = self_audit_ladder:report(d1, [row(10, 2, 5, 2), row(10, 2, 6, 1)], 2),
    ?assertNot(maps:get(discriminates, R)),
    ?assertEqual(2, maps:get(items_losing_grounded, R)).

d1_is_still_not_signable_test() ->
    R = self_audit_ladder:report(d1, [row(9, 3, 9, 1)], 1),
    ?assertEqual(false, maps:get(signable, R)),
    ?assertNot(maps:is_key(pass, R)).

%% --- DR: the within-slice remove control ---

%% DR exists to supply the denominator every ladder comparison has been missing.
%% It must reproduce 018's DIRECTION on this slice if the slice behaves like the
%% confirmatory one: more grounded dropped than ungrounded.
dr_reproduces_the_signed_direction_test() ->
    R = self_audit_ladder:report(dr, [row(10, 2, 5, 2), row(10, 2, 6, 2)], 2),
    ?assertEqual(dr, maps:get(rung, R)),
    ?assertNot(maps:get(discriminates, R)),
    ?assert(maps:get(attrition_grounded, R) > maps:get(attrition_ungrounded, R)).

dr_is_also_not_signable_test() ->
    R = self_audit_ladder:report(dr, [row(8, 2, 4, 1)], 1),
    ?assertEqual(false, maps:get(signable, R)),
    ?assertNot(maps:is_key(pass, R)).

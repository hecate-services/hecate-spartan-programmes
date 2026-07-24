%%% @doc Tests for M1's response parsing — where models trip: code fences, prose
%%% around the JSON, missing snippets (must NOT let the model dodge grounding by
%%% omitting the citation), and unparseable output (a parse failure the referee
%%% counts).
-module(self_audit_extract_tests).

-include_lib("eunit/include/eunit.hrl").

parse(Text) -> self_audit_extract:parse_fields(Text).

plain_json_test() ->
    T = <<"{\"fields\":[{\"class\":\"entity\",\"value\":\"Reuters\",\"snippet\":\"told Reuters today\"}]}">>,
    ?assertEqual({ok, [#{class => entity, value => <<"Reuters">>, snippet => <<"told Reuters today">>}]},
                 parse(T)).

fenced_json_test() ->
    T = <<"Here is the extraction:\n```json\n{\"fields\":[{\"class\":\"number\",\"value\":\"47\",\"snippet\":\"the 47 ships\"}]}\n```\nDone.">>,
    ?assertEqual({ok, [#{class => number, value => <<"47">>, snippet => <<"the 47 ships">>}]},
                 parse(T)).

%% A field with no snippet key becomes snippet=<<>> (ungrounded downstream), never
%% dropped — closing the "omit the snippet to dodge the grounding check" hole.
missing_snippet_becomes_empty_test() ->
    T = <<"{\"fields\":[{\"class\":\"date\",\"value\":\"March 3\"}]}">>,
    ?assertEqual({ok, [#{class => date, value => <<"March 3">>, snippet => <<>>}]},
                 parse(T)).

unknown_class_dropped_test() ->
    T = <<"{\"fields\":[{\"class\":\"colour\",\"value\":\"blue\",\"snippet\":\"the blue flag flew\"}]}">>,
    ?assertEqual({ok, []}, parse(T)).

no_json_is_parse_failure_test() ->
    ?assertEqual({error, unparseable}, parse(<<"I could not find any facts.">>)).

empty_fields_test() ->
    ?assertEqual({ok, []}, parse(<<"{\"fields\":[]}">>)).

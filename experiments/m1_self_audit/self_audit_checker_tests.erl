%%% @doc Tests for M1's grounding checker: the frozen rule (insight 014) and,
%%% specifically, that both red-teamed holes are closed — under-extraction cannot
%%% help (that is the referee's L2, not here), and short-token spurious grounding is
%%% killed by the snippet + specificity floor.
-module(self_audit_checker_tests).

-include_lib("eunit/include/eunit.hrl").

src() ->
    <<"On March 3, 2024, the United Nations reported that 47 shipments left the "
      "port of Antwerp. \"We will not stand down,\" said the envoy to Reuters.">>.

v(Class, Value, Snippet) ->
    #{class => Class, value => Value, snippet => Snippet}.

verdict(Field) ->
    {V, _} = self_audit_checker:classify(src(), Field),
    V.

%% A real cited date grounds.
grounded_date_test() ->
    ?assertEqual(grounded, verdict(v(date, <<"March 3, 2024">>, <<"On March 3, 2024, the United">>))).

%% A grounded entity (>= 2 tokens) and a single long entity (>= 6 chars).
grounded_entity_test() ->
    ?assertEqual(grounded, verdict(v(entity, <<"United Nations">>, <<"the United Nations reported">>))),
    ?assertEqual(grounded, verdict(v(entity, <<"Reuters">>, <<"the envoy to Reuters.">>))).

%% A grounded number: value in a real >=15-char snippet that carries letters.
grounded_number_test() ->
    ?assertEqual(grounded, verdict(v(number, <<"47">>, <<"that 47 shipments left">>))).

%% A grounded quote (its own snippet, >= 20 chars).
grounded_quote_test() ->
    ?assertEqual(grounded, verdict(v(quote, <<"We will not stand down">>,
                                     <<"\"We will not stand down,\" said the envoy">>))).

%% HOLE 2, closed: a bare year is EXCLUDED (not counted either way), so a
%% hallucinated "2024" cannot be laundered into a grounded hit via chance occurrence.
bare_year_excluded_test() ->
    ?assertEqual(excluded, verdict(v(date, <<"2024">>, <<"On March 3, 2024, the United">>))).

%% HOLE 2, closed: a short one-token entity is EXCLUDED (< 2 tokens and < 6 chars).
short_entity_excluded_test() ->
    ?assertEqual(excluded, verdict(v(entity, <<"UN">>, <<"the United Nations reported">>))).

%% HOLE 2, closed: a number whose snippet is a valid length but all-numeric (no
%% letter context) is EXCLUDED — the degenerate span cannot ground a bare digit.
number_without_context_excluded_test() ->
    ?assertEqual(excluded, verdict(v(number, <<"3">>, <<"3 3 3 3 3 3 3 3 3 3 3 3 3 3 3">>))).

%% Hallucination: a plausible field whose snippet is NOT in the source is UNGROUNDED.
hallucinated_snippet_ungrounded_test() ->
    ?assertEqual(ungrounded, verdict(v(number, <<"99">>, <<"a total of 99 aircraft were">>))).

%% Hallucination: the snippet IS in the source but the value is not inside it.
value_not_in_snippet_ungrounded_test() ->
    ?assertEqual(ungrounded, verdict(v(number, <<"88">>, <<"the United Nations reported">>))).

%% A missing / too-short snippet is UNGROUNDED (a failure to cite).
short_snippet_ungrounded_test() ->
    ?assertEqual(ungrounded, verdict(v(entity, <<"Antwerp">>, <<"Antwerp">>))).

%% Normalization: a curly apostrophe / smart quotes in the source must match ASCII
%% in the extraction, or normalization would manufacture fake ungrounded counts.
normalization_quotes_test() ->
    Source = <<"the envoy said \x{201C}we won\x{2019}t wait\x{201D} to the press"/utf8>>,
    F = v(quote, <<"we won't wait">>, <<"said \"we won't wait\" to the press">>),
    ?assertEqual(grounded, element(1, self_audit_checker:classify(Source, F))).

%% Tally sums the three verdicts.
tally_test() ->
    Fields = [v(entity, <<"United Nations">>, <<"the United Nations reported">>),   % grounded
              v(number, <<"99">>, <<"a total of 99 aircraft were">>),               % ungrounded
              v(date, <<"2024">>, <<"On March 3, 2024, the United">>)],             % excluded
    ?assertEqual(#{grounded => 1, ungrounded => 1, excluded => 1},
                 self_audit_checker:tally(src(), Fields)).

%%% @doc Experiment M1's mechanical grounding checker (insight 014, Fable-cleared
%%% round 14). Pure, deterministic — the source document owns the truth the way the
%%% arena world owned `mu`. No judge model, no rubric.
%%%
%%% A field the mind extracted is {class, value, snippet}, where snippet is the
%%% verbatim evidence span the mind must cite from the source. The classifier is the
%%% frozen rule, verbatim:
%%%
%%%   GROUNDED iff (a) the snippet (>= 15 chars; >= 20 for quotes) is a substring of
%%%   the source, (b) the field's value occurs within the snippet, and (c) class
%%%   specificity holds. A missing / too-short / non-matching snippet is UNGROUNDED.
%%%   Fields failing specificity are EXCLUDED from both arms symmetrically.
%%%
%%% Specificity (c) is what closes hole 2 — bare substring-in-source is spurious for
%%% short tokens ("3" occurs in any article by chance), so we demand a real cited
%%% span AND a class floor: dates in full surface form (not a bare year), entities of
%%% >= 2 tokens or 6 chars, numbers with a non-numeric token in their snippet. The
%%% floor removes the short-token channel SYMMETRICALLY, so an arm that extracts
%%% shorter tokens cannot game the metric. All comparison is after frozen
%%% normalization (NFKC, casefold, whitespace collapse, quote/dash unification) —
%%% part of the checker, not an implementation detail (curly quotes would otherwise
%%% manufacture fake ungrounded counts).
-module(self_audit_checker).

-export([classify/2, tally/2, normalize/1]).

-export_type([field/0, verdict/0]).

-type class()   :: date | number | entity | quote.
-type field()   :: #{class := class(), value := binary(), snippet := binary()}.
-type verdict() :: grounded | ungrounded | excluded.

-define(MIN_SNIPPET, 15).
-define(MIN_QUOTE, 20).

%% @doc Classify one extracted field against the source text.
-spec classify(binary(), field()) -> {verdict(), atom()}.
classify(Source, #{class := Class, value := V, snippet := Sn}) ->
    decide(Class, normalize(V), normalize(Sn), normalize(Source)).

%% @doc Tally grounded / ungrounded / excluded counts over a field list.
-spec tally(binary(), [field()]) -> #{grounded := non_neg_integer(),
                                       ungrounded := non_neg_integer(),
                                       excluded := non_neg_integer()}.
tally(Source, Fields) ->
    NSource = normalize(Source),
    lists:foldl(fun(F, Acc) -> bump(verdict_of(NSource, F), Acc) end,
                #{grounded => 0, ungrounded => 0, excluded => 0}, Fields).

verdict_of(NSource, #{class := Class, value := V, snippet := Sn}) ->
    {Verdict, _Reason} = decide(Class, normalize(V), normalize(Sn), NSource),
    Verdict.

bump(grounded, A)   -> A#{grounded := maps:get(grounded, A) + 1};
bump(ungrounded, A) -> A#{ungrounded := maps:get(ungrounded, A) + 1};
bump(excluded, A)   -> A#{excluded := maps:get(excluded, A) + 1}.

%% --- the frozen decision: specificity gate first, then grounding ---

decide(Class, V, Sn, Src) ->
    gate(specificity(Class, V, Sn), Class, V, Sn, Src).

gate(exclude, _Class, _V, _Sn, _Src) -> {excluded, low_specificity};
gate(ok, Class, V, Sn, Src)          -> ground(Class, V, Sn, Src).

ground(Class, V, Sn, Src) ->
    finish(snippet_ok(Class, Sn) andalso contains(Src, Sn) andalso contains(Sn, V)).

finish(true)  -> {grounded, ok};
finish(false) -> {ungrounded, not_cited}.

%% Specificity floor (excludes un-judgeable fields, symmetrically across arms).
%% Numbers are only excluded when they DO carry a valid snippet that lacks
%% non-numeric context; a number with no/short snippet falls through to grounding
%% and is marked ungrounded there (a failure to cite, not an exclusion).
specificity(date, V, _Sn)   -> exclude_when(is_bare_year(V));
specificity(entity, V, _Sn) -> exclude_when(not entity_specific(V));
specificity(number, _V, Sn) -> number_specificity(snippet_ok(number, Sn), Sn);
specificity(quote, _V, _Sn) -> ok.

number_specificity(true, Sn) -> exclude_when(not has_letter(Sn));
number_specificity(false, _Sn) -> ok.

exclude_when(true)  -> exclude;
exclude_when(false) -> ok.

snippet_ok(quote, Sn) -> string:length(Sn) >= ?MIN_QUOTE;
snippet_ok(_Class, Sn) -> string:length(Sn) >= ?MIN_SNIPPET.

is_bare_year(V) ->
    re:run(string:trim(V), "^[0-9]{4}$", [{capture, none}]) =:= match.

entity_specific(V) ->
    length(string:lexemes(V, " ")) >= 2 orelse string:length(V) >= 6.

has_letter(S) ->
    re:run(S, "\\p{L}", [unicode, {capture, none}]) =:= match.

contains(_Hay, <<>>)  -> false;
contains(Hay, Needle) -> string:find(Hay, Needle) =/= nomatch.

%% --- frozen normalization ---

-spec normalize(binary()) -> binary().
normalize(Bin) ->
    Nfkc = unicode:characters_to_nfkc_binary(Bin),
    Unified = unify(Nfkc),
    Folded = unicode:characters_to_binary(string:casefold(Unified)),
    collapse_ws(Folded).

unify(S) ->
    S1 = re:replace(S, "[\x{2018}\x{2019}\x{201A}\x{201B}]", "'",
                    [global, unicode, {return, binary}]),
    S2 = re:replace(S1, "[\x{201C}\x{201D}\x{201E}\x{201F}]", "\"",
                    [global, unicode, {return, binary}]),
    re:replace(S2, "[\x{2013}\x{2014}\x{2015}\x{2212}]", "-",
               [global, unicode, {return, binary}]).

collapse_ws(S) ->
    Single = re:replace(S, "\\s+", " ", [global, unicode, {return, binary}]),
    string:trim(Single).

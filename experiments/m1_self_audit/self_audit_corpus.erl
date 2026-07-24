%%% @doc Experiment M1's frozen corpus (insight 014). A corpus file is JSON-lines,
%%% one item per line: {"id": "...", "text": "..."} — `text` is the source document
%%% the checker treats as ground truth. The corpus is captured and frozen BEFORE any
%%% scoring; this module only reads it and splits it deterministically into a
%%% calibration slice (for the token-ceiling and void-band headroom) and a disjoint
%%% confirmatory slice (scored once). Sorting by id makes the split reproducible and
%%% independent of file order.
-module(self_audit_corpus).

-export([load/1, split/2]).

-export_type([item/0]).

-type item() :: #{id := binary(), text := binary()}.

-spec load(file:name_all()) -> {ok, [item()]} | {error, term()}.
load(Path) ->
    on_read(file:read_file(Path)).

on_read({error, R})   -> {error, {read, R}};
on_read({ok, Binary}) ->
    Lines = [L || L <- binary:split(Binary, <<"\n">>, [global]), L =/= <<>>],
    collect(Lines, []).

collect([], Acc) -> {ok, lists:reverse(Acc)};
collect([Line | Rest], Acc) ->
    parse_line(Line, Rest, Acc).

parse_line(Line, Rest, Acc) ->
    try jsx:decode(Line, [return_maps]) of
        #{<<"id">> := Id, <<"text">> := Text} when is_binary(Id), is_binary(Text) ->
            collect(Rest, [#{id => Id, text => Text} | Acc]);
        _Malformed ->
            {error, {bad_item, Line}}
    catch _:_ ->
        {error, {bad_json, Line}}
    end.

%% @doc Deterministic disjoint split: the NCalib lowest ids are the calibration
%% slice, the remainder the confirmatory slice. Frozen and file-order independent.
-spec split([item()], non_neg_integer()) -> {[item()], [item()]}.
split(Items, NCalib) ->
    Sorted = lists:sort(fun(#{id := A}, #{id := B}) -> A =< B end, Items),
    lists:split(min(NCalib, length(Sorted)), Sorted).

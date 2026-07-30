%%% @doc FIX 2 (insight 017): the per-item record store.
%%%
%%% This exists so a run can explain its own blocker afterwards.
%%%
%%% M1 kept the corpus, the code and the summary, and threw away the model's
%%% actual per-item output (016 defect 2). When the run was blocked by a
%%% 15.7-point differential parse gap, the data needed to classify those failures
%%% into truncation versus malformed format had already been discarded, and the
%%% question became unanswerable rather than merely unanswered. 017 registered the
%%% fix; 018 parked it for the first experiment needing a MEASURED result rather
%%% than a bounded direction. The 019 ladder is that experiment.
%%%
%%% The format is JSON Lines, one object per line, two kinds:
%%%   kind=pass  one LLM call: arm, pass, outcome, raw text, full usage
%%%   kind=item  one corpus item: the paired grounded/ungrounded counts per arm
%%%
%%% Per-item PAIRED COUNTS are stored as well as raw text, deliberately. 017's
%%% draft listed only the raw text, and the gate caught it: the reason a later
%%% sizing calculation had to reconstruct variance from a Poisson proxy is that
%%% the M1 run persisted aggregates only, so the empirical variance the referee
%%% actually saw could not be recovered. With per-item counts retained, no future
%%% sizing needs the proxy.
%%%
%%% A sink is a plain fun, so a caller that wants no store passes `none' and pays
%%% nothing, and a test can pass a collector without touching the filesystem.
-module(self_audit_record).

-export([open/1, close/1, sink/1, emit/2, encode/1]).

-export_type([sink/0]).

-type sink() :: file:io_device() | none.

%% @doc Open a record store, creating parent directories. `none' disables it.
-spec open(file:name_all() | none) -> sink().
open(none) ->
    none;
open(Path) ->
    ok = filelib:ensure_dir(Path),
    opened(file:open(Path, [write, raw, binary])).

opened({ok, Fd})    -> Fd;
opened({error, _R}) -> none.

-spec close(sink()) -> ok.
close(none) -> ok;
close(Fd)   -> file:close(Fd).

%% @doc An emit fun for `self_audit_extract:extract/4' and `attrition/3'.
-spec sink(sink()) -> self_audit_extract:emit().
sink(Store) -> fun(Row) -> emit(Store, Row) end.

-spec emit(sink(), map()) -> ok.
emit(none, _Row) ->
    ok;
emit(Fd, Row) ->
    file:write(Fd, [encode(Row), $\n]).

%% @doc Encode one row. A model can emit bytes that are not valid UTF-8, and a
%% record store that dies on the row it was built to preserve is worse than no
%% store, so an unencodable row degrades to a marker rather than raising.
-spec encode(map()) -> binary().
encode(Row) ->
    try jsx:encode(Row)
    catch _:_ -> jsx:encode(salvage(Row))
    end.

%% The fallback is BUILT rather than patched. Patching the offending row (its
%% original fields kept, `raw' replaced) leaves whatever actually broke the encode
%% still in the map, so the salvage raises in its turn and the exception escapes
%% the very guard that exists to stop it. Every value below is a binary, an atom,
%% an integer or a boolean, so this map cannot fail to encode.
salvage(Row) ->
    #{kind => scalar(maps:get(kind, Row, pass)),
      item => scalar(maps:get(item, Row, <<>>)),
      arm => scalar(maps:get(arm, Row, <<>>)),
      pass => scalar(maps:get(pass, Row, <<>>)),
      outcome => scalar(maps:get(outcome, Row, <<>>)),
      raw => <<"[unencodable]">>,
      raw_bytes => byte_size(raw_of(Row)),
      encode_error => true}.

scalar(V) when is_atom(V); is_integer(V) -> V;
scalar(V) when is_binary(V)              -> printable(V);
scalar(V)                                -> fmt(V).

%% A binary that is not valid UTF-8 is what broke the encode in the first place.
printable(B) -> valid(unicode:characters_to_binary(B, utf8, utf8), B).

valid(Bin, _Original) when is_binary(Bin) -> Bin;
valid(_Invalid, Original)                 -> fmt(Original).

fmt(V) -> iolist_to_binary(io_lib:format("~p", [V])).

raw_of(#{raw := R}) when is_binary(R) -> R;
raw_of(_Row)                          -> <<>>.

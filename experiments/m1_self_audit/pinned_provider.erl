%%% @doc The pinned measurement endpoint, owned by the harness.
%%%
%%% An experiment wants the opposite of the production carousel: one model, one
%%% version, no rotation, and no rate limit, so a retry loop cannot pollute a cost
%%% ledger and a wall-clock figure means something because the machine is fixed.
%%%
%%% The harness owns this rather than importing `spartan_mind_llm:provider_config/1'
%%% from hecate-spartan. Importing it would mean pinning the whole service, which
%%% drags macula, reckon-db, evoq and their Rust NIFs into a harness that needs a
%%% URL and a model name, and would tie every future re-run of this experiment to
%%% whether that stack still builds. Fifteen lines here buys reproducibility.
%%%
%%% The environment variable names deliberately match the service's, so an
%%% operator learns one set of names rather than two.
%%%
%%% MODEL PIN, chosen on instrument grounds before any scoring. M1 asks for strict
%%% JSON and one of its four field classes is `quote', so most real source items
%%% contain double quotes. Measured on the same article, twice each:
%%% mistral:7b-instruct-v0.3 emitted unparseable JSON 2/2 (it does not escape
%%% quotes inside strings); qwen2.5:7b-instruct parsed 2/2 and returned
%%% byte-identical token counts at temperature 0. Insight 014 blocks signing on a
%%% differential parse-failure rate above 5 points, and `draft_verify' makes two
%%% calls to `single_pass''s one, so an unreliable formatter biases the run
%%% structurally against the arm under test.
-module(pinned_provider).

-export([config/1]).

-define(URL_DEFAULT, "http://127.0.0.1:11434/v1/chat/completions").
-define(MODEL_DEFAULT, <<"qwen2.5:7b-instruct-q4_K_M">>).
%% CPU inference is slow. A fast-provider timeout would abort real answers.
-define(TIMEOUT_MS, 600000).

%% @doc Endpoint config for a named provider, or `undefined'.
%%
%% No `max_tokens' is declared: the caller's own cap applies, because a truncated
%% answer is a parse failure the referee counts, not a cheap answer.
-spec config(string()) -> map() | undefined.
config("local") ->
    #{url => url(), model => model(), keyless => true, timeout => ?TIMEOUT_MS};
config(_Unknown) ->
    undefined.

url() ->
    case os:getenv("HECATE_LOCAL_URL") of
        U when is_list(U), U =/= "" -> U;
        _Unset                      -> ?URL_DEFAULT
    end.

model() ->
    case os:getenv("HECATE_LOCAL_MODEL") of
        M when is_list(M), M =/= "" -> unicode:characters_to_binary(M);
        _Unset                      -> ?MODEL_DEFAULT
    end.

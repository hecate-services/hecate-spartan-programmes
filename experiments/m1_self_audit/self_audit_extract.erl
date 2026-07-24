%%% @doc Experiment M1's contestant: attributed fact extraction, in two arms.
%%%   single_pass : one call — draft the extraction and stop.
%%%   draft_verify: two calls — draft, then a verify pass that re-reads the draft
%%%                 against the source and removes/fixes ungrounded fields. This is
%%%                 the self-audit faculty (the deployed MINDfulness toggle) under
%%%                 test; token cost is the SUM of both calls.
%%%
%%% Calls are made to a PINNED provider at temperature 0 (not the production
%%% carousel, which shuffles providers per call — that would break pairing). The
%%% endpoint comes from `pinned_provider', which this harness owns: see that
%%% module for why it is not imported from hecate-spartan.
%%%
%%% THE LEDGER. Insight 014 names three requirements, all captured here:
%%%   - prompt + completion tokens per item, both arms, from provider usage;
%%%   - WALL-CLOCK per item — total elapsed for the call including every retry and
%%%     every backoff sleep, because that is the time the economics actually eats;
%%%   - RETRIES counted — 014 lists "retries count in the ledger" as a void
%%%     condition. A 429 yields no tokens but costs real time, so a retry loop is
%%%     invisible in a token-only ledger.
%%% `model' travels on every row so 014's "model/stack version change mid-run ->
%%% void" can actually fire; the assay checks it across the whole run.
%%% `cached' is OBSERVATIONAL ONLY — no kill or void criterion reads it. It is
%%% recorded because a broker that reports cached tokens changes what a repeated
%%% prefix costs, and we want the number.
-module(self_audit_extract).

-export([extract/3, call/2, parse_fields/1]).
%% Pure ledger arithmetic, exported so the ledger contract can be tested against
%% recorded provider usage shapes without a live backend.
-export([usage/2, sum_usage/2]).

-export_type([usage/0]).

-type usage() :: #{prompt := non_neg_integer(), completion := non_neg_integer(),
                   total := non_neg_integer(), cached := non_neg_integer(),
                   elapsed_ms := non_neg_integer(), retries := non_neg_integer(),
                   model := binary()}.

%% With reasoning_effort=low the JSON output is short (~a few hundred tokens); this
%% is generous headroom while keeping per-call token volume low (free-tier TPM).
-define(MAX_TOKENS, 2000).
%% Key-rotation budget for one call. Backoff is 1s, 2s, 3s, 4s between attempts.
-define(MAX_ATTEMPTS, 5).

%% @doc Extract fields for one item on one arm. Returns the fields, the summed
%% token usage, and the number of LLM calls (1 or 2; a retry would raise it).
-spec extract(single_pass | draft_verify, string(), binary()) ->
    {ok, [self_audit_checker:field()], usage(), pos_integer()} | {error, term()}.
extract(single_pass, Provider, Source) ->
    single(Provider, Source);
extract(draft_verify, Provider, Source) ->
    verify(Provider, Source).

single(Provider, Source) ->
    on_draft(call(Provider, draft_messages(Source))).

on_draft({error, _} = E) -> E;
on_draft({ok, Text, U}) ->
    on_fields(parse_fields(Text), U).

on_fields({error, R}, _U)      -> {error, {parse, R}};
on_fields({ok, Fields}, U)     -> {ok, Fields, U, 1}.

verify(Provider, Source) ->
    draft_then_verify(call(Provider, draft_messages(Source)), Provider, Source).

draft_then_verify({error, _} = E, _Provider, _Source) -> E;
draft_then_verify({ok, DraftText, U1}, Provider, Source) ->
    second_pass(call(Provider, verify_messages(Source, DraftText)), U1).

second_pass({error, _} = E, _U1) -> E;
second_pass({ok, Text, U2}, U1) ->
    on_fields2(parse_fields(Text), sum_usage(U1, U2)).

on_fields2({error, R}, _U)  -> {error, {parse, R}};
on_fields2({ok, Fields}, U) -> {ok, Fields, U, 2}.

%% draft_verify's cost is BOTH calls: tokens, wall-clock and retries all add. The
%% model is pinned for the whole run, so either row's is the run's model.
sum_usage(A, B) ->
    #{prompt      => maps:get(prompt, A) + maps:get(prompt, B),
      completion  => maps:get(completion, A) + maps:get(completion, B),
      total       => maps:get(total, A) + maps:get(total, B),
      cached      => maps:get(cached, A) + maps:get(cached, B),
      elapsed_ms  => maps:get(elapsed_ms, A) + maps:get(elapsed_ms, B),
      retries     => maps:get(retries, A) + maps:get(retries, B),
      model       => maps:get(model, A)}.

%% --- prompts (frozen with the experiment) ---

draft_messages(Source) ->
    [#{<<"role">> => <<"system">>, <<"content">> => draft_system()},
     #{<<"role">> => <<"user">>, <<"content">> => <<"ARTICLE:\n", Source/binary>>}].

verify_messages(Source, DraftText) ->
    [#{<<"role">> => <<"system">>, <<"content">> => verify_system()},
     #{<<"role">> => <<"user">>,
       <<"content">> => <<"ARTICLE:\n", Source/binary, "\n\nDRAFT:\n", DraftText/binary>>}].

draft_system() ->
    <<"You extract facts that are EXPLICITLY present in the ARTICLE. For each fact "
      "output: class (one of date, number, entity, quote), value (the fact itself), "
      "and snippet (a span of at least 15 characters copied VERBATIM from the article "
      "that contains the value). Do not invent facts or snippets. Output ONLY JSON of "
      "the form {\"fields\":[{\"class\":...,\"value\":...,\"snippet\":...}]} and nothing else.">>.

verify_system() ->
    <<"You are a strict verifier. Given an ARTICLE and a DRAFT extraction, remove "
      "every field whose snippet is NOT an exact substring of the article, and every "
      "field whose value does not appear inside its snippet. Correct snippets to exact "
      "article spans where you can; drop the field if you cannot. Keep every field that "
      "is correctly grounded. Output ONLY the corrected JSON {\"fields\":[...]}.">>.

%% --- the pinned call ---

%% A pinned temperature-0 call. To run at scale on rate-limited free tiers, it
%% retries on 429 / 5xx / transport errors, rotating across the provider's keys
%% (shuffled per call to spread first attempts) with a short backoff. The MODEL is
%% pinned throughout; only the account rotates.
%%
%% The returned usage carries the ledger: a retried success's tokens, the TOTAL
%% wall-clock (every attempt plus every backoff sleep), and how many retries it
%% took. A 429 yields no tokens, which is precisely why retries and wall-clock are
%% recorded separately — in a token-only ledger a retry loop looks free.
-spec call(string(), [map()]) -> {ok, binary(), usage()} | {error, term()}.
call(Provider, Messages) ->
    Started = erlang:monotonic_time(millisecond),
    stamp_elapsed(dispatch(pinned_provider:config(Provider), Messages), Started).

%% Wall-clock spans the WHOLE call, so retry backoff sleeps are counted. A failed
%% call has no usage map to stamp.
stamp_elapsed({ok, Text, U}, Started) ->
    {ok, Text, U#{elapsed_ms := erlang:monotonic_time(millisecond) - Started}};
stamp_elapsed(Error, _Started) ->
    Error.

dispatch(undefined, _Messages) -> {error, unknown_provider};
dispatch(Config, Messages) ->
    attempt(Config, Messages, shuffle(keys_of(Config)), ?MAX_ATTEMPTS, 0).

attempt(_Config, _Messages, _Keys, 0, _Retries) -> {error, exhausted};
attempt(Config, Messages, [Key | Rest], Left, Retries) ->
    handle(do_call(Config, Messages, Key), Config, Messages, Rest ++ [Key], Left, Retries).

handle({error, {http, 429, _}}, C, M, Keys, Left, R)       -> retry(C, M, Keys, Left, R);
handle({error, {http, Code, _}}, C, M, Keys, Left, R) when Code >= 500 -> retry(C, M, Keys, Left, R);
handle({error, {httpc, _}}, C, M, Keys, Left, R)           -> retry(C, M, Keys, Left, R);
handle({ok, Text, U}, _C, _M, _Keys, _Left, R)             -> {ok, Text, U#{retries := R}};
handle(Result, _C, _M, _Keys, _Left, _R)                   -> Result.

retry(Config, Messages, Keys, Left, Retries) ->
    timer:sleep(1000 * (?MAX_ATTEMPTS + 1 - Left)),
    attempt(Config, Messages, Keys, Left - 1, Retries + 1).

do_call(undefined, _Messages, _Key) -> {error, unknown_provider};
do_call(Config, Messages, Key) ->
    Model = maps:get(model, Config),
    Base = #{<<"model">> => Model, <<"temperature">> => 0,
             <<"max_tokens">> => maps:get(max_tokens, Config, ?MAX_TOKENS),
             <<"messages">> => Messages},
    Body = jsx:encode(reasoning(Model, Base)),
    Req = {maps:get(url, Config), header(Key), "application/json", Body},
    post(Req, maps:get(timeout, Config, 120000), Model).

header(none) -> [];
header(Key)  -> [{"Authorization", "Bearer " ++ Key}].

%% reasoning_effort=low only for reasoning models (groq gpt-oss): the extraction task
%% is mechanical, so low effort yields short clean JSON instead of hidden-reasoning
%% token burn that truncates to empty content and blows free-tier token/min ceilings.
%% Symmetric across arms, outcome-neutral. Non-reasoning endpoints reject the param,
%% so it is added only when the model is a reasoning one.
reasoning(Model, Base) ->
    add_effort(binary:match(Model, <<"oss">>), Base).

add_effort(nomatch, Base) -> Base;
add_effort(_Match, Base)  -> Base#{<<"reasoning_effort">> => <<"low">>}.

post(Req, Timeout, Model) ->
    Result = httpc:request(post, Req, [{timeout, Timeout}, {ssl, [{verify, verify_none}]}],
                           [{body_format, binary}]),
    on_http(Result, Model).

on_http({ok, {{_, 200, _}, _H, Resp}}, Model)  -> parse_response(Resp, Model);
on_http({ok, {{_, Code, _}, _H, Resp}}, _M)    -> {error, {http, Code, Resp}};
on_http({error, R}, _M)                        -> {error, {httpc, R}}.

parse_response(Resp, Model) ->
    try
        Json = jsx:decode(Resp, [return_maps]),
        [Choice | _] = maps:get(<<"choices">>, Json),
        Text = maps:get(<<"content">>, maps:get(<<"message">>, Choice)),
        {ok, text_bin(Text), usage(Json, Model)}
    catch _:_ ->
        {error, bad_response}
    end.

text_bin(T) when is_binary(T) -> T;
text_bin(_) -> <<>>.

%% `elapsed_ms' and `retries' are filled by the caller (they span attempts, so a
%% single response cannot know them); seeded here so the map shape is complete.
usage(Json, Model) ->
    U = maps:get(<<"usage">>, Json, #{}),
    #{prompt      => uint(maps:get(<<"prompt_tokens">>, U, 0)),
      completion  => uint(maps:get(<<"completion_tokens">>, U, 0)),
      total       => uint(total_of(U)),
      cached      => uint(cached_of(U)),
      elapsed_ms  => 0,
      retries     => 0,
      model       => Model}.

%% Prefer the reported total; fall back to prompt+completion so a provider that
%% omits total does not silently ledger a zero-cost call.
total_of(#{<<"total_tokens">> := T}) when is_integer(T) ->
    T;
total_of(#{<<"prompt_tokens">> := P, <<"completion_tokens">> := C})
  when is_integer(P), is_integer(C) ->
    P + C;
total_of(_NoTotal) ->
    0.

%% OpenAI nests cached tokens under prompt_tokens_details; brokers that report it
%% at all (Melious) put it at the top of usage. Observational only.
cached_of(#{<<"prompt_tokens_details">> := #{<<"cached_tokens">> := C}}) -> C;
cached_of(#{<<"cached_tokens">> := C})                                   -> C;
cached_of(_NoCached)                                                     -> 0.

uint(N) when is_integer(N), N >= 0 -> N;
uint(_) -> 0.

keys_of(#{keyless := true}) -> [none];
keys_of(#{keyenv := Env})   -> nonempty(all_keys(os:getenv(Env)));
keys_of(_Config)            -> [none].

all_keys(false) -> [];
all_keys("")    -> [];
all_keys(S)     -> [string:trim(K) || K <- string:tokens(S, ","), string:trim(K) =/= ""].

nonempty([]) -> [none];
nonempty(L)  -> L.

shuffle(L) -> [X || {_, X} <- lists:sort([{rand:uniform(), E} || E <- L])].

%% --- response -> fields ---

parse_fields(Text) ->
    decode_fields(strip_fences(Text)).

decode_fields(Clean) ->
    try
        Json = jsx:decode(Clean, [return_maps]),
        Raw = maps:get(<<"fields">>, Json),
        {ok, [F || F <- lists:map(fun to_field/1, Raw), F =/= skip]}
    catch _:_ ->
        {error, unparseable}
    end.

to_field(#{<<"class">> := C, <<"value">> := V} = F) when is_binary(V) ->
    build_field(class_atom(C), V, maps:get(<<"snippet">>, F, <<>>));
to_field(_) -> skip.

build_field(undefined, _V, _Sn)             -> skip;
build_field(A, V, Sn) when is_binary(Sn)    -> #{class => A, value => V, snippet => Sn};
build_field(A, V, _Sn)                      -> #{class => A, value => V, snippet => <<>>}.

class_atom(<<"date">>)   -> date;
class_atom(<<"number">>) -> number;
class_atom(<<"entity">>) -> entity;
class_atom(<<"quote">>)  -> quote;
class_atom(_)            -> undefined.

%% Models often wrap JSON in a ```json ... ``` fence or add prose; take the span from
%% the first '{' to the last '}'. A response with no braces is left as-is and fails to
%% decode (a parse failure the referee counts).
strip_fences(Text) ->
    first_brace(binary:match(Text, <<"{">>), Text).

first_brace(nomatch, Text) -> Text;
first_brace({Start, _Len}, Text) ->
    Sub = binary:part(Text, Start, byte_size(Text) - Start),
    to_last_brace(binary:matches(Sub, <<"}">>), Sub).

to_last_brace([], Sub)     -> Sub;
to_last_brace(Matches, Sub) ->
    {End, _Len} = lists:last(Matches),
    binary:part(Sub, 0, End + 1).

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
%%% FIX 1 and FIX 2 (insight 017, built 2026-07-31 for the 019 ladder). 014 froze
%%% "any output hitting the token limit is a parse-class failure" and the M1 run
%%% did not implement it, so a truncated body and a malformed one were the same
%%% event to the referee (016 defect 1). Truncation is now its own class, detected
%%% before parseability is even consulted. And every pass now offers its raw text,
%%% usage and outcome to an emit function, so a run can retain what it saw instead
%%% of discarding it (016 defect 2).
-module(self_audit_extract).

-export([extract/3, extract/4, attrition/3, call/2, parse_fields/1]).
%% Pure ledger arithmetic, exported so the ledger contract can be tested against
%% recorded provider usage shapes without a live backend.
-export([usage/2, usage/3, sum_usage/2, classify/2]).

-export_type([usage/0, pass/0, outcome/0, emit/0]).

-type usage() :: #{prompt := non_neg_integer(), completion := non_neg_integer(),
                   total := non_neg_integer(), cached := non_neg_integer(),
                   elapsed_ms := non_neg_integer(), retries := non_neg_integer(),
                   model := binary(), finish_reason := binary(),
                   truncated := boolean()}.
%% Which call within an arm produced a row. `copy' belongs to D0 (insight 019).
-type pass()    :: draft | verify | copy.
%% FIX 1: `truncated' is a class of its own, never folded into `malformed'.
-type outcome() :: ok | truncated | malformed.
%% FIX 2: called once per pass with the full record of that pass. The caller owns
%% where it goes; this module only guarantees it is offered.
-type emit()    :: fun((map()) -> any()).

%% With reasoning_effort=low the JSON output is short (~a few hundred tokens); this
%% is generous headroom while keeping per-call token volume low (free-tier TPM).
-define(MAX_TOKENS, 2000).
%% Key-rotation budget for one call. Backoff is 1s, 2s, 3s, 4s between attempts.
-define(MAX_ATTEMPTS, 5).

%% @doc Extract fields for one item on one arm. Returns the fields, the summed
%% token usage, and the number of LLM calls (1 or 2; a retry would raise it).
-spec extract(single_pass | draft_verify, string(), binary()) ->
    {ok, [self_audit_checker:field()], usage(), pos_integer()} | {error, term()}.
extract(Arm, Provider, Source) ->
    extract(Arm, Provider, Source, fun(_Row) -> ok end).

%% @doc As `extract/3', but every pass is offered to `Emit' before it is turned
%% into a result (FIX 2). The emitted row carries arm, pass, raw text, usage and
%% outcome, which is exactly what 016 could not explain its own blocker without.
-spec extract(single_pass | draft_verify, string(), binary(), emit()) ->
    {ok, [self_audit_checker:field()], usage(), pos_integer()} | {error, term()}.
extract(single_pass, Provider, Source, Emit) ->
    single(Provider, Source, Emit);
extract(draft_verify, Provider, Source, Emit) ->
    verify(Provider, Source, Emit).

single(Provider, Source, Emit) ->
    one(pass_call(Provider, draft_messages(Source), single_pass, draft, Emit)).

one({error, _} = E)              -> E;
one({ok, Fields, _Text, U})      -> {ok, Fields, U, 1}.

verify(Provider, Source, Emit) ->
    after_draft(pass_call(Provider, draft_messages(Source), draft_verify, draft, Emit),
                Provider, Source, Emit).

after_draft({error, _} = E, _Provider, _Source, _Emit) ->
    E;
after_draft({ok, _Fields, DraftText, U1}, Provider, Source, Emit) ->
    after_verify(pass_call(Provider, verify_messages(Source, DraftText),
                           draft_verify, verify, Emit), U1).

after_verify({error, _} = E, _U1)             -> E;
after_verify({ok, Fields, _Text, U2}, U1)     -> {ok, Fields, sum_usage(U1, U2), 2}.

%% @doc D0, the copy control (insight 019). One draft, then a pass whose ONLY
%% difference from `verify_messages/2' is the system prompt: same article, same
%% draft, same message shape, but the instruction is "reproduce exactly" instead
%% of "remove what you cannot confirm".
%%
%% Any field lost between the two lists is REGENERATION ATTRITION, lost with no
%% verification decision taken at all. That is mechanism (d) in 019, and it is the
%% one that survives an engine swap, so it is worth knowing before anything larger
%% is built.
%%
%% Both lists come from the SAME draft call, so the pairing is exact within the
%% item and the control costs two calls rather than three.
-spec attrition(string(), binary(), emit()) ->
    {ok, [self_audit_checker:field()], [self_audit_checker:field()], usage(), pos_integer()} |
    {error, term()}.
attrition(Provider, Source, Emit) ->
    after_d0_draft(pass_call(Provider, draft_messages(Source), copy_control, draft, Emit),
                   Provider, Source, Emit).

after_d0_draft({error, _} = E, _Provider, _Source, _Emit) ->
    E;
after_d0_draft({ok, DraftFields, DraftText, U1}, Provider, Source, Emit) ->
    after_copy(pass_call(Provider, copy_messages(Source, DraftText),
                         copy_control, copy, Emit), DraftFields, U1).

after_copy({error, _} = E, _DraftFields, _U1) ->
    E;
after_copy({ok, CopyFields, _Text, U2}, DraftFields, U1) ->
    {ok, DraftFields, CopyFields, sum_usage(U1, U2), 2}.

%% --- one pass: call, classify, offer to the sink, then deliver ---

pass_call(Provider, Messages, Arm, Pass, Emit) ->
    settle(call(Provider, Messages), Arm, Pass, Emit).

settle({error, Reason}, Arm, Pass, Emit) ->
    _ = Emit(#{kind => pass, arm => Arm, pass => Pass, outcome => call_failed,
               raw => <<>>, error => iolist_to_binary(io_lib:format("~p", [Reason]))}),
    {error, Reason};
settle({ok, Text, U}, Arm, Pass, Emit) ->
    Result = classify(Text, U),
    _ = Emit(row(Arm, Pass, Text, U, Result)),
    deliver(Result, Text, U).

row(Arm, Pass, Text, U, {Outcome, _Fields}) ->
    #{kind => pass, arm => Arm, pass => Pass, outcome => Outcome,
      raw => Text, usage => U}.

deliver({ok, Fields}, Text, U)   -> {ok, Fields, Text, U};
deliver({Outcome, _}, _Text, _U) -> {error, {parse, Outcome}}.

%% @doc FIX 1. Truncation is checked BEFORE parseability, and a truncated body is
%% a failure even when it happens to parse, because that is what 014 froze: "any
%% output hitting the token limit is a parse-class failure". Exported so the rule
%% can be tested without a live backend.
-spec classify(binary(), usage()) -> {outcome(), [self_audit_checker:field()]}.
classify(Text, U) ->
    on_truncation(maps:get(truncated, U, false), Text).

on_truncation(true, _Text) -> {truncated, []};
on_truncation(false, Text) -> parsed(parse_fields(Text)).

parsed({ok, Fields})         -> {ok, Fields};
parsed({error, unparseable}) -> {malformed, []}.

%% draft_verify's cost is BOTH calls: tokens, wall-clock and retries all add. The
%% model is pinned for the whole run, so either row's is the run's model.
%% `truncated' is sticky across passes: if EITHER call hit the cap the arm's
%% output is truncation-class, which is what makes the asymmetry 016 suspected
%% (the verify pass writes the longer body) visible instead of inferred.
sum_usage(A, B) ->
    #{prompt        => maps:get(prompt, A) + maps:get(prompt, B),
      completion    => maps:get(completion, A) + maps:get(completion, B),
      total         => maps:get(total, A) + maps:get(total, B),
      cached        => maps:get(cached, A) + maps:get(cached, B),
      elapsed_ms    => maps:get(elapsed_ms, A) + maps:get(elapsed_ms, B),
      retries       => maps:get(retries, A) + maps:get(retries, B),
      model         => maps:get(model, A),
      finish_reason => maps:get(finish_reason, B, <<>>),
      truncated     => maps:get(truncated, A, false) orelse maps:get(truncated, B, false)}.

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

%% D0's user message is byte-identical to `verify_messages/2'. Only the system
%% prompt differs, so the copy control changes exactly ONE variable against the
%% arm 018 signed. Anything lost here was lost by regenerating the document, not
%% by judging it.
copy_messages(Source, DraftText) ->
    [#{<<"role">> => <<"system">>, <<"content">> => copy_system()},
     #{<<"role">> => <<"user">>,
       <<"content">> => <<"ARTICLE:\n", Source/binary, "\n\nDRAFT:\n", DraftText/binary>>}].

copy_system() ->
    <<"Reproduce the DRAFT exactly as it is given to you. Do not verify anything "
      "against the article. Do not add, remove, correct, re-order or re-word any "
      "field. Copy every field through unchanged, including any field that looks "
      "wrong. Output ONLY the same JSON {\"fields\":[...]}, field for field.">>.

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
    %% The cap travels with the call because FIX 1's second truncation test is
    %% "completion_tokens == the cap actually sent"; a cap read from a default
    %% somewhere else would silently stop detecting.
    Cap = maps:get(max_tokens, Config, ?MAX_TOKENS),
    Base = #{<<"model">> => Model, <<"temperature">> => 0,
             <<"max_tokens">> => Cap,
             <<"messages">> => Messages},
    Body = jsx:encode(reasoning(Model, Base)),
    Req = {maps:get(url, Config), header(Key), "application/json", Body},
    post(Req, maps:get(timeout, Config, 120000), Model, Cap).

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

post(Req, Timeout, Model, Cap) ->
    Result = httpc:request(post, Req, [{timeout, Timeout}, {ssl, [{verify, verify_none}]}],
                           [{body_format, binary}]),
    on_http(Result, Model, Cap).

on_http({ok, {{_, 200, _}, _H, Resp}}, Model, Cap) -> parse_response(Resp, Model, Cap);
on_http({ok, {{_, Code, _}, _H, Resp}}, _M, _Cap)  -> {error, {http, Code, Resp}};
on_http({error, R}, _M, _Cap)                      -> {error, {httpc, R}}.

parse_response(Resp, Model, Cap) ->
    try
        Json = jsx:decode(Resp, [return_maps]),
        [Choice | _] = maps:get(<<"choices">>, Json),
        Text = maps:get(<<"content">>, maps:get(<<"message">>, Choice)),
        {ok, text_bin(Text), usage(Json, Model, Cap)}
    catch _:_ ->
        {error, bad_response}
    end.

text_bin(T) when is_binary(T) -> T;
text_bin(_) -> <<>>.

%% `elapsed_ms' and `retries' are filled by the caller (they span attempts, so a
%% single response cannot know them); seeded here so the map shape is complete.
usage(Json, Model) ->
    usage(Json, Model, ?MAX_TOKENS).

usage(Json, Model, Cap) ->
    U = maps:get(<<"usage">>, Json, #{}),
    Completion = uint(maps:get(<<"completion_tokens">>, U, 0)),
    Finish = finish_of(Json),
    #{prompt        => uint(maps:get(<<"prompt_tokens">>, U, 0)),
      completion    => Completion,
      total         => uint(total_of(U)),
      cached        => uint(cached_of(U)),
      elapsed_ms    => 0,
      retries       => 0,
      model         => Model,
      finish_reason => Finish,
      truncated     => truncated(Finish, Completion, Cap)}.

%% FIX 1 (insight 017), the rule 014 froze and the M1 run never built. Two tests,
%% because providers disagree about which they report: the OpenAI `finish_reason',
%% and the completion reaching the cap that was actually sent. Either is
%% truncation, and truncation is its own parse class.
truncated(<<"length">>, _Completion, _Cap) ->
    true;
truncated(_Finish, Completion, Cap) when is_integer(Cap), Cap > 0, Completion >= Cap ->
    true;
truncated(_Finish, _Completion, _Cap) ->
    false.

finish_of(Json) -> choice_finish(maps:get(<<"choices">>, Json, [])).

choice_finish([Choice | _]) when is_map(Choice) ->
    bin(maps:get(<<"finish_reason">>, Choice, <<>>));
choice_finish(_NoChoices) ->
    <<>>.

bin(B) when is_binary(B) -> B;
bin(_NotBinary)          -> <<>>.

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

%%% @doc Tests for M1's referee: the constant-free L1/L2 verdict, the structural
%%% token ceiling, and the void band — verified on crafted paired rows, so these are
%%% the actual decision logic, not hopes.
-module(self_audit_referee_tests).

-include_lib("eunit/include/eunit.hrl").

row(SpG, SpU, DvG, DvU, SpT, DvT) ->
    #{sp => #{grounded => SpG, ungrounded => SpU, excluded => 0},
      dv => #{grounded => DvG, ungrounded => DvU, excluded => 0},
      sp_tokens => SpT, dv_tokens => DvT}.

%% Clean pass: verify deletes garbage (4->1 ungrounded) and keeps all grounded, at
%% 2.1x tokens under a 2.4x ceiling, base rate in band.
pass_test() ->
    Rows = lists:duplicate(12, row(6, 4, 6, 1, 100, 210)),
    V = self_audit_referee:verdict(Rows, 2.4, 0.40),
    ?assert(maps:get(l1, V)),
    ?assert(maps:get(l2, V)),
    ?assert(maps:get(ceiling_ok, V)),
    ?assert(maps:get(pass, V)),
    ?assertNot(maps:get(void, V)).

%% L1 fails: only a 25% ungrounded reduction (< 50%).
l1_fail_test() ->
    Rows = lists:duplicate(12, row(6, 4, 6, 3, 100, 210)),
    V = self_audit_referee:verdict(Rows, 2.4, 0.40),
    ?assertNot(maps:get(l1, V)),
    ?assertNot(maps:get(pass, V)).

%% L2 fails: indiscriminate deletion removes more grounded (4) than ungrounded (2),
%% even though L1's 50% cut is met.
l2_fail_test() ->
    Rows = lists:duplicate(12, row(6, 4, 2, 2, 100, 210)),
    V = self_audit_referee:verdict(Rows, 2.4, 0.40),
    ?assert(maps:get(l1, V)),
    ?assertNot(maps:get(l2, V)),
    ?assertNot(maps:get(pass, V)).

%% Under-extraction (the hole): drop everything -> L1 passes (100% cut) but grounded
%% collapses far more than ungrounded -> L2 kills it.
under_extraction_blocked_test() ->
    Rows = lists:duplicate(12, row(6, 4, 0, 0, 100, 210)),
    V = self_audit_referee:verdict(Rows, 2.4, 0.40),
    ?assert(maps:get(l1, V)),
    ?assertNot(maps:get(l2, V)),
    ?assertNot(maps:get(pass, V)).

%% Ceiling fails: 3.0x tokens over a 2.4x ceiling.
ceiling_fail_test() ->
    Rows = lists:duplicate(12, row(6, 4, 6, 1, 100, 300)),
    V = self_audit_referee:verdict(Rows, 2.4, 0.40),
    ?assert(maps:get(l1, V)),
    ?assertNot(maps:get(ceiling_ok, V)),
    ?assertNot(maps:get(pass, V)).

%% Void: base ungrounded rate below 5% -> nothing to catch, cannot adjudicate.
void_low_base_test() ->
    Rows = lists:duplicate(12, row(6, 4, 6, 1, 100, 210)),
    V = self_audit_referee:verdict(Rows, 2.4, 0.02),
    ?assert(maps:get(void, V)),
    ?assertNot(maps:get(pass, V)).

%% Void: base rate above 40% -> task broken.
void_high_base_test() ->
    Rows = lists:duplicate(12, row(6, 4, 6, 1, 100, 210)),
    V = self_audit_referee:verdict(Rows, 2.4, 0.55),
    ?assert(maps:get(void, V)).

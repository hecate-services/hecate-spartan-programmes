%%% @doc The reporting path.
%%%
%%% `summary/1' runs AFTER scoring. A crash there destroys the verdict of a run
%%% that has already spent its compute, and M1's confirmatory slice is scored
%%% once. It had no test, and it did crash: `~.0f' raises badarg because Erlang's
%%% float precision must be greater than zero. A three-item smoke run caught it
%%% before a full run did.
%%%
%%% These tests do not check the wording. They check that every branch renders at
%%% all, for a verdict map shaped the way `finalize/3' shapes one.
-module(self_audit_assay_tests).

-include_lib("eunit/include/eunit.hrl").

verdict(Overrides) ->
    Base = #{n => 90, confirm_items => 108, confirm_scored => 90,
             calib_items => 35, calib_scored => 30,
             mean_sp_ungrounded => 1.234, mean_dv_ungrounded => 0.456,
             mean_sp_grounded => 3.5, mean_dv_grounded => 3.2,
             rel_reduction => 0.63, drop_grounded => 0.3, drop_ungrounded => 0.778,
             token_ratio => 2.05, ceiling => 2.31, base_ungrounded_rate => 0.26,
             mean_sp_ms => 21537.0, mean_dv_ms => 48983.0,
             total_retries => 0, total_cached => 0,
             model => <<"qwen2.5:7b-instruct-q4_K_M">>, model_stable => true,
             l1 => true, l2 => true, ceiling_ok => true, above_noise => true,
             void => false, parse_fail_gap_ok => true, pass => true,
             sp_parse_fail => 0.0, dv_parse_fail => 0.0},
    maps:merge(Base, Overrides).

%% The regression: float means went through `~.0f' and raised badarg.
renders_a_pass_test() ->
    ?assertEqual(ok, self_audit_assay:summary(verdict(#{}))).

renders_a_fail_test() ->
    ?assertEqual(ok, self_audit_assay:summary(verdict(#{pass => false, l1 => false}))).

renders_a_void_test() ->
    ?assertEqual(ok, self_audit_assay:summary(verdict(#{void => true, pass => false}))).

%% 014's model-change void has its own verdict line, so it has its own branch.
renders_a_model_change_void_test() ->
    ?assertEqual(ok, self_audit_assay:summary(
                       verdict(#{model_stable => false, void => true, pass => false}))).

%% An empty run must not divide by zero or crash on an undefined model.
renders_an_empty_run_test() ->
    ?assertEqual(ok, self_audit_assay:summary(
                       verdict(#{n => 0, confirm_scored => 0, calib_scored => 0,
                                 model => undefined,
                                 mean_sp_ms => 0.0, mean_dv_ms => 0.0}))).

%% Whole-number means are the case that made `~.0f' look plausible.
renders_integral_means_test() ->
    ?assertEqual(ok, self_audit_assay:summary(
                       verdict(#{mean_sp_ms => 20000.0, mean_dv_ms => 40000.0}))).

renders_an_error_test() ->
    ?assertEqual(ok, self_audit_assay:summary({error, {read, enoent}})).

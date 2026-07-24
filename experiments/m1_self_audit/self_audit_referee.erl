%%% @doc Experiment M1's referee (insight 014, Fable-cleared round 14). Pure: given
%%% the paired per-item tallies (only items where BOTH arms parsed), the frozen token
%%% ceiling, and the calibration base rate, it renders the constant-free verdict.
%%%
%%%   L1 (precision): mean UNGROUNDED fields/item falls >= 50% relative, and the
%%%       paired reduction is above item-sampling noise (mean > 2x standard error).
%%%   L2 (discrimination): the absolute drop in GROUNDED fields/item is SMALLER than
%%%       the absolute drop in UNGROUNDED fields/item — the audit must delete more
%%%       garbage than good material. No tunable constant.
%%%   Ceiling: mean draft_verify tokens/item over mean single_pass tokens/item must
%%%       not exceed the ceiling derived structurally from calibration (x1.1).
%%%   Void: calibration base ungrounded rate < 5% (nothing to catch) or > 40% (task
%%%       broken) — the run cannot adjudicate.
%%%
%%% A pass requires L1 AND L2 AND ceiling, on a non-void run.
-module(self_audit_referee).

-export([verdict/3, mean/1, sem/1]).

-type tally() :: #{grounded := non_neg_integer(), ungrounded := non_neg_integer(),
                   excluded := non_neg_integer()}.
-type row()   :: #{sp := tally(), dv := tally(),
                   sp_tokens := non_neg_integer(), dv_tokens := non_neg_integer()}.

-spec verdict([row()], number(), float()) -> map().
verdict(Rows, Ceiling, Base) ->
    SpUng = [t(sp, ungrounded, R) || R <- Rows],
    DvUng = [t(dv, ungrounded, R) || R <- Rows],
    SpGr  = [t(sp, grounded, R) || R <- Rows],
    DvGr  = [t(dv, grounded, R) || R <- Rows],
    SpTok = [maps:get(sp_tokens, R) || R <- Rows],
    DvTok = [maps:get(dv_tokens, R) || R <- Rows],
    DUng  = subtract(SpUng, DvUng),
    MeanSpUng = mean(SpUng),
    MeanDvUng = mean(DvUng),
    RelRed = rel_reduction(MeanSpUng, MeanDvUng),
    AboveNoise = mean(DUng) > 2.0 * sem(DUng),
    L1 = RelRed >= 0.5 andalso AboveNoise,
    DropGr  = mean(SpGr) - mean(DvGr),
    DropUng = MeanSpUng - MeanDvUng,
    L2 = DropGr < DropUng,
    Ratio = safe_div(mean(DvTok), mean(SpTok)),
    CeilingOk = Ratio =< Ceiling,
    Void = Base < 0.05 orelse Base > 0.40,
    #{n => length(Rows), void => Void, base_ungrounded_rate => Base,
      l1 => L1, l2 => L2, ceiling_ok => CeilingOk,
      pass => (not Void) andalso L1 andalso L2 andalso CeilingOk,
      rel_reduction => RelRed, above_noise => AboveNoise,
      drop_grounded => DropGr, drop_ungrounded => DropUng,
      token_ratio => Ratio, ceiling => Ceiling,
      mean_sp_ungrounded => MeanSpUng, mean_dv_ungrounded => MeanDvUng,
      mean_sp_grounded => mean(SpGr), mean_dv_grounded => mean(DvGr)}.

t(Arm, Key, Row) -> maps:get(Key, maps:get(Arm, Row)).

subtract(As, Bs) -> [A - B || {A, B} <- lists:zip(As, Bs)].

rel_reduction(+0.0, _Dv) -> 0.0;
rel_reduction(SpUng, DvUng) -> (SpUng - DvUng) / SpUng.

safe_div(_N, +0.0) -> 0.0;
safe_div(N, D)    -> N / D.

-spec mean([number()]) -> float().
mean([]) -> 0.0;
mean(L)  -> lists:sum(L) / length(L).

%% Standard error of the mean, sample sd / sqrt(n). Zero for n < 2.
-spec sem([number()]) -> float().
sem(L) when length(L) < 2 -> 0.0;
sem(L) ->
    N = length(L),
    M = mean(L),
    Var = lists:sum([(X - M) * (X - M) || X <- L]) / (N - 1),
    math:sqrt(Var) / math:sqrt(N).

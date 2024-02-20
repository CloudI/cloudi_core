%-*-Mode:erlang;coding:utf-8;tab-width:4;c-basic-offset:4;indent-tabs-mode:()-*-
% ex: set ft=erlang fenc=utf-8 sts=4 ts=4 sw=4 et nomod:
%%%
%%%------------------------------------------------------------------------
%%% @doc
%%% ==CloudI Statistics==
%%% Calculate statistics using the online algorithm.
%%%
%%% Philippe Pébay, Timothy B. Terriberry, Hemanth Kolla, Janine Bennett.
%%% Formulas for the Computation of Higher-Order Central Moments.
%%% Technical Report SAND2014-17343J, Sandia National Laboratories, 2014.
%%%
%%% Pébay, Philippe.  Formulas for Robust, One-Pass Parallel Computation of
%%% Covariances and Arbitrary-Order Statistical Moments.
%%% Technical Report SAND2008-6212, Sandia National Laboratories, 2008.
%%%
%%% Welford, B. P.. Note on a method for calculating corrected sums of
%%% squares and products. Technometrics vol. 4, no. 3, pp. 419–420, 1962.
%%% @end
%%%
%%% MIT License
%%%
%%% Copyright (c) 2022-2024 Michael Truog <mjtruog at protonmail dot com>
%%%
%%% Permission is hereby granted, free of charge, to any person obtaining a
%%% copy of this software and associated documentation files (the "Software"),
%%% to deal in the Software without restriction, including without limitation
%%% the rights to use, copy, modify, merge, publish, distribute, sublicense,
%%% and/or sell copies of the Software, and to permit persons to whom the
%%% Software is furnished to do so, subject to the following conditions:
%%%
%%% The above copyright notice and this permission notice shall be included in
%%% all copies or substantial portions of the Software.
%%%
%%% THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
%%% IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
%%% FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
%%% AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
%%% LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
%%% FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
%%% DEALINGS IN THE SOFTWARE.
%%%
%%% @author Michael Truog <mjtruog at protonmail dot com>
%%% @copyright 2022-2024 Michael Truog
%%% @version 2.0.8 {@date} {@time}
%%%------------------------------------------------------------------------

-module(cloudi_statistics).
-author('mjtruog at protonmail dot com').

%% external interface
-export([add/2,
         add_from_list/2,
         add_from_list/3,
         count/1,
         describe_distribution/1,
         describe_kurtosis/1,
         describe_skewness/1,
         kurtosis/1,
         mean/1,
         merge/2,
         new/0,
         normal_from_log_normal/1,
         normal_to_log_normal/1,
         skewness/1,
         standard_deviation/1,
         maximum/1,
         minimum/1,
         variance/1]).

-include("cloudi_core_i_constants.hrl").

-record(statistics,
    {
        n = 0 :: non_neg_integer(),
        mean = 0.0 :: float(),
        m2 = 0.0 :: float(),
        m3 = 0.0 :: float(),
        m4 = 0.0 :: float(),
        minimum = ?DBL_MAX :: float(),
        maximum = -?DBL_MAX :: float(),
        cached_kurtosis = undefined :: float() | undefined,
        cached_skewness = undefined :: float() | undefined,
        cached_stddev = undefined :: float() | undefined,
        cached_variance = undefined :: float() | undefined
    }).

%%%------------------------------------------------------------------------
%%% External interface functions
%%%------------------------------------------------------------------------

-type describe_distribution() ::
    normal | uniform | logistic | exponential |
    gamma_family | log_normal_family | undefined.
-type describe_kurtosis() ::
    leptokurtic | platykurtic | mesokurtic | undefined.
-type describe_skewness() ::
    highly_skewed | moderately_skewed | approximately_symmetric | undefined.
-type state() :: #statistics{}.
-export_type([describe_distribution/0,
              describe_kurtosis/0,
              describe_skewness/0,
              state/0]).

%%-------------------------------------------------------------------------
%% @doc
%% ===Add a sample for computing statistics.===
%% @end
%%-------------------------------------------------------------------------

-spec add(X :: number(),
          State :: state()) ->
    state().

add(X, #statistics{n = NOld,
                   mean = Mean,
                   m2 = M2,
                   m3 = M3,
                   m4 = M4,
                   minimum = Minimum,
                   maximum = Maximum} = State)
    when is_number(X) ->
    XAdd = float(X),
    N = NOld + 1,
    Delta = XAdd - Mean,
    DeltaN = Delta / N,
    DeltaN2 = DeltaN * DeltaN,
    Term1 = Delta * DeltaN * NOld,
    MeanNew = Mean + DeltaN,
    M4New = M4 +
            Term1 * DeltaN2 * (N * N - 3 * N + 3) +
            6 * DeltaN2 * M2 -
            4 * DeltaN * M3,
    M3New = M3 +
            Term1 * DeltaN * (N - 2) -
            3 * DeltaN * M2,
    M2New = M2 + Term1,
    MinimumNew = erlang:min(Minimum, XAdd),
    MaximumNew = erlang:max(Maximum, XAdd),
    State#statistics{n = N,
                     mean = MeanNew,
                     m2 = M2New,
                     m3 = M3New,
                     m4 = M4New,
                     minimum = MinimumNew,
                     maximum = MaximumNew,
                     cached_kurtosis = undefined,
                     cached_skewness = undefined,
                     cached_stddev = undefined,
                     cached_variance = undefined}.

%%-------------------------------------------------------------------------
%% @doc
%% ===Add samples from a list for computing statistics.===
%% @end
%%-------------------------------------------------------------------------

-spec add_from_list(L :: list(number()),
                    State :: state()) ->
    state().

add_from_list([], State) ->
    State;
add_from_list([X | L], State) ->
    add_from_list(L, add(X, State)).

%%-------------------------------------------------------------------------
%% @doc
%% ===Add samples from a function mapped on a list for computing statistics.===
%% @end
%%-------------------------------------------------------------------------

-spec add_from_list(F :: fun(),
                    L :: list(number()),
                    State :: state()) ->
    state().

add_from_list(F, L, State) ->
    if
        is_function(F, 1) ->
            add_from_list_1(L, State, F);
        is_function(F, 2) ->
            add_from_list_2(L, State, F);
        is_function(F, 3) ->
            add_from_list_3(L, State, F)
    end.

%%-------------------------------------------------------------------------
%% @doc
%% ===Count of samples previously added.===
%% @end
%%-------------------------------------------------------------------------

-spec count(State :: state()) ->
    non_neg_integer().

count(#statistics{n = N}) ->
    N.

%%-------------------------------------------------------------------------
%% @doc
%% ===Describe the distribution with a guess about its shape.===
%% Only use if the sample count is large enough to cover the distribution.
%% @end
%%-------------------------------------------------------------------------

-spec describe_distribution(State :: state()) ->
    {describe_distribution(), state()}.

describe_distribution(State) ->
    case kurtosis(State) of
        {undefined, _} = Result ->
            Result;
        {Kurtosis, StateNext} ->
            case skewness(StateNext) of
                {undefined, _} = Result ->
                    Result;
                {Skewness, StateNew} ->
                    SkewnessDelta = if
                        Skewness =< -4 orelse Skewness >= 4 ->
                            math:sqrt(abs(Skewness)) * 0.5;
                        true ->
                            0.25
                    end,
                    KurtosisDelta = if
                        Kurtosis >= 9 ->
                            math:sqrt(Kurtosis) * 0.5;
                        true ->
                            0.175
                    end,
                    describe_distribution_0(Skewness,
                                            Skewness - SkewnessDelta,
                                            Skewness + SkewnessDelta,
                                            Kurtosis,
                                            Kurtosis - KurtosisDelta,
                                            Kurtosis + KurtosisDelta,
                                            StateNew)
            end
    end.

%%-------------------------------------------------------------------------
%% @doc
%% ===Describe the excess kurtosis value.===
%% Only use if the sample count is large enough to cover the distribution.
%% @end
%%-------------------------------------------------------------------------

-spec describe_kurtosis(State :: state()) ->
    {describe_kurtosis(), state()}.

describe_kurtosis(State) ->
    case kurtosis(State) of
        {undefined, _} = Result ->
            Result;
        {Kurtosis, StateNew} ->
            KurtosisX10 = round(Kurtosis * 10),
            if
                KurtosisX10 > 0 ->
                    {leptokurtic, StateNew};
                KurtosisX10 < 0 ->
                    {platykurtic, StateNew};
                KurtosisX10 == 0 ->
                    {mesokurtic, StateNew}
            end
    end.

%%-------------------------------------------------------------------------
%% @doc
%% ===Describe the skewness value.===
%% Only use if the sample count is large enough to cover the distribution.
%%
%% (based on)
%% Bulmer, M. G..
%% Principles of Statistics. Dover Publications, 1979.
%% @end
%%-------------------------------------------------------------------------

-spec describe_skewness(State :: state()) ->
    {describe_skewness(), state()}.

describe_skewness(State) ->
    case skewness(State) of
        {undefined, _} = Result ->
            Result;
        {Skewness, StateNew} ->
            if
                Skewness < -1.0 orelse Skewness > 1.0 ->
                    {highly_skewed, StateNew};
                Skewness =< -0.5 orelse Skewness >= 0.5 ->
                    {moderately_skewed, StateNew};
                Skewness > -0.5 andalso Skewness < 0.5 ->
                    {approximately_symmetric, StateNew}
            end
    end.

%%-------------------------------------------------------------------------
%% @doc
%% ===Excess kurtosis of samples previously added.===
%% The minimum value returned is -2.0 (Fisher’s definition).
%% @end
%%-------------------------------------------------------------------------

-spec kurtosis(State :: state()) ->
    {float() | undefined, state()}.

kurtosis(#statistics{n = N,
                     m2 = M2,
                     m4 = M4,
                     cached_kurtosis = undefined} = State) ->
    Denominator = M2 * M2,
    if
        Denominator /= 0.0 ->
            Kurtosis = N * M4 / Denominator - 3.0,
            {Kurtosis, State#statistics{cached_kurtosis = Kurtosis}};
        true ->
            {undefined, State}
    end;
kurtosis(#statistics{cached_kurtosis = Kurtosis} = State) ->
    {Kurtosis, State}.

%%-------------------------------------------------------------------------
%% @doc
%% ===Maximum of samples previously added.===
%% @end
%%-------------------------------------------------------------------------

-spec maximum(State :: state()) ->
    float().

maximum(#statistics{maximum = Maximum}) ->
    Maximum.

%%-------------------------------------------------------------------------
%% @doc
%% ===Mean of samples previously added.===
%% The value returned is the arithmetic mean.
%% @end
%%-------------------------------------------------------------------------

-spec mean(State :: state()) ->
    float().

mean(#statistics{mean = Mean}) ->
    Mean.

%%-------------------------------------------------------------------------
%% @doc
%% ===Merge statistics state.===
%% @end
%%-------------------------------------------------------------------------

-spec merge(StateA :: state(),
            StateB :: state()) ->
    state().

merge(#statistics{} = StateA,
      #statistics{n = 0}) ->
    StateA;
merge(#statistics{n = 0},
      #statistics{} = StateB) ->
    StateB;
merge(#statistics{n = NA,
                  mean = MeanA,
                  m2 = M2A,
                  m3 = M3A,
                  m4 = M4A,
                  minimum = MinimumA,
                  maximum = MaximumA},
      #statistics{n = NB,
                  mean = MeanB,
                  m2 = M2B,
                  m3 = M3B,
                  m4 = M4B,
                  minimum = MinimumB,
                  maximum = MaximumB}) ->
    N = NA + NB,
    Delta = MeanA - MeanB,
    DeltaN = Delta / N,
    DeltaN2 = DeltaN * DeltaN,
    NA2 = NA * NA,
    NB2 = NB * NB,
    N_2 = NA * NB,
    M4 = M4A + M4B +
         DeltaN2 * DeltaN2 * N_2 * (NB * NB2 + NA * NA2) +
         6.0 * (NB2 * M2A + NA2 * M2B) * DeltaN2 +
         4.0 * (NB * M3A - NA * M3B) * DeltaN,
    M3 = M3A + M3B +
         N_2 * (NB - NA) * Delta * DeltaN2 +
         3.0 * (NB * M2A - NA * M2B) * DeltaN,
    M2 = M2A + M2B +
         N_2 * Delta * DeltaN,
    Mean = MeanB + NA * DeltaN,
    Minimum = erlang:min(MinimumA, MinimumB),
    Maximum = erlang:max(MaximumA, MaximumB),
    #statistics{n = N,
                mean = Mean,
                m2 = M2,
                m3 = M3,
                m4 = M4,
                minimum = Minimum,
                maximum = Maximum}.

%%-------------------------------------------------------------------------
%% @doc
%% ===Minimum of samples previously added.===
%% @end
%%-------------------------------------------------------------------------

-spec minimum(State :: state()) ->
    float().

minimum(#statistics{minimum = Minimum}) ->
    Minimum.

%%-------------------------------------------------------------------------
%% @doc
%% ===Create statistics state.===
%% @end
%%-------------------------------------------------------------------------

-spec new() ->
    state().

new() ->
    #statistics{}.

%%-------------------------------------------------------------------------
%% @doc
%% ===Convert the Log-normal distribution mean and standard deviation to Normal distribution mean and standard deviation.===
%% @end
%%-------------------------------------------------------------------------

-spec normal_from_log_normal(State :: state()) ->
    {{NormalMean :: float(),
      NormalStdDev :: float()} | undefined, state()}.

normal_from_log_normal(State) ->
    case variance(State) of
        {undefined, _} = Result ->
            Result;
        {Variance, #statistics{mean = Mean} = StateNew} ->
            NormalMean = math:exp(Mean + Variance / 2),
            NormalStandardDeviation = math:sqrt((math:exp(Variance) - 1) *
                                                math:exp(2 * Mean + Variance)),
            {{NormalMean, NormalStandardDeviation}, StateNew}
    end.

%%-------------------------------------------------------------------------
%% @doc
%% ===Convert the Normal distribution mean and standard deviation to Log-normal distribution mean and standard deviation.===
%% @end
%%-------------------------------------------------------------------------

-spec normal_to_log_normal(State :: state()) ->
    {{LogNormalMean :: float(),
      LogNormalStdDev :: float()} | undefined, state()}.

normal_to_log_normal(State) ->
    case variance(State) of
        {undefined, _} = Result ->
            Result;
        {Variance, #statistics{mean = Mean} = StateNew} ->
            Mean2 = Mean * Mean,
            Sum = Mean2 + Variance,
            LogNormalMean = math:log(Mean2 / math:sqrt(Sum)),
            LogNormalStandardDeviation = math:sqrt(math:log(Sum / Mean2)),
            {{LogNormalMean, LogNormalStandardDeviation}, StateNew}
    end.

%%-------------------------------------------------------------------------
%% @doc
%% ===Sample skewness of samples previously added.===
%% The value returned is the Fisher-Pearson coefficient of skewness.
%% @end
%%-------------------------------------------------------------------------

-spec skewness(State :: state()) ->
    {float() | undefined, state()}.

skewness(#statistics{n = N,
                     m2 = M2,
                     m3 = M3,
                     cached_skewness = undefined} = State) ->
    Denominator = math:pow(M2, 1.5),
    if
        Denominator /= 0.0 ->
            Skewness = math:sqrt(N) * M3 / Denominator,
            {Skewness, State#statistics{cached_skewness = Skewness}};
        true ->
            {undefined, State}
    end;
skewness(#statistics{cached_skewness = Skewness} = State) ->
    {Skewness, State}.

%%-------------------------------------------------------------------------
%% @doc
%% ===Sample standard deviation of samples previously added.===
%% @end
%%-------------------------------------------------------------------------

-spec standard_deviation(State :: state()) ->
    {float() | undefined, state()}.

standard_deviation(#statistics{cached_stddev = undefined} = State) ->
    case variance(State) of
        {undefined, _} = Result ->
            Result;
        {Variance, StateNew} ->
            StandardDeviation = math:sqrt(Variance),
            {StandardDeviation,
             StateNew#statistics{cached_stddev = StandardDeviation}}
    end;
standard_deviation(#statistics{cached_stddev = StandardDeviation} = State) ->
    {StandardDeviation, State}.

%%-------------------------------------------------------------------------
%% @doc
%% ===Sample variance of samples previously added.===
%% @end
%%-------------------------------------------------------------------------

-spec variance(State :: state()) ->
    {float() | undefined, state()}.

variance(#statistics{n = N,
                     m2 = M2,
                     cached_variance = undefined} = State) ->
    if
        N > 1 ->
            Variance = M2 / (N - 1.0),
            {Variance, State#statistics{cached_variance = Variance}};
        true ->
            {undefined, State}
    end;
variance(#statistics{cached_variance = Variance} = State) ->
    {Variance, State}.

%%%------------------------------------------------------------------------
%%% Private functions
%%%------------------------------------------------------------------------

add_from_list_1([X0 | L], State, F) ->
    add_from_list_1(L, add(F(X0), State), F);
add_from_list_1([], State, _) ->
    State.

add_from_list_2([X0, X1 | L], State, F) ->
    add_from_list_2(L, add(F(X0, X1), State), F);
add_from_list_2(_, State, _) ->
    State.

add_from_list_3([X0, X1, X2 | L], State, F) ->
    add_from_list_3(L, add(F(X0, X1, X2), State), F);
add_from_list_3(_, State, _) ->
    State.

describe_distribution_0(Skewness, SkewnessLow, SkewnessHigh,
                        Kurtosis, KurtosisLow, KurtosisHigh, State)
    when SkewnessLow < 0 andalso SkewnessHigh > 0 ->
    if
        KurtosisLow < 0 andalso KurtosisHigh > 0 ->
            {normal, State};
        KurtosisLow < -1.2 andalso KurtosisHigh > -1.2 ->
            {uniform, State};
        KurtosisLow < 1.2 andalso KurtosisHigh > 1.2 ->
            {logistic, State};
        true ->
            describe_distribution_1(Skewness, SkewnessLow, SkewnessHigh,
                                    Kurtosis, KurtosisLow, KurtosisHigh, State)
    end;
describe_distribution_0(Skewness, SkewnessLow, SkewnessHigh,
                        Kurtosis, KurtosisLow, KurtosisHigh, State)
    when SkewnessLow < 2 andalso SkewnessHigh > 2 ->
    if
        KurtosisLow < 6 andalso KurtosisHigh > 6 ->
            {exponential, State};
        true ->
            describe_distribution_1(Skewness, SkewnessLow, SkewnessHigh,
                                    Kurtosis, KurtosisLow, KurtosisHigh, State)
    end;
describe_distribution_0(Skewness, SkewnessLow, SkewnessHigh,
                        Kurtosis, KurtosisLow, KurtosisHigh, State) ->
    describe_distribution_1(Skewness, SkewnessLow, SkewnessHigh,
                            Kurtosis, KurtosisLow, KurtosisHigh, State).

describe_distribution_1(Skewness, SkewnessLow, SkewnessHigh,
                        Kurtosis, KurtosisLow, KurtosisHigh, State) ->
    TestL0 = [],
    TestL1 = skewness_check(TestL0,
                            gamma_family, fun gamma_kurtosis/1,
                            Skewness, SkewnessLow, SkewnessHigh,
                            Kurtosis, KurtosisLow, KurtosisHigh),
    TestLN = skewness_check(TestL1,
                            log_normal_family, fun log_normal_kurtosis/1,
                            Skewness, SkewnessLow, SkewnessHigh,
                            Kurtosis, KurtosisLow, KurtosisHigh),
    case TestLN of
        [{_, TestType} | _] ->
            {TestType, State};
        [] ->
            {undefined, State}
    end.

skewness_check(TestL, TestType, TestF,
               Skewness, SkewnessLow, SkewnessHigh,
               Kurtosis, KurtosisLow, KurtosisHigh)
    when is_function(TestF, 1) ->
    TestKurtosis = TestF(Skewness),
    Passed = if
        KurtosisLow < TestKurtosis andalso
        KurtosisHigh > TestKurtosis ->
            true;
        true ->
            TestKurtosisLow = TestF(SkewnessLow),
            TestKurtosisHigh = TestF(SkewnessHigh),
            TestKurtosisLow < Kurtosis andalso TestKurtosisHigh > Kurtosis
    end,
    if
        Passed =:= true ->
            lists:keymerge(1, TestL,
                           [{abs(TestKurtosis - Kurtosis), TestType}]);
        Passed =:= false ->
            TestL
    end.

gamma_kurtosis(Skewness) ->
    X = 2 / Skewness,
    6 / (X * X).

log_normal_kurtosis(Skewness) ->
    if
        Skewness /= 0.0 ->
            A = log_normal_skewness_a(Skewness),
            A2 = A * A,
            A2 * A2 + 2 * A2 * A + 3 * A2 - 6;
        true ->
            0.0
    end.

log_normal_skewness_a(Skewness) ->
    % use Halley's method to determine A based on Log-normal skewness
    % A = e^(NormalStandardDeviation^2)
    % (A + 2)^2 * (A - 1) = Skewness^2
    % B = A - 1
    % (B + 3)^2 * B = Skewness^2
    Skewness2 = Skewness * Skewness,
    log_normal_skewness_b(math:pow(Skewness2, 1 / 3) - 1, Skewness2) + 1.

log_normal_skewness_b(B, Skewness2) ->
    B2 = B * B,
    F0B = B2 * B + 6 * B2 + 9 * B - Skewness2,
    F1B = 3 * B2 + 12 * B + 9,
    F2B = 6 * B + 12,
    BE = B - (2 * F0B * F1B) / ((2 * F1B * F1B) - (F0B * F2B)),
    if
        abs(BE - B) > 0.0001 ->
            log_normal_skewness_b(BE, Skewness2);
        true ->
            BE
    end.


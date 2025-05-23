%-*-Mode:erlang;coding:utf-8;tab-width:4;c-basic-offset:4;indent-tabs-mode:()-*-
% ex: set ft=erlang fenc=utf-8 sts=4 ts=4 sw=4 et nomod:
%%%------------------------------------------------------------------------
%%% @doc
%%% ==CloudI Core Basic Tests==
%%% @end
%%%
%%% MIT License
%%%
%%% Copyright (c) 2014-2025 Michael Truog <mjtruog at protonmail dot com>
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
%%% @copyright 2014-2025 Michael Truog
%%% @version 2.0.8 {@date} {@time}
%%%------------------------------------------------------------------------

-module(cloudi_service_SUITE).
-behaviour(cloudi_service).

%% cloudi_service callbacks
-export([cloudi_service_init/4,
         cloudi_service_handle_request/11,
         cloudi_service_handle_info/3,
         cloudi_service_terminate/3]).

%% CT callbacks
-export([all/0,
         groups/0,
         suite/0,
         init_per_suite/1,
         end_per_suite/1,
         group/1,
         init_per_group/2,
         end_per_group/2,
         init_per_testcase/2,
         end_per_testcase/2]).

%% test callbacks
-export([t_cloudi_code_status_1/1,
         t_service_internal_sync_1/1,
         t_service_internal_sync_2/1,
         t_service_internal_sync_3/1,
         t_service_internal_async_1/1,
         t_service_internal_async_2/1,
         t_service_internal_async_3/1,
         t_service_internal_aspects_1/1,
         t_service_internal_terminate_1/1,
         t_service_internal_terminate_2/1,
         t_service_internal_terminate_3/1,
         t_service_internal_terminate_4/1,
         t_service_internal_update_1/1,
         t_service_internal_update_pid_options_1/1,
         t_service_internal_update_pid_options_2/1,
         t_service_internal_log_1/1,
         t_service_internal_idle_1/1,
         t_service_internal_stop_error_1/1,
         t_service_internal_stop_error_2/1,
         t_service_internal_stop_error_3/1,
         t_service_internal_stop_error_4/1,
         t_service_internal_stop_shutdown_1/1,
         t_service_internal_stop_shutdown_2/1,
         t_service_internal_stop_shutdown_3/1,
         t_service_internal_stop_shutdown_4/1,
         t_service_internal_stop_shutdown_5/1,
         t_service_internal_stop_shutdown_6/1,
         t_service_internal_stop_shutdown_7/1,
         t_service_internal_stop_shutdown_8/1,
         t_service_internal_stop_normal_1/1,
         t_service_internal_stop_normal_2/1,
         t_service_internal_stop_normal_3/1,
         t_service_internal_stop_normal_4/1,
         t_service_internal_fatal_timeout_1/1,
         t_service_internal_fatal_timeout_2/1,
         t_service_internal_fatal_timeout_3/1,
         t_cloudi_args_type_1/1,
         t_cloudi_service_name_1/1]).

%% test helpers
-export([service_increment_aspect_init/5,
         service_increment_aspect_request_before/11,
         service_increment_aspect_request_after/12,
         service_increment_aspect_info/3,
         service_increment_aspect_terminate/3]).

-record(state,
    {
        mode :: atom(),
        requests = [] :: list({cloudi_service:request_type(),
                               cloudi_service:service_name(),
                               cloudi_service:service_name_pattern(),
                               cloudi_service:request_info(),
                               cloudi_service:request(),
                               cloudi_service:timeout_value_milliseconds(),
                               cloudi_service:priority(),
                               cloudi_service:trans_id(),
                               cloudi_service:source()}),
        count = 0 :: non_neg_integer()
    }).

-include_lib("common_test/include/ct.hrl").
-include_lib("cloudi_core/include/cloudi_logger.hrl").
-include_lib("cloudi_core/include/cloudi_service_api.hrl").

-ifndef(CLOUDI_TEST_TIMEOUT).
-define(CLOUDI_TEST_TIMEOUT, 10). % seconds
-endif.
-define(EXCEPTION(E),
        (fun() ->
             try E, no_exception
             catch ErrorType:Error -> {ErrorType, Error}
             end
         end)()).
-define(VSN, {"test", "version", "(any erlang term data can be used)"}).
-define(SERVICE_PREFIX1, "/").
-define(SERVICE_SUFFIX1, "service_name").
-define(RESPONSE_INFO1, <<"response_info">>).
-define(RESPONSE1, <<"response">>).
-define(REQUEST_INFO1, <<"request_info">>).
-define(REQUEST1, <<"request">>).
-define(REQUEST_INFO2, <<>>).
-define(REQUEST2, <<"requests">>).
-define(REQUEST_INFO3, <<>>).
-define(REQUEST3, <<"mcast">>).
-define(REQUEST_INFO4, <<>>).
-define(REQUEST4, <<"request_stateless">>).
-define(REQUEST_INFO5, <<>>).
-define(REQUEST5, <<"increment">>).
-define(REQUEST_INFO6, <<>>).
-define(REQUEST6, <<"count">>).
-define(REQUEST_INFO7, <<>>).
-define(REQUEST7, <<"crash">>).
-vsn(?VSN).

%%%------------------------------------------------------------------------
%%% Callback functions from cloudi_service
%%%------------------------------------------------------------------------

cloudi_service_init(Args, ?SERVICE_PREFIX1, _Timeout, Dispatcher) ->
    Defaults = [
        {mode,                             undefined}],
    [Mode] = cloudi_proplists:take_values(Defaults, Args),
    NewMode = if
        Mode =:= idle ->
            idle;
        Mode =:= reply;
        Mode =:= reply_timeout;
        Mode =:= terminate_sleep;
        Mode =:= pid ->
            ok = cloudi_service:subscribe(Dispatcher,
                                          ?SERVICE_SUFFIX1),
            Mode;
        Mode =:= reply_x4 ->
            ok = cloudi_service:subscribe(Dispatcher,
                                          ?SERVICE_SUFFIX1),
            ok = cloudi_service:subscribe(Dispatcher,
                                          ?SERVICE_SUFFIX1),
            ok = cloudi_service:subscribe(Dispatcher,
                                          ?SERVICE_SUFFIX1),
            ok = cloudi_service:subscribe(Dispatcher,
                                          ?SERVICE_SUFFIX1),
            reply;
        Mode =:= init_send_sync ->
            {ok, _, _} = cloudi_service:send_sync(Dispatcher,
                                                  ?SERVICE_PREFIX1 ++
                                                  ?SERVICE_SUFFIX1,
                                                  ?REQUEST_INFO4, ?REQUEST4,
                                                  undefined, undefined),
            undefined;
        Mode =:= init_send_async_recv ->
            {ok, TransId} = cloudi_service:send_async(Dispatcher,
                                                      ?SERVICE_PREFIX1 ++
                                                      ?SERVICE_SUFFIX1,
                                                      ?REQUEST_INFO4, ?REQUEST4,
                                                      undefined, undefined),
            {ok, _, _} = cloudi_service:recv_async(Dispatcher, TransId),
            undefined
    end,
    {ok, #state{mode = NewMode}}.

cloudi_service_handle_request(RequestType, Name, Pattern,
                              ?REQUEST_INFO1 = RequestInfo, ?REQUEST1 = Request,
                              Timeout, Priority, TransId, Pid,
                              #state{mode = reply,
                                     requests = Requests} = State,
                              _Dispatcher) ->
    NewRequests = [{RequestType, Name, Pattern, RequestInfo, Request,
                    Timeout, Priority, TransId, Pid} | Requests],
    {reply, ?RESPONSE_INFO1, ?RESPONSE1,
     State#state{requests = NewRequests}};
cloudi_service_handle_request(_RequestType, _Name, _Pattern,
                              ?REQUEST_INFO2, ?REQUEST2,
                              _Timeout, _Priority, _TransId, _Pid,
                              #state{mode = reply,
                                     requests = Requests} = State,
                              _Dispatcher) ->
    {reply, <<>>, lists:reverse(Requests), State#state{requests = []}};
cloudi_service_handle_request(_RequestType, Name, _Pattern,
                              ?REQUEST_INFO3, ?REQUEST3,
                              _Timeout, _Priority, _TransId, _Pid,
                              #state{mode = reply} = State,
                              Dispatcher) ->
    {ok, TransIds} = cloudi_service:mcast_async(Dispatcher, Name,
                                                ?REQUEST_INFO1, ?REQUEST1,
                                                undefined, undefined),
    {ok, Responses} = cloudi_service:recv_asyncs(Dispatcher,
                                                 {5, seconds}, TransIds),
    {reply, Responses, State};
cloudi_service_handle_request(_RequestType, _Name, _Pattern,
                              ?REQUEST_INFO4, ?REQUEST4,
                              _Timeout, _Priority, _TransId, _Pid,
                              #state{mode = Mode} = State,
                              _Dispatcher)
    when (Mode =:= reply) orelse
         (Mode =:= terminate_sleep) ->
    {reply, ?RESPONSE_INFO1, ?RESPONSE1, State};
cloudi_service_handle_request(_RequestType, _Name, _Pattern,
                              ?REQUEST_INFO5, ?REQUEST5,
                              _Timeout, _Priority, _TransId, _Pid,
                              #state{mode = reply,
                                     count = Count} = State,
                              _Dispatcher) ->
    {reply, ?RESPONSE_INFO1, ?RESPONSE1,
     State#state{count = Count + 1}};
cloudi_service_handle_request(_RequestType, _Name, _Pattern,
                              ?REQUEST_INFO6, ?REQUEST6,
                              _Timeout, _Priority, _TransId, _Pid,
                              #state{mode = reply,
                                     count = Count} = State,
                              _Dispatcher) ->
    {reply, Count, State};
cloudi_service_handle_request(_RequestType, _Name, _Pattern,
                              ?REQUEST_INFO1, ?REQUEST1,
                              Timeout, _Priority, _TransId, _Pid,
                              #state{mode = reply_timeout} = State,
                              _Dispatcher) ->
    receive after Timeout + 100 -> ok end,
    {reply, ?RESPONSE_INFO1, ?RESPONSE1, State};
cloudi_service_handle_request(_RequestType, _Name, _Pattern,
                              <<>>, <<>>,
                              _Timeout, _Priority, _TransId, _Pid,
                              #state{mode = pid} = State,
                              _Dispatcher) ->
    {reply, self(), State};
cloudi_service_handle_request(_RequestType, _Name, _Pattern,
                              <<>>, {stop, Reason},
                              _Timeout, _Priority, _TransId, _Pid,
                              #state{mode = pid} = State,
                              _Dispatcher) ->
    {stop, Reason, State};
cloudi_service_handle_request(_RequestType, _Name, _Pattern,
                              <<>>, service_pids,
                              _Timeout, _Priority, _TransId, _Pid,
                              #state{mode = pid} = State,
                              Dispatcher) ->
    Service = cloudi_service:self(Dispatcher),
    {reply, {Dispatcher, Service}, State};
cloudi_service_handle_request(_RequestType, _Name, _Pattern,
                              ?REQUEST_INFO7, ?REQUEST7,
                              _Timeout, _Priority, _TransId, _Pid,
                              #state{} = State,
                              _Dispatcher) ->
    erlang:exit(crash),
    {noreply, State}.

cloudi_service_handle_info(increment,
                           #state{mode = reply,
                                  count = Count} = State, _Dispatcher) ->
    {noreply, State#state{count = Count + 2}};
cloudi_service_handle_info({pid, Pid},
                           #state{mode = pid} = State, _Dispatcher) ->
    Pid ! {pid, self()},
    {noreply, State};
cloudi_service_handle_info({stop, Reason},
                           #state{mode = pid} = State, _Dispatcher) ->
    {stop, Reason, State};
cloudi_service_handle_info(Request, State, _Dispatcher) ->
    {stop, cloudi_string:format("Unknown info \"~w\"", [Request]), State}.

cloudi_service_terminate(_Reason, _Timeout, undefined) ->
    % cloudi_service_init/3 caused an exception
    ok;
cloudi_service_terminate(terminate_sleep_test_1, _Timeout,
                         #state{mode = terminate_sleep}) ->
    % t_service_internal_terminate_1/1 and
    % t_service_internal_terminate_2/1 result
    ?LOG_INFO("terminate_sleep_test_1 requires brutal_kill", []),
    receive after 2000 -> ok end,
    ?LOG_FATAL("execution should never get to this point", []),
    ok;
cloudi_service_terminate(terminate_sleep_test_2, _Timeout,
                         #state{mode = terminate_sleep}) ->
    % t_service_internal_terminate_3/1 and
    % t_service_internal_terminate_4/1 result
    ?LOG_INFO("terminate_sleep_test_2 does not requires brutal_kill", []),
    receive after 3000 -> ok end,
    ?LOG_INFO("terminate_sleep_test_2 finished the terminate function", []),
    ok;
cloudi_service_terminate(_Reason, _Timeout,
                         #state{mode = reply,
                                count = 60}) ->
    % t_service_internal_aspects_1/1 result
    ok;
cloudi_service_terminate(_Reason, _Timeout,
                         #state{mode = reply,
                                count = 100}) ->
    % t_service_internal_update_1/1 result
    ok;
cloudi_service_terminate(_Reason, _Timeout,
                         #state{count = 0}) ->
    ok.

%%%------------------------------------------------------------------------
%%% Callback functions from CT
%%%------------------------------------------------------------------------

all() ->
    [{group, cloudi_runtime_1},
     {group, service_internal_1},
     {group, cloudi_modules_1}].

groups() ->
    [{cloudi_runtime_1, [sequence],
      [t_cloudi_code_status_1]},
     {service_internal_1, [sequence],
      [t_service_internal_sync_1,
       t_service_internal_sync_2,
       t_service_internal_sync_3,
       t_service_internal_async_1,
       t_service_internal_async_2,
       t_service_internal_async_3,
       t_service_internal_aspects_1,
       t_service_internal_terminate_1,
       t_service_internal_terminate_2,
       t_service_internal_terminate_3,
       t_service_internal_terminate_4,
       t_service_internal_update_1,
       t_service_internal_update_pid_options_1,
       t_service_internal_update_pid_options_2,
       t_service_internal_log_1,
       t_service_internal_idle_1,
       t_service_internal_stop_error_1,
       t_service_internal_stop_error_2,
       t_service_internal_stop_error_3,
       t_service_internal_stop_error_4,
       t_service_internal_stop_shutdown_1,
       t_service_internal_stop_shutdown_2,
       t_service_internal_stop_shutdown_3,
       t_service_internal_stop_shutdown_4,
       t_service_internal_stop_shutdown_5,
       t_service_internal_stop_shutdown_6,
       t_service_internal_stop_shutdown_7,
       t_service_internal_stop_shutdown_8,
       t_service_internal_stop_normal_1,
       t_service_internal_stop_normal_2,
       t_service_internal_stop_normal_3,
       t_service_internal_stop_normal_4,
       t_service_internal_fatal_timeout_1,
       t_service_internal_fatal_timeout_2,
       t_service_internal_fatal_timeout_3]},
     {cloudi_modules_1, [parallel],
      [t_cloudi_args_type_1,
       t_cloudi_service_name_1]}].

suite() ->
    [{ct_hooks, [cth_surefire]},
     {timetrap, {seconds, ?CLOUDI_TEST_TIMEOUT}}].

init_per_suite(Config) ->
    ok = reltool_util:application_start(cloudi_core, [], infinity),
    Config.

end_per_suite(_Config) ->
    ok = reltool_util:application_stop(cloudi_core),
    ok.

group(_GroupName) ->
    [].

init_per_group(_GroupName, Config) ->
    Config.

end_per_group(_GroupName, Config) ->
    Config.

init_per_testcase(TestCase) ->
    error_logger:info_msg("~p init~n", [TestCase]),
    if
        TestCase =:= t_cloudi_code_status_1 ->
            ok;
        true ->
            error_logger:tty(false)
    end,
    ?LOG_INFO("~p init", [TestCase]),
    ok.

end_per_testcase(TestCase) ->
    if
        TestCase =:= t_cloudi_code_status_1 ->
            ok;
        true ->
            error_logger:tty(true)
    end,
    error_logger:info_msg("~p end~n", [TestCase]),
    ?LOG_INFO("~p end", [TestCase]),
    ok.

init_per_testcase(TestCase, Config)
    when (TestCase =:= t_service_internal_sync_1) orelse
         (TestCase =:= t_service_internal_sync_2) orelse
         (TestCase =:= t_service_internal_async_1) orelse
         (TestCase =:= t_service_internal_update_1) ->
    ok = init_per_testcase(TestCase),
    {ok, ServiceIds} = cloudi_service_api:services_add([
        % using proplist configuration format, not the tuple/record format
        [{prefix, ?SERVICE_PREFIX1},
         {module, ?MODULE},
         {args, [{mode, reply}]},
         {options,
          [{request_timeout_adjustment, true},
           {response_timeout_adjustment, true},
           {automatic_loading, false},
           {hibernate, false}]}]
        ], infinity),
    [{service_ids, ServiceIds} | Config];
init_per_testcase(TestCase, Config)
    when (TestCase =:= t_service_internal_sync_3) ->
    ok = init_per_testcase(TestCase),
    {ok, ServiceIds} = cloudi_service_api:services_add([
        % using proplist configuration format, not the tuple/record format
        [{prefix, ?SERVICE_PREFIX1},
         {module, ?MODULE},
         {args, [{mode, reply}]},
         {options,
          [{request_timeout_adjustment, true},
           {response_timeout_adjustment, true},
           {automatic_loading, false},
           {hibernate, true}]}]
        ], infinity),
    [{service_ids, ServiceIds} | Config];
init_per_testcase(TestCase, Config)
    when (TestCase =:= t_service_internal_async_2) ->
    ok = init_per_testcase(TestCase),
    {ok, ServiceIds} = cloudi_service_api:services_add([
        % using proplist configuration format, not the tuple/record format
        [{prefix, ?SERVICE_PREFIX1},
         {module, ?MODULE},
         {args, [{mode, reply_x4}]},
         {options,
          [{request_timeout_adjustment, true},
           {response_timeout_adjustment, true},
           {automatic_loading, false}]}]
        ], infinity),
    [{service_ids, ServiceIds} | Config];
init_per_testcase(TestCase, Config)
    when (TestCase =:= t_service_internal_async_3) ->
    ok = init_per_testcase(TestCase),
    {ok, ServiceIds} = cloudi_service_api:services_add([
        % using proplist configuration format, not the tuple/record format
        [{prefix, ?SERVICE_PREFIX1},
         {module, ?MODULE},
         {args, [{mode, reply_x4}]},
         {count_process, 2},
         {options,
          [{request_timeout_adjustment, true},
           {response_timeout_adjustment, true},
           {automatic_loading, false}]}]
        ], infinity),
    [{service_ids, ServiceIds} | Config];
init_per_testcase(TestCase, Config)
    when (TestCase =:= t_service_internal_aspects_1) ->
    ok = init_per_testcase(TestCase),
    InitAfter1 = fun(_, _, _, #state{count = Count} = State, _) ->
        {ok, State#state{count = Count + 3}}
    end,
    InitAfter2 = {?MODULE, service_increment_aspect_init},
    RequestBefore = {?MODULE, service_increment_aspect_request_before},
    RequestAfter = {?MODULE, service_increment_aspect_request_after},
    InfoBefore = {?MODULE, service_increment_aspect_info},
    InfoAfter = {?MODULE, service_increment_aspect_info},
    TerminateBefore = {?MODULE, service_increment_aspect_terminate},
    {ok, ServiceIds} = cloudi_service_api:services_add([
        % using proplist configuration format, not the tuple/record format
        [{prefix, ?SERVICE_PREFIX1},
         {module, ?MODULE},
         {args, [{mode, reply}]},
         {options,
          [{request_timeout_adjustment, true},
           {response_timeout_adjustment, true},
           {automatic_loading, false},
           {aspects_init_after, [InitAfter1, InitAfter2]},
           {aspects_request_before, [RequestBefore]},
           {aspects_request_after, [RequestAfter]},
           {aspects_info_before, [InfoBefore]},
           {aspects_info_after, [InfoAfter]},
           {aspects_terminate_before, [TerminateBefore]}]}]
        ], infinity),
    [{service_ids, ServiceIds} | Config];
init_per_testcase(TestCase, Config)
    when (TestCase =:= t_service_internal_terminate_1) ->
    ok = init_per_testcase(TestCase),
    {ok, ServiceIds} = cloudi_service_api:services_add([
        % using proplist configuration format, not the tuple/record format
        [{prefix, ?SERVICE_PREFIX1},
         {module, ?MODULE},
         {args, [{mode, terminate_sleep}]},
         % make max terminate execution time 1.5 second
         {max_r, 200},
         {max_t, 300},
         {options,
          [{automatic_loading, false}]}]
        ], infinity),
    [{service_ids, ServiceIds} | Config];
init_per_testcase(TestCase, Config)
    when (TestCase =:= t_service_internal_terminate_2) ->
    ok = init_per_testcase(TestCase),
    {ok, ServiceIds} = cloudi_service_api:services_add([
        % using proplist configuration format, not the tuple/record format
        [{prefix, ?SERVICE_PREFIX1},
         {module, ?MODULE},
         {args, [{mode, terminate_sleep}]},
         % make max terminate execution time 1.5 second
         {max_r, 200},
         {max_t, 300},
         {options,
          [{automatic_loading, false},
           {duo_mode, true}]}]
        ], infinity),
    [{service_ids, ServiceIds} | Config];
init_per_testcase(TestCase, Config)
    when (TestCase =:= t_service_internal_terminate_3) ->
    ok = init_per_testcase(TestCase),
    {ok, ServiceIds} = cloudi_service_api:services_add([
        % using proplist configuration format, not the tuple/record format
        [{prefix, ?SERVICE_PREFIX1},
         {module, ?MODULE},
         {args, [{mode, terminate_sleep}]},
         % make max terminate execution time 3.191 seconds
         {max_r, 94},
         {max_t, 300},
         {options,
          [{automatic_loading, false}]}]
        ], infinity),
    [{service_ids, ServiceIds} | Config];
init_per_testcase(TestCase, Config)
    when (TestCase =:= t_service_internal_terminate_4) ->
    ok = init_per_testcase(TestCase),
    {ok, ServiceIds} = cloudi_service_api:services_add([
        % using proplist configuration format, not the tuple/record format
        [{prefix, ?SERVICE_PREFIX1},
         {module, ?MODULE},
         {args, [{mode, terminate_sleep}]},
         % make max terminate execution time 3.191 seconds
         {max_r, 94},
         {max_t, 300},
         {options,
          [{automatic_loading, false},
           {duo_mode, true}]}]
        ], infinity),
    [{service_ids, ServiceIds} | Config];
init_per_testcase(TestCase, Config)
    when (TestCase =:= t_service_internal_idle_1) ->
    ok = init_per_testcase(TestCase),
    {ok, ServiceIds} = cloudi_service_api:services_add([
        % using proplist configuration format, not the tuple/record format
        [{prefix, ?SERVICE_PREFIX1},
         {module, ?MODULE},
         {args, [{mode, idle}]},
         {options,
          [{automatic_loading, false}]}]
        ], infinity),
    [{service_ids, ServiceIds} | Config];
init_per_testcase(TestCase, Config)
    when (TestCase =:= t_service_internal_update_pid_options_1) orelse
         (TestCase =:= t_service_internal_update_pid_options_2) orelse
         (TestCase =:= t_service_internal_stop_error_1) orelse
         (TestCase =:= t_service_internal_stop_error_2) orelse
         (TestCase =:= t_service_internal_stop_shutdown_1) orelse
         (TestCase =:= t_service_internal_stop_shutdown_2) orelse
         (TestCase =:= t_service_internal_stop_shutdown_5) orelse
         (TestCase =:= t_service_internal_stop_shutdown_6) orelse
         (TestCase =:= t_service_internal_stop_normal_1) orelse
         (TestCase =:= t_service_internal_stop_normal_2) ->
    DuoMode = (TestCase =:= t_service_internal_update_pid_options_2),
    ok = init_per_testcase(TestCase),
    {ok, ServiceIds} = cloudi_service_api:services_add([
        % using the record configuration format (from cloudi_service_api.hrl)
        #internal{prefix = ?SERVICE_PREFIX1,
                  module = ?MODULE,
                  args = [{mode, pid}],
                  options = [{automatic_loading, false},
                             {request_pid_uses, infinity},
                             {info_pid_uses, infinity},
                             {duo_mode, DuoMode}]}
        ], infinity),
    [{service_ids, ServiceIds} | Config];
init_per_testcase(TestCase, Config)
    when (TestCase =:= t_service_internal_stop_error_3) orelse
         (TestCase =:= t_service_internal_stop_error_4) orelse
         (TestCase =:= t_service_internal_stop_shutdown_3) orelse
         (TestCase =:= t_service_internal_stop_shutdown_4) orelse
         (TestCase =:= t_service_internal_stop_shutdown_7) orelse
         (TestCase =:= t_service_internal_stop_shutdown_8) orelse
         (TestCase =:= t_service_internal_stop_normal_3) orelse
         (TestCase =:= t_service_internal_stop_normal_4) ->
    ok = init_per_testcase(TestCase),
    {ok, ServiceIds} = cloudi_service_api:services_add([
        % using the record configuration format (from cloudi_service_api.hrl)
        #internal{prefix = ?SERVICE_PREFIX1,
                  module = ?MODULE,
                  args = [{mode, pid}],
                  options = [{automatic_loading, false},
                             {duo_mode, true},
                             {request_pid_uses, infinity},
                             {info_pid_uses, infinity}]}
        ], infinity),
    [{service_ids, ServiceIds} | Config];
init_per_testcase(TestCase, Config)
    when (TestCase =:= t_service_internal_fatal_timeout_1) ->
    ok = init_per_testcase(TestCase),
    {ok, ServiceIds} = cloudi_service_api:services_add([
        % using the record configuration format (from cloudi_service_api.hrl)
        #internal{prefix = ?SERVICE_PREFIX1,
                  module = ?MODULE,
                  args = [{mode, reply_timeout}],
                  options = [{automatic_loading, false},
                             {fatal_timeout, true},
                             {fatal_timeout_interrupt, true},
                             {fatal_timeout_delay, 0}]}
        ], infinity),
    [{service_ids, ServiceIds} | Config];
init_per_testcase(TestCase, Config)
    when (TestCase =:= t_service_internal_fatal_timeout_2) ->
    ok = init_per_testcase(TestCase),
    {ok, ServiceIds} = cloudi_service_api:services_add([
        % using the record configuration format (from cloudi_service_api.hrl)
        #internal{prefix = ?SERVICE_PREFIX1,
                  module = ?MODULE,
                  args = [{mode, reply_timeout}],
                  options = [{automatic_loading, false},
                             {fatal_timeout, true},
                             {fatal_timeout_interrupt, false},
                             {fatal_timeout_delay, 0}]}
        ], infinity),
    [{service_ids, ServiceIds} | Config];
init_per_testcase(TestCase, Config)
    when (TestCase =:= t_service_internal_fatal_timeout_3) ->
    ok = init_per_testcase(TestCase),
    {ok, ServiceIds} = cloudi_service_api:services_add([
        % using the record configuration format (from cloudi_service_api.hrl)
        #internal{prefix = ?SERVICE_PREFIX1,
                  module = ?MODULE,
                  args = [{mode, reply_timeout}],
                  options = [{automatic_loading, false},
                             {fatal_timeout, true},
                             {fatal_timeout_interrupt, true},
                             {fatal_timeout_delay, 200}]}
        ], infinity),
    [{service_ids, ServiceIds} | Config];
init_per_testcase(TestCase, Config) ->
    ok = init_per_testcase(TestCase),
    Config.

end_per_testcase(TestCase, Config) ->
    ok = end_per_testcase(TestCase),
    case lists:keytake(service_ids, 1, Config) of
        {value, {_, ServiceIds}, NewConfig} ->
            ok = cloudi_service_api:services_remove(ServiceIds, infinity),
            NewConfig;
        false ->
            Config
    end.

%%%------------------------------------------------------------------------
%%% test cases
%%%------------------------------------------------------------------------

t_cloudi_code_status_1(_Config) ->
    {ok, CodeStatus} = cloudi_service_api:code_status(infinity),
    error_logger:info_msg("~p~n", [CodeStatus]),
    ?LOG_INFO("~p", [CodeStatus]),
    ok.

t_service_internal_sync_1(_Config) ->
    % make sure synchronous sends work normally,
    % fail within the cloudi_service_init/3 callback with invalid_state,
    % and that an exception within cloudi_service_init/3 doesn't affect
    % other services
    Context0 = cloudi:new([{timeout_sync, {5, seconds}}]),
    ServiceName = ?SERVICE_PREFIX1 ++ ?SERVICE_SUFFIX1,
    Self = self(),
    {{ok, ?RESPONSE_INFO1, ?RESPONSE1},
     Context1} = cloudi:send_sync(Context0,
                                  ServiceName,
                                  ?REQUEST_INFO1, ?REQUEST1,
                                  {5, seconds}, undefined),
    {{ok,
      [{'send_sync', ServiceName, ServiceName, ?REQUEST_INFO1, ?REQUEST1,
        Timeout1, 0, TransId1, Self}]},
     Context2} = cloudi:send_sync(Context1,
                                  ServiceName,
                                  ?REQUEST2),
    true = Timeout1 =< 5000,
    true = uuid:is_v1(TransId1),
    {error,
     {service_internal_start_failed,
      {error, invalid_state}}} = cloudi_service_api:services_add([
        [{prefix, ?SERVICE_PREFIX1},
         {module, ?MODULE},
         {args, [{mode, init_send_sync}]},
         {options, [{automatic_loading, false}]}]
        ], infinity),
    {{ok, ?RESPONSE_INFO1, ?RESPONSE1},
     Context3}= cloudi:send_sync(Context2,
                                 ServiceName,
                                 ?REQUEST_INFO1, ?REQUEST1,
                                 undefined, undefined),
    {{ok,
      [{'send_sync', ServiceName, ServiceName, ?REQUEST_INFO1, ?REQUEST1,
        _Timeout2, 0, TransId2, Self}]},
     _Context4} = cloudi:send_sync(Context3,
                                   ServiceName,
                                   ?REQUEST2),
    true = uuid:is_v1(TransId2),
    true = (uuid:get_v1_time_ns(TransId2) >
            uuid:get_v1_time_ns(TransId1)),
    {error,
     {service_internal_start_failed,
      {error, invalid_state}}} = cloudi_service_api:services_add([
        [{prefix, ?SERVICE_PREFIX1},
         {module, ?MODULE},
         {args, [{mode, init_send_sync}]},
         {options, [{automatic_loading, false}]}]
        ], infinity),
    ok.

t_service_internal_sync_2(_Config) ->
    % check sync service requests that cause exceptions
    Context0 = cloudi:new(),
    ServiceName = ?SERVICE_PREFIX1 ++ ?SERVICE_SUFFIX1,
    {{ok, ?RESPONSE_INFO1, ?RESPONSE1},
     Context1} = cloudi:send_sync(Context0,
                                  ServiceName,
                                  ?REQUEST_INFO4, ?REQUEST4,
                                  undefined, undefined),
    {{ok, {_, Service}},
     Context2} = cloudi:get_pid(Context1,
                                ServiceName,
                                limit_min),
    true = erlang:is_process_alive(Service),
    {{error, timeout},
     _Context3} = cloudi:send_sync(Context2,
                                   ServiceName,
                                   ?REQUEST_INFO7, ?REQUEST7,
                                   limit_min, undefined),
    receive after 100 -> ok end,
    false = erlang:is_process_alive(Service),
    ok.

t_service_internal_sync_3(Config) ->
    ok = t_service_internal_sync_2(Config).

t_service_internal_async_1(_Config) ->
    % make sure asynchronous sends work normally, that recv_async
    % fails within the cloudi_service_init/3 callback with invalid_state,
    % and that an exception within cloudi_service_init/3 doesn't affect
    % other services
    Context0 = cloudi:new(),
    ServiceName = ?SERVICE_PREFIX1 ++ ?SERVICE_SUFFIX1,
    Self = self(),
    TimeoutMax = cloudi:timeout_async(Context0),
    {{ok, TransId1},
     Context1} = cloudi:send_async(Context0,
                                   ServiceName,
                                   ?REQUEST_INFO1, ?REQUEST1,
                                   undefined, undefined),
    {{ok, ?RESPONSE_INFO1, ?RESPONSE1, TransId1},
     Context2} = cloudi:recv_async(Context1, TransId1),
    {{ok,
      [{'send_async', ServiceName, ServiceName, ?REQUEST_INFO1, ?REQUEST1,
        Timeout1, 0, TransId1, Self}]},
     Context3} = cloudi:send_sync(Context2,
                                  ServiceName,
                                  ?REQUEST2),
    true = (Timeout1 > (TimeoutMax - 1000)) andalso (Timeout1 =< TimeoutMax),
    true = uuid:is_v1(TransId1),
    {error,
     {service_internal_start_failed,
      {error, invalid_state}}} = cloudi_service_api:services_add([
        [{prefix, ?SERVICE_PREFIX1},
         {module, ?MODULE},
         {args, [{mode, init_send_async_recv}]},
         {max_r, 0},
         {options, [{automatic_loading, false}]}]
        ], infinity),
    {{ok, TransId2},
     Context4} = cloudi:send_async(Context3,
                                   ServiceName,
                                   ?REQUEST_INFO1, ?REQUEST1,
                                   undefined, undefined),
    {{ok, ?RESPONSE_INFO1, ?RESPONSE1, TransId2},
     Context5} = cloudi:recv_async(Context4, TransId2),
    {{ok,
      [{'send_async', ServiceName, ServiceName, ?REQUEST_INFO1, ?REQUEST1,
        Timeout2, 0, TransId2, Self}]},
     _Context6} = cloudi:send_sync(Context5,
                                   ServiceName,
                                   ?REQUEST2),
    true = (Timeout2 > (TimeoutMax - 1000)) andalso (Timeout2 =< TimeoutMax),
    true = uuid:is_v1(TransId2),
    true = (uuid:get_v1_time_ns(TransId2) >
            uuid:get_v1_time_ns(TransId1)),
    {error,
     {service_internal_start_failed,
      {error, invalid_state}}} = cloudi_service_api:services_add([
        [{prefix, ?SERVICE_PREFIX1},
         {module, ?MODULE},
         {args, [{mode, init_send_async_recv}]},
         {max_r, 0},
         {options, [{automatic_loading, false}]}]
        ], infinity),
    ok.

t_service_internal_async_2(_Config) ->
    % make sure mcast_async works normally and remains ordered when
    % sending to a service that has a single process
    % (including cloudi:recv_asyncs functionality)
    receive after 1000 -> ok end,
    Context0 = cloudi:new(),
    ServiceName = ?SERVICE_PREFIX1 ++ ?SERVICE_SUFFIX1,
    Self = self(),
    TimeoutMax = cloudi:timeout_async(Context0),
    {{ok, [TransId1, TransId2, TransId3, TransId4]},
     Context1} = cloudi:mcast_async(Context0,
                                    ServiceName,
                                    ?REQUEST_INFO1, ?REQUEST1,
                                    undefined, undefined),
    {{ok, ?RESPONSE_INFO1, ?RESPONSE1, TransId1},
     Context2} = cloudi:recv_async(Context1, <<0:128>>),
    {{ok, ?RESPONSE_INFO1, ?RESPONSE1, TransId2},
     Context3} = cloudi:recv_async(Context2, <<0:128>>),
    {{ok, ?RESPONSE_INFO1, ?RESPONSE1, TransId3},
     Context4} = cloudi:recv_async(Context3, <<0:128>>),
    {{ok, ?RESPONSE_INFO1, ?RESPONSE1, TransId4},
     Context5} = cloudi:recv_async(Context4, <<0:128>>),
    true = (uuid:get_v1_time_ns(TransId1) <
            uuid:get_v1_time_ns(TransId2)) andalso
           (uuid:get_v1_time_ns(TransId2) <
            uuid:get_v1_time_ns(TransId3)) andalso
           (uuid:get_v1_time_ns(TransId3) <
            uuid:get_v1_time_ns(TransId4)),
    {{ok,
      [{'send_async', ServiceName, ServiceName, ?REQUEST_INFO1, ?REQUEST1,
        Timeout1, 0, TransId1, Self},
       {'send_async', ServiceName, ServiceName, ?REQUEST_INFO1, ?REQUEST1,
        Timeout2, 0, TransId2, Self},
       {'send_async', ServiceName, ServiceName, ?REQUEST_INFO1, ?REQUEST1,
        Timeout3, 0, TransId3, Self},
       {'send_async', ServiceName, ServiceName, ?REQUEST_INFO1, ?REQUEST1,
        Timeout4, 0, TransId4, Self}]},
     Context6} = cloudi:send_sync(Context5,
                                  ServiceName,
                                  ?REQUEST2),
    true = (Timeout1 > (TimeoutMax - 1000)) andalso (Timeout1 =< TimeoutMax),
    true = (Timeout2 > (TimeoutMax - 1000)) andalso (Timeout2 =< TimeoutMax),
    true = (Timeout3 > (TimeoutMax - 1000)) andalso (Timeout3 =< TimeoutMax),
    true = (Timeout4 > (TimeoutMax - 1000)) andalso (Timeout4 =< TimeoutMax),
    true = uuid:is_v1(TransId1),
    true = uuid:is_v1(TransId2),
    true = uuid:is_v1(TransId3),
    true = uuid:is_v1(TransId4),

    {{ok, [TransId5, TransId6, TransId7, TransId8] = TransIds},
     Context7} = cloudi:mcast_async(Context6,
                                    ServiceName,
                                    ?REQUEST_INFO1, ?REQUEST1,
                                    undefined, undefined),
    {{ok,
      [{?RESPONSE_INFO1, ?RESPONSE1, TransId5},
       {?RESPONSE_INFO1, ?RESPONSE1, TransId6},
       {?RESPONSE_INFO1, ?RESPONSE1, TransId7},
       {?RESPONSE_INFO1, ?RESPONSE1, TransId8}]},
     Context8} = cloudi:recv_asyncs(Context7, TransIds),
    true = (uuid:get_v1_time_ns(TransId5) <
            uuid:get_v1_time_ns(TransId6)) andalso
           (uuid:get_v1_time_ns(TransId6) <
            uuid:get_v1_time_ns(TransId7)) andalso
           (uuid:get_v1_time_ns(TransId7) <
            uuid:get_v1_time_ns(TransId8)),
    {{ok,
      [{'send_async', ServiceName, ServiceName, ?REQUEST_INFO1, ?REQUEST1,
        Timeout5, 0, TransId5, Self},
       {'send_async', ServiceName, ServiceName, ?REQUEST_INFO1, ?REQUEST1,
        Timeout6, 0, TransId6, Self},
       {'send_async', ServiceName, ServiceName, ?REQUEST_INFO1, ?REQUEST1,
        Timeout7, 0, TransId7, Self},
       {'send_async', ServiceName, ServiceName, ?REQUEST_INFO1, ?REQUEST1,
        Timeout8, 0, TransId8, Self}]},
     _Context9} = cloudi:send_sync(Context8,
                                   ServiceName,
                                   ?REQUEST2),
    true = (Timeout5 > (TimeoutMax - 1000)) andalso (Timeout5 =< TimeoutMax),
    true = (Timeout6 > (TimeoutMax - 1000)) andalso (Timeout6 =< TimeoutMax),
    true = (Timeout7 > (TimeoutMax - 1000)) andalso (Timeout7 =< TimeoutMax),
    true = (Timeout8 > (TimeoutMax - 1000)) andalso (Timeout8 =< TimeoutMax),
    true = uuid:is_v1(TransId5),
    true = uuid:is_v1(TransId6),
    true = uuid:is_v1(TransId7),
    true = uuid:is_v1(TransId8),
    ok.

t_service_internal_async_3(_Config) ->
    % make sure mcast_async works normally and remains ordered when
    % sending to a single service process (i.e., when only 2 service processes
    % exist, a service mcast_async to the service name will only be able to
    % send to a single service process)
    % (including cloudi_service:recv_asyncs functionality)
    receive after 1000 -> ok end,
    Context0 = cloudi:new(),
    ServiceName = ?SERVICE_PREFIX1 ++ ?SERVICE_SUFFIX1,
    {{ok,
      [{?RESPONSE_INFO1, ?RESPONSE1, TransId1},
       {?RESPONSE_INFO1, ?RESPONSE1, TransId2},
       {?RESPONSE_INFO1, ?RESPONSE1, TransId3},
       {?RESPONSE_INFO1, ?RESPONSE1, TransId4}]},
     _Context1} = cloudi:send_sync(Context0, ServiceName, ?REQUEST3),
    true = (uuid:get_v1_time_ns(TransId1) <
            uuid:get_v1_time_ns(TransId2)) andalso
           (uuid:get_v1_time_ns(TransId2) <
            uuid:get_v1_time_ns(TransId3)) andalso
           (uuid:get_v1_time_ns(TransId3) <
            uuid:get_v1_time_ns(TransId4)),
    true = uuid:is_v1(TransId1),
    true = uuid:is_v1(TransId2),
    true = uuid:is_v1(TransId3),
    true = uuid:is_v1(TransId4),
    ok.

t_service_internal_aspects_1(_Config) ->
    % make sure aspects occur as expected

    % count == 3 (0 + 3), InitAfter1
    % count == 7 (3 + 4), InitAfter2
    Context0 = cloudi:new(),
    ServiceName = ?SERVICE_PREFIX1 ++ ?SERVICE_SUFFIX1,
    % count == 12 (7 + 5), RequestBefore
    {{ok, ?RESPONSE_INFO1, ?RESPONSE1},
     Context1} = cloudi:send_sync(Context0,
                                  ServiceName, % count == 13 (12 + 1)
                                  ?REQUEST_INFO5, ?REQUEST5,
                                  undefined, undefined),
    % count == 18 (13 + 5), RequestAfter
    % count == 23 (18 + 5), RequestBefore
    {{ok, ?RESPONSE_INFO1, ?RESPONSE1},
     Context2} = cloudi:send_sync(Context1,
                                  ServiceName, % count == 24 (23 + 1)
                                  ?REQUEST_INFO5, ?REQUEST5,
                                  undefined, undefined),
    % count == 29 (24 + 5), RequestAfter
    {{ok, {_, Service}},
     Context3} = cloudi:get_pid(Context2,
                                ServiceName,
                                limit_min),
    % count == 35 (29 + 6), InfoBefore
    Service ! increment, % count == 37 (35 + 2)
    % count == 43 (37 + 6), InfoAfter
    % count == 48 (43 + 5), RequestBefore
    {{ok, Count},
     _Context4} = cloudi:send_sync(Context3,
                                   ServiceName,
                                   ?REQUEST_INFO6, ?REQUEST6,
                                   undefined, undefined),
    48 = Count,
    % count == 53 (48 + 5), RequestAfter
    % count == 60 (53 + 7), TerminateBefore
    ok.

service_increment_aspect_init(_, _, _, #state{count = Count} = State, _) ->
    {ok, State#state{count = Count + 4}}.

service_increment_aspect_request_before(_, _, _, _, _, _, _, _, _,
                                        #state{count = Count} = State, _) ->
    {ok, State#state{count = Count + 5}}.

service_increment_aspect_request_after(_, _, _, _, _, _, _, _, _, _,
                                       #state{count = Count} = State, _) ->
    {ok, State#state{count = Count + 5}}.

service_increment_aspect_info(_, #state{count = Count} = State, _) ->
    {ok, State#state{count = Count + 6}}.

service_increment_aspect_terminate(_, _, #state{count = Count} = State) ->
    {ok, State#state{count = Count + 7}}.

t_service_internal_terminate_1(_Config) ->
    % verify the cloudi_service_terminate/2 function execution
    % limitation is enforced
    Context0 = cloudi:new(),
    ServiceName = ?SERVICE_PREFIX1 ++ ?SERVICE_SUFFIX1,
    {{ok, ?RESPONSE_INFO1, ?RESPONSE1},
     Context1} = cloudi:send_sync(Context0,
                                  ServiceName,
                                  ?REQUEST_INFO4, ?REQUEST4,
                                  undefined, undefined),
    {{ok, {_, Service}},
     _Context2} = cloudi:get_pid(Context1,
                                 ServiceName,
                                 limit_min),
    erlang:exit(Service, terminate_sleep_test_1),
    % wait for termination
    receive after 4000 -> ok end,
    ok.

t_service_internal_terminate_2(Config) ->
    ok = t_service_internal_terminate_1(Config).

t_service_internal_terminate_3(_Config) ->
    % verify the cloudi_service_terminate/2 function execution
    % takes the appropriate amount of time
    Context0 = cloudi:new(),
    ServiceName = ?SERVICE_PREFIX1 ++ ?SERVICE_SUFFIX1,
    {{ok, ?RESPONSE_INFO1, ?RESPONSE1},
     Context1} = cloudi:send_sync(Context0,
                                  ServiceName,
                                  ?REQUEST_INFO4, ?REQUEST4,
                                  undefined, undefined),
    {{ok, {_, Service}},
     _Context2} = cloudi:get_pid(Context1,
                                 ServiceName,
                                 limit_min),
    erlang:exit(Service, terminate_sleep_test_2),
    % wait for termination
    receive after 4000 -> ok end,
    ok.

t_service_internal_terminate_4(Config) ->
    ok = t_service_internal_terminate_3(Config).

t_service_internal_update_1(Config) ->
    % update state
    Context0 = cloudi:new(),
    ServiceName = ?SERVICE_PREFIX1 ++ ?SERVICE_SUFFIX1,
    {{ok, Count0},
     Context1} = cloudi:send_sync(Context0,
                                  ServiceName,
                                  ?REQUEST_INFO6, ?REQUEST6,
                                  undefined, undefined),
    0 = Count0,
    {ok, [{ServiceId, _}]} = cloudi_service_api:services(infinity),
    [ServiceId] = ?config(service_ids, Config),
    ModuleState0 = fun(ModuleVersion, ModuleVersion,
                       #state{count = CountValue0} = OldState) ->
        true = [?VSN] == ModuleVersion,
        true = Count0 == CountValue0,
        {ok, OldState#state{count = CountValue0 + 100}}
    end,
    % an exact service_id can be used since the module is only used once
    % (if the module was used in many services, "" or <<>> would need to be
    %  used as the service_id for the update)
    {ok, [[ServiceId]]} = cloudi_service_api:
                          services_update([{ServiceId,
                                            [{module, ?MODULE},
                                             {module_state, ModuleState0}]}],
                                          infinity),
    {{ok, Count1},
     Context2} = cloudi:send_sync(Context1,
                                  ServiceName,
                                  ?REQUEST_INFO6, ?REQUEST6,
                                  undefined, undefined),
    100 = Count1,
    ModuleState1 = fun(ModuleVersion, ModuleVersion,
                       #state{count = CountValue1}) ->
        true = [?VSN] == ModuleVersion,
        true = Count1 == CountValue1,
        {error, not_updating}
    end,
    {error,
     {[ServiceId],
      {service_internal_update_failed,
       [not_updating]}},
     []} = cloudi_service_api:
           services_update([{ServiceId,
                             [{module, ?MODULE},
                              {module_state, ModuleState1}]}],
                           infinity),
    {{ok, Count1},
     _Context3} = cloudi:send_sync(Context2,
                                   ServiceName,
                                   ?REQUEST_INFO6, ?REQUEST6,
                                   undefined, undefined),
    ok.

t_service_internal_update_pid_options_1(Config) ->
    t_service_internal_update_pid_options(Config, false).

t_service_internal_update_pid_options_2(Config) ->
    t_service_internal_update_pid_options(Config, true).

t_service_internal_update_pid_options(Config, DuoMode) ->
    Context0 = cloudi:new(),
    ServiceName = ?SERVICE_PREFIX1 ++ ?SERVICE_SUFFIX1,
    {{ok, {Dispatcher, Service}},
     Context1} = cloudi:send_sync(Context0,
                                  ServiceName,
                                  <<>>, service_pids,
                                  undefined, undefined),
    {{ok, RequestPid0},
     Context2} = cloudi:send_sync(Context1,
                                  ServiceName,
                                  <<>>),
    Service ! {pid, self()},
    InfoPid0 = receive
        {pid, InfoPidValue0} ->
            InfoPidValue0
    end,
    if
        DuoMode =:= true ->
            true = (Dispatcher /= Service),
            true = (InfoPid0 =:= Service);
        DuoMode =:= false ->
            true = (Dispatcher =:= Service)
    end,
    true = (InfoPid0 /= RequestPid0),
    [{max_heap_size,
      MaxHeapSizeDefault},
     {message_queue_data,
      MessageQueueDataDefault},
     {priority,
      PriorityDefault}] = erlang:process_info(Dispatcher,
                                              [max_heap_size,
                                               message_queue_data,
                                               priority]),
    on_heap = MessageQueueDataDefault,
    normal = PriorityDefault,
    [{max_heap_size,
      MaxHeapSizeDefault},
     {message_queue_data,
      MessageQueueDataDefault},
     {priority,
      PriorityDefault}] = erlang:process_info(InfoPid0,
                                              [max_heap_size,
                                               message_queue_data,
                                               priority]),
    [{max_heap_size,
      MaxHeapSizeDefault},
     {message_queue_data,
      MessageQueueDataDefault},
     {priority,
      PriorityDefault}] = erlang:process_info(RequestPid0,
                                              [max_heap_size,
                                               message_queue_data,
                                               priority]),
    DispatcherPidOptions1 = [{max_heap_size,
                              #{error_logger => true,
                                kill => true,
                                size => 1048577}},
                             {priority, high}],
    InfoPidOptions1 = [{max_heap_size,
                        #{error_logger => true,
                          kill => true,
                          size => 1048578}},
                       {message_queue_data, off_heap},
                       {priority, low}],
    RequestPidOptions1 = [{max_heap_size,
                           #{error_logger => true,
                             kill => true,
                             size => 1048579}},
                          {priority, normal}],
    Options0 = [{dispatcher_pid_options,
                 [{sensitive, true} | DispatcherPidOptions1]},
                {info_pid_options, InfoPidOptions1},
                {request_pid_options,
                 [{sensitive, false} | RequestPidOptions1]}],
    [ServiceId] = ?config(service_ids, Config),
    {ok, [[ServiceId]]} = cloudi_service_api:
                          services_update([{ServiceId,
                                            [{module, ?MODULE},
                                             {options, Options0}]}],
                                          infinity),
    {{ok, RequestPid1},
     Context3} = cloudi:send_sync(Context2,
                                  ServiceName,
                                  <<>>),
    Service ! {pid, self()},
    InfoPid1 = receive
        {pid, InfoPidValue1} ->
            InfoPidValue1
    end,
    false = erlang:is_process_alive(RequestPid0),
    true = erlang:is_process_alive(RequestPid1),
    if
        DuoMode =:= true ->
            % ensure dispatcher_pid_options have been applied
            _ = sys:get_state(Dispatcher, infinity),

            true = erlang:is_process_alive(InfoPid0),
            true = (InfoPid0 == InfoPid1);
        DuoMode =:= false ->
            false = erlang:is_process_alive(InfoPid0),
            true = (InfoPid0 /= InfoPid1),
            true = erlang:is_process_alive(InfoPid1)
    end,
    [{max_heap_size,
      MaxHeapSize1},
     {priority,
      high}] = erlang:process_info(Dispatcher,
                                   [max_heap_size,
                                    priority]),
    #{error_logger := true,
      kill := true,
      size := 1048577} = MaxHeapSize1,
    [{max_heap_size,
      MaxHeapSize2},
     {message_queue_data,
      off_heap},
     {priority,
      low}] = erlang:process_info(InfoPid1,
                                  [max_heap_size,
                                   message_queue_data,
                                   priority]),
    #{error_logger := true,
      kill := true,
      size := 1048578} = MaxHeapSize2,
    [{max_heap_size,
      MaxHeapSize3},
     {priority,
      normal}] = erlang:process_info(RequestPid1,
                                     [max_heap_size,
                                      priority]),
    #{error_logger := true,
      kill := true,
      size := 1048579} = MaxHeapSize3,
    DispatcherPidOptions2 = [{priority, normal}],
    InfoPidOptions2 = [{message_queue_data, off_heap}],
    RequestPidOptions2 = [{max_heap_size,
                           #{error_logger => true,
                             kill => true,
                             size => 1048579}}],
    Options1 = [{dispatcher_pid_options, DispatcherPidOptions2},
                {info_pid_options, InfoPidOptions2},
                {request_pid_options, RequestPidOptions2}],
    {ok, [[ServiceId]]} = cloudi_service_api:
                          services_update([{ServiceId,
                                            [{module, ?MODULE},
                                             {options, Options1}]}],
                                          infinity),
    {{ok, RequestPid2},
     _} = cloudi:send_sync(Context3,
                           ServiceName,
                           <<>>),
    Service ! {pid, self()},
    InfoPid2 = receive
        {pid, InfoPidValue2} ->
            InfoPidValue2
    end,
    false = erlang:is_process_alive(RequestPid1),
    true = erlang:is_process_alive(RequestPid2),
    if
        DuoMode =:= true ->
            % ensure dispatcher_pid_options have been applied
            _ = sys:get_state(Dispatcher, infinity),

            true = erlang:is_process_alive(InfoPid1),
            true = (InfoPid1 == InfoPid2);
        DuoMode =:= false ->
            false = erlang:is_process_alive(InfoPid1),
            true = (InfoPid1 /= InfoPid2),
            true = erlang:is_process_alive(InfoPid2)
    end,
    [{max_heap_size,
      MaxHeapSizeDefault},
     {message_queue_data,
      MessageQueueDataDefault},
     {priority,
      PriorityDefault}] = erlang:process_info(Dispatcher,
                                              [max_heap_size,
                                               message_queue_data,
                                               priority]),
    [{max_heap_size,
      MaxHeapSizeDefault},
     {message_queue_data,
      off_heap},
     {priority,
      PriorityDefault}] = erlang:process_info(InfoPid2,
                                              [max_heap_size,
                                               message_queue_data,
                                               priority]),
    [{message_queue_data,
      MessageQueueDataDefault},
     {priority,
      PriorityDefault},
     {max_heap_size,
      MaxHeapSize4}] = erlang:process_info(RequestPid2,
                                           [message_queue_data,
                                            priority,
                                            max_heap_size]),
    #{error_logger := true,
      kill := true,
      size := 1048579} = MaxHeapSize4,
    ok.

t_service_internal_log_1(_Config) ->
    ?LOG_METADATA_SET([{test, t_service_internal_log_1},
                       {pid, self()} | ?LOG_METADATA_GET()]),
    ?LOG_INFO("Logging metadata", []),
    ok.

t_service_internal_idle_1(Config) ->
    [ServiceId] = ?config(service_ids, Config),
    {ok, []} = cloudi_service_api:
               service_subscriptions(ServiceId, infinity),
    {error, not_found} = cloudi_service_api:
                         service_subscriptions(<<0:128>>, infinity),
    ok.

t_service_internal_stop_error_1(_Config) ->
    ok = service_internal_stop(request, error_unique_and_special).

t_service_internal_stop_error_2(_Config) ->
    ok = service_internal_stop(info, error_unique_and_special).

t_service_internal_stop_error_3(_Config) ->
    ok = service_internal_stop(request, error_unique_and_special).

t_service_internal_stop_error_4(_Config) ->
    ok = service_internal_stop(info, error_unique_and_special).

t_service_internal_stop_shutdown_1(_Config) ->
    ok = service_internal_stop(request, shutdown).

t_service_internal_stop_shutdown_2(_Config) ->
    ok = service_internal_stop(info, shutdown).

t_service_internal_stop_shutdown_3(_Config) ->
    ok = service_internal_stop(request, shutdown).

t_service_internal_stop_shutdown_4(_Config) ->
    ok = service_internal_stop(info, shutdown).

t_service_internal_stop_shutdown_5(_Config) ->
    ok = service_internal_stop(request, {shutdown, shutdown_unique_reason}).

t_service_internal_stop_shutdown_6(_Config) ->
    ok = service_internal_stop(info, {shutdown, shutdown_unique_reason}).

t_service_internal_stop_shutdown_7(_Config) ->
    ok = service_internal_stop(request, {shutdown, shutdown_unique_reason}).

t_service_internal_stop_shutdown_8(_Config) ->
    ok = service_internal_stop(info, {shutdown, shutdown_unique_reason}).

t_service_internal_stop_normal_1(_Config) ->
    ok = service_internal_stop(request, normal).

t_service_internal_stop_normal_2(_Config) ->
    ok = service_internal_stop(info, normal).

t_service_internal_stop_normal_3(_Config) ->
    ok = service_internal_stop(request, normal).

t_service_internal_stop_normal_4(_Config) ->
    ok = service_internal_stop(info, normal).

service_internal_stop(StopType, Reason) ->
    Context0 = cloudi:new(),
    ServiceName = ?SERVICE_PREFIX1 ++ ?SERVICE_SUFFIX1,
    {{ok, RequestPid},
     Context1} = cloudi:send_sync(Context0,
                                  ServiceName,
                                  <<>>),
    {{ok, {_, Service}},
     Context2} = cloudi:get_pid(Context1,
                                ServiceName,
                                limit_min),
    Service ! {pid, self()},
    InfoPid = receive
        {pid, InfoPidValue} ->
            InfoPidValue
    end,
    ServiceMonitor = erlang:monitor(process, Service),
    RequestPidMonitor = erlang:monitor(process, RequestPid),
    InfoPidMonitor = erlang:monitor(process, InfoPid),
    if
        StopType =:= request ->
            {{ok, _},
             _Context3} = cloudi:send_async(Context2,
                                            ServiceName,
                                            {stop, Reason}),
            ok;
        StopType =:= info ->
            Service ! {stop, Reason},
            ok
    end,
    receive
        {'DOWN', ServiceMonitor, process, Service, Reason} ->
            ok
    end,
    receive
        {'DOWN', RequestPidMonitor, process, RequestPid, Reason} ->
            ok
    end,
    receive
        {'DOWN', InfoPidMonitor, process, InfoPid, Reason} ->
            ok
    end,
    ok.

t_service_internal_fatal_timeout_1(_Config) ->
    Context0 = cloudi:new([{timeout_async, 499}, % limit_min
                           {timeout_sync, 1000}]),
    ServiceName = ?SERVICE_PREFIX1 ++ ?SERVICE_SUFFIX1,
    {{ok, {_, Service}},
     Context1} = cloudi:get_pid(Context0,
                                ServiceName),
    true = erlang:is_process_alive(Service),
    {{ok, TransId},
     Context2} = cloudi:send_async(Context1,
                                   ServiceName,
                                   ?REQUEST_INFO1, ?REQUEST1,
                                   undefined, undefined),
    receive after 499 + 200 -> ok end,
    {{error, timeout},
     _Context3} = cloudi:recv_async(Context2, TransId),
    false = erlang:is_process_alive(Service),
    ok.

t_service_internal_fatal_timeout_2(_Config) ->
    Context0 = cloudi:new([{timeout_async, 499}, % limit_min
                           {timeout_sync, 1000}]),
    ServiceName = ?SERVICE_PREFIX1 ++ ?SERVICE_SUFFIX1,
    {{ok, {_, Service}},
     Context1} = cloudi:get_pid(Context0,
                                ServiceName),
    true = erlang:is_process_alive(Service),
    {{ok, TransId},
     Context2} = cloudi:send_async(Context1,
                                   ServiceName,
                                   ?REQUEST_INFO1, ?REQUEST1,
                                   undefined, undefined),
    receive after 499 + 200 -> ok end,
    {{ok, ?RESPONSE_INFO1, ?RESPONSE1, TransId},
     _Context3} = cloudi:recv_async(Context2, TransId),
    false = erlang:is_process_alive(Service),
    ok.

t_service_internal_fatal_timeout_3(_Config) ->
    Context0 = cloudi:new([{timeout_async, 499}, % limit_min
                           {timeout_sync, 1000}]),
    ServiceName = ?SERVICE_PREFIX1 ++ ?SERVICE_SUFFIX1,
    {{ok, {_, Service}},
     Context1} = cloudi:get_pid(Context0,
                                ServiceName),
    true = erlang:is_process_alive(Service),
    {{ok, TransId0},
     Context2} = cloudi:send_async(Context1,
                                   ServiceName,
                                   ?REQUEST_INFO1, ?REQUEST1,
                                   undefined, undefined),
    {{ok, ?RESPONSE_INFO1, ?RESPONSE1, TransId0},
     Context3} = cloudi:recv_async(Context2, TransId0),
    {{ok, TransId1},
     Context4} = cloudi:send_async(Context3,
                                   ServiceName,
                                   ?REQUEST_INFO1, ?REQUEST1,
                                   undefined, undefined),
    true = TransId1 /= TransId0,
    {{ok, ?RESPONSE_INFO1, ?RESPONSE1, TransId1},
     _Context5} = cloudi:recv_async(Context4, TransId1),
    receive after 499 + 200 -> ok end,
    true = erlang:is_process_alive(Service),
    ok.

t_cloudi_args_type_1(_Config) ->
    % based on cloudi_service_name:suffix/2 but enforcing checks on whether
    % it is a service name or service name pattern for service initialization
    "." = cloudi_args_type:service_name_suffix("//", "//."),
    "." = cloudi_args_type:service_name_pattern_suffix("//", "//."),
    % Name
    "." = cloudi_args_type:service_name_suffix("/*/", "/./."),
    "." = cloudi_args_type:service_name_suffix("/*/", "/..../."),
    "" = cloudi_args_type:service_name_suffix("*", "."),
    "" = cloudi_args_type:service_name_suffix("*.", ".."),
    "." = cloudi_args_type:service_name_suffix("*.", "..."),
    % Pattern
    "." = cloudi_args_type:service_name_pattern_suffix("/*/", "/*/."),
    {exit, badarg} = ?EXCEPTION(cloudi_args_type:
                                service_name_suffix("/*/", "/*/.")),
    "." = cloudi_args_type:service_name_pattern_suffix("/*", "/*."),
    {exit, badarg} = ?EXCEPTION(cloudi_args_type:
                                service_name_suffix("/*", "/*.")),
    % errors
    {exit, badarg} = ?EXCEPTION(cloudi_args_type:
                                service_name_suffix("/*/", "//.")),
    {exit, badarg} = ?EXCEPTION(cloudi_args_type:
                                service_name_pattern_suffix("/*/", "//.")),
    {exit, badarg} = ?EXCEPTION(cloudi_args_type:
                                service_name_suffix("/*/", "/*")),
    {exit, badarg} = ?EXCEPTION(cloudi_args_type:
                                service_name_pattern_suffix("/*/", "/*")),
    {exit, badarg} = ?EXCEPTION(cloudi_args_type:
                                service_name_suffix("", ".")),
    {exit, badarg} = ?EXCEPTION(cloudi_args_type:
                                service_name_pattern_suffix("", ".")),
    {exit, badarg} = ?EXCEPTION(cloudi_args_type:
                                service_name_suffix(".", "")),
    {exit, badarg} = ?EXCEPTION(cloudi_args_type:
                                service_name_pattern_suffix(".", "")),
    ok.

t_cloudi_service_name_1(_Config) ->
    "." = cloudi_service_name:suffix("//", "//."),
    % Name
    "." = cloudi_service_name:suffix("/*/", "/./."),
    "." = cloudi_service_name:suffix("/*/", "/..../."),
    "" = cloudi_service_name:suffix("*", "."),
    "" = cloudi_service_name:suffix("*.", ".."),
    "." = cloudi_service_name:suffix("*.", "..."),
    % Pattern
    "." = cloudi_service_name:suffix("/*/", "/*/."),
    "." = cloudi_service_name:suffix("/*", "/*."),
    % errors
    {exit, badarg} = ?EXCEPTION(cloudi_service_name:suffix("/*/", "//.")),
    {exit, badarg} = ?EXCEPTION(cloudi_service_name:suffix("/*/", "/*")),
    {exit, badarg} = ?EXCEPTION(cloudi_service_name:suffix("", ".")),
    {exit, badarg} = ?EXCEPTION(cloudi_service_name:suffix(".", "")),
    ok.


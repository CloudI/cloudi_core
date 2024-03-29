%-*-Mode:erlang;coding:utf-8;tab-width:4;c-basic-offset:4;indent-tabs-mode:()-*-
% ex: set ft=erlang fenc=utf-8 sts=4 ts=4 sw=4 et nomod:
%%%
%%%------------------------------------------------------------------------
%%% @doc
%%% ==CloudI Services==
%%% Manage all cloudi_core_i_spawn processes with monitors and their
%%% configuration.  Perform process restarts but do not escalate failures
%%% (only log failures).
%%% @end
%%%
%%% MIT License
%%%
%%% Copyright (c) 2011-2023 Michael Truog <mjtruog at protonmail dot com>
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
%%% @copyright 2011-2023 Michael Truog
%%% @version 2.0.6 {@date} {@time}
%%%------------------------------------------------------------------------

-module(cloudi_core_i_services_monitor).
-author('mjtruog at protonmail dot com').

-behaviour(gen_server).

%% external interface
-export([start_link/0,
         monitor/15,
         process_init_begin/1,
         process_init_end/1,
         process_init_end/2,
         process_terminate_begin/2,
         process_terminate_begin/3,
         process_increase/5,
         process_decrease/5,
         shutdown/2,
         restart/2,
         suspend/2,
         resume/2,
         update/2,
         search/2,
         status/3,
         node_status/1,
         pids/2]).

%% gen_server callbacks
-export([init/1,
         handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-include("cloudi_availability.hrl").
-include("cloudi_logger.hrl").
-include("cloudi_core_i_constants.hrl").
-include("cloudi_core_i_configuration.hrl").

-record(service,
    {
        service_m :: cloudi_core_i_spawn,
        service_f :: start_internal | start_external,
        service_a :: cloudi_core_i_spawn:arguments_execution(),
        process_index :: non_neg_integer(),
        process_count :: pos_integer(),
        thread_count :: pos_integer(),
        scope :: atom(),
        % pids is only accurate (in this record) on the pid lookup (find2)
        % due to the overwrite of #service{} for the key1 ServiceId value
        pids :: list(pid()),
        os_pid :: undefined | pos_integer(),
        monitor :: undefined | reference(),
        time_start
            :: cloudi_timestamp:native_monotonic(),
        time_restart
            :: undefined | cloudi_timestamp:native_monotonic(),
        time_terminate = undefined
            :: undefined | cloudi_timestamp:native_monotonic(),
        restart_count_total :: non_neg_integer(),
        restart_count = 0 :: non_neg_integer(),
        restart_times = [] :: list(cloudi_timestamp:seconds_monotonic()),
        timeout_term :: cloudi_service_api:timeout_terminate_milliseconds(),
        restart_all :: boolean(),
        restart_delay :: tuple() | false,
        critical :: boolean(),
        % from the supervisor behavior documentation:
        % If more than MaxR restarts occur within MaxT seconds,
        % the supervisor terminates all child processes...
        max_r :: non_neg_integer(),
        max_t :: non_neg_integer()
    }).

-record(pids_change_input,
    {
        terminated = false :: boolean(),
        ignore :: boolean(),
        period :: pos_integer(),
        changes :: list({Direction :: increase | decrease,
                         RateCurrent :: number(),
                         RateLimit :: number(),
                         ProcessCountLimit :: number()})
    }).

-record(pids_change,
    {
        process_count :: pos_integer(),
        count_increase = 0 :: non_neg_integer(),
        count_decrease = 0 :: non_neg_integer(),
        increase = 0 :: non_neg_integer(),
        decrease = 0 :: non_neg_integer(),
        rate = 0.0 :: float()
    }).

-record(state,
    {
        services = key2value:new(maps)
            :: key2value:
               key2value(cloudi_service_api:service_id(),
                                  pid(), #service{}),
        failed = 0 % number of services that had MaxR restarts
            :: non_neg_integer(),
        durations_update = cloudi_availability:durations_new()
            :: cloudi_availability:durations(cloudi_service_api:service_id()),
        durations_suspend = cloudi_availability:durations_new()
            :: cloudi_availability:durations(cloudi_service_api:service_id()),
        suspended = sets:new()
            :: sets:set(cloudi_service_api:service_id()),
        durations_restart = cloudi_availability:durations_new()
            :: cloudi_availability:durations(cloudi_service_api:service_id()),
        changes = #{}
            :: #{cloudi_service_api:service_id() :=
                 list({increase | decrease, number(), number(), number()})}
    }).

-record(cloudi_service_init_end,
    {
        pid :: pid(),
        os_pid :: undefined | pos_integer(),
        time_initialized :: cloudi_timestamp:native_monotonic()
    }).

-record(restart_stage2,
    {
        time_terminate :: cloudi_timestamp:native_monotonic(),
        service_id :: cloudi_service_api:service_id(),
        service :: #service{}
    }).

-record(restart_stage3,
    {
        pid :: undefined | pid(),
        time_terminate :: cloudi_timestamp:native_monotonic(),
        service_id :: cloudi_service_api:service_id(),
        service :: #service{}
    }).

-record(cloudi_service_terminate_begin,
    {
        pid :: pid(),
        os_pid :: undefined | pos_integer(),
        reason :: any(),
        time_terminate :: cloudi_timestamp:native_monotonic()
    }).

-record(cloudi_service_terminate_end,
    {
        pid :: undefined | pid(),
        reason :: any(),
        service_id :: cloudi_service_api:service_id(),
        service :: #service{}
    }).

%%%------------------------------------------------------------------------
%%% External interface functions
%%%------------------------------------------------------------------------

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-spec monitor(M :: cloudi_core_i_spawn,
              F :: start_internal | start_external,
              A :: list(),
              ProcessIndex :: non_neg_integer(),
              ProcessCount :: pos_integer(),
              ThreadCount :: pos_integer(),
              Scope :: atom(),
              TimeoutTerm :: cloudi_service_api:
                             timeout_terminate_value_milliseconds(),
              RestartAll :: boolean(),
              RestartDelay :: tuple() | false,
              Critical :: boolean(),
              MaxR :: non_neg_integer(),
              MaxT :: non_neg_integer(),
              ServiceId :: uuid:uuid(),
              Timeout :: infinity | pos_integer()) ->
    {ok, list(pid())} |
    {error, any()}.

monitor(M, F, A, ProcessIndex, ProcessCount, ThreadCount, Scope,
        TimeoutTerm, RestartAll, RestartDelay,
        Critical, MaxR, MaxT, ServiceId, Timeout)
    when is_atom(M), is_atom(F), is_list(A),
         is_integer(ProcessIndex), ProcessIndex >= 0,
         is_integer(ProcessCount), ProcessCount > 0,
         is_integer(ThreadCount), ThreadCount > 0, is_atom(Scope),
         is_integer(TimeoutTerm),
         TimeoutTerm >= ?TIMEOUT_TERMINATE_MIN,
         TimeoutTerm =< ?TIMEOUT_TERMINATE_MAX,
         is_boolean(RestartAll),
         is_boolean(Critical),
         is_integer(MaxR), MaxR >= 0, is_integer(MaxT), MaxT >= 0,
         is_binary(ServiceId), byte_size(ServiceId) == 16 ->
    ?CATCH_EXIT(gen_server:call(?MODULE,
                                {monitor, M, F, A,
                                 ProcessIndex, ProcessCount, ThreadCount,
                                 Scope, TimeoutTerm, RestartAll, RestartDelay,
                                 Critical, MaxR, MaxT, ServiceId},
                                Timeout)).

-spec process_init_begin(Pids :: list(pid() | nonempty_list(pid()))) ->
    ok.

process_init_begin([]) ->
    ok;
process_init_begin([[_ | _] = PidsService | Pids]) ->
    ok = process_init_begin(PidsService),
    process_init_begin(Pids);
process_init_begin([Pid | Pids])
    when is_pid(Pid) ->
    Pid ! cloudi_service_init_begin,
    process_init_begin(Pids).

-spec process_init_end(Pid :: pid()) ->
    ok.

process_init_end(Pid) ->
    process_init_end(Pid, undefined).

-spec process_init_end(Pid :: pid(),
                       OSPid :: undefined | pos_integer()) ->
    ok.

process_init_end(Pid, OSPid)
    when is_pid(Pid) ->
    TimeInitialized = cloudi_timestamp:native_monotonic(),
    ?MODULE ! #cloudi_service_init_end{pid = Pid,
                                       os_pid = OSPid,
                                       time_initialized = TimeInitialized},
    ok.

-spec process_terminate_begin(Pid :: pid(),
                              Reason :: any()) ->
    ok.

process_terminate_begin(Pid, Reason) ->
    process_terminate_begin(Pid, undefined, Reason).

-spec process_terminate_begin(Pid :: pid(),
                              OSPid :: undefined | pos_integer(),
                              Reason :: any()) ->
    ok.

process_terminate_begin(Pid, OSPid, Reason)
    when is_pid(Pid) ->
    TimeTerminate = cloudi_timestamp:native_monotonic(),
    ?MODULE ! #cloudi_service_terminate_begin{pid = Pid,
                                              os_pid = OSPid,
                                              reason = Reason,
                                              time_terminate = TimeTerminate},
    ok.

process_increase(Pid, Period, RateCurrent, RateMax, ProcessCountMax)
    when is_pid(Pid), is_integer(Period), is_number(RateCurrent),
         is_number(RateMax), is_number(ProcessCountMax) ->
    ?MODULE ! {increase, Pid, Period, RateCurrent, RateMax, ProcessCountMax},
    ok.

process_decrease(Pid, Period, RateCurrent, RateMin, ProcessCountMin)
    when is_pid(Pid), is_integer(Period), is_number(RateCurrent),
         is_number(RateMin), is_number(ProcessCountMin) ->
    ?MODULE ! {decrease, Pid, Period, RateCurrent, RateMin, ProcessCountMin},
    ok.

shutdown(ServiceId, Timeout)
    when is_binary(ServiceId), byte_size(ServiceId) == 16 ->
    ?CATCH_EXIT(gen_server:call(?MODULE,
                                {shutdown, ServiceId},
                                Timeout)).

restart(ServiceId, Timeout)
    when is_binary(ServiceId), byte_size(ServiceId) == 16 ->
    ?CATCH_EXIT(gen_server:call(?MODULE,
                                {restart, ServiceId},
                                Timeout)).

suspend(ServiceId, Timeout)
    when is_binary(ServiceId), byte_size(ServiceId) == 16 ->
    ?CATCH_EXIT(gen_server:call(?MODULE,
                                {suspend, ServiceId},
                                Timeout)).

resume(ServiceId, Timeout)
    when is_binary(ServiceId), byte_size(ServiceId) == 16 ->
    ?CATCH_EXIT(gen_server:call(?MODULE,
                                {resume, ServiceId},
                                Timeout)).

update(UpdatePlan, Timeout) ->
    ?CATCH_EXIT(gen_server:call(?MODULE,
                                {update, UpdatePlan},
                                Timeout)).

search([_ | _] = PidList, Timeout) ->
    ?CATCH_EXIT(gen_server:call(?MODULE,
                                {search, PidList},
                                Timeout)).

status([_ | _] = ServiceIdList, Required, Timeout) ->
    ?CATCH_EXIT(gen_server:call(?MODULE,
                                {status, ServiceIdList, Required},
                                Timeout)).

node_status(Timeout) ->
    ?CATCH_EXIT(gen_server:call(?MODULE,
                                node_status,
                                Timeout)).

pids(ServiceId, Timeout)
    when is_binary(ServiceId), byte_size(ServiceId) == 16 ->
    ?CATCH_EXIT(gen_server:call(?MODULE,
                                {pids, ServiceId},
                                Timeout)).

%%%------------------------------------------------------------------------
%%% Callback functions from gen_server
%%%------------------------------------------------------------------------

init([]) ->
    {ok, #state{}}.

handle_call({monitor, M, F, A, ProcessIndex, ProcessCount, ThreadCount,
             Scope, TimeoutTerm, RestartAll, RestartDelay,
             Critical, MaxR, MaxT, ServiceId}, _,
            #state{services = Services} = State) ->
    TimeStart = cloudi_timestamp:native_monotonic(),
    TimeRestart = undefined,
    Restarts = 0,
    case erlang:apply(M, F, [ProcessIndex, ProcessCount,
                             TimeStart, TimeRestart,
                             Restarts | A]) of
        {ok, Pid} when is_pid(Pid) ->
            Pids = [Pid],
            ServicesNew = new_service_processes(false, M, F, A,
                                                ProcessIndex, ProcessCount,
                                                ThreadCount, Scope, Pids,
                                                TimeStart, TimeRestart,
                                                Restarts, TimeoutTerm,
                                                RestartAll, RestartDelay,
                                                Critical, MaxR, MaxT,
                                                ServiceId, Services),
            {reply, {ok, Pids}, State#state{services = ServicesNew}};
        {ok, [Pid | _] = Pids} = Success when is_pid(Pid) ->
            ServicesNew = new_service_processes(false, M, F, A,
                                                ProcessIndex, ProcessCount,
                                                ThreadCount, Scope, Pids,
                                                TimeStart, TimeRestart,
                                                Restarts, TimeoutTerm,
                                                RestartAll, RestartDelay,
                                                Critical, MaxR, MaxT,
                                                ServiceId, Services),
            {reply, Success, State#state{services = ServicesNew}};
        {error, _} = Error ->
            {reply, Error, State}
    end;

handle_call({shutdown, ServiceId}, _,
            #state{services = Services} = State) ->
    case key2value:find1(ServiceId, Services) of
        {ok, {Pids, #service{} = Service}} ->
            StateNew = terminate_service(true, Pids, undefined,
                                         Service, ServiceId, undefined, State),
            {reply, {ok, Pids},
             terminated_service(false, ServiceId, StateNew)};
        error ->
            {reply, {error, not_found}, State}
    end;

handle_call({restart, ServiceId}, _,
            #state{services = Services} = State) ->
    case key2value:find1(ServiceId, Services) of
        {ok, {Pids, _}} ->
            {reply, restart_pids(Pids), State};
        error ->
            {reply, {error, not_found}, State}
    end;

handle_call({suspend, ServiceId}, _,
            #state{services = Services,
                   suspended = Suspended} = State) ->
    case key2value:find1(ServiceId, Services) of
        {ok, {Pids, _}} ->
            StateNew = case suspend_pids(Pids) of
                ok ->
                    SuspendedNew = sets:add_element(ServiceId, Suspended),
                    State#state{suspended = SuspendedNew};
                {error, already_suspended} ->
                    State
            end,
            {reply, ok, StateNew};
        error ->
            {reply, {error, not_found}, State}
    end;

handle_call({resume, ServiceId}, _,
            #state{services = Services,
                   durations_update = DurationsUpdate,
                   durations_suspend = DurationsSuspend,
                   suspended = Suspended} = State) ->
    case key2value:find1(ServiceId, Services) of
        {ok, {Pids, _}} ->
            StateNew = case resume_pids(Pids, DurationsSuspend,
                                        DurationsUpdate, ServiceId) of
                {ok, DurationsSuspendNew} ->
                    SuspendedNew = sets:del_element(ServiceId, Suspended),
                    State#state{durations_suspend = DurationsSuspendNew,
                                suspended = SuspendedNew};
                {error, already_resumed} ->
                    State
            end,
            {reply, ok, StateNew};
        error ->
            {reply, {error, not_found}, State}
    end;

handle_call({update,
             #config_service_update{
                 uuids = ServiceIdList} = UpdatePlan}, _,
            #state{services = Services,
                   durations_update = Durations} = State) ->
    case service_ids_pids(ServiceIdList, Services) of
        {ok, PidList0} ->
            T0 = cloudi_timestamp:native_monotonic(),
            {Reply, StateNew} = case update_start(PidList0, UpdatePlan) of
                {[], PidListN} ->
                    Results0 = update_before(UpdatePlan),
                    ResultsN = update_now(PidListN, Results0, true),
                    {ResultsSuccess,
                     ResultsError} = update_results(ResultsN),
                    UpdateSuccess = (ResultsError == []),
                    ServicesNew = update_after(UpdateSuccess,
                                               PidListN, ResultsSuccess,
                                               UpdatePlan, Services),
                    if
                        UpdateSuccess =:= true ->
                            {ok, State#state{services = ServicesNew}};
                        UpdateSuccess =:= false ->
                            {{error, ResultsError}, State}
                    end;
                {Results0, PidListN} ->
                    ResultsN = update_now(PidListN, Results0, false),
                    {[], ResultsError} = update_results(ResultsN),
                    {{error, ResultsError}, State}
            end,
            T1 = cloudi_timestamp:native_monotonic(),
            DurationsNew = cloudi_availability:
                           durations_store(ServiceIdList, {T0, T1}, Durations),
            {reply, Reply, StateNew#state{durations_update = DurationsNew}};
        {error, Reason} ->
            {reply, {aborted, [Reason]}, State}
    end;

handle_call({search, PidList}, _,
            #state{services = Services} = State) ->
    ServiceIdList = lists:foldl(fun(Pid, L) ->
        case key2value:find2(Pid, Services) of
            {ok, {[ServiceId], _}} ->
                lists:umerge(L, [ServiceId]);
            error ->
                L
        end
    end, [], PidList),
    {reply, {ok, ServiceIdList}, State};

handle_call({status, ServiceIdList, Required}, _,
            #state{services = Services,
                   durations_update = DurationsUpdate,
                   durations_suspend = DurationsSuspend,
                   suspended = Suspended,
                   durations_restart = DurationsRestart} = State) ->
    TimeNow = cloudi_timestamp:native_monotonic(),
    Reply = status_service_ids(ServiceIdList, Required, TimeNow,
                               DurationsUpdate, DurationsSuspend, Suspended,
                               DurationsRestart, Services),
    {reply, Reply, State};

handle_call(node_status, _,
            #state{services = Services,
                   failed = Failed,
                   durations_restart = DurationsRestart} = State) ->
    Running = key2value:size1(Services),
    Restarted = cloudi_availability:durations_size(DurationsRestart),
    LocalStatusList = [{services_running, erlang:integer_to_list(Running)},
                       {services_restarted, erlang:integer_to_list(Restarted)},
                       {services_failed, erlang:integer_to_list(Failed)}],
    {reply, {ok, LocalStatusList}, State};

handle_call({pids, ServiceId}, _,
            #state{services = Services} = State) ->
    case key2value:find1(ServiceId, Services) of
        {ok, {PidList, #service{scope = Scope}}} ->
            {reply, {ok, Scope, PidList}, State};
        error ->
            {reply, {error, not_found}, State}
    end;

handle_call(Request, _, State) ->
    {stop, cloudi_string:format("Unknown call \"~w\"", [Request]),
     error, State}.

handle_cast(Request, State) ->
    {stop, cloudi_string:format("Unknown cast \"~w\"", [Request]), State}.

handle_info({'DOWN', _MonitorRef, 'process', Pid, shutdown},
            #state{services = Services} = State) ->
    case key2value:find2(Pid, Services) of
        {ok, {[ServiceId], #service{} = Service}} ->
            ?LOG_INFO_SYNC("Service pid ~p shutdown~n ~p",
                           [Pid, service_id(ServiceId)]),
            {Pids, _} = key2value:fetch1(ServiceId, Services),
            StateNew = terminate_service(false, Pids, undefined,
                                         Service, ServiceId, Pid, State),
            {noreply, terminated_service(true, ServiceId, StateNew)};
        error ->
            % Service pid has already terminated
            {noreply, State}
    end;

handle_info({'DOWN', _MonitorRef, 'process', Pid,
             {shutdown, cloudi_count_process_dynamic_terminate}},
            #state{services = Services} = State) ->
    case key2value:find2(Pid, Services) of
        {ok, {[ServiceId], #service{}}} ->
            ?LOG_INFO("Service pid ~p terminated (count_process_dynamic)~n ~p",
                      [Pid, service_id(ServiceId)]),
            ServicesNew = key2value:erase(ServiceId, Pid, Services),
            {noreply, State#state{services = ServicesNew}};
        error ->
            % Service pid has already terminated
            {noreply, State}
    end;

handle_info({'DOWN', _MonitorRef, 'process', Pid, {shutdown, Reason}},
            #state{services = Services} = State) ->
    case key2value:find2(Pid, Services) of
        {ok, {[ServiceId], #service{} = Service}} ->
            ?LOG_INFO_SYNC("Service pid ~p shutdown (~tp)~n ~p",
                           [Pid, Reason, service_id(ServiceId)]),
            {Pids, _} = key2value:fetch1(ServiceId, Services),
            StateNew = terminate_service(false, Pids, Reason,
                                         Service, ServiceId, Pid, State),
            {noreply, terminated_service(true, ServiceId, StateNew)};
        error ->
            % Service pid has already terminated
            {noreply, State}
    end;

handle_info({'DOWN', _MonitorRef, 'process', Pid, Info},
            #state{services = Services} = State) ->
    case key2value:find2(Pid, Services) of
        {ok, {[ServiceId], #service{} = Service}} ->
            ?LOG_WARN("Service pid ~p error: ~tp~n ~p",
                      [Pid, Info, service_id(ServiceId)]),
            {noreply, restart(Service, ServiceId, Pid, State)};
        error ->
            % Service pid has already terminated
            {noreply, State}
    end;

handle_info(#restart_stage2{time_terminate = TimeTerminate,
                            service_id = ServiceId,
                            service = Service},
            State) ->
    {noreply,
     restart_stage2(Service, ServiceId, TimeTerminate, undefined, State)};

handle_info(#restart_stage3{pid = PidOld,
                            time_terminate = TimeTerminate,
                            service_id = ServiceId,
                            service = Service},
            State) ->
    {noreply,
     restart_stage3(Service, ServiceId, TimeTerminate, PidOld, State)};

handle_info(#cloudi_service_terminate_begin{pid = Pid,
                                            os_pid = OSPid,
                                            reason = Reason,
                                            time_terminate = TimeTerminate},
            #state{services = Services} = State) ->
    case key2value:find2(Pid, Services) of
        {ok, {[ServiceId], #service{os_pid = OSPidOld} = Service}} ->
            OSPidNew = if
                OSPidOld =:= undefined ->
                    OSPid;
                is_integer(OSPidOld) ->
                    OSPidOld
            end,
            ServiceNew = Service#service{os_pid = OSPidNew,
                                         time_terminate = TimeTerminate},
            ok = terminate_end_enforce(TimeTerminate, self(),
                                       Pid, Reason, ServiceId, ServiceNew),
            ServicesNew = key2value:store(ServiceId, Pid,
                                                   ServiceNew, Services),
            {noreply, State#state{services = ServicesNew}};
        error ->
            {noreply, State}
    end;

handle_info(#cloudi_service_terminate_end{pid = Pid,
                                          reason = Reason,
                                          service_id = ServiceId,
                                          service = Service}, State) ->
    ok = terminate_end_enforce_now(Pid, Reason, ServiceId, Service),
    {noreply, State};

handle_info(#cloudi_service_init_end{pid = Pid,
                                     os_pid = OSPid},
            #state{services = Services} = State) ->
    % either a service was initialized for the first time
    % or a service process has initialized due to count_process_dynamic
    % or an external service process was updated with a new OS process
    ok = cloudi_core_i_configurator:service_process_init_end(Pid),
    ServicesNew = os_pid_update(OSPid, Pid, Services),
    {noreply, State#state{services = ServicesNew}};

handle_info({changes, ServiceId}, State) ->
    {noreply, pids_change_check(ServiceId, State)};

handle_info({Direction,
             Pid, Period, RateCurrent,
             RateLimit, ProcessCountLimit},
            #state{services = Services,
                   suspended = Suspended,
                   changes = Changes} = State)
    when (Direction =:= increase);
         (Direction =:= decrease) ->
    case key2value:find2(Pid, Services) of
        {ok, {[ServiceId], _}} ->
            Ignore = sets:is_element(ServiceId, Suspended),
            Entry = {Direction, RateCurrent, RateLimit, ProcessCountLimit},
            ChangeNew = case maps:find(ServiceId, Changes) of
                {ok, #pids_change_input{ignore = IgnoreOld,
                                        changes = ChangeList} = Change} ->
                    Change#pids_change_input{ignore = IgnoreOld orelse Ignore,
                                             changes = [Entry | ChangeList]};
                error ->
                    erlang:send_after(Period * 1000, self(),
                                      {changes, ServiceId}),
                    #pids_change_input{ignore = Ignore,
                                       period = Period,
                                       changes = [Entry]}
            end,
            {noreply, State#state{changes = maps:put(ServiceId,
                                                     ChangeNew,
                                                     Changes)}};
        error ->
            % discard old change
            {noreply, State}
    end;

handle_info({ReplyRef, _}, State) when is_reference(ReplyRef) ->
    % gen_server:call/3 had a timeout exception that was caught but the
    % reply arrived later and must be discarded
    {noreply, State};

handle_info(Request, State) ->
    {stop, cloudi_string:format("Unknown info \"~w\"", [Request]), State}.

terminate(_, _) ->
    ok.

code_change(_, State, _) ->
    {ok, State}.

%%%------------------------------------------------------------------------
%%% Private functions
%%%------------------------------------------------------------------------

os_pid_update(undefined, _, Services) ->
    Services;
os_pid_update(OSPid, Pid, Services) ->
    case key2value:find2(Pid, Services) of
        {ok, {[ServiceId], #service{pids = Pids,
                                    os_pid = OSPidOld} = ServiceOld}} ->
            if
                OSPidOld =:= undefined ->
                    ok;
                is_integer(OSPidOld) ->
                    % after an update creates a new OS process,
                    % ensure SIGKILL is sent to the old OS process after
                    % the termination timeout
                    true = OSPid /= OSPidOld,
                    terminate_end_enforce(undefined, self(),
                                          undefined, undefined, ServiceId,
                                          ServiceOld)
            end,
            lists:foldl(fun(P, D) ->
                {[ServiceId],
                 #service{} = Service} = key2value:fetch2(P, D),
                key2value:store(ServiceId, P,
                                         Service#service{os_pid = OSPid}, D)
            end, Services, Pids);
        error ->
            Services
    end.

initialize_wait(Pids) ->
    % only used for initialization after a restart due to how the error reason
    % is needed by cloudi_core_i_configurator when the service is started for
    % the first time
    MonitorPids = [{erlang:monitor(process, Pid), Pid} || Pid <- Pids],
    ok = process_init_begin(Pids),
    {Time, OSPid} = initialize_wait_pids(MonitorPids, undefined, undefined),
    {Time, OSPid, MonitorPids}.

initialize_wait_pids([], Time, OSPid) ->
    TimeNew = if
        Time =:= undefined ->
            cloudi_timestamp:native_monotonic(); % all initializations failed
        is_integer(Time) ->
            Time
    end,
    {TimeNew, OSPid};
initialize_wait_pids([{MonitorRef, Pid} | MonitorPids], Time, OSPid) ->
    receive
        #cloudi_service_init_end{pid = Pid,
                                 os_pid = OSPidNext,
                                 time_initialized = TimeInitialized} ->
            TimeNew = if
                Time =:= undefined ->
                    TimeInitialized;
                is_integer(Time) ->
                    erlang:max(Time, TimeInitialized)
            end,
            OSPidNew = if
                OSPidNext =:= undefined ->
                    OSPid;
                is_integer(OSPidNext) ->
                    undefined = OSPid,
                    OSPidNext
            end,
            initialize_wait_pids(MonitorPids, TimeNew, OSPidNew);
        {'DOWN', MonitorRef, process, Pid, _} = DOWN ->
            self() ! DOWN,
            initialize_wait_pids(MonitorPids, Time, OSPid)
    end.

restart(#service{time_start = TimeStart,
                 time_restart = TimeRestart,
                 time_terminate = TimeTerminate} = Service,
        ServiceId, PidOld, State) ->
    TimeTerminateNew = if
        TimeTerminate =:= undefined ->
            % process_terminate_begin/2 was not called by PidOld
            % so service initialization did not complete and the
            % termination start time is the process start time
            if
                TimeRestart =:= undefined ->
                    TimeStart;
                is_integer(TimeRestart) ->
                    TimeRestart
            end;
        is_integer(TimeTerminate) ->
            TimeTerminate
    end,
    restart_stage1(Service#service{time_terminate = undefined},
                   ServiceId, TimeTerminateNew, PidOld, State).

restart_stage1(#service{pids = Pids,
                        restart_all = false} = Service,
               ServiceId, TimeTerminate, PidOld,
               #state{services = Services,
                      suspended = Suspended} = State) ->
    case sets:is_element(ServiceId, Suspended) of
        true ->
            {PidsSuspended, _} = key2value:fetch1(ServiceId, Services),
            ok = resume_restart_pids(PidsSuspended, Pids);
        false ->
            ok
    end,
    StateNew = terminate_service(true, Pids, undefined,
                                 Service, ServiceId, PidOld, State),
    restart_stage2(Service#service{pids = [],
                                   monitor = undefined},
                   ServiceId, TimeTerminate, PidOld, StateNew);
restart_stage1(#service{restart_all = true} = Service,
               ServiceId, TimeTerminate, PidOld,
               #state{services = Services} = State) ->
    {Pids, _} = key2value:fetch1(ServiceId, Services),
    StateNew = terminate_service(true, Pids, undefined,
                                 Service, ServiceId, PidOld, State),
    restart_stage2(Service#service{pids = [],
                                   monitor = undefined},
                   ServiceId, TimeTerminate, PidOld, StateNew).

restart_stage2_async(Service, ServiceId, TimeTerminate) ->
    self() ! #restart_stage2{time_terminate = TimeTerminate,
                             service_id = ServiceId,
                             service = Service},
    ok.

restart_stage3_async(Delay, Service, ServiceId, TimeTerminate, PidOld) ->
    erlang:send_after(Delay, self(),
                      #restart_stage3{pid = PidOld,
                                      time_terminate = TimeTerminate,
                                      service_id = ServiceId,
                                      service = Service}),
    ok.

restart_stage2(#service{restart_count = 0,
                        critical = Critical,
                        max_r = 0} = Service,
               ServiceId, _, PidOld, State) ->
    % no restarts allowed
    ok = restart_log_failure_maxr0(PidOld, Critical, service_id(ServiceId)),
    restart_failed(Critical, Service, ServiceId, State);
restart_stage2(#service{restart_count = RestartCount,
                        restart_times = RestartTimes,
                        critical = Critical,
                        max_r = MaxR,
                        max_t = MaxT} = Service,
               ServiceId, TimeTerminate, PidOld, State)
    when MaxR == RestartCount ->
    % last restart? (must check this before a restart_delay occurs)
    SecondsNow = cloudi_timestamp:seconds_monotonic(),
    {RestartCountNew,
     RestartTimesNew} = cloudi_timestamp:
                        seconds_filter_monotonic(RestartTimes,
                                                 SecondsNow,
                                                 MaxT),
    if
        RestartCountNew < RestartCount ->
            restart_stage2(Service#service{
                               restart_count = RestartCountNew,
                               restart_times = RestartTimesNew},
                           ServiceId, TimeTerminate, PidOld, State);
        true ->
            ok = restart_log_failure_maxr(PidOld, Critical, MaxR, MaxT,
                                          service_id(ServiceId)),
            restart_failed(Critical, Service, ServiceId, State)
    end;
restart_stage2(#service{restart_times = RestartTimes,
                        restart_delay = RestartDelay,
                        max_t = MaxT} = Service,
               ServiceId, TimeTerminate, PidOld, State) ->
    case cloudi_core_i_rate_based_configuration:
         restart_delay_value(RestartTimes, MaxT, RestartDelay) of
        false ->
            restart_stage3(Service, ServiceId, TimeTerminate, PidOld, State);
        {RestartCountNew,
         RestartTimesNew,
         0} ->
            restart_stage3(Service#service{restart_count = RestartCountNew,
                                           restart_times = RestartTimesNew},
                           ServiceId, TimeTerminate, PidOld, State);
        {RestartCountNew,
         RestartTimesNew,
         Delay} when Delay > 0 andalso Delay =< ?TIMEOUT_MAX_ERLANG ->
            restart_stage3_async(Delay,
                                 Service#service{
                                     restart_count = RestartCountNew,
                                     restart_times = RestartTimesNew},
                                 ServiceId, TimeTerminate, PidOld),
            State
    end.

restart_stage3(#service{restart_count_total = Restarts,
                        restart_times = RestartTimes,
                        restart_all = RestartAll,
                        max_t = MaxT} = Service,
               ServiceId, TimeTerminate, PidOld, State) ->
    TimeRestart = cloudi_timestamp:native_monotonic(),
    SecondsNow = cloudi_timestamp:convert(TimeRestart, native, second),
    RestartsNew = Restarts + 1,
    {RestartCountNew,
     RestartTimesNew} = cloudi_timestamp:
                        seconds_filter_monotonic([SecondsNow | RestartTimes],
                                                 SecondsNow,
                                                 MaxT),
    ServiceNew =  Service#service{restart_count_total = RestartsNew,
                                  restart_count = RestartCountNew,
                                  restart_times = RestartTimesNew},
    T = SecondsNow - lists:min(RestartTimesNew),
    if
        RestartAll =:= false ->
            restart_stage3_one(T, TimeRestart, ServiceNew,
                               ServiceId, TimeTerminate, PidOld, State);
        RestartAll =:= true ->
            restart_stage3_all(0, [], T, TimeRestart, ServiceNew,
                               ServiceId, TimeTerminate, PidOld, State)
    end.

restart_stage3_one(T, TimeRestart,
                   #service{service_m = M,
                            service_f = F,
                            service_a = A,
                            process_index = ProcessIndex,
                            process_count = ProcessCount,
                            time_start = TimeStart,
                            restart_count_total = Restarts,
                            restart_count = RestartCount} = Service,
                   ServiceId, TimeTerminate, PidOld, State) ->
    case erlang:apply(M, F, [ProcessIndex, ProcessCount,
                             TimeStart, TimeRestart, Restarts | A]) of
        {ok, Pid} when is_pid(Pid) ->
            ok = restart_log_success_one(PidOld, RestartCount, T,
                                         Pid, service_id(ServiceId)),
            restart_success_one(Service, ServiceId, TimeTerminate,
                                [Pid], State);
        {ok, [Pid | _] = Pids} when is_pid(Pid) ->
            ok = restart_log_success_one(PidOld, RestartCount, T,
                                         Pids, service_id(ServiceId)),
            restart_success_one(Service, ServiceId, TimeTerminate,
                                Pids, State);
        {error, _} = Error ->
            ok = restart_log_failure(Error, service_id(ServiceId)),
            restart_stage2_async(Service#service{time_restart = TimeRestart},
                                 ServiceId, TimeTerminate),
            State
    end.

restart_stage3_all(ProcessCount, ProcessRestartsOld, T, _,
                   #service{process_count = ProcessCount,
                            restart_count = RestartCount} = Service,
                   ServiceId, TimeTerminate, PidOld, State) ->
    ProcessRestarts = lists:reverse(ProcessRestartsOld),
    ok = restart_log_success_all(PidOld, RestartCount, T,
                                 ProcessRestarts, service_id(ServiceId)),
    restart_success_all(0, lists:reverse(ProcessRestarts), TimeTerminate,
                        Service, ServiceId, TimeTerminate, State);
restart_stage3_all(ProcessIndex, ProcessRestarts, T, TimeRestart,
                   #service{service_m = M,
                            service_f = F,
                            service_a = A,
                            process_count = ProcessCount,
                            time_start = TimeStart,
                            restart_count_total = Restarts} = Service,
                   ServiceId, TimeTerminate, PidOld, State) ->
    case erlang:apply(M, F, [ProcessIndex, ProcessCount,
                             TimeStart, TimeRestart, Restarts | A]) of
        {ok, Pid} when is_pid(Pid) ->
            restart_stage3_all(ProcessIndex + 1, [Pid | ProcessRestarts],
                               T, TimeRestart, Service,
                               ServiceId, TimeTerminate, PidOld, State);
        {ok, [Pid | _] = Pids} when is_pid(Pid) ->
            restart_stage3_all(ProcessIndex + 1, [Pids | ProcessRestarts],
                               T, TimeRestart, Service,
                               ServiceId, TimeTerminate, PidOld, State);
        {error, _} = Error ->
            ok = restart_log_failure(Error, service_id(ServiceId)),
            Pids = lists:flatten(ProcessRestarts),
            StateNew = terminate_service(true, Pids, undefined,
                                         Service, ServiceId, undefined, State),
            restart_stage2_async(Service#service{time_restart = TimeRestart},
                                 ServiceId, TimeTerminate),
            StateNew
    end.

restart_success_one(Service, ServiceId, TimeTerminate, Pids,
                    #state{services = Services,
                           durations_restart = Durations} = State) ->
    {TimeInitialized, OSPid,
     MonitorPids} = initialize_wait(Pids),
    #service{restart_count_total = Restarts,
             restart_count = RestartCount,
             restart_times = RestartTimes} = Service,
    ServicesNext = key2value:map1(ServiceId, fun(ServiceOld) ->
        ServiceOld#service{restart_count_total = Restarts,
                           restart_count = RestartCount,
                           restart_times = RestartTimes}
    end, Services),
    ServicesNew = lists:foldl(fun({MonitorRef, P}, D) ->
        key2value:store(ServiceId, P,
            Service#service{pids = Pids,
                            os_pid = OSPid,
                            monitor = MonitorRef,
                            time_restart = TimeInitialized}, D)
    end, ServicesNext, MonitorPids),
    DurationsNew = cloudi_availability:
                   durations_store([ServiceId],
                                   {TimeTerminate, TimeInitialized},
                                   Durations),
    State#state{services = ServicesNew,
                durations_restart = DurationsNew}.

restart_success_all(_, [], TimeInitialized, _, ServiceId, TimeTerminate,
                    #state{durations_restart = Durations} = State) ->
    DurationsNew = cloudi_availability:
                   durations_store([ServiceId],
                                   {TimeTerminate, TimeInitialized},
                                   Durations),
    State#state{durations_restart = DurationsNew};
restart_success_all(ProcessIndex,
                    [ProcessRestart | ProcessRestarts], TimeInitialized,
                    Service, ServiceId, TimeTerminate,
                    #state{services = Services} = State) ->
    Pids = if
        is_pid(ProcessRestart) ->
            [ProcessRestart];
        is_list(ProcessRestart) ->
            ProcessRestart
    end,
    {TimeInitializedProcess, OSPid,
     MonitorPids} = initialize_wait(Pids),
    ServicesNew = lists:foldl(fun({MonitorRef, P}, D) ->
        key2value:store(ServiceId, P,
            Service#service{process_index = ProcessIndex,
                            pids = Pids,
                            os_pid = OSPid,
                            monitor = MonitorRef,
                            time_restart = TimeInitializedProcess}, D)
    end, Services, MonitorPids),
    TimeInitializedNew = erlang:max(TimeInitialized, TimeInitializedProcess),
    restart_success_all(ProcessIndex + 1,
                        ProcessRestarts, TimeInitializedNew,
                        Service, ServiceId, TimeTerminate,
                        State#state{services = ServicesNew}).

restart_failed(Critical, Service, ServiceId,
               #state{services = Services,
                      failed = Failed} = State) ->
    StateNext = case key2value:find1(ServiceId, Services) of
        {ok, {Pids, _}} ->
            % if other processes were started by this service instance
            % they will get a shutdown here
            terminate_service(false, Pids, undefined,
                              Service, ServiceId, undefined, State);
        error ->
            State
    end,
    StateNew = terminated_service(true, ServiceId,
                                  StateNext#state{failed = Failed + 1}),
    if
        Critical =:= true ->
            ok = init:stop(1);
        Critical =:= false ->
            ok
    end,
    StateNew.

restart_log_success_one(PidOld, RestartCount, T,
                        Pid, ServiceIdStr)
    when is_pid(Pid) ->
    if
        RestartCount == 1 ->
            if
                PidOld =:= undefined ->
                    ?LOG_WARN_SYNC("successful restart (R = 1)~n"
                                   "    ~p~n"
                                   " ~p",
                                   [Pid, ServiceIdStr]);
                is_pid(PidOld) ->
                    ?LOG_WARN_SYNC("successful restart (R = 1)~n"
                                   "    (~p is now ~p)~n"
                                   " ~p",
                                   [PidOld, Pid, ServiceIdStr])
            end;
        true ->
            if
                PidOld =:= undefined ->
                    ?LOG_WARN_SYNC("successful restart "
                                   "(R = ~p, T = ~p elapsed seconds)~n"
                                   "    ~p~n"
                                   " ~p",
                                   [RestartCount, T,
                                    Pid, ServiceIdStr]);
                is_pid(PidOld) ->
                    ?LOG_WARN_SYNC("successful restart "
                                   "(R = ~p, T = ~p elapsed seconds)~n"
                                   "    (~p is now ~p)~n"
                                   " ~p",
                                   [RestartCount, T, PidOld,
                                    Pid, ServiceIdStr])
            end
    end;
restart_log_success_one(PidOld, RestartCount, T,
                        [_ | _] = Pids, ServiceIdStr) ->
    if
        RestartCount == 1 ->
            if
                PidOld =:= undefined ->
                    ?LOG_WARN_SYNC("successful restart (R = 1)~n"
                                   "    ~p~n"
                                   " ~p",
                                   [Pids, ServiceIdStr]);
                is_pid(PidOld) ->
                    ?LOG_WARN_SYNC("successful restart (R = 1)~n"
                                   "    (~p is now one of~n"
                                   "     ~p)~n"
                                   " ~p",
                                   [PidOld, Pids, ServiceIdStr])
            end;
        true ->
            if
                PidOld =:= undefined ->
                    ?LOG_WARN_SYNC("successful restart "
                                   "(R = ~p, T = ~p elapsed seconds)~n"
                                   "    ~p~n"
                                   " ~p",
                                   [RestartCount, T,
                                    Pids, ServiceIdStr]);
                is_pid(PidOld) ->
                    ?LOG_WARN_SYNC("successful restart "
                                   "(R = ~p, T = ~p elapsed seconds)~n"
                                   "    (~p is now one of~n"
                                   "     ~p)~n"
                                   " ~p",
                                   [RestartCount, T, PidOld,
                                    Pids, ServiceIdStr])
            end
    end.

restart_log_success_all(PidOld, RestartCount, T,
                        Pids, ServiceIdStr) ->
    if
        RestartCount == 1 ->
            if
                PidOld =:= undefined ->
                    ?LOG_WARN_SYNC("successful restart_all (R = 1)~n"
                                   "    ~p~n"
                                   " ~p",
                                   [Pids, ServiceIdStr]);
                is_pid(PidOld) ->
                    ?LOG_WARN_SYNC("successful restart_all (R = 1)~n"
                                   "    (~p is now one of~n"
                                   "     ~p)~n"
                                   " ~p",
                                   [PidOld, Pids, ServiceIdStr])
            end;
        true ->
            if
                PidOld =:= undefined ->
                    ?LOG_WARN_SYNC("successful restart_all "
                                   "(R = ~p, T = ~p elapsed seconds)~n"
                                   "    ~p~n"
                                   " ~p",
                                   [RestartCount, T,
                                    Pids, ServiceIdStr]);
                is_pid(PidOld) ->
                    ?LOG_WARN_SYNC("successful restart_all "
                                   "(R = ~p, T = ~p elapsed seconds)~n"
                                   "    (~p is now one of~n"
                                   "     ~p)~n"
                                   " ~p",
                                   [RestartCount, T, PidOld,
                                    Pids, ServiceIdStr])
            end
    end.

restart_log_failure_critical(true) ->
    {fatal, " (critical service failure shutdown!)"};
restart_log_failure_critical(false) ->
    {warn, ""}.

restart_log_failure_maxr0(undefined, Critical, ServiceIdStr) ->
    {Level, CriticalStr} = restart_log_failure_critical(Critical),
    ?LOG_SYNC(Level,
              "max restarts (MaxR = 0)~n"
              " ~p~s",
              [ServiceIdStr, CriticalStr]);
restart_log_failure_maxr0(PidOld, Critical, ServiceIdStr) ->
    {Level, CriticalStr} = restart_log_failure_critical(Critical),
    ?LOG_SYNC(Level,
              "max restarts (MaxR = 0) ~p~n"
              " ~p~s",
              [PidOld, ServiceIdStr, CriticalStr]).

restart_log_failure_maxr(undefined, Critical, MaxR, MaxT, ServiceIdStr) ->
    {Level, CriticalStr} = restart_log_failure_critical(Critical),
    ?LOG_SYNC(Level,
              "max restarts (MaxR = ~p, MaxT = ~p seconds)~n"
              " ~p~s",
              [MaxR, MaxT, ServiceIdStr, CriticalStr]);
restart_log_failure_maxr(PidOld, Critical, MaxR, MaxT, ServiceIdStr) ->
    {Level, CriticalStr} = restart_log_failure_critical(Critical),
    ?LOG_SYNC(Level,
              "max restarts (MaxR = ~p, MaxT = ~p seconds) ~p~n"
              " ~p~s",
              [MaxR, MaxT, PidOld, ServiceIdStr, CriticalStr]).

restart_log_failure({error, _} = Error, ServiceIdStr) ->
    ?LOG_ERROR_SYNC("failed ~tp restart~n"
                    " ~p",
                    [Error, ServiceIdStr]).

terminate_service(Block, Pids, Reason, Service, ServiceId, PidOld,
                  #state{services = Services,
                         durations_update = DurationsUpdate,
                         durations_suspend = DurationsSuspend,
                         suspended = Suspended,
                         changes = Changes} = State) ->
    ShutdownExit = if
        Reason =:= undefined ->
            shutdown;
        true ->
            {shutdown, Reason}
    end,
    ServicesNew = terminate_service_pids(Pids, Services, self(), ShutdownExit,
                                         Service, ServiceId, PidOld),
    if
        Block =:= true ->
            ok = terminate_service_wait(Pids, PidOld);
        Block =:= false ->
            ok
    end,
    % clear all data and messages related to the old processes
    DurationsUpdateNew = cloudi_availability:
                         durations_erase(ServiceId, DurationsUpdate),
    DurationsSuspendNew = cloudi_availability:
                          durations_erase(ServiceId, DurationsSuspend),
    SuspendedNew = sets:del_element(ServiceId, Suspended),
    ChangesNew = case maps:find(ServiceId, Changes) of
        {ok, #pids_change_input{} = Change} ->
            maps:put(ServiceId,
                     Change#pids_change_input{changes = []}, Changes);
        error ->
            Changes
    end,
    ok = terminate_service_clear(Pids),
    State#state{services = ServicesNew,
                durations_update = DurationsUpdateNew,
                durations_suspend = DurationsSuspendNew,
                suspended = SuspendedNew,
                changes = ChangesNew}.

terminate_service_pids([], Services, _, _, _, _, _) ->
    Services;
terminate_service_pids([PidOld | Pids], Services, Self, ShutdownExit,
                       Service, ServiceId, PidOld) ->
    ServicesNew = key2value:erase(ServiceId, PidOld, Services),
    terminate_service_pids(Pids, ServicesNew, Self, ShutdownExit,
                           Service, ServiceId, PidOld);
terminate_service_pids([Pid | Pids], Services, Self, ShutdownExit,
                       Service, ServiceId, PidOld) ->
    erlang:exit(Pid, ShutdownExit),
    ok = terminate_end_enforce(undefined, Self, Pid, ShutdownExit,
                               ServiceId, Service),
    ServicesNew = key2value:erase(ServiceId, Pid, Services),
    terminate_service_pids(Pids, ServicesNew, Self, ShutdownExit,
                           Service, ServiceId, PidOld).

terminate_service_wait([], _) ->
    ok;
terminate_service_wait([PidOld | Pids], PidOld) ->
    terminate_service_wait(Pids, PidOld);
terminate_service_wait([Pid | Pids], PidOld) ->
    ok = suspended_pid_unblock(Pid),
    % ensure each service process has executed its termination source code
    % (or has died due to a termination timeout)
    receive
        {'DOWN', _MonitorRef, 'process', Pid, _} ->
            terminate_service_wait(Pids, PidOld);
        #cloudi_service_terminate_end{pid = Pid,
                                      reason = ShutdownExit,
                                      service_id = ServiceId,
                                      service = Service} ->
            ok = terminate_end_enforce_now(Pid, ShutdownExit,
                                           ServiceId, Service),
            receive
                {'DOWN', _MonitorRef, 'process', Pid, _} ->
                    terminate_service_wait(Pids, PidOld)
            end
    end.

-ifdef(SEND_REMOTE_MAY_SUSPEND).
suspended_pid_unblock(Pid) ->
    case erlang:process_info(Pid, [trap_exit, status]) of
        [{trap_exit, true},
         {status, suspended}] ->
            % If Pid sent too many distributed Erlang messages
            % (based on dist_buf_busy_limit) it can be in a suspended state
            % that prevents it from receiving a non-kill exit signal.
            % Unable to wait for termination to occur in this situation
            % because the suspended state can last for a long period of time.
            true = erlang:exit(Pid, kill),
            ok;
        _ ->
            ok
    end.
-endif.

terminate_service_clear([]) ->
    ok;
terminate_service_clear([Pid | Pids] = L) ->
    receive
        {'cloudi_service_update', Pid} ->
            terminate_service_clear(L);
        {'cloudi_service_update_now', Pid, _} ->
            terminate_service_clear(L);
        {'cloudi_service_suspended', Pid, _} ->
            terminate_service_clear(L);
        {increase, Pid, _, _, _, _} ->
            terminate_service_clear(L);
        {decrease, Pid, _, _, _, _} ->
            terminate_service_clear(L)
    after
        0 ->
            terminate_service_clear(Pids)
    end.

terminate_end_enforce(TimeTerminate, Self,
                      Pid, Reason, ServiceId,
                      #service{os_pid = OSPid,
                               timeout_term = TimeoutTerm} = Service) ->
    TimeoutTermNew = if
        TimeTerminate =:= undefined ->
            TimeoutTerm;
        is_integer(TimeTerminate) ->
            TimeoutTerm -
            cloudi_timestamp:convert(cloudi_timestamp:native_monotonic() -
                                     TimeTerminate, native, millisecond)
    end,
    Timeout = if
        OSPid =:= undefined ->
            TimeoutTermNew;
        is_integer(OSPid) ->
            ?TIMEOUT_TERMINATE_EXTERNAL(TimeoutTermNew)
    end,
    if
        Timeout > 0 ->
            erlang:send_after(Timeout, Self,
                              #cloudi_service_terminate_end{
                                  pid = Pid,
                                  reason = Reason,
                                  service_id = ServiceId,
                                  service = Service}),
            ok;
        true ->
            terminate_end_enforce_now(Pid, Reason, ServiceId, Service)
    end.

terminate_end_enforce_now(Pid, Reason, ServiceId,
                          #service{os_pid = OSPid,
                                   timeout_term = TimeoutTerm}) ->
    if
        OSPid =:= undefined ->
            ok;
        is_integer(OSPid) ->
            % SIGKILL exit automatically logged if it occurs
            _ = cloudi_os_process:kill(sigkill, OSPid),
            ok
    end,
    case is_pid(Pid) andalso erlang:is_process_alive(Pid) of
        true ->
            ?LOG_ERROR_SYNC("Service pid ~p brutal_kill (~tp)~n"
                            " ~p after ~p ms (MaxT/MaxR)",
                            [Pid, Reason, service_id(ServiceId), TimeoutTerm]),
            erlang:exit(Pid, kill);
        false ->
            ok
    end,
    ok.

% the service is completely terminated and will not restart
terminated_service(ConfigurationRemove, ServiceId,
                   #state{durations_restart = Durations,
                          changes = Changes} = State) ->
    ChangesNew = case maps:find(ServiceId, Changes) of
        {ok, #pids_change_input{} = Change} ->
            % changes timer needs to handle removal
            maps:put(ServiceId,
                     Change#pids_change_input{terminated = true}, Changes);
        error ->
            Changes
    end,
    if
        ConfigurationRemove =:= true ->
            ok = cloudi_core_i_configurator:service_terminated(ServiceId);
        ConfigurationRemove =:= false ->
            ok
    end,
    State#state{durations_restart = cloudi_availability:
                                    durations_erase(ServiceId, Durations),
                changes = ChangesNew}.

pids_change_check(ServiceId,
                  #state{suspended = Suspended,
                         changes = Changes} = State) ->
    case maps:take(ServiceId, Changes) of
        {#pids_change_input{ignore = IgnoreOld} = Change, ChangesNew} ->
            Ignore = IgnoreOld orelse sets:is_element(ServiceId, Suspended),
            pids_change_check(Change#pids_change_input{ignore = Ignore},
                              ServiceId,
                              State#state{changes = ChangesNew});
        error ->
            pids_change_check(undefined, ServiceId, State)
    end.

pids_change_check(undefined, _, State) ->
    State;
pids_change_check(#pids_change_input{changes = []}, _, State) ->
    State;
pids_change_check(#pids_change_input{terminated = true,
                                     period = Period} = Change,
                  ServiceId,
                  #state{changes = Changes} = State) ->
    % remove after the next changes message
    erlang:send_after(Period * 1000, self(), {changes, ServiceId}),
    ChangesNew = maps:put(ServiceId,
                          Change#pids_change_input{changes = []},
                          Changes),
    State#state{changes = ChangesNew};
pids_change_check(#pids_change_input{ignore = true}, _, State) ->
    State;
pids_change_check(#pids_change_input{changes = ChangeList}, ServiceId,
                  #state{services = Services} = State) ->
    {Pids,
     #service{process_count = ProcessCount,
              thread_count = ThreadCount}} = key2value:
                                             fetch1(ServiceId, Services),
    if
        length(Pids) =:= ProcessCount * ThreadCount ->
            {I, Rate} = pids_change(ChangeList, ProcessCount),
            pids_change_now(I, Pids, ProcessCount, Rate,
                            ServiceId, State);
        true ->
            % avoid changing count_process while changes are still
            % in-progress due to past ChangeList data
            State
    end.

pids_change_now(I, Pids, ProcessCount, Rate, ServiceId,
                #state{services = Services} = State)
    when I > 0 ->
    State#state{services = pids_change_increase(I, Pids, ProcessCount, Rate,
                                                ServiceId, Services)};
pids_change_now(I, Pids, ProcessCount, Rate, ServiceId,
                #state{services = Services} = State)
    when I < 0 ->
    State#state{services = pids_change_decrease(I, Pids, ProcessCount, Rate,
                                                ServiceId, Services)};
pids_change_now(0, _, ProcessCount, Rate, ServiceId, State) ->
    ?LOG_TRACE("count_process_dynamic(~p):~n "
               "constant ~p for ~p requests/second",
               [service_id(ServiceId), ProcessCount,
                erlang:round(Rate * 10) / 10]),
    State.

pids_change(ChangeList, ProcessCountCurrent) ->
    pids_change_loop(ChangeList,
                     #pids_change{process_count = ProcessCountCurrent}).

pids_change_loop([],
                 #pids_change{process_count = ProcessCount,
                              count_increase = CountIncrease,
                              count_decrease = CountDecrease,
                              increase = Increase,
                              decrease = Decrease,
                              rate = Rate}) ->
    Change = erlang:round(if
        CountIncrease == CountDecrease ->
            CountBoth = CountIncrease + CountDecrease,
            ((Increase / CountIncrease) *
             (CountIncrease / CountBoth) +
             (Decrease / CountDecrease) *
             (CountDecrease / CountBoth)) - ProcessCount;
        CountIncrease > CountDecrease ->
            (Increase / CountIncrease) - ProcessCount;
        CountIncrease < CountDecrease ->
            (Decrease / CountDecrease) - ProcessCount
    end),
    {Change, Rate};
pids_change_loop([{increase, RateCurrent,
                   RateMax, ProcessCountMax} | ChangeList],
                 #pids_change{process_count = ProcessCount,
                              count_increase = CountIncrease,
                              increase = Increase,
                              rate = Rate} = State)
    when RateCurrent > RateMax ->
    IncreaseNew = Increase + (if
        ProcessCountMax =< ProcessCount ->
            % if floating point ProcessCount was specified in the configuration
            % and the number of schedulers changed, it would be possible to
            % have: ProcessCountMax < ProcessCount
            ProcessCount;
        ProcessCountMax > ProcessCount ->
            erlang:min(ceil((ProcessCount * RateCurrent) / RateMax),
                       ProcessCountMax)
    end),
    pids_change_loop(ChangeList,
                     State#pids_change{count_increase = (CountIncrease + 1),
                                       increase = IncreaseNew,
                                       rate = (Rate + RateCurrent)});
pids_change_loop([{decrease, RateCurrent,
                   RateMin, ProcessCountMin} | ChangeList],
                 #pids_change{process_count = ProcessCount,
                              count_decrease = CountDecrease,
                              decrease = Decrease,
                              rate = Rate} = State)
    when RateCurrent < RateMin ->
    DecreaseNew = Decrease + (if
        ProcessCountMin >= ProcessCount ->
            % if floating point ProcessCount was specified in the configuration
            % and the number of schedulers changed, it would be possible to
            % have: ProcessCountMin > ProcessCount
            ProcessCount;
        ProcessCountMin < ProcessCount ->
            erlang:max(floor((ProcessCount * RateCurrent) / RateMin),
                       ProcessCountMin)
    end),
    pids_change_loop(ChangeList,
                     State#pids_change{count_decrease = (CountDecrease + 1),
                                       decrease = DecreaseNew,
                                       rate = (Rate + RateCurrent)}).

pids_change_increase_loop(0, _, _, _, Services) ->
    Services;
pids_change_increase_loop(Count, ProcessIndex,
                          #service{service_m = M,
                                   service_f = F,
                                   service_a = A,
                                   process_count = ProcessCount,
                                   thread_count = ThreadCount,
                                   scope = Scope,
                                   time_start = TimeStart,
                                   time_restart = TimeRestart,
                                   restart_count_total = Restarts,
                                   timeout_term = TimeoutTerm,
                                   restart_all = RestartAll,
                                   restart_delay = RestartDelay,
                                   critical = Critical,
                                   max_r = MaxR,
                                   max_t = MaxT} = Service,
                          ServiceId, Services) ->
    ServicesNew = case erlang:apply(M, F, [ProcessIndex, ProcessCount,
                                           TimeStart, TimeRestart,
                                           Restarts | A]) of
        {ok, Pid} when is_pid(Pid) ->
            ?LOG_INFO("~p -> ~p (count_process_dynamic)",
                      [service_id(ServiceId), Pid]),
            new_service_processes(true, M, F, A,
                                  ProcessIndex, ProcessCount,
                                  ThreadCount, Scope, [Pid],
                                  TimeStart, TimeRestart, Restarts,
                                  TimeoutTerm, RestartAll, RestartDelay,
                                  Critical, MaxR, MaxT, ServiceId, Services);
        {ok, [Pid | _] = Pids} when is_pid(Pid) ->
            ?LOG_INFO("~p -> ~p (count_process_dynamic)",
                      [service_id(ServiceId), Pids]),
            new_service_processes(true, M, F, A,
                                  ProcessIndex, ProcessCount,
                                  ThreadCount, Scope, Pids,
                                  TimeStart, TimeRestart, Restarts,
                                  TimeoutTerm, RestartAll, RestartDelay,
                                  Critical, MaxR, MaxT, ServiceId, Services);
        {error, _} = Error ->
            ?LOG_ERROR("failed ~tp increase (count_process_dynamic)~n ~p",
                       [Error, service_id(ServiceId)]),
            Services
    end,
    pids_change_increase_loop(Count - 1, ProcessIndex + 1,
                              Service, ServiceId, ServicesNew).

pids_change_increase(Count, PidsOld, ProcessCountCurrent, Rate,
                     ServiceId, Services) ->
    ServiceL = service_instance(PidsOld, ServiceId, Services),
    ?LOG_INFO("count_process_dynamic(~p):~n "
              "increasing ~p with ~p for ~p requests/second~n~p",
              [service_id(ServiceId), ProcessCountCurrent, Count,
               erlang:round(Rate * 10) / 10,
               [P || #service{pids = P} <- ServiceL]]),
    ProcessCount = ProcessCountCurrent + Count,
    {ServiceLNew, % reversed
     ServicesNew} = pids_change_update(ServiceL, ProcessCount,
                                       ServiceId, Services),
    [#service{process_index = ProcessIndex} = Service | _] = ServiceLNew,
    pids_change_increase_loop(Count, ProcessIndex + 1, Service,
                              ServiceId, ServicesNew).

pids_change_decrease_loop(0, ServiceL) ->
    ServiceL;
pids_change_decrease_loop(Count, [#service{pids = Pids} | ServiceL]) ->
    lists:foreach(fun(P) ->
        cloudi_core_i_rate_based_configuration:
        count_process_dynamic_terminate(P)
    end, Pids),
    pids_change_decrease_loop(Count + 1, ServiceL).

pids_change_decrease(Count, PidsOld, ProcessCountCurrent, Rate,
                     ServiceId, Services) ->
    ServiceL = service_instance(PidsOld, ServiceId, Services),
    ?LOG_INFO("count_process_dynamic(~p):~n "
              "decreasing ~p with ~p for ~p requests/second~n~p",
              [service_id(ServiceId), ProcessCountCurrent, Count,
               erlang:round(Rate * 10) / 10,
               [P || #service{pids = P} <- ServiceL]]),
    ProcessCount = ProcessCountCurrent + Count,
    {ServiceLNew, % reversed
     ServicesNew} = pids_change_update(ServiceL, ProcessCount,
                                       ServiceId, Services),
    [_ | _] = pids_change_decrease_loop(Count, ServiceLNew),
    ServicesNew.

pids_change_update(ServiceL, ProcessCount, ServiceId, Services) ->
    pids_change_update(ServiceL, [], ProcessCount, ServiceId, Services).

pids_change_update([], Output, _, _, Services) ->
    {Output, Services};
pids_change_update([#service{process_index = ProcessIndex,
                             pids = Pids} = Service | ServiceL], Output,
                   ProcessCount, ServiceId, Services) ->
    ProcessCountUpdate = ProcessIndex < ProcessCount,
    ServiceNew = Service#service{process_count = ProcessCount},
    ServicesNew = lists:foldl(fun(Pid, ServicesNext) ->
        if
            ProcessCountUpdate =:= true ->
                cloudi_core_i_rate_based_configuration:
                count_process_dynamic_update(Pid, ProcessCount);
            ProcessCountUpdate =:= false ->
                ok
        end,
        key2value:store(ServiceId, Pid, ServiceNew, ServicesNext)
    end, Services, Pids),
    pids_change_update(ServiceL, [ServiceNew | Output],
                       ProcessCount, ServiceId, ServicesNew).

service_instance(Pids, ServiceId, Services) ->
    service_instance(Pids, [], ServiceId, Services).

service_instance([], Results, _, _) ->
    Results;
service_instance([Pid | Pids], Results, ServiceId, Services) ->
    case key2value:find2(Pid, Services) of
        {ok, {[ServiceId], #service{pids = [Pid]} = Service}} ->
            service_instance(Pids,
                             lists:keymerge(#service.process_index,
                                            Results, [Service]),
                             ServiceId, Services);
        {ok, {[ServiceId], #service{pids = ThreadPids} = Service}} ->
            service_instance(Pids -- ThreadPids,
                             lists:keymerge(#service.process_index,
                                            Results, [Service]),
                             ServiceId, Services)
    end.

service_ids_pids(ServiceIdList, Services) ->
    service_ids_pids(ServiceIdList, [], Services).

service_ids_pids([], PidsList, _) ->
    {ok, lists:flatten(lists:reverse(PidsList))};
service_ids_pids([ServiceId | ServiceIdList], PidsList, Services) ->
    case service_id_pids(ServiceId, Services) of
        {ok, PidsOrdered} ->
            service_ids_pids(ServiceIdList, [PidsOrdered | PidsList], Services);
        {error, _} = Error ->
            Error
    end.

service_id_pids(ServiceId, Services) ->
    case key2value:find1(ServiceId, Services) of
        {ok, {Pids, #service{process_count = ProcessCount}}} ->
            {PidsOrdered,
             _} = service_id_pids_ordered(Pids, ProcessCount, Services),
            {ok, PidsOrdered};
        error ->
            {error, not_found}
    end.

service_id_pids_ordered(Pids, ProcessCount, Services) ->
    % all pids must be in process_index order
    service_id_pids_ordered(ProcessCount - 1, [], [],
                            service_id_pids_ordered_put(Pids, #{}, Services)).

service_id_pids_ordered(ProcessIndex, Pids, OSPids, ProcessLookup) ->
    {ProcessPids, OSPid} = maps:get(ProcessIndex, ProcessLookup),
    PidsNew = ProcessPids ++ Pids,
    OSPidsNew = if
        OSPid =:= undefined ->
            OSPids;
        is_integer(OSPid) ->
            [OSPid | OSPids]
    end,
    if
        ProcessIndex == 0 ->
            {PidsNew, OSPidsNew};
        ProcessIndex > 0 ->
            service_id_pids_ordered(ProcessIndex - 1,
                                    PidsNew, OSPidsNew, ProcessLookup)
    end.

service_id_pids_ordered_put([], ProcessLookup, _) ->
    ProcessLookup;
service_id_pids_ordered_put([Pid | Pids], ProcessLookup, Services) ->
    {_,
     #service{process_index = ProcessIndex,
              pids = ProcessPids,
              os_pid = OSPid}} = key2value:fetch2(Pid, Services),
    ProcessLookupNew = maps:put(ProcessIndex,
                                {ProcessPids, OSPid}, ProcessLookup),
    service_id_pids_ordered_put(Pids, ProcessLookupNew, Services).

status_service_ids(ServiceIdList, Required, TimeNow,
                   DurationsUpdate, DurationsSuspend, Suspended,
                   DurationsRestart, Services) ->
    TimeDayStart = TimeNow - ?NATIVE_TIME_IN_DAY,
    TimeWeekStart = TimeNow - ?NATIVE_TIME_IN_WEEK,
    TimeMonthStart = TimeNow - ?NATIVE_TIME_IN_MONTH,
    TimeYearStart = TimeNow - ?NATIVE_TIME_IN_YEAR,
    TimeOffset = erlang:time_offset(),
    status_service_ids(ServiceIdList, [], Required, TimeNow,
                       TimeDayStart, TimeWeekStart,
                       TimeMonthStart, TimeYearStart, TimeOffset,
                       DurationsUpdate, DurationsSuspend, Suspended,
                       DurationsRestart, Services).

status_service_ids([], StatusList, _, _, _, _, _, _, _, _, _, _, _, _) ->
    {ok, lists:reverse(StatusList)};
status_service_ids([ServiceId | ServiceIdList], StatusList, Required, TimeNow,
                   TimeDayStart, TimeWeekStart,
                   TimeMonthStart, TimeYearStart, TimeOffset,
                   DurationsUpdate, DurationsSuspend, Suspended,
                   DurationsRestart, Services) ->
    case status_service_id(ServiceId, TimeNow,
                           TimeDayStart, TimeWeekStart,
                           TimeMonthStart, TimeYearStart, TimeOffset,
                           DurationsUpdate, DurationsSuspend, Suspended,
                           DurationsRestart, Services) of
        {ok, Status} ->
            status_service_ids(ServiceIdList,
                               [{ServiceId, Status} | StatusList],
                               Required, TimeNow,
                               TimeDayStart, TimeWeekStart,
                               TimeMonthStart, TimeYearStart, TimeOffset,
                               DurationsUpdate, DurationsSuspend, Suspended,
                               DurationsRestart, Services);
        {error, {service_not_found, _}} = Error ->
            if
                Required =:= true ->
                    Error;
                Required =:= false ->
                    status_service_ids(ServiceIdList, StatusList,
                                       Required, TimeNow,
                                       TimeDayStart, TimeWeekStart,
                                       TimeMonthStart, TimeYearStart,
                                       TimeOffset, DurationsUpdate,
                                       DurationsSuspend, Suspended,
                                       DurationsRestart, Services)
            end
    end.

status_service_id(ServiceId, TimeNow,
                  TimeDayStart, TimeWeekStart,
                  TimeMonthStart, TimeYearStart, TimeOffset,
                  DurationsUpdate, DurationsSuspend, Suspended,
                  DurationsRestart, Services) ->
    case key2value:find1(ServiceId, Services) of
        {ok, {Pids, #service{service_m = Module,
                             service_f = Function,
                             service_a = Arguments,
                             process_count = ProcessCount,
                             thread_count = ThreadCount,
                             time_start = TimeStart,
                             time_restart = TimeRestart,
                             restart_count_total = Restarts}}} ->
            cloudi_core_i_spawn = Module,
            DurationsStateUpdate = cloudi_availability:
                                   durations_state(ServiceId,
                                                   DurationsUpdate),
            DurationsStateSuspend = cloudi_availability:
                                    durations_state(ServiceId,
                                                    DurationsSuspend),
            ProcessingSuspended = sets:is_element(ServiceId, Suspended),
            DurationsStateRestart = cloudi_availability:
                                    durations_state(ServiceId,
                                                    DurationsRestart),
            TimeRunning = if
                TimeRestart =:= undefined ->
                    TimeStart;
                is_integer(TimeRestart) ->
                    TimeRestart
            end,
            NanoSecondsTotal = cloudi_timestamp:
                               convert(TimeNow - TimeStart,
                                       native, nanosecond),
            NanoSecondsRunning = cloudi_timestamp:
                                 convert(TimeNow - TimeRunning,
                                         native, nanosecond),
            UptimeTotal = cloudi_timestamp:
                          nanoseconds_to_string(NanoSecondsTotal),
            UptimeRunning = cloudi_timestamp:
                            nanoseconds_to_string(NanoSecondsRunning),
            {ApproximateYearUpdate,
             NanoSecondsYearUpdate} = cloudi_availability:
                                      durations_sum(DurationsStateUpdate,
                                                    TimeYearStart),
            {ApproximateYearSuspend,
             NanoSecondsYearSuspend} = cloudi_availability:
                                       durations_sum(DurationsStateSuspend,
                                                     TimeYearStart),
            {ApproximateYearRestart,
             NanoSecondsYearRestart,
             ViewYearRestart} = cloudi_availability:
                                durations_sum_with_view(DurationsStateRestart,
                                                        TimeYearStart,
                                                        TimeNow,
                                                        year,
                                                        TimeOffset),
            {ApproximateMonthUpdate,
             NanoSecondsMonthUpdate} = cloudi_availability:
                                       durations_sum(DurationsStateUpdate,
                                                     TimeMonthStart),
            {ApproximateMonthSuspend,
             NanoSecondsMonthSuspend} = cloudi_availability:
                                        durations_sum(DurationsStateSuspend,
                                                      TimeMonthStart),
            {ApproximateMonthRestart,
             NanoSecondsMonthRestart,
             ViewMonthRestart} = cloudi_availability:
                                 durations_sum_with_view(DurationsStateRestart,
                                                         TimeMonthStart,
                                                         TimeNow,
                                                         month,
                                                         TimeOffset),
            {ApproximateWeekUpdate,
             NanoSecondsWeekUpdate} = cloudi_availability:
                                      durations_sum(DurationsStateUpdate,
                                                    TimeWeekStart),
            {ApproximateWeekSuspend,
             NanoSecondsWeekSuspend} = cloudi_availability:
                                       durations_sum(DurationsStateSuspend,
                                                     TimeWeekStart),
            {ApproximateWeekRestart,
             NanoSecondsWeekRestart,
             ViewWeekRestart} = cloudi_availability:
                                durations_sum_with_view(DurationsStateRestart,
                                                        TimeWeekStart,
                                                        TimeNow,
                                                        week,
                                                        TimeOffset),
            {ApproximateDayUpdate,
             NanoSecondsDayUpdate} = cloudi_availability:
                                     durations_sum(DurationsStateUpdate,
                                                   TimeDayStart),
            {ApproximateDaySuspend,
             NanoSecondsDaySuspend} = cloudi_availability:
                                      durations_sum(DurationsStateSuspend,
                                                    TimeDayStart),
            {ApproximateDayRestart,
             NanoSecondsDayRestart,
             ViewDayRestart} = cloudi_availability:
                               durations_sum_with_view(DurationsStateRestart,
                                                       TimeDayStart,
                                                       TimeNow,
                                                       day,
                                                       TimeOffset),
            Status0 = [],
            Status1 = case cloudi_availability:
                           nanoseconds_to_availability_year(
                               NanoSecondsRunning,
                               ApproximateYearUpdate orelse
                               ApproximateYearSuspend,
                               NanoSecondsYearUpdate +
                               NanoSecondsYearSuspend) of
                ?AVAILABILITY_ZERO ->
                    Status0;
                AvailabilityYearProcessing ->
                    [{availability_year_processing,
                      AvailabilityYearProcessing} | Status0]
            end,
            Status2 = case cloudi_availability:
                           nanoseconds_to_availability_year(
                               NanoSecondsRunning,
                               ApproximateYearUpdate,
                               NanoSecondsYearUpdate) of
                ?AVAILABILITY_ZERO ->
                    Status1;
                AvailabilityYearUpdated ->
                    [{availability_year_updated,
                      AvailabilityYearUpdated} | Status1]
            end,
            Status3 = case cloudi_availability:
                           nanoseconds_to_availability_year(
                               NanoSecondsRunning) of
                ?AVAILABILITY_ZERO ->
                    Status2;
                AvailabilityYearRunning ->
                    [{availability_year_running,
                      AvailabilityYearRunning} | Status2]
            end,
            Status4 = case cloudi_availability:
                           nanoseconds_to_availability_year(
                               NanoSecondsTotal,
                               ApproximateYearRestart,
                               NanoSecondsYearRestart) of
                ?AVAILABILITY_ZERO ->
                    Status3;
                AvailabilityYearTotal ->
                    [{availability_year_total,
                      AvailabilityYearTotal} | Status3]
            end,
            Status5 = case cloudi_availability:
                           nanoseconds_to_availability_month(
                               NanoSecondsRunning,
                               ApproximateMonthUpdate orelse
                               ApproximateMonthSuspend,
                               NanoSecondsMonthUpdate +
                               NanoSecondsMonthSuspend) of
                ?AVAILABILITY_ZERO ->
                    Status4;
                AvailabilityMonthProcessing ->
                    [{availability_month_processing,
                      AvailabilityMonthProcessing} | Status4]
            end,
            Status6 = case cloudi_availability:
                           nanoseconds_to_availability_month(
                               NanoSecondsRunning,
                               ApproximateMonthUpdate,
                               NanoSecondsMonthUpdate) of
                ?AVAILABILITY_ZERO ->
                    Status5;
                AvailabilityMonthUpdated ->
                    [{availability_month_updated,
                      AvailabilityMonthUpdated} | Status5]
            end,
            Status7 = case cloudi_availability:
                           nanoseconds_to_availability_month(
                               NanoSecondsRunning) of
                ?AVAILABILITY_ZERO ->
                    Status6;
                AvailabilityMonthRunning ->
                    [{availability_month_running,
                      AvailabilityMonthRunning} | Status6]
            end,
            Status8 = case cloudi_availability:
                           nanoseconds_to_availability_month(
                               NanoSecondsTotal,
                               ApproximateMonthRestart,
                               NanoSecondsMonthRestart) of
                ?AVAILABILITY_ZERO ->
                    Status7;
                AvailabilityMonthTotal ->
                    [{availability_month_total,
                      AvailabilityMonthTotal} | Status7]
            end,
            Status9 = case cloudi_availability:
                           nanoseconds_to_availability_week(
                               NanoSecondsRunning,
                               ApproximateWeekUpdate orelse
                               ApproximateWeekSuspend,
                               NanoSecondsWeekUpdate +
                               NanoSecondsWeekSuspend) of
                ?AVAILABILITY_ZERO ->
                    Status8;
                AvailabilityWeekProcessing ->
                    [{availability_week_processing,
                      AvailabilityWeekProcessing} | Status8]
            end,
            Status10 = case cloudi_availability:
                            nanoseconds_to_availability_week(
                                NanoSecondsRunning,
                                ApproximateWeekUpdate,
                                NanoSecondsWeekUpdate) of
                ?AVAILABILITY_ZERO ->
                    Status9;
                AvailabilityWeekUpdated ->
                    [{availability_week_updated,
                      AvailabilityWeekUpdated} | Status9]
            end,
            Status11 = case cloudi_availability:
                            nanoseconds_to_availability_week(
                                NanoSecondsRunning) of
                ?AVAILABILITY_ZERO ->
                    Status10;
                AvailabilityWeekRunning ->
                    [{availability_week_running,
                      AvailabilityWeekRunning} | Status10]
            end,
            Status12 = case cloudi_availability:
                            nanoseconds_to_availability_week(
                                NanoSecondsTotal,
                                ApproximateWeekRestart,
                                NanoSecondsWeekRestart) of
                ?AVAILABILITY_ZERO ->
                    Status11;
                AvailabilityWeekTotal ->
                    [{availability_week_total,
                      AvailabilityWeekTotal} | Status11]
            end,
            Status13 = [{availability_day_total,
                         cloudi_availability:
                         nanoseconds_to_availability_day(
                             NanoSecondsTotal,
                             ApproximateDayRestart,
                             NanoSecondsDayRestart)},
                        {availability_day_running,
                         cloudi_availability:
                         nanoseconds_to_availability_day(
                             NanoSecondsRunning)},
                        {availability_day_updated,
                         cloudi_availability:
                         nanoseconds_to_availability_day(
                             NanoSecondsRunning,
                             ApproximateDayUpdate,
                             NanoSecondsDayUpdate)},
                        {availability_day_processing,
                         cloudi_availability:
                         nanoseconds_to_availability_day(
                             NanoSecondsRunning,
                             ApproximateDayUpdate orelse
                             ApproximateDaySuspend,
                             NanoSecondsDayUpdate +
                             NanoSecondsDaySuspend)} | Status12],
            DowntimeYearRestart = TimeStart =< TimeMonthStart andalso
                                  NanoSecondsYearRestart > 0,
            DowntimeMonthRestart = TimeStart =< TimeWeekStart andalso
                                   (NanoSecondsMonthRestart > 0 orelse
                                    NanoSecondsYearRestart > 0),
            DowntimeWeekRestart = TimeStart =< TimeDayStart andalso
                                  (NanoSecondsWeekRestart > 0 orelse
                                   NanoSecondsMonthRestart > 0 orelse
                                   NanoSecondsYearRestart > 0),
            DowntimeDayRestart = NanoSecondsDayRestart > 0 orelse
                                 NanoSecondsWeekRestart > 0 orelse
                                 NanoSecondsMonthRestart > 0 orelse
                                 NanoSecondsYearRestart > 0,
            Status14 = if
                DowntimeYearRestart =:= true ->
                    [{outages_year_restarting,
                      ViewYearRestart} |
                     Status13];
                DowntimeYearRestart =:= false ->
                    Status13
            end,
            Status15 = if
                DowntimeMonthRestart =:= true ->
                    [{outages_month_restarting,
                      ViewMonthRestart} |
                     Status14];
                DowntimeMonthRestart =:= false ->
                    Status14
            end,
            Status16 = if
                DowntimeWeekRestart =:= true ->
                    [{outages_week_restarting,
                      ViewWeekRestart} |
                     Status15];
                DowntimeWeekRestart =:= false ->
                    Status15
            end,
            Status17 = if
                DowntimeDayRestart =:= true ->
                    [{outages_day_restarting,
                      ViewDayRestart} |
                     Status16];
                DowntimeDayRestart =:= false ->
                    Status16
            end,
            Status18 = if
                TimeRunning =< TimeMonthStart,
                NanoSecondsYearSuspend > 0 ->
                    [{interrupt_year_suspended,
                      cloudi_availability:
                      nanoseconds_to_string_gt(NanoSecondsYearSuspend,
                                               ApproximateYearSuspend)} |
                     Status17];
                true ->
                    Status17
            end,
            Status19 = if
                TimeRunning =< TimeWeekStart,
                NanoSecondsMonthSuspend > 0 orelse
                NanoSecondsYearSuspend > 0 ->
                    [{interrupt_month_suspended,
                      cloudi_availability:
                      nanoseconds_to_string_gt(NanoSecondsMonthSuspend,
                                               ApproximateMonthSuspend)} |
                     Status18];
                true ->
                    Status18
            end,
            Status20 = if
                TimeRunning =< TimeDayStart,
                NanoSecondsWeekSuspend > 0 orelse
                NanoSecondsMonthSuspend > 0 orelse
                NanoSecondsYearSuspend > 0 ->
                    [{interrupt_week_suspended,
                      cloudi_availability:
                      nanoseconds_to_string_gt(NanoSecondsWeekSuspend,
                                               ApproximateWeekSuspend)} |
                     Status19];
                true ->
                    Status19
            end,
            Status21 = if
                NanoSecondsDaySuspend > 0 orelse
                NanoSecondsWeekSuspend > 0 orelse
                NanoSecondsMonthSuspend > 0 orelse
                NanoSecondsYearSuspend > 0 ->
                    [{interrupt_day_suspended,
                      cloudi_availability:
                      nanoseconds_to_string_gt(NanoSecondsDaySuspend,
                                               ApproximateDaySuspend)} |
                     Status20];
                true ->
                    Status20
            end,
            Status22 = if
                TimeRunning =< TimeMonthStart,
                NanoSecondsYearUpdate > 0 ->
                    [{interrupt_year_updating,
                      cloudi_availability:
                      nanoseconds_to_string_gt(NanoSecondsYearUpdate,
                                               ApproximateYearUpdate)} |
                     Status21];
                true ->
                    Status21
            end,
            Status23 = if
                TimeRunning =< TimeWeekStart,
                NanoSecondsMonthUpdate > 0 orelse
                NanoSecondsYearUpdate > 0 ->
                    [{interrupt_month_updating,
                      cloudi_availability:
                      nanoseconds_to_string_gt(NanoSecondsMonthUpdate,
                                               ApproximateMonthUpdate)} |
                     Status22];
                true ->
                    Status22
            end,
            Status24 = if
                TimeRunning =< TimeDayStart,
                NanoSecondsWeekUpdate > 0 orelse
                NanoSecondsMonthUpdate > 0 orelse
                NanoSecondsYearUpdate > 0 ->
                    [{interrupt_week_updating,
                      cloudi_availability:
                      nanoseconds_to_string_gt(NanoSecondsWeekUpdate,
                                               ApproximateWeekUpdate)} |
                     Status23];
                true ->
                    Status23
            end,
            Status25 = if
                NanoSecondsDayUpdate > 0 orelse
                NanoSecondsWeekUpdate > 0 orelse
                NanoSecondsMonthUpdate > 0 orelse
                NanoSecondsYearUpdate > 0 ->
                    [{interrupt_day_updating,
                      cloudi_availability:
                      nanoseconds_to_string_gt(NanoSecondsDayUpdate,
                                               ApproximateDayUpdate)} |
                     Status24];
                true ->
                    Status24
            end,
            Status26 = if
                DowntimeYearRestart =:= true ->
                    [{downtime_year_restarting,
                      cloudi_availability:
                      nanoseconds_to_string_gt(NanoSecondsYearRestart,
                                               ApproximateYearRestart)} |
                     Status25];
                DowntimeYearRestart =:= false ->
                    Status25
            end,
            Status27 = if
                DowntimeMonthRestart =:= true ->
                    [{downtime_month_restarting,
                      cloudi_availability:
                      nanoseconds_to_string_gt(NanoSecondsMonthRestart,
                                               ApproximateMonthRestart)} |
                     Status26];
                DowntimeMonthRestart =:= false ->
                    Status26
            end,
            Status28 = if
                DowntimeWeekRestart =:= true ->
                    [{downtime_week_restarting,
                      cloudi_availability:
                      nanoseconds_to_string_gt(NanoSecondsWeekRestart,
                                               ApproximateWeekRestart)} |
                     Status27];
                DowntimeWeekRestart =:= false ->
                    Status27
            end,
            Status29 = if
                DowntimeDayRestart =:= true ->
                    [{downtime_day_restarting,
                      cloudi_availability:
                      nanoseconds_to_string_gt(NanoSecondsDayRestart,
                                               ApproximateDayRestart)} |
                     Status28];
                DowntimeDayRestart =:= false ->
                    Status28
            end,
            NanoSecondsProcessing = NanoSecondsRunning -
                                    (NanoSecondsYearUpdate +
                                     NanoSecondsYearSuspend),
            ApproximateProcessing = ProcessingSuspended orelse
                                    ApproximateYearUpdate orelse
                                    ApproximateYearSuspend,
            UptimeProcessing = cloudi_availability:
                               nanoseconds_to_string_lt(NanoSecondsProcessing,
                                                        ApproximateProcessing),
            Status30 = [{size_erlang, status_pids_size(Pids)},
                        {suspended, ProcessingSuspended},
                        {uptime_total, UptimeTotal},
                        {uptime_running, UptimeRunning},
                        {uptime_processing, UptimeProcessing},
                        {uptime_restarts,
                         erlang:integer_to_list(Restarts)} | Status29],
            {PidsOrdered,
             OSPidsOrdered} = service_id_pids_ordered(Pids, ProcessCount,
                                                      Services),
            StatusN = if
                Function =:= start_internal ->
                    [] = OSPidsOrdered,
                    Module:status_internal(ProcessCount,
                                           PidsOrdered,
                                           Arguments, Status30);
                Function =:= start_external ->
                    Module:status_external(ProcessCount, ThreadCount,
                                           OSPidsOrdered, PidsOrdered,
                                           Arguments, Status30)
            end,
            {ok, StatusN};
        error ->
            {error, {service_not_found, ServiceId}}
    end.

status_pids_size(Pids) ->
    status_pids_size(Pids, 0).

status_pids_size([], PidsSize) ->
    PidsSize;
status_pids_size([Pid | Pids], PidsSize) ->
    case erlang:process_info(Pid, memory) of
        undefined ->
            status_pids_size(Pids, PidsSize);
        {memory, PidSize} ->
            status_pids_size(Pids, PidsSize + PidSize)
    end.

restart_pids([]) ->
    ok;
restart_pids([Pid | PidList]) ->
    erlang:exit(Pid, restart),
    restart_pids(PidList).

suspend_pids(PidList) ->
    Self = self(),
    _ = [Pid ! {'cloudi_service_suspended', Self, true} || Pid <- PidList],
    suspend_pids_recv(PidList, ok).

suspend_pids_recv([], Result) ->
    if
        Result =:= ok ->
            ok;
        true ->
            {error, Result}
    end;
suspend_pids_recv([Pid | PidList], Result)
    when is_pid(Pid) ->
    receive
        {'DOWN', _, 'process', Pid, _} = DOWN ->
            self() ! DOWN,
            suspend_pids_recv(PidList, Result);
        {'cloudi_service_suspended', Pid, already_suspended} ->
            suspend_pids_recv(PidList, already_suspended);
        {'cloudi_service_suspended', Pid, ok} ->
            suspend_pids_recv(PidList, Result)
    end.

resume_restart_pids([], _) ->
    ok;
resume_restart_pids([Pid | PidList], PidsRestart) ->
    case lists:member(Pid, PidsRestart) of
        true ->
            resume_restart_pids(PidList, PidsRestart);
        false ->
            Pid ! {'cloudi_service_suspended', undefined, false},
            resume_restart_pids(PidList, PidsRestart)
    end.

resume_pids(PidList, DurationsSuspend, DurationsUpdate, ServiceId) ->
    Self = self(),
    _ = [Pid ! {'cloudi_service_suspended', Self, false} || Pid <- PidList],
    case resume_pids_recv(PidList, ok, undefined) of
        {ok, undefined} ->
            {ok, DurationsSuspend};
        {ok, Duration} ->
            % track the duration of time suspended minus the
            % duration of time updating (if any updating occurred)
            % so the processing time can be calculated accurately
            % based on the running time
            {ok,
             cloudi_availability:
             durations_store_difference([ServiceId], Duration,
                                        DurationsSuspend, DurationsUpdate)};
        {error, _} = Error ->
            Error
    end.

resume_pids_recv([], Result, Duration) ->
    if
        Result =:= ok ->
            {ok, Duration};
        true ->
            {error, Result}
    end;
resume_pids_recv([Pid | PidList], Result, Duration)
    when is_pid(Pid) ->
    receive
        {'DOWN', _, 'process', Pid, _} = DOWN ->
            self() ! DOWN,
            resume_pids_recv(PidList, Result, Duration);
        {'cloudi_service_suspended', Pid, already_resumed} ->
            resume_pids_recv(PidList, already_resumed, Duration);
        {'cloudi_service_suspended', Pid, {ok, {T0, T1} = DurationNext}} ->
            DurationNew = case Duration of
                undefined ->
                    DurationNext;
                {T0Old, T1Old} ->
                    {erlang:min(T0, T0Old), erlang:max(T1, T1Old)}
            end,
            resume_pids_recv(PidList, Result, DurationNew)
    end.

update_start(PidList, UpdatePlan) ->
    Self = self(),
    _ = [Pid ! {'cloudi_service_update', Self, UpdatePlan} || Pid <- PidList],
    update_start_recv(PidList, [], []).

update_start_recv([], PidListNew, UpdateResults) ->
    {UpdateResults, lists:reverse(PidListNew)};
update_start_recv([Pid | PidList], PidListNew, UpdateResults)
    when is_pid(Pid) ->
    receive
        {'DOWN', _, 'process', Pid, _} = DOWN ->
            self() ! DOWN,
            update_start_recv(PidList, [undefined | PidListNew],
                              [{error, pid_died} | UpdateResults]);
        {'cloudi_service_update', Pid} ->
            update_start_recv(PidList, [Pid | PidListNew],
                              UpdateResults);
        {'cloudi_service_update', Pid, {error, _} = UpdateResult} ->
            update_start_recv(PidList, [undefined | PidListNew],
                              [UpdateResult | UpdateResults])
    end.

update_now(PidList, UpdateResults, UpdateStart) ->
    Self = self(),
    lists:foreach(fun(Pid) ->
        if
            Pid =:= undefined ->
                ok;
            is_pid(Pid) ->
                Pid ! {'cloudi_service_update_now', Self, UpdateStart}
        end
    end, PidList),
    update_now_recv(PidList, UpdateResults).

update_now_recv([], UpdateResults) ->
    lists:reverse(UpdateResults);
update_now_recv([Pid | PidList], UpdateResults) ->
    if
        Pid =:= undefined ->
            update_now_recv(PidList, UpdateResults);
        is_pid(Pid) ->
            UpdateResult = receive
                {'DOWN', _, 'process', Pid, _} = DOWN ->
                    self() ! DOWN,
                    {error, pid_died};
                {'cloudi_service_update_now', Pid, Result} ->
                    Result
            end,
            update_now_recv(PidList, [UpdateResult | UpdateResults])
    end.

update_results(Results) ->
    update_results(Results, [], []).

update_results([], ResultsSuccess, ResultsError) ->
    {lists:reverse(ResultsSuccess), lists:usort(ResultsError)};
update_results([ok | Results], ResultsSuccess, ResultsError) ->
    update_results(Results, ResultsSuccess, ResultsError);
update_results([{ok, Result} | Results], ResultsSuccess, ResultsError) ->
    update_results(Results, [Result | ResultsSuccess], ResultsError);
update_results([{error, Reason} | Results], ResultsSuccess, ResultsError) ->
    update_results(Results, ResultsSuccess, [Reason | ResultsError]).

update_load_module([]) ->
    ok;
update_load_module([_ | _] = ModulesLoad) ->
    reltool_util:modules_reload(ModulesLoad).

update_load_module([], ModulesLoad) ->
    update_load_module(ModulesLoad);
update_load_module([CodePathAdd | CodePathsAdd], ModulesLoad) ->
    case code:add_patha(CodePathAdd) of
        true ->
            update_load_module(CodePathsAdd, ModulesLoad);
        {error, _} = Error ->
            Error
    end.

update_reload_stop(#config_service_update{
                       type = internal,
                       module = Module,
                       reload_stop = ReloadStop}) ->
    if
        ReloadStop =:= true ->
            ok = cloudi_core_i_services_internal_reload:
                 service_remove(Module);
        ReloadStop =:= false ->
            ok
    end;
update_reload_stop(#config_service_update{
                       type = external}) ->
    ok.

update_reload_start(#config_service_update{
                        type = internal,
                        module = Module,
                        options_keys = OptionsKeys,
                        options = #config_service_options{
                            reload = ReloadStart},
                        reload_stop = ReloadStop}) ->
    Reload = case lists:member(reload, OptionsKeys) of
        true ->
            ReloadStart;
        false ->
            ReloadStop
    end,
    if
        Reload =:= true ->
            ok = cloudi_core_i_services_internal_reload:
                 service_add(Module);
        Reload =:= false ->
            ok
    end;
update_reload_start(#config_service_update{
                        type = external}) ->
    ok.

update_before(#config_service_update{
                  modules_load = ModulesLoad,
                  code_paths_add = CodePathsAdd} = UpdatePlan) ->
    ok = update_reload_stop(UpdatePlan),
    UpdateModuleResult = update_load_module(CodePathsAdd, ModulesLoad),
    [UpdateModuleResult].

update_unload_module([]) ->
    ok;
update_unload_module([CodePathRemove | CodePathsRemove]) ->
    _ = code:del_path(CodePathRemove),
    update_unload_module(CodePathsRemove).

update_unload_module([], CodePathsRemove) ->
    update_unload_module(CodePathsRemove);
update_unload_module([Module | ModulesUnload], CodePathsRemove) ->
    _ = reltool_util:module_unload(Module),
    update_unload_module(ModulesUnload, CodePathsRemove).

update_service(_, _,
               #config_service_update{
                   type = internal,
                   dest_refresh = DestRefresh,
                   timeout_init = TimeoutInit,
                   timeout_async = TimeoutAsync,
                   timeout_sync = TimeoutSync,
                   dest_list_deny = DestListDeny,
                   dest_list_allow = DestListAllow,
                   options_keys = OptionsKeys,
                   options = Options,
                   uuids = ServiceIds}, Services0) ->
    ServicesN = lists:foldl(fun(ServiceId, Services1) ->
        key2value:update1(ServiceId, fun(ServiceOld) ->
            #service{service_m = Module,
                     service_a = Arguments} = ServiceOld,
            cloudi_core_i_spawn = Module,
            ArgumentsNew = Module:update_internal_f(DestRefresh,
                                                    TimeoutInit,
                                                    TimeoutAsync,
                                                    TimeoutSync,
                                                    DestListDeny,
                                                    DestListAllow,
                                                    OptionsKeys,
                                                    Options,
                                                    Arguments),
            ServiceOld#service{service_a = ArgumentsNew}
        end, Services1)
    end, Services0, ServiceIds),
    ServicesN;
update_service(Pids, Ports,
               #config_service_update{
                   type = external,
                   file_path = FilePath,
                   args = Args,
                   env = Env,
                   dest_refresh = DestRefresh,
                   timeout_init = TimeoutInit,
                   timeout_async = TimeoutAsync,
                   timeout_sync = TimeoutSync,
                   dest_list_deny = DestListDeny,
                   dest_list_allow = DestListAllow,
                   options_keys = OptionsKeys,
                   options = Options,
                   uuids = [ServiceId]}, Services0) ->
    ServicesN = key2value:update1(ServiceId, fun(ServiceOld) ->
        #service{service_m = Module,
                 service_a = Arguments} = ServiceOld,
        cloudi_core_i_spawn = Module,
        ArgumentsNext = Module:update_external_f(FilePath,
                                                 Args,
                                                 Env,
                                                 DestRefresh,
                                                 TimeoutInit,
                                                 TimeoutAsync,
                                                 TimeoutSync,
                                                 DestListDeny,
                                                 DestListAllow,
                                                 OptionsKeys,
                                                 Options,
                                                 Arguments),
        ServiceOld#service{service_a = ArgumentsNext}
    end, Services0),
    if
        Ports == [] ->
            ok;
        length(Pids) == length(Ports) ->
            {_, ServiceNew} = key2value:fetch1(ServiceId,
                                                        ServicesN),
            #service{service_a = ArgumentsNew,
                     process_count = ProcessCount,
                     thread_count = ThreadCount} = ServiceNew,
            Result = case cloudi_core_i_configurator:
                          service_update_external(Pids, Ports, ArgumentsNew,
                                                  ThreadCount, ProcessCount) of
                ok ->
                    ok;
                {error, _} = Error ->
                    ?LOG_ERROR("failed ~tp service update~n ~p",
                               [Error, service_id(ServiceId)]),
                    error
            end,
            _ = [Pid ! {'cloudi_service_update_after', Result} || Pid <- Pids],
            ok
    end,
    ServicesN.

update_after(UpdateSuccess, PidList, ResultsSuccess,
             #config_service_update{
                 modules_unload = ModulesUnload,
                 code_paths_remove = CodePathsRemove} = UpdatePlan, Services) ->
    ServicesNew = if
        UpdateSuccess =:= true ->
            update_service(PidList, ResultsSuccess, UpdatePlan, Services);
        UpdateSuccess =:= false ->
            Services
    end,
    update_unload_module(ModulesUnload, CodePathsRemove),
    ok = update_reload_start(UpdatePlan),
    ServicesNew.

service_id(ID) ->
    uuid:uuid_to_string(ID, list_nodash).

new_service_processes(Init, M, F, A,
                      ProcessIndex, ProcessCount, ThreadCount, Scope, Pids,
                      TimeStart, TimeRestart, Restarts,
                      TimeoutTerm, RestartAll, RestartDelay,
                      Critical, MaxR, MaxT, ServiceId, Services) ->
    ServicesNew = new_service_processes_store(Pids, M, F, A,
                                              ProcessIndex, ProcessCount,
                                              ThreadCount, Scope, Pids,
                                              TimeStart, TimeRestart, Restarts,
                                              TimeoutTerm, RestartAll,
                                              RestartDelay, Critical,
                                              MaxR, MaxT, ServiceId, Services),
    if
        Init =:= true ->
            ok = process_init_begin(Pids);
        Init =:= false ->
            ok
    end,
    ServicesNew.

new_service_processes_store([], _, _, _, _, _, _, _, _, _,
                            _, _, _, _, _, _, _, _, _, Services) ->
    Services;
new_service_processes_store([P | L], M, F, A,
                            ProcessIndex, ProcessCount,
                            ThreadCount, Scope, Pids,
                            TimeStart, TimeRestart, Restarts,
                            TimeoutTerm, RestartAll, RestartDelay,
                            Critical, MaxR, MaxT, ServiceId, Services) ->
    OSPid = undefined,
    MonitorRef = erlang:monitor(process, P),
    Service = new_service_process(M, F, A,
                                  ProcessIndex, ProcessCount, ThreadCount,
                                  Scope, Pids, OSPid, MonitorRef,
                                  TimeStart, TimeRestart, Restarts,
                                  TimeoutTerm, RestartAll, RestartDelay,
                                  Critical, MaxR, MaxT),
    ServicesNew = key2value:store(ServiceId, P,
                                           Service, Services),
    new_service_processes_store(L, M, F, A,
                                ProcessIndex, ProcessCount,
                                ThreadCount, Scope, Pids,
                                TimeStart, TimeRestart, Restarts,
                                TimeoutTerm, RestartAll, RestartDelay,
                                Critical, MaxR, MaxT, ServiceId, ServicesNew).

new_service_process(M, F, A, ProcessIndex, ProcessCount, ThreadCount,
                    Scope, Pids, OSPid, MonitorRef,
                    TimeStart, TimeRestart, Restarts,
                    TimeoutTerm, RestartAll, RestartDelay,
                    Critical, MaxR, MaxT) ->
    #service{service_m = M,
             service_f = F,
             service_a = A,
             process_index = ProcessIndex,
             process_count = ProcessCount,
             thread_count = ThreadCount,
             scope = Scope,
             pids = Pids,
             os_pid = OSPid,
             monitor = MonitorRef,
             time_start = TimeStart,
             time_restart = TimeRestart,
             restart_count_total = Restarts,
             timeout_term = TimeoutTerm,
             restart_all = RestartAll,
             restart_delay = RestartDelay,
             critical = Critical,
             max_r = MaxR,
             max_t = MaxT}.


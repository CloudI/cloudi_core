%-*-Mode:erlang;coding:utf-8;tab-width:4;c-basic-offset:4;indent-tabs-mode:()-*-
% ex: set ft=erlang fenc=utf-8 sts=4 ts=4 sw=4 et nomod:
%%%
%%%------------------------------------------------------------------------
%%% @doc
%%% ==CloudI Internal Service==
%%% Erlang process which manages internal service requests and info messages
%%% for modules that implement the cloudi_service behavior.
%%% @end
%%%
%%% MIT License
%%%
%%% Copyright (c) 2011-2025 Michael Truog <mjtruog at protonmail dot com>
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
%%% @copyright 2011-2025 Michael Truog
%%% @version 2.0.8 {@date} {@time}
%%%------------------------------------------------------------------------

-module(cloudi_core_i_services_internal).
-author('mjtruog at protonmail dot com').

-behaviour(gen_server).

%% external interface
-export([start_link/19,
         get_status/1,
         get_status/2]).

%% gen_server callbacks
-export([init/1,
         handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

%% duo_mode callbacks
-export([duo_mode_loop_init/1,
         duo_mode_loop/1]).

%% duo_mode sys callbacks
-export([system_continue/3,
         system_terminate/4,
         system_code_change/4]).

%% cloudi_core_i_services_internal callbacks (request pid and info pid)
-export([handle_module_request_loop_hibernate/2,
         handle_module_info_loop_hibernate/2]).

-include("cloudi_logger.hrl").
-include("cloudi_core_i_configuration.hrl").
-include("cloudi_core_i_constants.hrl").
-include("cloudi_core_i_services_common_types.hrl").

-ifdef(ERLANG_OTP_VERSION_27_FEATURES).
-export([format_status/1]).
-else.
-export([format_status/2]).
-endif.

-record(state,
    {
        % state record fields common for cloudi_core_i_services_common.hrl:

        % ( 2) self() value cached
        dispatcher :: pid(),
        % ( 3) timeout enforcement for any outgoing service requests
        send_timeouts = #{}
            :: #{cloudi:trans_id() :=
                 {active | passive | {pid(), any()},
                  pid() | undefined, reference()}} |
               list({cloudi:trans_id(),
                     {active | passive | {pid(), any()},
                      pid() | undefined, reference()}}),
        % ( 4) if a sent service request timeout is greater than or equal to
        % the service configuration option request_timeout_immediate_max,
        % monitor the destination process with the sent service request
        % transaction id
        send_timeout_monitors = #{}
            :: #{pid() := {reference(), list(cloudi:trans_id())}} |
               list({pid(), {reference(), list(cloudi:trans_id())}}),
        % ( 5) timeout enforcement for any incoming service requests
        recv_timeouts = #{}
            :: undefined |
               #{cloudi:trans_id() := reference()} |
               list({cloudi:trans_id(), reference()}),
        % ( 6) timeout enforcement for any responses to
        % asynchronous outgoing service requests
        async_responses = #{}
            :: #{cloudi:trans_id() :=
                 {cloudi:response_info(), cloudi:response()}} |
               list({cloudi:trans_id(),
                     {cloudi:response_info(), cloudi:response()}}),
        % ( 7) deferred stop reason to use when done processing
        stop = undefined
            :: atom() | {shutdown, atom()},
        % ( 8) pending update configuration
        update_plan = undefined
            :: undefined | #config_service_update{},
        % ( 9) is the request/info pid suspended?
        suspended = #suspended{}
            :: undefined | #suspended{},
        % (10) is the request/info pid busy?
        queue_requests = true
            :: undefined | boolean(),
        % (11) queued incoming service requests
        queued = pqueue4:new()
            :: undefined |
               pqueue4:pqueue4(
                   cloudi:message_service_request()) |
               list({cloudi:priority_value(), any()}),
        % (12) queued size in bytes
        queued_size = 0 :: non_neg_integer(),
        % (13) erlang:system_info(wordsize) cached
        queued_word_size :: pos_integer(),

        % state record fields unique to the dispatcher Erlang process:

        % (14) queued incoming Erlang process messages
        queued_info = queue:new()
            :: undefined | queue:queue(any()) |
               list(any()),
        % (15) service module
        module :: module(),
        % (16) state internal to the service module source code
        service_state = undefined :: any(),
        % (17) 0-based index of the process in all service instance processes
        process_index :: non_neg_integer(),
        % (18) current count of all Erlang processes for the service instance
        process_count :: pos_integer(),
        % (19) subscribe/unsubscribe name prefix set in service configuration
        prefix :: cloudi:service_name_pattern(),
        % (20) default timeout for send_async set in service configuration
        timeout_async
            :: cloudi_service_api:timeout_send_async_value_milliseconds(),
        % (21) default timeout for send_sync set in service configuration
        timeout_sync
            :: cloudi_service_api:timeout_send_sync_value_milliseconds(),
        % (22) cloudi_service_terminate timeout set by max_r and max_t
        timeout_term
            :: cloudi_service_api:timeout_terminate_value_milliseconds(),
        % (23) duo_mode_pid if duo_mode == true, else dispatcher pid
        receiver_pid :: pid(),
        % (24) separate Erlang process for incoming throughput
        duo_mode_pid :: undefined | pid(),
        % (25) separate Erlang process for service request memory usage
        request_pid = undefined :: undefined | pid(),
        % (26) separate Erlang process for Erlang message memory usage
        info_pid = undefined :: undefined | pid(),
        % (27) transaction id (UUIDv1) generator
        uuid_generator :: uuid:state(),
        % (28) how service destination lookups occur for a service request send
        dest_refresh :: cloudi_service_api:dest_refresh(),
        % (29) cached cpg data for lazy destination refresh methods
        cpg_data
            :: undefined | cpg_data:state() |
               list({cloudi:service_name_pattern(), any()}),
        % (30) ACL lookup for denied destinations
        dest_deny
            :: undefined | trie:trie() |
               list({cloudi:service_name_pattern(), any()}),
        % (31) ACL lookup for allowed destinations
        dest_allow
            :: undefined | trie:trie() |
               list({cloudi:service_name_pattern(), any()}),
        % (32) service configuration options
        options
            :: #config_service_options{} |
               cloudi_service_api:service_options_internal()
    }).

% used when duo_mode is true (the duo_mode pid is also a permanent info pid)
-record(state_duo,
    {
        % ( 2) self() value cached
        duo_mode_pid :: pid(),
        % ( 3) timeout enforcement for any incoming service requests
        recv_timeouts = #{}
            :: #{cloudi:trans_id() := reference()} |
               list({cloudi:trans_id(), reference()}),
        % ( 4) deferred stop reason to use when done processing
        stop = undefined
            :: atom() | {shutdown, atom()},
        % ( 5) pending update configuration
        update_plan = undefined
            :: undefined | #config_service_update{},
        % ( 6) is the request pid suspended?
        suspended = #suspended{}
            :: #suspended{},
        % ( 7) is the request pid busy?
        queue_requests = true :: boolean(),
        % ( 8) queued incoming service requests
        queued = pqueue4:new()
            :: pqueue4:pqueue4(
                   cloudi:message_service_request()) |
               list({cloudi:priority_value(), any()}),
        % ( 9) queued size in bytes
        queued_size = 0 :: non_neg_integer(),
        % (10) erlang:system_info(wordsize) cached
        queued_word_size :: pos_integer(),
        % (11) queued incoming Erlang process messages
        queued_info = queue:new()
            :: queue:queue(any()) |
               list(any()),
        % (12) service module
        module :: module(),
        % (13) state internal to the service module source code
        service_state = undefined :: any(),
        % (14) cloudi_service_terminate timeout set by max_r and max_t
        timeout_term :: pos_integer(),
        % (15) separate Erlang process for outgoing throughput
        dispatcher :: pid(),
        % (16) separate Erlang process for service request memory usage
        request_pid = undefined :: undefined | pid(),
        % (17) service configuration options
        options
            :: #config_service_options{} |
               cloudi_service_api:service_options_internal()
    }).

-include("cloudi_core_i_services_common.hrl").

%%%------------------------------------------------------------------------
%%% External interface functions
%%%------------------------------------------------------------------------

start_link(ProcessIndex, ProcessCount, TimeStart, TimeRestart, Restarts,
           GroupLeader, Module, Args, Timeout, [PrefixC | _] = Prefix,
           TimeoutAsync, TimeoutSync, TimeoutTerm,
           DestRefresh, DestDeny, DestAllow,
           #config_service_options{
               scope = Scope,
               dispatcher_pid_options = PidOptions} = ConfigOptions, ID,
           Parent)
    when is_integer(ProcessIndex), is_integer(ProcessCount),
         is_integer(TimeStart), is_integer(Restarts),
         is_atom(Module), is_list(Args), is_integer(Timeout),
         is_integer(PrefixC),
         is_integer(TimeoutAsync), is_integer(TimeoutSync),
         is_integer(TimeoutTerm), is_pid(Parent) ->
    true = (DestRefresh =:= immediate_closest) orelse
           (DestRefresh =:= lazy_closest) orelse
           (DestRefresh =:= immediate_furthest) orelse
           (DestRefresh =:= lazy_furthest) orelse
           (DestRefresh =:= immediate_random) orelse
           (DestRefresh =:= lazy_random) orelse
           (DestRefresh =:= immediate_local) orelse
           (DestRefresh =:= lazy_local) orelse
           (DestRefresh =:= immediate_remote) orelse
           (DestRefresh =:= lazy_remote) orelse
           (DestRefresh =:= immediate_newest) orelse
           (DestRefresh =:= lazy_newest) orelse
           (DestRefresh =:= immediate_oldest) orelse
           (DestRefresh =:= lazy_oldest) orelse
           (DestRefresh =:= none),
    case cpg:scope_exists(Scope) of
        ok ->
            gen_server:start_link(?MODULE,
                                  [ProcessIndex, ProcessCount,
                                   TimeStart, TimeRestart, Restarts,
                                   GroupLeader, Module, Args, Timeout, Prefix,
                                   TimeoutAsync, TimeoutSync, TimeoutTerm,
                                   DestRefresh, DestDeny, DestAllow,
                                   ConfigOptions, ID, Parent],
                                  [{timeout, Timeout + ?TIMEOUT_DELTA},
                                   {spawn_opt,
                                    spawn_opt_options_before(PidOptions)}]);
        {error, Reason} ->
            {error, {service_options_scope_invalid, Reason}}
    end.

get_status(Dispatcher) ->
    get_status(Dispatcher, 5000).

get_status(Dispatcher, Timeout) ->
    gen_server:call(Dispatcher, {get_status, Timeout}, Timeout).

%%%------------------------------------------------------------------------
%%% Callback functions from gen_server
%%%------------------------------------------------------------------------

init([ProcessIndex, ProcessCount, TimeStart, TimeRestart, Restarts,
      GroupLeader, Module, Args, Timeout, Prefix,
      TimeoutAsync, TimeoutSync, TimeoutTerm,
      DestRefresh, DestDeny, DestAllow,
      #config_service_options{
          dispatcher_pid_options = PidOptions,
          bind = Bind,
          info_pid_options = InfoPidOptions,
          duo_mode = DuoMode} = ConfigOptions, ID, Parent]) ->
    ok = spawn_opt_options_after(PidOptions),
    Uptime = uptime(TimeStart, TimeRestart, Restarts),
    erlang:put(?SERVICE_ID_PDICT_KEY, ID),
    erlang:put(?SERVICE_UPTIME_PDICT_KEY, Uptime),
    erlang:put(?SERVICE_FILE_PDICT_KEY, Module),
    Dispatcher = self(),
    if
        GroupLeader =:= undefined ->
            ok;
        is_pid(GroupLeader) ->
            erlang:group_leader(GroupLeader, Dispatcher)
    end,
    ok = quickrand:seed([quickrand]),
    WordSize = erlang:system_info(wordsize),
    ok = cloudi_core_i_concurrency:bind_init(Bind),
    ConfigOptionsNew = check_init_send(ConfigOptions),
    DuoModePid = if
        DuoMode =:= true ->
            erlang:put(?PROCESS_DESCRIPTION_PDICT_KEY,
                       process_description("dispatcher (sender)",
                                           ProcessIndex)),
            spawn_opt_proc_lib(fun() ->
                erlang:put(?SERVICE_ID_PDICT_KEY, ID),
                erlang:put(?SERVICE_UPTIME_PDICT_KEY, Uptime),
                erlang:put(?SERVICE_FILE_PDICT_KEY, Module),
                erlang:put(?PROCESS_DESCRIPTION_PDICT_KEY,
                           process_description("duo_mode info_pid (receiver)",
                                               ProcessIndex)),
                duo_mode_loop_init(#state_duo{duo_mode_pid = self(),
                                              queued_word_size = WordSize,
                                              module = Module,
                                              timeout_term = TimeoutTerm,
                                              dispatcher = Dispatcher,
                                              options = ConfigOptionsNew})
            end, InfoPidOptions);
        DuoMode =:= false ->
            erlang:put(?PROCESS_DESCRIPTION_PDICT_KEY,
                       process_description("dispatcher (sender/receiver)",
                                           ProcessIndex)),
            undefined
    end,
    ReceiverPid = if
        is_pid(DuoModePid) ->
            DuoModePid;
        DuoModePid =:= undefined ->
            Dispatcher
    end,
    Variant = application:get_env(cloudi_core, uuid_v1_variant,
                                  ?UUID_V1_VARIANT_DEFAULT),
    {ok, MacAddress} = application:get_env(cloudi_core, mac_address),
    {ok, TimestampType} = application:get_env(cloudi_core, timestamp_type),
    UUID = uuid:new(Dispatcher, [{timestamp_type, TimestampType},
                                          {mac_address, MacAddress},
                                          {variant, Variant}]),
    Groups = destination_refresh_groups(DestRefresh, undefined),
    State = #state{dispatcher = Dispatcher,
                   queued_word_size = WordSize,
                   module = Module,
                   process_index = ProcessIndex,
                   process_count = ProcessCount,
                   prefix = Prefix,
                   timeout_async = TimeoutAsync,
                   timeout_sync = TimeoutSync,
                   timeout_term = TimeoutTerm,
                   receiver_pid = ReceiverPid,
                   duo_mode_pid = DuoModePid,
                   uuid_generator = UUID,
                   dest_refresh = DestRefresh,
                   cpg_data = Groups,
                   dest_deny = DestDeny,
                   dest_allow = DestAllow,
                   options = ConfigOptionsNew},
    ReceiverPid ! {'cloudi_service_init_execute', Args, Timeout,
                   cloudi_core_i_services_internal_init:
                   process_dictionary_get(),
                   State},
    % no process dictionary or state modifications below

    % send after 'cloudi_service_init_execute' to avoid race with
    % cloudi_core_i_services_monitor:process_init_begin/1
    ok = cloudi_core_i_services_internal_sup:
         process_started(Parent, Dispatcher, ReceiverPid),

    #config_service_options{
        dest_refresh_start = Delay,
        scope = Scope} = ConfigOptionsNew,
    ok = destination_refresh(DestRefresh, Dispatcher, Delay, Scope),
    {ok, State}.

handle_call(process_index, _,
            #state{process_index = ProcessIndex} = State) ->
    hibernate_check({reply, ProcessIndex, State});

handle_call(process_count, _,
            #state{process_count = ProcessCount} = State) ->
    hibernate_check({reply, ProcessCount, State});

handle_call(process_count_max, _,
            #state{process_count = ProcessCount,
                   options = #config_service_options{
                       count_process_dynamic = CountProcessDynamic}} = State) ->
    case cloudi_core_i_rate_based_configuration:
         count_process_dynamic_limits(CountProcessDynamic) of
        undefined ->
            hibernate_check({reply, ProcessCount, State});
        {_, ProcessCountMax} ->
            hibernate_check({reply, ProcessCountMax, State})
    end;

handle_call(process_count_min, _,
            #state{process_count = ProcessCount,
                   options = #config_service_options{
                       count_process_dynamic = CountProcessDynamic}} = State) ->
    case cloudi_core_i_rate_based_configuration:
         count_process_dynamic_limits(CountProcessDynamic) of
        undefined ->
            hibernate_check({reply, ProcessCount, State});
        {ProcessCountMin, _} ->
            hibernate_check({reply, ProcessCountMin, State})
    end;

handle_call(self, _,
            #state{receiver_pid = ReceiverPid} = State) ->
    hibernate_check({reply, ReceiverPid, State});

handle_call({monitor, Pid}, _, State) ->
    hibernate_check({reply, erlang:monitor(process, Pid), State});

handle_call({demonitor, MonitorRef}, _, State) ->
    hibernate_check({reply, erlang:demonitor(MonitorRef), State});

handle_call({demonitor, MonitorRef, Options}, _, State) ->
    hibernate_check({reply, erlang:demonitor(MonitorRef, Options), State});

handle_call(dispatcher, _,
            #state{dispatcher = Dispatcher} = State) ->
    hibernate_check({reply, Dispatcher, State});

handle_call({'subscribe', Suffix}, _,
            #state{prefix = Prefix,
                   receiver_pid = ReceiverPid,
                   options = #config_service_options{
                       count_process_dynamic = CountProcessDynamic,
                       scope = Scope}} = State) ->
    Result = case cloudi_core_i_rate_based_configuration:
                  count_process_dynamic_terminated(CountProcessDynamic) of
        false ->
            Pattern = Prefix ++ Suffix,
            _ = trie:is_pattern2_bytes(Pattern),
            cpg:join(Scope, Pattern,
                              ReceiverPid, infinity);
        true ->
            error
    end,
    hibernate_check({reply, Result, State});

handle_call({'subscribe_count', Suffix}, _,
            #state{prefix = Prefix,
                   receiver_pid = ReceiverPid,
                   options = #config_service_options{
                       scope = Scope}} = State) ->
    Pattern = Prefix ++ Suffix,
    _ = trie:is_pattern2_bytes(Pattern),
    Count = cpg:join_count(Scope, Pattern,
                                    ReceiverPid, infinity),
    hibernate_check({reply, Count, State});

handle_call({'unsubscribe', Suffix}, _,
            #state{prefix = Prefix,
                   receiver_pid = ReceiverPid,
                   options = #config_service_options{
                       count_process_dynamic = CountProcessDynamic,
                       scope = Scope}} = State) ->
    Result = case cloudi_core_i_rate_based_configuration:
                  count_process_dynamic_terminated(CountProcessDynamic) of
        false ->
            Pattern = Prefix ++ Suffix,
            _ = trie:is_pattern2_bytes(Pattern),
            cpg:leave(Scope, Pattern,
                               ReceiverPid, infinity);
        true ->
            error
    end,
    hibernate_check({reply, Result, State});

handle_call({'get_pid', Name}, Client,
            #state{timeout_sync = TimeoutSync} = State) ->
    handle_call({'get_pid', Name, TimeoutSync}, Client, State);

handle_call({'get_pid', Name, Timeout}, Client,
            #state{dest_deny = DestDeny,
                   dest_allow = DestAllow} = State) ->
    hibernate_check(case destination_allowed(Name, DestDeny, DestAllow) of
        true ->
            handle_get_pid(Name, Timeout, Client, State);
        false ->
            {reply, {error, timeout}, State}
    end);

handle_call({'get_pids', Name}, Client,
            #state{timeout_sync = TimeoutSync} = State) ->
    handle_call({'get_pids', Name, TimeoutSync}, Client, State);

handle_call({'get_pids', Name, Timeout}, Client,
            #state{dest_deny = DestDeny,
                   dest_allow = DestAllow} = State) ->
    hibernate_check(case destination_allowed(Name, DestDeny, DestAllow) of
        true ->
            handle_get_pids(Name, Timeout, Client, State);
        false ->
            {reply, {error, timeout}, State}
    end);

handle_call({'send_async', Name, RequestInfo, Request,
             undefined, Priority}, Client,
            #state{timeout_async = TimeoutAsync} = State) ->
    handle_call({'send_async', Name, RequestInfo, Request,
                 TimeoutAsync, Priority}, Client, State);

handle_call({'send_async', Name, RequestInfo, Request,
             Timeout, undefined}, Client,
            #state{options = #config_service_options{
                       priority_default = PriorityDefault}} = State) ->
    handle_call({'send_async', Name, RequestInfo, Request,
                 Timeout, PriorityDefault}, Client, State);

handle_call({'send_async', Name, RequestInfo, Request,
             Timeout, Priority}, Client,
            #state{dest_deny = DestDeny,
                   dest_allow = DestAllow} = State) ->
    true = trie:is_bytestring(Name),
    hibernate_check(case destination_allowed(Name, DestDeny, DestAllow) of
        true ->
            handle_send_async(Name, RequestInfo, Request,
                              Timeout, Priority, Client, State);
        false ->
            {reply, {error, timeout}, State}
    end);

handle_call({'send_async', Name, RequestInfo, Request,
             undefined, Priority, PatternPid}, Client,
            #state{timeout_async = TimeoutAsync} = State) ->
    handle_call({'send_async', Name, RequestInfo, Request,
                 TimeoutAsync, Priority, PatternPid}, Client, State);

handle_call({'send_async', Name, RequestInfo, Request,
             Timeout, undefined, PatternPid}, Client,
            #state{options = #config_service_options{
                       priority_default = PriorityDefault}} = State) ->
    handle_call({'send_async', Name, RequestInfo, Request,
                 Timeout, PriorityDefault, PatternPid}, Client, State);

handle_call({'send_async', Name, RequestInfo, Request,
             Timeout, Priority, {Pattern, Pid}}, _,
            State) ->
    true = trie:is_bytestring(Name),
    hibernate_check(handle_send_async_pid(Name, Pattern, RequestInfo, Request,
                                          Timeout, Priority, Pid, State));

handle_call({'send_async_active', Name, RequestInfo, Request,
             undefined, Priority}, Client,
            #state{timeout_async = TimeoutAsync} = State) ->
    handle_call({'send_async_active', Name, RequestInfo, Request,
                 TimeoutAsync, Priority}, Client, State);

handle_call({'send_async_active', Name, RequestInfo, Request,
             Timeout, undefined}, Client,
            #state{options = #config_service_options{
                       priority_default = PriorityDefault}} = State) ->
    handle_call({'send_async_active', Name, RequestInfo, Request,
                 Timeout, PriorityDefault}, Client, State);

handle_call({'send_async_active', Name, RequestInfo, Request,
             Timeout, Priority}, Client,
            #state{dest_deny = DestDeny,
                   dest_allow = DestAllow} = State) ->
    true = trie:is_bytestring(Name),
    hibernate_check(case destination_allowed(Name, DestDeny, DestAllow) of
        true ->
            handle_send_async_active(Name, RequestInfo, Request,
                                     Timeout, Priority, Client, State);
        false ->
            {reply, {error, timeout}, State}
    end);

handle_call({'send_async_active', Name, RequestInfo, Request,
             undefined, Priority, PatternPid}, Client,
            #state{timeout_async = TimeoutAsync} = State) ->
    handle_call({'send_async_active', Name, RequestInfo, Request,
                 TimeoutAsync, Priority, PatternPid}, Client, State);

handle_call({'send_async_active', Name, RequestInfo, Request,
             Timeout, undefined, PatternPid}, Client,
            #state{options = #config_service_options{
                       priority_default = PriorityDefault}} = State) ->
    handle_call({'send_async_active', Name, RequestInfo, Request,
                 Timeout, PriorityDefault, PatternPid}, Client, State);

handle_call({'send_async_active', Name, RequestInfo, Request,
             Timeout, Priority, {Pattern, Pid}}, _,
            State) ->
    true = trie:is_bytestring(Name),
    hibernate_check(handle_send_async_active_pid(Name, Pattern,
                                                 RequestInfo, Request,
                                                 Timeout, Priority,
                                                 undefined, Pid, State));

handle_call({'send_async_active', Name, RequestInfo, Request,
             undefined, Priority, TransId, PatternPid}, Client,
            #state{timeout_async = TimeoutAsync} = State) ->
    handle_call({'send_async_active', Name, RequestInfo, Request,
                 TimeoutAsync, Priority, TransId, PatternPid}, Client, State);

handle_call({'send_async_active', Name, RequestInfo, Request,
             Timeout, undefined, TransId, PatternPid}, Client,
            #state{options = #config_service_options{
                       priority_default = PriorityDefault}} = State) ->
    handle_call({'send_async_active', Name, RequestInfo, Request,
                 Timeout, PriorityDefault, TransId, PatternPid}, Client, State);

handle_call({'send_async_active', Name, RequestInfo, Request,
             Timeout, Priority, TransId, {Pattern, Pid}}, _,
            State) ->
    true = trie:is_bytestring(Name),
    hibernate_check(handle_send_async_active_pid(Name, Pattern,
                                                 RequestInfo, Request,
                                                 Timeout, Priority,
                                                 TransId, Pid, State));

handle_call({'send_sync', Name, RequestInfo, Request,
             undefined, Priority}, Client,
            #state{timeout_sync = TimeoutSync} = State) ->
    handle_call({'send_sync', Name, RequestInfo, Request,
                 TimeoutSync, Priority}, Client, State);

handle_call({'send_sync', Name, RequestInfo, Request,
             Timeout, undefined}, Client,
            #state{options = #config_service_options{
                       priority_default = PriorityDefault}} = State) ->
    handle_call({'send_sync', Name, RequestInfo, Request,
                 Timeout, PriorityDefault}, Client, State);

handle_call({'send_sync', Name, RequestInfo, Request,
             Timeout, Priority}, Client,
            #state{dest_deny = DestDeny,
                   dest_allow = DestAllow} = State) ->
    true = trie:is_bytestring(Name),
    hibernate_check(case destination_allowed(Name, DestDeny, DestAllow) of
        true ->
            handle_send_sync(Name, RequestInfo, Request,
                             Timeout, Priority, Client, State);
        false ->
            {reply, {error, timeout}, State}
    end);

handle_call({'send_sync', Name, RequestInfo, Request,
             undefined, Priority, PatternPid}, Client,
            #state{timeout_sync = TimeoutSync} = State) ->
    handle_call({'send_sync', Name, RequestInfo, Request,
                 TimeoutSync, Priority, PatternPid}, Client, State);

handle_call({'send_sync', Name, RequestInfo, Request,
             Timeout, undefined, PatternPid}, Client,
            #state{options = #config_service_options{
                       priority_default = PriorityDefault}} = State) ->
    handle_call({'send_sync', Name, RequestInfo, Request,
                 Timeout, PriorityDefault, PatternPid}, Client, State);

handle_call({'send_sync', Name, RequestInfo, Request,
             Timeout, Priority, {Pattern, Pid}}, Client,
            State) ->
    true = trie:is_bytestring(Name),
    hibernate_check(handle_send_sync_pid(Name, Pattern,
                                         RequestInfo, Request,
                                         Timeout, Priority,
                                         Pid, Client, State));

handle_call({'mcast_async', Name, RequestInfo, Request,
             undefined, Priority}, Client,
            #state{timeout_async = TimeoutAsync} = State) ->
    handle_call({'mcast_async', Name, RequestInfo, Request,
                 TimeoutAsync, Priority}, Client, State);

handle_call({'mcast_async', Name, RequestInfo, Request,
             Timeout, undefined}, Client,
            #state{options = #config_service_options{
                       priority_default = PriorityDefault}} = State) ->
    handle_call({'mcast_async', Name, RequestInfo, Request,
                 Timeout, PriorityDefault}, Client, State);

handle_call({'mcast_async', Name, RequestInfo, Request,
             Timeout, Priority}, Client,
            #state{dest_deny = DestDeny,
                   dest_allow = DestAllow} = State) ->
    true = trie:is_bytestring(Name),
    hibernate_check(case destination_allowed(Name, DestDeny, DestAllow) of
        true ->
            handle_mcast_async(Name, RequestInfo, Request,
                               Timeout, Priority, Client, State);
        false ->
            {reply, {error, timeout}, State}
    end);

handle_call({'mcast_async_active', Name, RequestInfo, Request,
             undefined, Priority}, Client,
            #state{timeout_async = TimeoutAsync} = State) ->
    handle_call({'mcast_async_active', Name, RequestInfo, Request,
                 TimeoutAsync, Priority}, Client, State);

handle_call({'mcast_async_active', Name, RequestInfo, Request,
             Timeout, undefined}, Client,
            #state{options = #config_service_options{
                       priority_default = PriorityDefault}} = State) ->
    handle_call({'mcast_async_active', Name, RequestInfo, Request,
                 Timeout, PriorityDefault}, Client, State);

handle_call({'mcast_async_active', Name, RequestInfo, Request,
             Timeout, Priority}, Client,
            #state{dest_deny = DestDeny,
                   dest_allow = DestAllow} = State) ->
    true = trie:is_bytestring(Name),
    hibernate_check(case destination_allowed(Name, DestDeny, DestAllow) of
        true ->
            handle_mcast_async_active(Name, RequestInfo, Request,
                                      Timeout, Priority, Client, State);
        false ->
            {reply, {error, timeout}, State}
    end);

handle_call({'recv_async', TransId, Consume}, Client,
            #state{timeout_sync = TimeoutSync} = State) ->
    handle_call({'recv_async', TimeoutSync, TransId, Consume}, Client, State);

handle_call({'recv_async', Timeout, TransId, Consume}, Client, State) ->
    hibernate_check(handle_recv_async(Timeout, TransId, Consume,
                                      Client, State));

handle_call({'recv_asyncs', Results, Consume}, Client,
            #state{timeout_sync = TimeoutSync} = State) ->
    handle_call({'recv_asyncs', TimeoutSync, Results, Consume},
                Client, State);

handle_call({'recv_asyncs', Timeout, Results, Consume}, Client, State) ->
    hibernate_check(handle_recv_asyncs(Timeout, Results, Consume,
                                       Client, State));

handle_call(prefix, _,
            #state{prefix = Prefix} = State) ->
    hibernate_check({reply, Prefix, State});

handle_call(timeout_async, _,
            #state{timeout_async = TimeoutAsync} = State) ->
    hibernate_check({reply, TimeoutAsync, State});

handle_call(timeout_sync, _,
            #state{timeout_sync = TimeoutSync} = State) ->
    hibernate_check({reply, TimeoutSync, State});

handle_call(priority_default, _,
            #state{options = #config_service_options{
                       priority_default = PriorityDefault}} = State) ->
    hibernate_check({reply, PriorityDefault, State});

handle_call(destination_refresh_immediate, _,
            #state{dest_refresh = DestRefresh} = State) ->
    Immediate = (DestRefresh =:= immediate_closest orelse
                 DestRefresh =:= immediate_furthest orelse
                 DestRefresh =:= immediate_random orelse
                 DestRefresh =:= immediate_local orelse
                 DestRefresh =:= immediate_remote orelse
                 DestRefresh =:= immediate_newest orelse
                 DestRefresh =:= immediate_oldest),
    hibernate_check({reply, Immediate, State});

handle_call(destination_refresh_lazy, _,
            #state{dest_refresh = DestRefresh} = State) ->
    Lazy = (DestRefresh =:= lazy_closest orelse
            DestRefresh =:= lazy_furthest orelse
            DestRefresh =:= lazy_random orelse
            DestRefresh =:= lazy_local orelse
            DestRefresh =:= lazy_remote orelse
            DestRefresh =:= lazy_newest orelse
            DestRefresh =:= lazy_oldest),
    hibernate_check({reply, Lazy, State});

handle_call(duo_mode, _,
            #state{options = #config_service_options{
                       duo_mode = DuoMode}} = State) ->
    hibernate_check({reply, DuoMode, State});

handle_call({source_subscriptions, Pid}, _,
            #state{options = #config_service_options{
                       scope = Scope}} = State) ->
    Subscriptions = cpg:which_groups(Scope, Pid, infinity),
    hibernate_check({reply, Subscriptions, State});

handle_call(context_options, _,
            #state{timeout_async = TimeoutAsync,
                   timeout_sync = TimeoutSync,
                   dest_refresh = DestRefresh,
                   uuid_generator = UUID,
                   cpg_data = Groups,
                   options = #config_service_options{
                       priority_default = PriorityDefault,
                       dest_refresh_start = DestRefreshStart,
                       dest_refresh_delay = DestRefreshDelay,
                       request_name_lookup = RequestNameLookup,
                       scope = Scope}} = State) ->
    Options = [{dest_refresh, DestRefresh},
               {dest_refresh_start, DestRefreshStart},
               {dest_refresh_delay, DestRefreshDelay},
               {request_name_lookup, RequestNameLookup},
               {timeout_async, TimeoutAsync},
               {timeout_sync, TimeoutSync},
               {priority_default, PriorityDefault},
               {uuid, UUID},
               {groups, Groups},
               {groups_scope, Scope}],
    hibernate_check({reply, Options, State});

handle_call(trans_id, _,
            #state{uuid_generator = UUID} = State) ->
    {TransId, UUIDNew} = uuid:get_v1(UUID),
    hibernate_check({reply, TransId, State#state{uuid_generator = UUIDNew}});

handle_call({get_status, Timeout}, _, State) ->
    hibernate_check({reply, sys_get_status(Timeout, State), State});

handle_call(Request, _, State) ->
    {stop, cloudi_string:format("Unknown call \"~w\"", [Request]),
     error, State}.

handle_cast(Request, State) ->
    {stop, cloudi_string:format("Unknown cast \"~w\"", [Request]), State}.

handle_info({'cloudi_service_request_success', RequestResponse,
             ServiceStateNew},
            #state{dispatcher = Dispatcher} = State) ->
    ok = handle_module_request_success(RequestResponse, Dispatcher),
    StateNew = State#state{service_state = ServiceStateNew},
    hibernate_check({noreply, process_queues(StateNew)});

handle_info({'cloudi_service_info_success',
             ServiceStateNew}, State) ->
    StateNew = State#state{service_state = ServiceStateNew},
    hibernate_check({noreply, process_queues(StateNew)});

handle_info({'cloudi_service_request_failure',
             Type, Error, Stack, ServiceStateNew}, State) ->
    Reason = if
        Type =:= stop ->
            true = Stack =:= undefined,
            case Error of
                shutdown ->
                    ?LOG_WARN("request stop shutdown", []);
                {shutdown, ShutdownReason} ->
                    ?LOG_WARN("request stop shutdown (~tp)",
                              [ShutdownReason]);
                _ ->
                    ?LOG_ERROR("request stop ~tp", [Error])
            end,
            Error;
        true ->
            ?LOG_ERROR("request ~tp ~tp~n~tp", [Type, Error, Stack]),
            {Type, {Error, Stack}}
    end,
    {stop, Reason, State#state{service_state = ServiceStateNew}};

handle_info({'cloudi_service_info_failure',
             Type, Error, Stack, ServiceStateNew}, State) ->
    Reason = if
        Type =:= stop ->
            true = Stack =:= undefined,
            case Error of
                shutdown ->
                    ?LOG_WARN("info stop shutdown", []);
                {shutdown, ShutdownReason} ->
                    ?LOG_WARN("info stop shutdown (~tp)",
                              [ShutdownReason]);
                _ ->
                    ?LOG_ERROR("info stop ~tp", [Error])
            end,
            Error;
        true ->
            ?LOG_ERROR("info ~tp ~tp~n~tp", [Type, Error, Stack]),
            {Type, {Error, Stack}}
    end,
    {stop, Reason, State#state{service_state = ServiceStateNew}};

handle_info({'cloudi_service_get_pid_retry', Name, Timeout, Client}, State) ->
    hibernate_check(handle_get_pid(Name, Timeout,
                                   Client, State));

handle_info({'cloudi_service_get_pids_retry', Name, Timeout, Client}, State) ->
    hibernate_check(handle_get_pids(Name, Timeout,
                                    Client, State));

handle_info({'cloudi_service_send_async_retry',
             Name, RequestInfo, Request, Timeout, Priority, Client}, State) ->
    hibernate_check(handle_send_async(Name, RequestInfo, Request,
                                      Timeout, Priority,
                                      Client, State));

handle_info({'cloudi_service_send_async_active_retry',
             Name, RequestInfo, Request, Timeout, Priority, Client}, State) ->
    hibernate_check(handle_send_async_active(Name, RequestInfo, Request,
                                             Timeout, Priority,
                                             Client, State));

handle_info({'cloudi_service_send_sync_retry',
             Name, RequestInfo, Request, Timeout, Priority, Client}, State) ->
    hibernate_check(handle_send_sync(Name, RequestInfo, Request,
                                     Timeout, Priority, Client, State));

handle_info({'cloudi_service_mcast_async_retry',
             Name, RequestInfo, Request, Timeout, Priority, Client}, State) ->
    hibernate_check(handle_mcast_async(Name, RequestInfo, Request,
                                       Timeout, Priority, Client, State));

handle_info({'cloudi_service_mcast_async_active_retry',
             Name, RequestInfo, Request, Timeout, Priority, Client}, State) ->
    hibernate_check(handle_mcast_async_active(Name, RequestInfo, Request,
                                              Timeout, Priority,
                                              Client, State));

handle_info({ForwardType, Name, Pattern,
             NameNext, RequestInfoNext, RequestNext,
             Timeout, Priority, TransId, Source},
            #state{dest_refresh = DestRefresh,
                   cpg_data = Groups,
                   dest_deny = DestDeny,
                   dest_allow = DestAllow,
                   options = #config_service_options{
                       request_name_lookup = RequestNameLookup,
                       response_timeout_immediate_max =
                           ResponseTimeoutImmediateMax,
                       scope = Scope}} = State)
    when ForwardType =:= 'cloudi_service_forward_async_retry';
         ForwardType =:= 'cloudi_service_forward_sync_retry' ->
    hibernate_check(case destination_allowed(NameNext, DestDeny, DestAllow) of
        true ->
            {SendType,
             ForwardRetryInterval} = if
                ForwardType =:= 'cloudi_service_forward_async_retry' ->
                    {'cloudi_service_send_async',
                     ?FORWARD_ASYNC_INTERVAL};
                ForwardType =:= 'cloudi_service_forward_sync_retry' ->
                    {'cloudi_service_send_sync',
                     ?FORWARD_SYNC_INTERVAL}
            end,
            case destination_get(DestRefresh, Scope, NameNext, Source,
                                 Groups, Timeout) of
                {error, timeout} ->
                    {noreply, State};
                {error, _} when RequestNameLookup =:= async ->
                    ok = return_null_response(SendType, Name, Pattern,
                                              Timeout, TransId, Source,
                                              ResponseTimeoutImmediateMax),
                    {noreply, State};
                {error, _} when Timeout >= ForwardRetryInterval ->
                    erlang:send_after(ForwardRetryInterval, self(),
                                      {ForwardType, Name, Pattern,
                                       NameNext, RequestInfoNext, RequestNext,
                                       Timeout - ForwardRetryInterval,
                                       Priority, TransId, Source}),
                    {nohibernate,
                     {noreply, State}};
                {error, _} ->
                    {noreply, State};
                {ok, PatternNext, PidNext} when Timeout >= ?FORWARD_DELTA ->
                    PidNext ! {SendType, NameNext, PatternNext,
                               RequestInfoNext, RequestNext,
                               Timeout - ?FORWARD_DELTA,
                               Priority, TransId, Source},
                    {noreply, State};
                _ ->
                    {noreply, State}
            end;
        false ->
            {noreply, State}
    end);

handle_info({'cloudi_service_recv_async_retry',
             Timeout, TransId, Consume, Client}, State) ->
    hibernate_check(handle_recv_async(Timeout, TransId, Consume,
                                      Client, State));

handle_info({'cloudi_service_recv_asyncs_retry',
             Timeout, Results, Consume, Client}, State) ->
    hibernate_check(handle_recv_asyncs(Timeout, Results, Consume,
                                       Client, State));

handle_info({SendType, Name, Pattern, RequestInfo, Request,
             Timeout, Priority, TransId, Source},
            #state{dispatcher = Dispatcher,
                   queue_requests = false,
                   module = Module,
                   service_state = ServiceState,
                   request_pid = RequestPid,
                   options = #config_service_options{
                       rate_request_max = RateRequest,
                       response_timeout_immediate_max =
                           ResponseTimeoutImmediateMax} = ConfigOptions
                   } = State)
    when SendType =:= 'cloudi_service_send_async';
         SendType =:= 'cloudi_service_send_sync' ->
    {RateRequestOk, RateRequestNew} = if
        RateRequest =/= undefined ->
            cloudi_core_i_rate_based_configuration:
            rate_request_max_request(RateRequest);
        true ->
            {true, RateRequest}
    end,
    if
        RateRequestOk =:= true ->
            Type = if
                SendType =:= 'cloudi_service_send_async' ->
                    'send_async';
                SendType =:= 'cloudi_service_send_sync' ->
                    'send_sync'
            end,
            ConfigOptionsNew =
                check_incoming(true, ConfigOptions#config_service_options{
                                         rate_request_max = RateRequestNew}),
            hibernate_check({noreply,
                             State#state{
                                 queue_requests = true,
                                 request_pid = handle_module_request_loop_pid(
                                     RequestPid,
                                     {'cloudi_service_request_loop',
                                      Type, Name, Pattern,
                                      RequestInfo, Request,
                                      Timeout, Priority, TransId, Source,
                                      ServiceState, Dispatcher,
                                      Module, ConfigOptionsNew},
                                     ConfigOptionsNew, Dispatcher),
                                 options = ConfigOptionsNew}});
        RateRequestOk =:= false ->
            ok = return_null_response(SendType, Name, Pattern,
                                      Timeout, TransId, Source,
                                      ResponseTimeoutImmediateMax),
            hibernate_check({noreply,
                             State#state{
                                 options = ConfigOptions#config_service_options{
                                     rate_request_max = RateRequestNew}}})
    end;

handle_info({SendType, Name, Pattern, _, _, 0, _, TransId, Source},
            #state{queue_requests = true,
                   options = #config_service_options{
                       response_timeout_immediate_max =
                           ResponseTimeoutImmediateMax}} = State)
    when SendType =:= 'cloudi_service_send_async';
         SendType =:= 'cloudi_service_send_sync' ->
    if
        0 =:= ResponseTimeoutImmediateMax ->
            ok = return_null_response(SendType, Name, Pattern,
                                      0, TransId, Source);
        true ->
            ok
    end,
    hibernate_check({noreply, State});

handle_info({SendType, Name, Pattern, _, _,
             Timeout, Priority, TransId, Source} = T,
            #state{queue_requests = true,
                   queued = Queue,
                   queued_size = QueuedSize,
                   queued_word_size = WordSize,
                   options = #config_service_options{
                       queue_limit = QueueLimit,
                       queue_size = QueueSize,
                       rate_request_max = RateRequest,
                       response_timeout_immediate_max =
                           ResponseTimeoutImmediateMax} = ConfigOptions
                   } = State)
    when SendType =:= 'cloudi_service_send_async';
         SendType =:= 'cloudi_service_send_sync' ->
    QueueLimitOk = if
        QueueLimit =/= undefined ->
            pqueue4:len(Queue) < QueueLimit;
        true ->
            true
    end,
    {QueueSizeOk, Size} = if
        QueueSize =/= undefined ->
            QueueElementSize = erlang_term:byte_size({0, T}, WordSize),
            {(QueuedSize + QueueElementSize) =< QueueSize, QueueElementSize};
        true ->
            {true, 0}
    end,
    {RateRequestOk, RateRequestNew} = if
        RateRequest =/= undefined ->
            cloudi_core_i_rate_based_configuration:
            rate_request_max_request(RateRequest);
        true ->
            {true, RateRequest}
    end,
    StateNew = State#state{
        options = ConfigOptions#config_service_options{
            rate_request_max = RateRequestNew}},
    hibernate_check(if
        QueueLimitOk, QueueSizeOk, RateRequestOk ->
            {noreply,
             recv_timeout_start(Timeout, Priority, TransId,
                                Size, T, StateNew)};
        true ->
            ok = return_null_response(SendType, Name, Pattern,
                                      Timeout, TransId, Source,
                                      ResponseTimeoutImmediateMax),
            {noreply, StateNew}
    end);

handle_info({'cloudi_service_recv_timeout', Priority, TransId, Size},
            #state{recv_timeouts = RecvTimeouts,
                   queue_requests = QueueRequests,
                   queued = Queue,
                   queued_size = QueuedSize} = State) ->
    {QueueNew, QueuedSizeNew} = if
        QueueRequests =:= true ->
            F = fun({_, {_, _, _, _, _, _, _, Id, _}}) -> Id == TransId end,
            {Removed,
             QueueNext} = pqueue4:remove_unique(F, Priority, Queue),
            QueuedSizeNext = if
                Removed =:= true ->
                    QueuedSize - Size;
                Removed =:= false ->
                    % false if a timer message was sent while cancelling
                    QueuedSize
            end,
            {QueueNext, QueuedSizeNext};
        true ->
            {Queue, QueuedSize}
    end,
    hibernate_check({noreply,
                     State#state{
                         recv_timeouts = maps:remove(TransId, RecvTimeouts),
                         queued = QueueNew,
                         queued_size = QueuedSizeNew}});

handle_info({'cloudi_service_return_async',
             Name, Pattern, ResponseInfo, Response,
             TimeoutOld, TransId, Source},
            #state{send_timeouts = SendTimeouts,
                   receiver_pid = ReceiverPid,
                   options = #config_service_options{
                       request_timeout_immediate_max =
                           RequestTimeoutImmediateMax,
                       response_timeout_adjustment =
                           ResponseTimeoutAdjustment}} = State) ->
    true = Source =:= ReceiverPid,
    hibernate_check(case maps:find(TransId, SendTimeouts) of
        error ->
            % send_async timeout already occurred
            {noreply, State};
        {ok, {active, Pid, Tref}}
            when ResponseInfo == <<>>, Response == <<>> ->
            if
                ResponseTimeoutAdjustment;
                TimeoutOld >= RequestTimeoutImmediateMax ->
                    cancel_timer_async(Tref);
                true ->
                    ok
            end,
            ReceiverPid ! {'timeout_async_active', TransId},
            {noreply, send_timeout_end(TransId, Pid, State)};
        {ok, {active, Pid, Tref}} ->
            Timeout = if
                ResponseTimeoutAdjustment;
                TimeoutOld >= RequestTimeoutImmediateMax ->
                    case erlang:cancel_timer(Tref) of
                        false ->
                            0;
                        V ->
                            V
                    end;
                true ->
                    TimeoutOld
            end,
            ReceiverPid ! {'return_async_active', Name, Pattern,
                           ResponseInfo, Response, Timeout, TransId},
            {noreply, send_timeout_end(TransId, Pid, State)};
        {ok, {passive, Pid, Tref}}
            when ResponseInfo == <<>>, Response == <<>> ->
            if
                ResponseTimeoutAdjustment;
                TimeoutOld >= RequestTimeoutImmediateMax ->
                    cancel_timer_async(Tref);
                true ->
                    ok
            end,
            {noreply, send_timeout_end(TransId, Pid, State)};
        {ok, {passive, Pid, Tref}} ->
            Timeout = if
                ResponseTimeoutAdjustment;
                TimeoutOld >= RequestTimeoutImmediateMax ->
                    case erlang:cancel_timer(Tref) of
                        false ->
                            0;
                        V ->
                            V
                    end;
                true ->
                    TimeoutOld
            end,
            {noreply, send_timeout_end(TransId, Pid,
                async_response_timeout_start(ResponseInfo, Response, Timeout,
                                             TransId, State))}
    end);

handle_info({'cloudi_service_return_sync',
             _, _, ResponseInfo, Response,
             TimeoutOld, TransId, Source},
            #state{send_timeouts = SendTimeouts,
                   receiver_pid = ReceiverPid,
                   options = #config_service_options{
                       request_timeout_immediate_max =
                           RequestTimeoutImmediateMax,
                       response_timeout_adjustment =
                           ResponseTimeoutAdjustment}} = State) ->
    true = Source =:= ReceiverPid,
    hibernate_check(case maps:find(TransId, SendTimeouts) of
        error ->
            % send_async timeout already occurred
            {noreply, State};
        {ok, {Client, Pid, Tref}} ->
            if
                ResponseTimeoutAdjustment;
                TimeoutOld >= RequestTimeoutImmediateMax ->
                    cancel_timer_async(Tref);
                true ->
                    ok
            end,
            if
                ResponseInfo == <<>>, Response == <<>> ->
                    gen_server:reply(Client, {error, timeout});
                ResponseInfo == <<>> ->
                    gen_server:reply(Client, {ok, Response});
                true ->
                    gen_server:reply(Client, {ok, ResponseInfo, Response})
            end,
            {noreply, send_timeout_end(TransId, Pid, State)}
    end);

handle_info({'cloudi_service_send_async_timeout', TransId},
            #state{send_timeouts = SendTimeouts,
                   receiver_pid = ReceiverPid} = State) ->
    hibernate_check(case maps:find(TransId, SendTimeouts) of
        error ->
            % timer may have sent before being cancelled
            {noreply, State};
        {ok, {active, Pid, _}} ->
            ReceiverPid ! {'timeout_async_active', TransId},
            {noreply, send_timeout_end(TransId, Pid, State)};
        {ok, {passive, Pid, _}} ->
            {noreply, send_timeout_end(TransId, Pid, State)}
    end);

handle_info({'cloudi_service_send_sync_timeout', TransId},
            #state{send_timeouts = SendTimeouts} = State) ->
    hibernate_check(case maps:find(TransId, SendTimeouts) of
        error ->
            % timer may have sent before being cancelled
            {noreply, State};
        {ok, {Client, Pid, _}} ->
            gen_server:reply(Client, {error, timeout}),
            {noreply, send_timeout_end(TransId, Pid, State)}
    end);

handle_info({'cloudi_service_recv_async_timeout', TransId},
            #state{async_responses = AsyncResponses} = State) ->
    hibernate_check({noreply,
                     State#state{
                         async_responses =
                             maps:remove(TransId, AsyncResponses)}});

handle_info({SendMinimalType, Name, RequestInfo, Request,
             Timeout, Destination, ReceiverPid},
            #state{uuid_generator = UUID,
                   dest_refresh = DestRefresh,
                   cpg_data = Groups,
                   dest_deny = DestDeny,
                   dest_allow = DestAllow,
                   options = #config_service_options{
                       priority_default = PriorityDefault,
                       request_name_lookup = RequestNameLookup,
                       scope = Scope}} = State)
    when SendMinimalType =:= 'cloudi_service_send_async_minimal';
         SendMinimalType =:= 'cloudi_service_send_sync_minimal' ->
    {SendType,
     SendRetryInterval} = if
        SendMinimalType =:= 'cloudi_service_send_async_minimal' ->
            {'cloudi_service_send_async',
             ?SEND_ASYNC_INTERVAL};
        SendMinimalType =:= 'cloudi_service_send_sync_minimal' ->
            {'cloudi_service_send_sync',
             ?SEND_SYNC_INTERVAL}
    end,
    hibernate_check(case Destination of
        {Pattern, Pid} ->
            {TransId, UUIDNew} = uuid:get_v1(UUID),
            ReceiverPid ! {SendMinimalType, TransId},
            Pid ! {SendType, Name, Pattern, RequestInfo, Request,
                   Timeout, PriorityDefault, TransId, ReceiverPid},
            {noreply, State#state{uuid_generator = UUIDNew}};
        undefined ->
            case destination_allowed(Name, DestDeny, DestAllow) of
                true ->
                    case destination_get(DestRefresh, Scope, Name, ReceiverPid,
                                         Groups, Timeout) of
                        {error, timeout} ->
                            ReceiverPid ! {SendMinimalType, timeout},
                            {noreply, State};
                        {error, _} when RequestNameLookup =:= async ->
                            ReceiverPid ! {SendMinimalType, timeout},
                            {noreply, State};
                        {error, _} when Timeout >= SendRetryInterval ->
                            erlang:send_after(SendRetryInterval, self(),
                                              {SendMinimalType,
                                               Name, RequestInfo, Request,
                                               Timeout - SendRetryInterval,
                                               Destination, ReceiverPid}),
                            {nohibernate,
                             {noreply, State}};
                        {error, _} ->
                            ReceiverPid ! {SendMinimalType, timeout},
                            {noreply, State};
                        {ok, Pattern, Pid} ->
                            {TransId, UUIDNew} = uuid:get_v1(UUID),
                            ReceiverPid ! {SendMinimalType, TransId},
                            Pid ! {SendType,
                                   Name, Pattern, RequestInfo, Request,
                                   Timeout, PriorityDefault,
                                   TransId, ReceiverPid},
                            {noreply, State#state{uuid_generator = UUIDNew}}
                    end;
                false ->
                    ReceiverPid ! {SendMinimalType, timeout},
                    {noreply, State}
            end
    end);

handle_info({cloudi_cpg_data, Groups},
            #state{dispatcher = Dispatcher,
                   dest_refresh = DestRefresh,
                   options = #config_service_options{
                       dest_refresh_delay = Delay,
                       scope = Scope}} = State) ->
    ok = destination_refresh(DestRefresh, Dispatcher, Delay, Scope),
    hibernate_check({noreply, State#state{cpg_data = Groups}});

handle_info('cloudi_hibernate_rate',
            #state{duo_mode_pid = undefined,
                   request_pid = RequestPid,
                   info_pid = InfoPid,
                   options = #config_service_options{
                       hibernate = Hibernate} = ConfigOptions} = State) ->
    {Value, HibernateNew} = cloudi_core_i_rate_based_configuration:
                            hibernate_reinit(Hibernate),
    HibernateMessage = {'cloudi_hibernate', Value},
    ok = pid_send(RequestPid, HibernateMessage),
    ok = pid_send(InfoPid, HibernateMessage),
    hibernate_check({noreply,
                     State#state{
                         options = ConfigOptions#config_service_options{
                             hibernate = HibernateNew}}});

handle_info({'cloudi_hibernate', Hibernate},
            #state{duo_mode_pid = DuoModePid,
                   options = ConfigOptions} = State) ->
    true = is_pid(DuoModePid),
    % force the hibernate state
    hibernate_check({noreply,
                     State#state{
                         options = ConfigOptions#config_service_options{
                             hibernate = Hibernate}}});

handle_info('cloudi_count_process_dynamic_rate',
            #state{dispatcher = Dispatcher,
                   duo_mode_pid = undefined,
                   options = #config_service_options{
                       count_process_dynamic =
                           CountProcessDynamic} = ConfigOptions} = State) ->
    CountProcessDynamicNew = cloudi_core_i_rate_based_configuration:
                             count_process_dynamic_reinit(Dispatcher,
                                                          CountProcessDynamic),
    hibernate_check({noreply,
                     State#state{
                         options = ConfigOptions#config_service_options{
                             count_process_dynamic =
                                 CountProcessDynamicNew}}});

handle_info({'cloudi_count_process_dynamic_update', ProcessCount}, State) ->
    hibernate_check({noreply, State#state{process_count = ProcessCount}});

handle_info('cloudi_count_process_dynamic_terminate',
            #state{receiver_pid = ReceiverPid,
                   options = #config_service_options{
                       count_process_dynamic = CountProcessDynamic,
                       scope = Scope} = ConfigOptions} = State) ->
    cpg:leave(Scope, ReceiverPid, infinity),
    CountProcessDynamicNew =
        cloudi_core_i_rate_based_configuration:
        count_process_dynamic_terminate_set(ReceiverPid, CountProcessDynamic),
    hibernate_check({noreply,
                     State#state{
                         options = ConfigOptions#config_service_options{
                             count_process_dynamic =
                                 CountProcessDynamicNew}}});

handle_info('cloudi_count_process_dynamic_terminate_check',
            #state{update_plan = UpdatePlan,
                   suspended = Suspended,
                   queue_requests = QueueRequests,
                   duo_mode_pid = undefined} = State) ->
    StopReason = {shutdown, cloudi_count_process_dynamic_terminate},
    StopDelayed = stop_delayed(UpdatePlan, Suspended, QueueRequests),
    if
        StopDelayed =:= false ->
            {stop, StopReason, State};
        StopDelayed =:= true ->
            hibernate_check({noreply, State#state{stop = StopReason}})
    end;

handle_info('cloudi_count_process_dynamic_terminate_now',
            #state{duo_mode_pid = undefined} = State) ->
    {stop, {shutdown, cloudi_count_process_dynamic_terminate}, State};

handle_info('cloudi_rate_request_max_rate',
            #state{duo_mode_pid = undefined,
                   options = #config_service_options{
                       rate_request_max =
                           RateRequest} = ConfigOptions} = State) ->
    RateRequestNew = cloudi_core_i_rate_based_configuration:
                     rate_request_max_reinit(RateRequest),
    hibernate_check({noreply,
                     State#state{
                         options = ConfigOptions#config_service_options{
                             rate_request_max = RateRequestNew}}});

handle_info({'EXIT', _, shutdown},
            #state{duo_mode_pid = DuoModePid} = State) ->
    % CloudI Service shutdown
    if
        is_pid(DuoModePid) ->
            erlang:exit(DuoModePid, shutdown);
        true ->
            ok
    end,
    {stop, shutdown, State};

handle_info({'EXIT', _, {shutdown, _} = Shutdown},
            #state{duo_mode_pid = DuoModePid} = State) ->
    % CloudI Service shutdown w/reason
    if
        is_pid(DuoModePid) ->
            erlang:exit(DuoModePid, shutdown);
        true ->
            ok
    end,
    {stop, Shutdown, State};

handle_info({'EXIT', _, restart},
            #state{duo_mode_pid = DuoModePid} = State) ->
    % CloudI Service API requested a restart
    if
        is_pid(DuoModePid) ->
            erlang:exit(DuoModePid, restart);
        true ->
            ok
    end,
    {stop, restart, State};

handle_info({'EXIT', DuoModePid, Reason},
            #state{duo_mode_pid = DuoModePid} = State) ->
    ?LOG_ERROR("~p duo_mode exited: ~tp", [DuoModePid, Reason]),
    {stop, Reason, State};

handle_info({'EXIT', RequestPid,
             {'cloudi_service_request_success', _RequestResponse,
              _ServiceStateNew} = Result},
            #state{request_pid = RequestPid} = State) ->
    handle_info(Result, State#state{request_pid = undefined});

handle_info({'EXIT', RequestPid,
             {'cloudi_service_request_failure',
              _Type, _Error, _Stack, _ServiceStateNew} = Result},
            #state{request_pid = RequestPid} = State) ->
    handle_info(Result, State#state{request_pid = undefined});

handle_info({'EXIT', RequestPid, 'cloudi_service_request_loop_exit'},
            #state{request_pid = RequestPid} = State) ->
    {noreply, State#state{request_pid = undefined}};

handle_info({'EXIT', RequestPid, Reason},
            #state{request_pid = RequestPid} = State) ->
    ?LOG_ERROR("~p request exited: ~tp", [RequestPid, Reason]),
    {stop, Reason, State};

handle_info({'EXIT', InfoPid,
             {'cloudi_service_info_success',
              _ServiceStateNew} = Result},
            #state{info_pid = InfoPid} = State) ->
    handle_info(Result, State#state{info_pid = undefined});

handle_info({'EXIT', InfoPid,
             {'cloudi_service_info_failure',
              _Type, _Error, _Stack, _ServiceStateNew} = Result},
            #state{info_pid = InfoPid} = State) ->
    handle_info(Result, State#state{info_pid = undefined});

handle_info({'EXIT', InfoPid, 'cloudi_service_info_loop_exit'},
            #state{info_pid = InfoPid} = State) ->
    {noreply, State#state{info_pid = undefined}};

handle_info({'EXIT', InfoPid, Reason},
            #state{info_pid = InfoPid} = State) ->
    ?LOG_ERROR("~p info exited: ~tp", [InfoPid, Reason]),
    {stop, Reason, State};

handle_info({'EXIT', Dispatcher, Reason},
            #state{dispatcher = Dispatcher} = State) ->
    ?LOG_ERROR("~p service exited: ~tp", [Dispatcher, Reason]),
    {stop, Reason, State};

handle_info({'EXIT', Pid, Reason}, State) ->
    ?LOG_ERROR("~p forced exit: ~tp", [Pid, Reason]),
    {stop, Reason, State};

handle_info({'cloudi_service_stop', Reason}, State) ->
    {stop, Reason, State};

handle_info('cloudi_service_fatal_timeout',
            #state{update_plan = UpdatePlan,
                   suspended = Suspended,
                   queue_requests = QueueRequests,
                   duo_mode_pid = undefined,
                   options = #config_service_options{
                       fatal_timeout_interrupt =
                           FatalTimeoutInterrupt}} = State) ->
    StopReason = fatal_timeout,
    StopDelayed = stop_delayed(UpdatePlan, FatalTimeoutInterrupt,
                               Suspended, QueueRequests),
    if
        StopDelayed =:= false ->
            {stop, StopReason, State};
        StopDelayed =:= true ->
            hibernate_check({noreply, State#state{stop = StopReason}})
    end;

handle_info({'cloudi_service_suspended', SuspendPending, Suspend},
            #state{dispatcher = Dispatcher,
                   suspended = SuspendedOld,
                   queue_requests = QueueRequests,
                   service_state = ServiceState,
                   duo_mode_pid = undefined,
                   options = Options} = State) ->
    hibernate_check(case suspended_change(SuspendedOld, Suspend,
                                          SuspendPending, Dispatcher,
                                          QueueRequests, ServiceState,
                                          Options) of
        undefined ->
            {noreply, State};
        {#suspended{processing = false} = SuspendedNew,
         false, ServiceStateNew} ->
            StateNew = State#state{suspended = SuspendedNew,
                                   service_state = ServiceStateNew},
            {noreply,
             process_queues(StateNew)};
        {SuspendedNew, QueueRequestsNew, ServiceStateNew} ->
            {noreply,
             State#state{suspended = SuspendedNew,
                         queue_requests = QueueRequestsNew,
                         service_state = ServiceStateNew}}
    end);

handle_info({'cloudi_service_update', UpdatePending, UpdatePlan},
            #state{dispatcher = Dispatcher,
                   update_plan = undefined,
                   suspended = Suspended,
                   queue_requests = QueueRequests,
                   duo_mode_pid = undefined} = State) ->
    #config_service_update{sync = Sync} = UpdatePlan,
    ProcessBusy = case Suspended of
        #suspended{processing = true,
                   busy = SuspendedWhileBusy} ->
            SuspendedWhileBusy;
        #suspended{processing = false} ->
            QueueRequests
    end,
    UpdatePlanNew = if
        Sync =:= true, ProcessBusy =:= true ->
            UpdatePlan#config_service_update{update_pending = UpdatePending,
                                             process_busy = ProcessBusy};
        true ->
            UpdatePending ! {'cloudi_service_update', Dispatcher},
            UpdatePlan#config_service_update{process_busy = ProcessBusy}
    end,
    hibernate_check({noreply, State#state{update_plan = UpdatePlanNew,
                                          queue_requests = true}});

handle_info({'cloudi_service_update_now', UpdateNow, UpdateStart},
            #state{update_plan = UpdatePlan,
                   duo_mode_pid = undefined} = State) ->
    #config_service_update{process_busy = ProcessBusy} = UpdatePlan,
    UpdatePlanNew = UpdatePlan#config_service_update{
                        update_now = UpdateNow,
                        update_start = UpdateStart},
    StateNew = State#state{update_plan = UpdatePlanNew},
    if
        ProcessBusy =:= true ->
            hibernate_check({noreply, StateNew});
        ProcessBusy =:= false ->
            hibernate_check({noreply, process_update(StateNew)})
    end;

handle_info({'cloudi_service_update_state', UpdatePlan},
            #state{duo_mode_pid = DuoModePid} = State) ->
    true = is_pid(DuoModePid),
    StateNew = update_state(State, UpdatePlan),
    hibernate_check({noreply, StateNew});

handle_info({'cloudi_service_init_execute', Args, Timeout,
             ProcessDictionary, State},
            #state{dispatcher = Dispatcher,
                   queue_requests = true,
                   module = Module,
                   prefix = Prefix,
                   duo_mode_pid = undefined,
                   options = #config_service_options{
                       aspects_init_after = Aspects,
                       init_pid_options = PidOptions}} = State) ->
    ok = initialize_wait(Timeout),
    {ok, DispatcherProxy} = cloudi_core_i_services_internal_init:
                            start_link(Timeout, PidOptions,
                                       ProcessDictionary, State),
    Result = try Module:cloudi_service_init(Args, Prefix, Timeout,
                                            DispatcherProxy) of
        {ok, ServiceStateInit} ->
            aspects_init_after(Aspects, Args, Prefix, Timeout,
                               ServiceStateInit, DispatcherProxy);
        {stop, _, _} = Stop ->
            Stop;
        {stop, _} = Stop ->
            Stop
    catch
        ErrorType:Error:ErrorStackTrace ->
            ?LOG_ERROR_SYNC("init ~tp ~tp~n~tp",
                            [ErrorType, Error, ErrorStackTrace]),
            {stop, {ErrorType, {Error, ErrorStackTrace}}}
    end,
    {ProcessDictionaryNew,
     #state{options = ConfigOptions} = StateNext} =
        cloudi_core_i_services_internal_init:
        stop_link(DispatcherProxy),
    ok = cloudi_core_i_services_internal_init:
         process_dictionary_set(ProcessDictionaryNew),
    hibernate_check(case Result of
        {ok, ServiceStateNew} ->
            ConfigOptionsNew = check_init_receive(ConfigOptions),
            false = erlang:process_flag(trap_exit, true),
            ok = cloudi_core_i_services_monitor:
                 process_init_end(Dispatcher),
            StateNew = StateNext#state{service_state = ServiceStateNew,
                                       options = ConfigOptionsNew},
            {noreply, process_queues(StateNew)};
        {stop, Reason, ServiceState} ->
            {stop, Reason, StateNext#state{service_state = ServiceState,
                                           duo_mode_pid = undefined}};
        {stop, Reason} ->
            {stop, Reason, StateNext#state{service_state = undefined,
                                           duo_mode_pid = undefined}}
    end);

handle_info({'cloudi_service_init_state', ProcessDictionaryNew, StateNew},
            #state{duo_mode_pid = DuoModePid}) ->
    true = is_pid(DuoModePid),
    ok = cloudi_core_i_services_internal_init:
         process_dictionary_set(ProcessDictionaryNew),
    false = erlang:process_flag(trap_exit, true),
    hibernate_check({noreply, StateNew});

handle_info({'DOWN', _MonitorRef, process, Pid, _Info} = Request, State) ->
    case send_timeout_dead(Pid, State) of
        {true, StateNew} ->
            hibernate_check({noreply, StateNew});
        {false, #state{duo_mode_pid = DuoModePid} = StateNew} ->
            if
                DuoModePid =:= undefined ->
                    handle_info_message(Request, StateNew);
                is_pid(DuoModePid) ->
                    DuoModePid ! Request,
                    hibernate_check({noreply, StateNew})
            end
    end;

handle_info({ReplyRef, _}, State) when is_reference(ReplyRef) ->
    % gen_server:call/3 had a timeout exception that was caught but the
    % reply arrived later and must be discarded
    hibernate_check({noreply, State});

handle_info(Request, #state{duo_mode_pid = DuoModePid} = State) ->
    if
        DuoModePid =:= undefined ->
            handle_info_message(Request, State);
        is_pid(DuoModePid) ->
            % should never happen, but random code could
            % send random messages to the dispatcher Erlang process
            ?LOG_ERROR("Unknown info \"~w\"", [Request]),
            hibernate_check({noreply, State})
    end.

terminate(Reason,
          #state{dispatcher = Dispatcher,
                 module = Module,
                 service_state = ServiceState,
                 timeout_term = TimeoutTerm,
                 duo_mode_pid = undefined,
                 options = #config_service_options{
                     aspects_terminate_before = Aspects}} = State) ->
    ok = cloudi_core_i_services_monitor:
         process_terminate_begin(Dispatcher, Reason),
    ServiceStateNew = aspects_terminate_before(Aspects, Reason, TimeoutTerm,
                                               ServiceState),
    _ = Module:cloudi_service_terminate(Reason, TimeoutTerm, ServiceStateNew),
    ok = terminate_pids(Reason, State),
    ok;

terminate(_, _) ->
    ok.

terminate_pids(normal,
               #state{request_pid = RequestPid,
                      info_pid = InfoPid,
                      options = #config_service_options{
                          monkey_chaos = MonkeyChaos}}) ->
    ok = pid_send(RequestPid, {'cloudi_service_request_loop_exit', false}),
    ok = pid_send(InfoPid, {'cloudi_service_info_loop_exit', false}),
    ok = cloudi_core_i_runtime_testing:monkey_chaos_destroy(MonkeyChaos);
terminate_pids(_, _) ->
    ok.

code_change(_, State, _) ->
    {ok, State}.

-ifdef(ERLANG_OTP_VERSION_27_FEATURES).
format_status(Status) ->
    maps:update_with(state, fun format_status_state/1, Status).
-else.
format_status(_Opt, [_PDict, State]) ->
    [{data, [{"State", format_status_state(State)}]}].
-endif.

-ifdef(VERBOSE_STATE).
format_status_state(#state{} = State) ->
    State.
-else.
format_status_state(#state{send_timeouts = SendTimeouts,
                           send_timeout_monitors = SendTimeoutMonitors,
                           recv_timeouts = RecvTimeouts,
                           async_responses = AsyncResponses,
                           queued = Queue,
                           queued_info = QueueInfo,
                           cpg_data = Groups,
                           dest_deny = DestDeny,
                           dest_allow = DestAllow,
                           options = ConfigOptions} = State) ->
    RecvTimeoutsNew = if
        RecvTimeouts =:= undefined ->
            undefined;
        true ->
            maps:to_list(RecvTimeouts)
    end,
    QueueNew = if
        Queue =:= undefined ->
            undefined;
        true ->
            pqueue4:to_plist(Queue)
    end,
    QueueInfoNew = if
        QueueInfo =:= undefined ->
            undefined;
        true ->
            queue:to_list(QueueInfo)
    end,
    GroupsNew = case Groups of
        undefined ->
            undefined;
        {GroupsDictI, GroupsData} ->
            GroupsDictI:to_list(GroupsData)
    end,
    DestDenyNew = if
        DestDeny =:= undefined ->
            undefined;
        true ->
            trie:to_list(DestDeny)
    end,
    DestAllowNew = if
        DestAllow =:= undefined ->
            undefined;
        true ->
            trie:to_list(DestAllow)
    end,
    ConfigOptionsNew = cloudi_core_i_configuration:
                       services_format_options_internal(ConfigOptions),
    State#state{send_timeouts = maps:to_list(SendTimeouts),
                send_timeout_monitors = maps:to_list(SendTimeoutMonitors),
                recv_timeouts = RecvTimeoutsNew,
                async_responses = maps:to_list(AsyncResponses),
                queued = QueueNew,
                queued_info = QueueInfoNew,
                cpg_data = GroupsNew,
                dest_deny = DestDenyNew,
                dest_allow = DestAllowNew,
                options = ConfigOptionsNew}.
-endif.

%%%------------------------------------------------------------------------
%%% Private functions
%%%------------------------------------------------------------------------

initialize_wait(Timeout) ->
    receive
        cloudi_service_init_begin ->
            ok
    after
        Timeout ->
            erlang:exit(timeout)
    end.

handle_get_pid(Name, Timeout, Client,
               #state{receiver_pid = ReceiverPid,
                      dest_refresh = DestRefresh,
                      cpg_data = Groups,
                      options = #config_service_options{
                          request_name_lookup = RequestNameLookup,
                          scope = Scope}} = State) ->
    case destination_get(DestRefresh, Scope, Name, ReceiverPid,
                         Groups, Timeout) of
        {error, timeout} ->
            gen_server:reply(Client, {error, timeout}),
            {noreply, State};
        {error, _} when RequestNameLookup =:= async ->
            gen_server:reply(Client, {error, timeout}),
            {noreply, State};
        {error, _} when Timeout >= ?SEND_SYNC_INTERVAL ->
            erlang:send_after(?SEND_SYNC_INTERVAL, self(),
                              {'cloudi_service_get_pid_retry',
                               Name, Timeout - ?SEND_SYNC_INTERVAL, Client}),
            {nohibernate,
             {noreply, State}};
        {error, _} ->
            gen_server:reply(Client, {error, timeout}),
            {noreply, State};
        {ok, Pattern, Pid} ->
            gen_server:reply(Client, {ok, {Pattern, Pid}}),
            {noreply, State}
    end.

handle_get_pids(Name, Timeout, Client,
                #state{receiver_pid = ReceiverPid,
                       dest_refresh = DestRefresh,
                       cpg_data = Groups,
                       options = #config_service_options{
                           request_name_lookup = RequestNameLookup,
                           scope = Scope}} = State) ->
    case destination_all(DestRefresh, Scope, Name, ReceiverPid,
                         Groups, Timeout) of
        {error, timeout} ->
            gen_server:reply(Client, {error, timeout}),
            {noreply, State};
        {error, _} when RequestNameLookup =:= async ->
            gen_server:reply(Client, {error, timeout}),
            {noreply, State};
        {error, _} when Timeout >= ?SEND_SYNC_INTERVAL ->
            erlang:send_after(?SEND_SYNC_INTERVAL, self(),
                              {'cloudi_service_get_pids_retry',
                               Name, Timeout - ?SEND_SYNC_INTERVAL, Client}),
            {nohibernate,
             {noreply, State}};
        {error, _} ->
            gen_server:reply(Client, {error, timeout}),
            {noreply, State};
        {ok, Pattern, Pids} ->
            gen_server:reply(Client,
                             {ok, [{Pattern, Pid} || Pid <- Pids]}),
            {noreply, State}
    end.

handle_send_async(Name, RequestInfo, Request,
                  Timeout, Priority, Client,
                  #state{receiver_pid = ReceiverPid,
                         uuid_generator = UUID,
                         dest_refresh = DestRefresh,
                         cpg_data = Groups,
                         options = #config_service_options{
                             request_name_lookup = RequestNameLookup,
                             scope = Scope}} = State) ->
    case destination_get(DestRefresh, Scope, Name, ReceiverPid,
                         Groups, Timeout) of
        {error, timeout} ->
            gen_server:reply(Client, {error, timeout}),
            {noreply, State};
        {error, _} when RequestNameLookup =:= async ->
            gen_server:reply(Client, {error, timeout}),
            {noreply, State};
        {error, _} when Timeout >= ?SEND_ASYNC_INTERVAL ->
            erlang:send_after(?SEND_ASYNC_INTERVAL, self(),
                              {'cloudi_service_send_async_retry',
                               Name, RequestInfo, Request,
                               Timeout - ?SEND_ASYNC_INTERVAL,
                               Priority, Client}),
            {nohibernate,
             {noreply, State}};
        {error, _} ->
            gen_server:reply(Client, {error, timeout}),
            {noreply, State};
        {ok, Pattern, Pid} ->
            {TransId, UUIDNew} = uuid:get_v1(UUID),
            Pid ! {'cloudi_service_send_async',
                   Name, Pattern, RequestInfo, Request,
                   Timeout, Priority, TransId, ReceiverPid},
            gen_server:reply(Client, {ok, TransId}),
            {noreply,
             send_async_timeout_start(Timeout, TransId, Pid,
                                      State#state{uuid_generator = UUIDNew})}
    end.

handle_send_async_pid(Name, Pattern, RequestInfo, Request,
                      Timeout, Priority, Pid,
                      #state{receiver_pid = ReceiverPid,
                             uuid_generator = UUID} = State) ->
    {TransId, UUIDNew} = uuid:get_v1(UUID),
    Pid ! {'cloudi_service_send_async',
           Name, Pattern, RequestInfo, Request,
           Timeout, Priority, TransId, ReceiverPid},
    {reply, {ok, TransId},
     send_async_timeout_start(Timeout, TransId, Pid,
                              State#state{uuid_generator = UUIDNew})}.

handle_send_async_active(Name, RequestInfo, Request,
                         Timeout, Priority, Client,
                         #state{receiver_pid = ReceiverPid,
                                uuid_generator = UUID,
                                dest_refresh = DestRefresh,
                                cpg_data = Groups,
                                options = #config_service_options{
                                    request_name_lookup = RequestNameLookup,
                                    scope = Scope}} = State) ->
    case destination_get(DestRefresh, Scope, Name, ReceiverPid,
                         Groups, Timeout) of
        {error, timeout} ->
            gen_server:reply(Client, {error, timeout}),
            {noreply, State};
        {error, _} when RequestNameLookup =:= async ->
            gen_server:reply(Client, {error, timeout}),
            {noreply, State};
        {error, _} when Timeout >= ?SEND_ASYNC_INTERVAL ->
            erlang:send_after(?SEND_ASYNC_INTERVAL, self(),
                              {'cloudi_service_send_async_active_retry',
                               Name, RequestInfo, Request,
                               Timeout - ?SEND_ASYNC_INTERVAL,
                               Priority, Client}),
            {nohibernate,
             {noreply, State}};
        {error, _} ->
            gen_server:reply(Client, {error, timeout}),
            {noreply, State};
        {ok, Pattern, Pid} ->
            {TransId, UUIDNew} = uuid:get_v1(UUID),
            Pid ! {'cloudi_service_send_async',
                   Name, Pattern, RequestInfo, Request,
                   Timeout, Priority, TransId, ReceiverPid},
            gen_server:reply(Client, {ok, TransId}),
            {noreply,
             send_async_active_timeout_start(Timeout, TransId, Pid,
                                             State#state{
                                                 uuid_generator = UUIDNew})}
    end.

handle_send_async_active_pid(Name, Pattern, RequestInfo, Request,
                             Timeout, Priority, TransIdOld, Pid,
                             #state{receiver_pid = ReceiverPid,
                                    uuid_generator = UUID} = State) ->
    {TransId, UUIDNew} = if
        TransIdOld =:= undefined ->
            uuid:get_v1(UUID);
        true ->
            {TransIdOld, UUID}
    end,
    Pid ! {'cloudi_service_send_async',
           Name, Pattern, RequestInfo, Request,
           Timeout, Priority, TransId, ReceiverPid},
    {reply, {ok, TransId},
     send_async_active_timeout_start(Timeout, TransId, Pid,
                                     State#state{uuid_generator = UUIDNew})}.

handle_send_sync(Name, RequestInfo, Request,
                 Timeout, Priority, Client,
                 #state{receiver_pid = ReceiverPid,
                        uuid_generator = UUID,
                        dest_refresh = DestRefresh,
                        cpg_data = Groups,
                        options = #config_service_options{
                            request_name_lookup = RequestNameLookup,
                            scope = Scope}} = State) ->
    case destination_get(DestRefresh, Scope, Name, ReceiverPid,
                         Groups, Timeout) of
        {error, timeout} ->
            gen_server:reply(Client, {error, timeout}),
            {noreply, State};
        {error, _} when RequestNameLookup =:= async ->
            gen_server:reply(Client, {error, timeout}),
            {noreply, State};
        {error, _} when Timeout >= ?SEND_SYNC_INTERVAL ->
            erlang:send_after(?SEND_SYNC_INTERVAL, self(),
                              {'cloudi_service_send_sync_retry',
                               Name, RequestInfo, Request,
                               Timeout - ?SEND_SYNC_INTERVAL,
                               Priority, Client}),
            {nohibernate,
             {noreply, State}};
        {error, _} ->
            gen_server:reply(Client, {error, timeout}),
            {noreply, State};
        {ok, Pattern, Pid} ->
            {TransId, UUIDNew} = uuid:get_v1(UUID),
            Pid ! {'cloudi_service_send_sync',
                   Name, Pattern, RequestInfo, Request,
                   Timeout, Priority, TransId, ReceiverPid},
            {noreply,
             send_sync_timeout_start(Timeout, TransId, Pid, Client,
                                     State#state{uuid_generator = UUIDNew})}
    end.

handle_send_sync_pid(Name, Pattern, RequestInfo, Request,
                     Timeout, Priority, Pid, Client,
                     #state{receiver_pid = ReceiverPid,
                            uuid_generator = UUID} = State) ->
    {TransId, UUIDNew} = uuid:get_v1(UUID),
    Pid ! {'cloudi_service_send_sync',
           Name, Pattern, RequestInfo, Request,
           Timeout, Priority, TransId, ReceiverPid},
    {noreply,
     send_sync_timeout_start(Timeout, TransId, Pid, Client,
                             State#state{uuid_generator = UUIDNew})}.

handle_mcast_async_pids(_Name, _Pattern, _RequestInfo, _Request,
                        _Timeout, _Priority,
                        TransIdList, [], Client,
                        State) ->
    gen_server:reply(Client, {ok, lists:reverse(TransIdList)}),
    State;

handle_mcast_async_pids(Name, Pattern, RequestInfo, Request,
                        Timeout, Priority,
                        TransIdList, [Pid | PidList], Client,
                        #state{receiver_pid = ReceiverPid,
                               uuid_generator = UUID} = State) ->
    {TransId, UUIDNew} = uuid:get_v1(UUID),
    Pid ! {'cloudi_service_send_async',
           Name, Pattern, RequestInfo, Request,
           Timeout, Priority, TransId, ReceiverPid},
    StateNew = send_async_timeout_start(Timeout,
                                        TransId,
                                        Pid,
                                        State#state{uuid_generator = UUIDNew}),
    handle_mcast_async_pids(Name, Pattern, RequestInfo, Request,
                            Timeout, Priority,
                            [TransId | TransIdList], PidList, Client,
                            StateNew).

handle_mcast_async(Name, RequestInfo, Request,
                   Timeout, Priority, Client,
                   #state{receiver_pid = ReceiverPid,
                          dest_refresh = DestRefresh,
                          cpg_data = Groups,
                          options = #config_service_options{
                              request_name_lookup = RequestNameLookup,
                              scope = Scope}} = State) ->
    case destination_all(DestRefresh, Scope, Name, ReceiverPid,
                         Groups, Timeout) of
        {error, timeout} ->
            gen_server:reply(Client, {error, timeout}),
            {noreply, State};
        {error, _} when RequestNameLookup =:= async ->
            gen_server:reply(Client, {error, timeout}),
            {noreply, State};
        {error, _} when Timeout >= ?MCAST_ASYNC_INTERVAL ->
            erlang:send_after(?MCAST_ASYNC_INTERVAL, self(),
                              {'cloudi_service_mcast_async_retry',
                               Name, RequestInfo, Request,
                               Timeout - ?MCAST_ASYNC_INTERVAL,
                               Priority, Client}),
            {nohibernate,
             {noreply, State}};
        {error, _} ->
            gen_server:reply(Client, {error, timeout}),
            {noreply, State};
        {ok, Pattern, PidList} ->
            {noreply,
             handle_mcast_async_pids(Name, Pattern, RequestInfo, Request,
                                     Timeout, Priority,
                                     [], PidList, Client, State)}
    end.

handle_mcast_async_pids_active(_Name, _Pattern, _RequestInfo, _Request,
                               _Timeout, _Priority,
                               TransIdList, [], Client,
                               State) ->
    gen_server:reply(Client, {ok, lists:reverse(TransIdList)}),
    State;

handle_mcast_async_pids_active(Name, Pattern, RequestInfo, Request,
                               Timeout, Priority,
                               TransIdList, [Pid | PidList], Client,
                               #state{receiver_pid = ReceiverPid,
                                      uuid_generator = UUID} = State) ->
    {TransId, UUIDNew} = uuid:get_v1(UUID),
    Pid ! {'cloudi_service_send_async',
           Name, Pattern, RequestInfo, Request,
           Timeout, Priority, TransId, ReceiverPid},
    StateNew = send_async_active_timeout_start(Timeout, TransId, Pid,
                                               State#state{
                                                   uuid_generator = UUIDNew}),
    handle_mcast_async_pids_active(Name, Pattern, RequestInfo, Request,
                                   Timeout, Priority,
                                   [TransId | TransIdList], PidList, Client,
                                   StateNew).

handle_mcast_async_active(Name, RequestInfo, Request,
                          Timeout, Priority, Client,
                          #state{receiver_pid = ReceiverPid,
                                 dest_refresh = DestRefresh,
                                 cpg_data = Groups,
                                 options = #config_service_options{
                                     request_name_lookup = RequestNameLookup,
                                     scope = Scope}} = State) ->
    case destination_all(DestRefresh, Scope, Name, ReceiverPid,
                         Groups, Timeout) of
        {error, timeout} ->
            gen_server:reply(Client, {error, timeout}),
            {noreply, State};
        {error, _} when RequestNameLookup =:= async ->
            gen_server:reply(Client, {error, timeout}),
            {noreply, State};
        {error, _} when Timeout >= ?MCAST_ASYNC_INTERVAL ->
            erlang:send_after(?MCAST_ASYNC_INTERVAL, self(),
                              {'cloudi_service_mcast_async_active_retry',
                               Name, RequestInfo, Request,
                               Timeout - ?MCAST_ASYNC_INTERVAL,
                               Priority, Client}),
            {nohibernate,
             {noreply, State}};
        {error, _} ->
            gen_server:reply(Client, {error, timeout}),
            {noreply, State};
        {ok, Pattern, PidList} ->
            {noreply,
             handle_mcast_async_pids_active(Name, Pattern, RequestInfo, Request,
                                            Timeout, Priority,
                                            [], PidList, Client, State)}
    end.

handle_recv_async(Timeout, <<0:128>> = TransId, Consume, Client,
                  #state{async_responses = AsyncResponses} = State) ->
    case maps:to_list(AsyncResponses) of
        [] when Timeout >= ?RECV_ASYNC_INTERVAL ->
            erlang:send_after(?RECV_ASYNC_INTERVAL, self(),
                              {'cloudi_service_recv_async_retry',
                               Timeout - ?RECV_ASYNC_INTERVAL,
                               TransId, Consume, Client}),
            {nohibernate,
             {noreply, State}};
        [] ->
            gen_server:reply(Client, {error, timeout}),
            {noreply, State};
        L when Consume =:= true ->
            TransIdPick = ?RECV_ASYNC_STRATEGY(L),
            {{ResponseInfo, Response},
             AsyncResponsesNew} = maps:take(TransIdPick, AsyncResponses),
            gen_server:reply(Client, {ok, ResponseInfo, Response, TransIdPick}),
            {noreply, State#state{async_responses = AsyncResponsesNew}};
        L when Consume =:= false ->
            TransIdPick = ?RECV_ASYNC_STRATEGY(L),
            {ResponseInfo, Response} = maps:get(TransIdPick,
                                                AsyncResponses),
            gen_server:reply(Client, {ok, ResponseInfo, Response, TransIdPick}),
            {noreply, State}
    end;

handle_recv_async(Timeout, TransId, Consume, Client,
                  #state{async_responses = AsyncResponses} = State) ->
    case maps:find(TransId, AsyncResponses) of
        error when Timeout >= ?RECV_ASYNC_INTERVAL ->
            erlang:send_after(?RECV_ASYNC_INTERVAL, self(),
                              {'cloudi_service_recv_async_retry',
                               Timeout - ?RECV_ASYNC_INTERVAL,
                               TransId, Consume, Client}),
            {nohibernate,
             {noreply, State}};
        error ->
            gen_server:reply(Client, {error, timeout}),
            {noreply, State};
        {ok, {ResponseInfo, Response}} when Consume =:= true ->
            gen_server:reply(Client, {ok, ResponseInfo, Response, TransId}),
            {noreply,
             State#state{
                 async_responses = maps:remove(TransId,
                                               AsyncResponses)}};
        {ok, {ResponseInfo, Response}} when Consume =:= false ->
            gen_server:reply(Client, {ok, ResponseInfo, Response, TransId}),
            {noreply, State}
    end.

handle_recv_asyncs(Timeout, Results, Consume, Client,
                   #state{async_responses = AsyncResponses} = State) ->
    case recv_asyncs_pick(Results, Consume, AsyncResponses) of
        {true, _, ResultsNew, AsyncResponsesNew} ->
            gen_server:reply(Client, {ok, ResultsNew}),
            {noreply, State#state{async_responses = AsyncResponsesNew}};
        {false, _, ResultsNew, AsyncResponsesNew}
            when Timeout >= ?RECV_ASYNC_INTERVAL ->
            erlang:send_after(?RECV_ASYNC_INTERVAL, self(),
                              {'cloudi_service_recv_asyncs_retry',
                               Timeout - ?RECV_ASYNC_INTERVAL,
                               ResultsNew, Consume, Client}),
            {nohibernate,
             {noreply, State#state{async_responses = AsyncResponsesNew}}};
        {false, false, ResultsNew, AsyncResponsesNew} ->
            gen_server:reply(Client, {ok, ResultsNew}),
            {noreply, State#state{async_responses = AsyncResponsesNew}};
        {false, true, _, _} ->
            gen_server:reply(Client, {error, timeout}),
            {noreply, State}
    end.

handle_module_request(Type, Name, Pattern, RequestInfo, Request,
                      Timeout, Priority, TransId, Source,
                      ServiceState, Dispatcher, Module,
                      #config_service_options{
                          request_timeout_adjustment =
                              RequestTimeoutAdjustment,
                          aspects_request_before =
                              AspectsBefore,
                          aspects_request_after =
                              AspectsAfter} = ConfigOptions) ->
    RequestTimeoutF = request_timeout_adjustment_f(RequestTimeoutAdjustment),
    case aspects_request_before(AspectsBefore, Type,
                                Name, Pattern, RequestInfo, Request,
                                Timeout, Priority, TransId, Source,
                                ServiceState, Dispatcher) of
        {ok, ServiceStateNext} ->
            case handle_module_request_f(Type, Name, Pattern,
                                         RequestInfo, Request,
                                         Timeout, Priority, TransId, Source,
                                         ServiceStateNext, Dispatcher, Module,
                                         ConfigOptions) of
                {'cloudi_service_request_success',
                 {ReturnType, NameNext, PatternNext,
                  ResponseInfo, Response,
                  TimeoutNext, TransId, Source},
                 ServiceStateNew}
                when ReturnType =:= 'cloudi_service_return_async';
                     ReturnType =:= 'cloudi_service_return_sync' ->
                    Result = {reply, ResponseInfo, Response},
                    case aspects_request_after(AspectsAfter, Type,
                                               Name, Pattern,
                                               RequestInfo, Request,
                                               Timeout, Priority,
                                               TransId, Source,
                                               Result, ServiceStateNew,
                                               Dispatcher) of
                        {ok, ServiceStateFinal} ->
                            TimeoutNew = if
                                TimeoutNext == Timeout ->
                                    RequestTimeoutF(Timeout);
                                true ->
                                    TimeoutNext
                            end,
                            {'cloudi_service_request_success',
                             {ReturnType, NameNext, PatternNext,
                              ResponseInfo, Response,
                              TimeoutNew, TransId, Source},
                             ServiceStateFinal};
                        {stop, Reason, ServiceStateFinal} ->
                            {'cloudi_service_request_failure',
                             stop, Reason, undefined, ServiceStateFinal}
                    end;
                {'cloudi_service_request_success',
                 {ForwardType, Name, Pattern,
                  NameNext, RequestInfoNext, RequestNext,
                  TimeoutNext, PriorityNext, TransId, Source},
                 ServiceStateNew}
                when ForwardType =:= 'cloudi_service_forward_async_retry';
                     ForwardType =:= 'cloudi_service_forward_sync_retry' ->
                    Result = {forward, NameNext,
                              RequestInfoNext, RequestNext,
                              TimeoutNext, PriorityNext},
                    case aspects_request_after(AspectsAfter, Type,
                                               Name, Pattern,
                                               RequestInfo, Request,
                                               Timeout, Priority,
                                               TransId, Source,
                                               Result, ServiceStateNew,
                                               Dispatcher) of
                        {ok, ServiceStateFinal} ->
                            TimeoutNew = if
                                TimeoutNext == Timeout ->
                                    RequestTimeoutF(Timeout);
                                true ->
                                    TimeoutNext
                            end,
                            {'cloudi_service_request_success',
                             {ForwardType, Name, Pattern,
                              NameNext, RequestInfoNext, RequestNext,
                              TimeoutNew, PriorityNext, TransId, Source},
                             ServiceStateFinal};
                        {stop, Reason, ServiceStateFinal} ->
                            {'cloudi_service_request_failure',
                             stop, Reason, undefined, ServiceStateFinal}
                    end;
                {'cloudi_service_request_success',
                 undefined,
                 ServiceStateNew} ->
                    Result = noreply,
                    case aspects_request_after(AspectsAfter, Type,
                                               Name, Pattern,
                                               RequestInfo, Request,
                                               Timeout, Priority,
                                               TransId, Source,
                                               Result, ServiceStateNew,
                                               Dispatcher) of
                        {ok, ServiceStateFinal} ->
                            {'cloudi_service_request_success',
                             undefined,
                             ServiceStateFinal};
                        {stop, Reason, ServiceStateFinal} ->
                            {'cloudi_service_request_failure',
                             stop, Reason, undefined, ServiceStateFinal}
                    end;
                {'cloudi_service_request_failure', _, _, _, _} = Error ->
                    Error
            end;
        {stop, Reason, ServiceStateNext} ->
            {'cloudi_service_request_failure',
             stop, Reason, undefined, ServiceStateNext}
    end.

handle_module_request_f('send_async', Name, Pattern, RequestInfo, Request,
                        Timeout, Priority, TransId, Source,
                        ServiceState, Dispatcher, Module,
                        #config_service_options{
                            response_timeout_immediate_max =
                                ResponseTimeoutImmediateMax,
                            fatal_exceptions =
                                FatalExceptions}) ->
    try Module:cloudi_service_handle_request('send_async',
                                             Name, Pattern,
                                             RequestInfo, Request,
                                             Timeout, Priority,
                                             TransId, Source,
                                             ServiceState,
                                             Dispatcher) of
        {reply, <<>>, ServiceStateNew} ->
            if
                Timeout < ResponseTimeoutImmediateMax ->
                    {'cloudi_service_request_success',
                     undefined, ServiceStateNew};
                true ->
                    {'cloudi_service_request_success',
                     {'cloudi_service_return_async', Name, Pattern,
                      <<>>, <<>>, Timeout, TransId, Source},
                     ServiceStateNew}
            end;
        {reply, Response, ServiceStateNew} ->
            {'cloudi_service_request_success',
             {'cloudi_service_return_async', Name, Pattern,
              <<>>, Response, Timeout, TransId, Source},
             ServiceStateNew};
        {reply, <<>>, <<>>, ServiceStateNew} ->
            if
                Timeout < ResponseTimeoutImmediateMax ->
                    {'cloudi_service_request_success',
                     undefined, ServiceStateNew};
                true ->
                    {'cloudi_service_request_success',
                     {'cloudi_service_return_async', Name, Pattern,
                      <<>>, <<>>, Timeout, TransId, Source},
                     ServiceStateNew}
            end;
        {reply, ResponseInfo, Response, ServiceStateNew} ->
            {'cloudi_service_request_success',
             {'cloudi_service_return_async', Name, Pattern,
              ResponseInfo, Response, Timeout, TransId, Source},
             ServiceStateNew};
        {forward, _, _, _, TimeoutNext, PriorityNext, ServiceStateNew}
            when PriorityNext < ?PRIORITY_HIGH;
                 PriorityNext > ?PRIORITY_LOW;
                 TimeoutNext < 0 ->
            try erlang:exit(badarg)
            catch
                exit:badarg:ErrorStackTrace ->
                    {'cloudi_service_request_failure',
                     exit, badarg, ErrorStackTrace, ServiceStateNew}
            end;
        {forward, NameNext, RequestInfoNext, RequestNext,
                  TimeoutNext, PriorityNext, ServiceStateNew} ->
            {'cloudi_service_request_success',
             {'cloudi_service_forward_async_retry', Name, Pattern,
              NameNext, RequestInfoNext, RequestNext,
              TimeoutNext, PriorityNext, TransId, Source},
             ServiceStateNew};
        {forward, NameNext, RequestInfoNext, RequestNext,
                  ServiceStateNew} ->
            {'cloudi_service_request_success',
             {'cloudi_service_forward_async_retry', Name, Pattern,
              NameNext, RequestInfoNext, RequestNext,
              Timeout, Priority, TransId, Source},
             ServiceStateNew};
        {noreply, ServiceStateNew} ->
            {'cloudi_service_request_success', undefined, ServiceStateNew};
        {stop, Reason, ServiceStateNew} ->
            {'cloudi_service_request_failure',
             stop, Reason, undefined, ServiceStateNew}
    catch
        throw:{cloudi_service_return, {<<>>}} ->
            if
                Timeout < ResponseTimeoutImmediateMax ->
                    {'cloudi_service_request_success',
                     undefined, ServiceState};
                true ->
                    {'cloudi_service_request_success',
                     {'cloudi_service_return_async', Name, Pattern,
                      <<>>, <<>>, Timeout, TransId, Source},
                     ServiceState}
            end;
        throw:{cloudi_service_return, {Response}} ->
            {'cloudi_service_request_success',
             {'cloudi_service_return_async', Name, Pattern,
              <<>>, Response, Timeout, TransId, Source},
             ServiceState};
        throw:{cloudi_service_return, {<<>>, <<>>}} ->
            if
                Timeout < ResponseTimeoutImmediateMax ->
                    {'cloudi_service_request_success',
                     undefined, ServiceState};
                true ->
                    {'cloudi_service_request_success',
                     {'cloudi_service_return_async', Name, Pattern,
                      <<>>, <<>>, Timeout, TransId, Source},
                     ServiceState}
            end;
        throw:{cloudi_service_return, {ResponseInfo, Response}} ->
            {'cloudi_service_request_success',
             {'cloudi_service_return_async', Name, Pattern,
              ResponseInfo, Response,
              Timeout, TransId, Source},
             ServiceState};
        throw:{cloudi_service_return,
               {ReturnType, Name, Pattern,
                ResponseInfo, Response,
                TimeoutNext, TransId, Source}}
            when ReturnType =:= 'cloudi_service_return_async' ->
            if
                ResponseInfo == <<>>, Response == <<>> ->
                    if
                        TimeoutNext < ResponseTimeoutImmediateMax ->
                            {'cloudi_service_request_success',
                             undefined, ServiceState};
                        true ->
                            {'cloudi_service_request_success',
                             {ReturnType, Name, Pattern,
                              <<>>, <<>>, TimeoutNext, TransId, Source},
                             ServiceState}
                    end;
                true ->
                    {'cloudi_service_request_success',
                     {ReturnType, Name, Pattern,
                      ResponseInfo, Response,
                      TimeoutNext, TransId, Source},
                     ServiceState}
            end;
        throw:{cloudi_service_forward,
               {ForwardType, NameNext,
                RequestInfoNext, RequestNext,
                TimeoutNext, PriorityNext, TransId, Source}}
            when ForwardType =:= 'cloudi_service_forward_async_retry' ->
            {'cloudi_service_request_success',
             {ForwardType, Name, Pattern,
              NameNext, RequestInfoNext, RequestNext,
              TimeoutNext, PriorityNext, TransId, Source},
             ServiceState};
        ErrorType:Error:ErrorStackTrace ->
            if
                FatalExceptions =:= true ->
                    {'cloudi_service_request_failure',
                     ErrorType, Error, ErrorStackTrace, ServiceState};
                FatalExceptions =:= false ->
                    ?LOG_ERROR("request exception ~tp ~tp~n~tp",
                               [ErrorType, Error, ErrorStackTrace]),
                    {'cloudi_service_request_success',
                     {'cloudi_service_return_async', Name, Pattern,
                      <<>>, <<>>, Timeout, TransId, Source},
                     ServiceState}
            end
    end;

handle_module_request_f('send_sync', Name, Pattern, RequestInfo, Request,
                        Timeout, Priority, TransId, Source,
                        ServiceState, Dispatcher, Module,
                        #config_service_options{
                            response_timeout_immediate_max =
                                ResponseTimeoutImmediateMax,
                            fatal_exceptions =
                                FatalExceptions}) ->
    try Module:cloudi_service_handle_request('send_sync',
                                             Name, Pattern,
                                             RequestInfo, Request,
                                             Timeout, Priority,
                                             TransId, Source,
                                             ServiceState,
                                             Dispatcher) of
        {reply, <<>>, ServiceStateNew} ->
            if
                Timeout < ResponseTimeoutImmediateMax ->
                    {'cloudi_service_request_success',
                     undefined, ServiceStateNew};
                true ->
                    {'cloudi_service_request_success',
                     {'cloudi_service_return_sync', Name, Pattern,
                      <<>>, <<>>, Timeout, TransId, Source},
                     ServiceStateNew}
            end;
        {reply, Response, ServiceStateNew} ->
            {'cloudi_service_request_success',
             {'cloudi_service_return_sync', Name, Pattern,
              <<>>, Response, Timeout, TransId, Source},
             ServiceStateNew};
        {reply, <<>>, <<>>, ServiceStateNew} ->
            if
                Timeout < ResponseTimeoutImmediateMax ->
                    {'cloudi_service_request_success',
                     undefined, ServiceStateNew};
                true ->
                    {'cloudi_service_request_success',
                     {'cloudi_service_return_sync', Name, Pattern,
                      <<>>, <<>>, Timeout, TransId, Source},
                     ServiceStateNew}
            end;
        {reply, ResponseInfo, Response, ServiceStateNew} ->
            {'cloudi_service_request_success',
             {'cloudi_service_return_sync', Name, Pattern,
              ResponseInfo, Response, Timeout, TransId, Source},
             ServiceStateNew};
        {forward, _, _, _, TimeoutNext, PriorityNext, ServiceStateNew}
            when PriorityNext < ?PRIORITY_HIGH;
                 PriorityNext > ?PRIORITY_LOW;
                 TimeoutNext < 0 ->
            try erlang:exit(badarg)
            catch
                exit:badarg:ErrorStackTrace ->
                    {'cloudi_service_request_failure',
                     exit, badarg, ErrorStackTrace, ServiceStateNew}
            end;
        {forward, NameNext, RequestInfoNext, RequestNext,
                  TimeoutNext, PriorityNext, ServiceStateNew} ->
            {'cloudi_service_request_success',
             {'cloudi_service_forward_sync_retry', Name, Pattern,
              NameNext, RequestInfoNext, RequestNext,
              TimeoutNext, PriorityNext, TransId, Source},
             ServiceStateNew};
        {forward, NameNext, RequestInfoNext, RequestNext,
                  ServiceStateNew} ->
            {'cloudi_service_request_success',
             {'cloudi_service_forward_sync_retry', Name, Pattern,
              NameNext, RequestInfoNext, RequestNext,
              Timeout, Priority, TransId, Source},
             ServiceStateNew};
        {noreply, ServiceStateNew} ->
            {'cloudi_service_request_success', undefined, ServiceStateNew};
        {stop, Reason, ServiceStateNew} ->
            {'cloudi_service_request_failure',
             stop, Reason, undefined, ServiceStateNew}
    catch
        throw:{cloudi_service_return, {<<>>}} ->
            if
                Timeout < ResponseTimeoutImmediateMax ->
                    {'cloudi_service_request_success',
                     undefined, ServiceState};
                true ->
                    {'cloudi_service_request_success',
                     {'cloudi_service_return_sync', Name, Pattern,
                      <<>>, <<>>, Timeout, TransId, Source},
                     ServiceState}
            end;
        throw:{cloudi_service_return, {Response}} ->
            {'cloudi_service_request_success',
             {'cloudi_service_return_sync', Name, Pattern,
              <<>>, Response, Timeout, TransId, Source},
             ServiceState};
        throw:{cloudi_service_return, {<<>>, <<>>}} ->
            if
                Timeout < ResponseTimeoutImmediateMax ->
                    {'cloudi_service_request_success',
                     undefined, ServiceState};
                true ->
                    {'cloudi_service_request_success',
                     {'cloudi_service_return_sync', Name, Pattern,
                      <<>>, <<>>, Timeout, TransId, Source},
                     ServiceState}
            end;
        throw:{cloudi_service_return, {ResponseInfo, Response}} ->
            {'cloudi_service_request_success',
             {'cloudi_service_return_sync', Name, Pattern,
              ResponseInfo, Response,
              Timeout, TransId, Source},
             ServiceState};
        throw:{cloudi_service_return,
               {ReturnType, Name, Pattern,
                ResponseInfo, Response,
                TimeoutNext, TransId, Source}}
            when ReturnType =:= 'cloudi_service_return_sync' ->
            if
                ResponseInfo == <<>>, Response == <<>> ->
                    if
                        TimeoutNext < ResponseTimeoutImmediateMax ->
                            {'cloudi_service_request_success',
                             undefined, ServiceState};
                        true ->
                            {'cloudi_service_request_success',
                             {ReturnType, Name, Pattern,
                              <<>>, <<>>, TimeoutNext, TransId, Source},
                             ServiceState}
                    end;
                true ->
                    {'cloudi_service_request_success',
                     {ReturnType, Name, Pattern,
                      ResponseInfo, Response,
                      TimeoutNext, TransId, Source},
                     ServiceState}
            end;
        throw:{cloudi_service_forward,
               {ForwardType, NameNext,
                RequestInfoNext, RequestNext,
                TimeoutNext, PriorityNext, TransId, Source}}
            when ForwardType =:= 'cloudi_service_forward_sync_retry' ->
            {'cloudi_service_request_success',
             {ForwardType, Name, Pattern,
              NameNext, RequestInfoNext, RequestNext,
              TimeoutNext, PriorityNext, TransId, Source},
             ServiceState};
        ErrorType:Error:ErrorStackTrace ->
            if
                FatalExceptions =:= true ->
                    {'cloudi_service_request_failure',
                     ErrorType, Error, ErrorStackTrace, ServiceState};
                FatalExceptions =:= false ->
                    ?LOG_ERROR("request exception ~tp ~tp~n~tp",
                               [ErrorType, Error, ErrorStackTrace]),
                    {'cloudi_service_request_success',
                     {'cloudi_service_return_sync', Name, Pattern,
                      <<>>, <<>>, Timeout, TransId, Source},
                     ServiceState}
            end
    end.

handle_module_request_success(undefined, _) ->
    ok;
handle_module_request_success({ReturnType, _, _, _, _, _, _, Source} = T, _)
    when ReturnType =:= 'cloudi_service_return_async';
         ReturnType =:= 'cloudi_service_return_sync' ->
    Source ! T,
    ok;
handle_module_request_success({ForwardType, _, _,
                               NameNext, _, _, _, _, _, _} = T,
                              Dispatcher)
    when ForwardType =:= 'cloudi_service_forward_async_retry';
         ForwardType =:= 'cloudi_service_forward_sync_retry' ->
    true = trie:is_bytestring(NameNext),
    Dispatcher ! T,
    ok.

handle_module_info(Request, ServiceState, Dispatcher, Module,
                   #config_service_options{
                       aspects_info_before =
                           AspectsBefore,
                       aspects_info_after =
                           AspectsAfter}) ->
    case aspects_info_before(AspectsBefore, Request,
                             ServiceState, Dispatcher) of
        {ok, ServiceStateNext} ->
            try Module:cloudi_service_handle_info(Request,
                                                  ServiceStateNext,
                                                  Dispatcher) of
                {noreply, ServiceStateNew} ->
                    case aspects_info_after(AspectsAfter, Request,
                                            ServiceStateNew, Dispatcher) of
                        {ok, ServiceStateFinal} ->
                            {'cloudi_service_info_success',
                             ServiceStateFinal};
                        {stop, Reason, ServiceStateFinal} ->
                            {'cloudi_service_info_failure',
                             stop, Reason, undefined,
                             ServiceStateFinal}
                    end;
                {stop, Reason, ServiceStateNew} ->
                    {'cloudi_service_info_failure',
                     stop, Reason, undefined, ServiceStateNew}
            catch
                ErrorType:Error:ErrorStackTrace ->
                    {'cloudi_service_info_failure',
                     ErrorType, Error, ErrorStackTrace, ServiceState}
            end;
        {stop, Reason, ServiceStateNext} ->
            {'cloudi_service_info_failure',
             stop, Reason, undefined, ServiceStateNext}
    end.

send_async_active_timeout_start(Timeout, TransId, Pid,
                                #state{dispatcher = Dispatcher,
                                       send_timeouts = SendTimeouts,
                                       send_timeout_monitors =
                                           SendTimeoutMonitors,
                                       options = #config_service_options{
                                           request_timeout_immediate_max =
                                               RequestTimeoutImmediateMax}} =
                                    State)
    when is_integer(Timeout), is_binary(TransId), is_pid(Pid),
         Timeout >= RequestTimeoutImmediateMax ->
    SendTimeoutMonitorsNew = case maps:find(Pid, SendTimeoutMonitors) of
        {ok, {MonitorRef, TransIdList}} ->
            maps:put(Pid,
                     {MonitorRef,
                      lists:umerge(TransIdList, [TransId])},
                     SendTimeoutMonitors);
        error ->
            MonitorRef = erlang:monitor(process, Pid),
            maps:put(Pid, {MonitorRef, [TransId]}, SendTimeoutMonitors)
    end,
    State#state{
        send_timeouts = maps:put(TransId,
            {active, Pid,
             erlang:send_after(Timeout, Dispatcher,
                               {'cloudi_service_send_async_timeout', TransId})},
            SendTimeouts),
        send_timeout_monitors = SendTimeoutMonitorsNew};

send_async_active_timeout_start(Timeout, TransId, _Pid,
                                #state{dispatcher = Dispatcher,
                                       send_timeouts = SendTimeouts} = State)
    when is_integer(Timeout), is_binary(TransId) ->
    State#state{
        send_timeouts = maps:put(TransId,
            {active, undefined,
             erlang:send_after(Timeout, Dispatcher,
                               {'cloudi_service_send_async_timeout', TransId})},
            SendTimeouts)}.

recv_timeout_start(Timeout, Priority, TransId, Size, T,
                   #state{recv_timeouts = RecvTimeouts,
                          queued = Queue,
                          queued_size = QueuedSize,
                          receiver_pid = ReceiverPid} = State)
    when is_integer(Timeout), is_integer(Priority), is_binary(TransId) ->
    State#state{
        recv_timeouts = maps:put(TransId,
            erlang:send_after(Timeout, ReceiverPid,
                {'cloudi_service_recv_timeout', Priority, TransId, Size}),
            RecvTimeouts),
        queued = pqueue4:in({Size, T}, Priority, Queue),
        queued_size = QueuedSize + Size}.

duo_recv_timeout_start(Timeout, Priority, TransId, Size, T,
                       #state_duo{duo_mode_pid = DuoModePid,
                                  recv_timeouts = RecvTimeouts,
                                  queued = Queue,
                                  queued_size = QueuedSize} = State)
    when is_integer(Timeout), is_integer(Priority), is_binary(TransId) ->
    State#state_duo{
        recv_timeouts = maps:put(TransId,
            erlang:send_after(Timeout, DuoModePid,
                {'cloudi_service_recv_timeout', Priority, TransId, Size}),
            RecvTimeouts),
        queued = pqueue4:in({Size, T}, Priority, Queue),
        queued_size = QueuedSize + Size}.

recv_asyncs_pick(Results, Consume, AsyncResponses) ->
    recv_asyncs_pick(Results, [], true, false, Consume, AsyncResponses).

recv_asyncs_pick([], L, Done, FoundOne, _Consume, AsyncResponsesNew) ->
    {Done, not FoundOne, lists:reverse(L), AsyncResponsesNew};

recv_asyncs_pick([{<<>>, <<>>, TransId} = Entry | Results], L,
                 Done, FoundOne, Consume, AsyncResponses) ->
    case maps:find(TransId, AsyncResponses) of
        error ->
            recv_asyncs_pick(Results,
                             [Entry | L],
                             false, FoundOne, Consume, AsyncResponses);
        {ok, {ResponseInfo, Response}} ->
            AsyncResponsesNew = if
                Consume =:= true ->
                    maps:remove(TransId, AsyncResponses);
                Consume =:= false ->
                    AsyncResponses
            end,
            recv_asyncs_pick(Results,
                             [{ResponseInfo, Response, TransId} | L],
                             Done, true, Consume, AsyncResponsesNew)
    end;

recv_asyncs_pick([{_, _, _} = Entry | Results], L,
                 Done, _FoundOne, Consume, AsyncResponses) ->
    recv_asyncs_pick(Results, [Entry | L],
                     Done, true, Consume, AsyncResponses).

process_queue(#state{dispatcher = Dispatcher,
                     recv_timeouts = RecvTimeouts,
                     queue_requests = true,
                     queued = Queue,
                     queued_size = QueuedSize,
                     module = Module,
                     service_state = ServiceState,
                     request_pid = RequestPid,
                     options = ConfigOptions} = State) ->
    case pqueue4:out(Queue) of
        {empty, QueueNew} ->
            State#state{queue_requests = false,
                        queued = QueueNew};
        {{value,
          {Size,
           {'cloudi_service_send_async', Name, Pattern,
            RequestInfo, Request,
            _, Priority, TransId, Source}}}, QueueNew} ->
            {RecvTimer,
             RecvTimeoutsNew} = maps:take(TransId, RecvTimeouts),
            Timeout = case erlang:cancel_timer(RecvTimer) of
                false ->
                    0;
                V ->
                    V
            end,
            ConfigOptionsNew = check_incoming(true, ConfigOptions),
            State#state{
                recv_timeouts = RecvTimeoutsNew,
                queued = QueueNew,
                queued_size = QueuedSize - Size,
                request_pid = handle_module_request_loop_pid(RequestPid,
                    {'cloudi_service_request_loop',
                     'send_async', Name, Pattern,
                     RequestInfo, Request,
                     Timeout, Priority, TransId, Source,
                     ServiceState, Dispatcher,
                     Module, ConfigOptionsNew}, ConfigOptionsNew, Dispatcher),
                options = ConfigOptionsNew};
        {{value,
          {Size,
           {'cloudi_service_send_sync', Name, Pattern,
            RequestInfo, Request,
            _, Priority, TransId, Source}}}, QueueNew} ->
            {RecvTimer,
             RecvTimeoutsNew} = maps:take(TransId, RecvTimeouts),
            Timeout = case erlang:cancel_timer(RecvTimer) of
                false ->
                    0;
                V ->
                    V
            end,
            ConfigOptionsNew = check_incoming(true, ConfigOptions),
            State#state{
                recv_timeouts = RecvTimeoutsNew,
                queued = QueueNew,
                queued_size = QueuedSize - Size,
                request_pid = handle_module_request_loop_pid(RequestPid,
                    {'cloudi_service_request_loop',
                     'send_sync', Name, Pattern,
                     RequestInfo, Request,
                     Timeout, Priority, TransId, Source,
                     ServiceState, Dispatcher,
                     Module, ConfigOptionsNew}, ConfigOptionsNew, Dispatcher),
                options = ConfigOptionsNew}
    end.

handle_info_message(Request,
                    #state{queue_requests = true,
                           queued_info = QueueInfo,
                           duo_mode_pid = undefined} = State) ->
    hibernate_check({noreply,
                     State#state{
                         queued_info = queue:in(Request, QueueInfo)}});
handle_info_message(Request,
                    #state{dispatcher = Dispatcher,
                           module = Module,
                           service_state = ServiceState,
                           info_pid = InfoPid,
                           duo_mode_pid = undefined,
                           options = ConfigOptions} = State) ->
    ConfigOptionsNew = check_incoming(false, ConfigOptions),
    hibernate_check({noreply,
                     State#state{
                         queue_requests = true,
                         info_pid = handle_module_info_loop_pid(InfoPid,
                             {'cloudi_service_info_loop',
                              Request, ServiceState, Dispatcher,
                              Module, ConfigOptionsNew},
                              ConfigOptionsNew, Dispatcher),
                         options = ConfigOptionsNew}}).

process_queue_info(#state{dispatcher = Dispatcher,
                          queue_requests = true,
                          queued_info = QueueInfo,
                          module = Module,
                          service_state = ServiceState,
                          info_pid = InfoPid,
                          options = ConfigOptions} = State) ->
    case queue:out(QueueInfo) of
        {empty, QueueInfoNew} ->
            State#state{queue_requests = false,
                        queued_info = QueueInfoNew};
        {{value, Request}, QueueInfoNew} ->
            ConfigOptionsNew = check_incoming(false, ConfigOptions),
            State#state{
                queued_info = QueueInfoNew,
                info_pid = handle_module_info_loop_pid(InfoPid,
                    {'cloudi_service_info_loop',
                     Request, ServiceState, Dispatcher,
                     Module, ConfigOptionsNew}, ConfigOptionsNew, Dispatcher),
                options = ConfigOptionsNew}
    end.

process_update(#state{dispatcher = Dispatcher,
                      update_plan = UpdatePlan,
                      service_state = ServiceState} = State) ->
    #config_service_update{update_now = UpdateNow,
                           process_busy = false} = UpdatePlan,
    StateNew = case update(ServiceState, State, UpdatePlan) of
        {ok, ServiceStateNext, StateNext} ->
            UpdateNow ! {'cloudi_service_update_now', Dispatcher, ok},
            StateNext#state{service_state = ServiceStateNext};
        {error, _} = Error ->
            UpdateNow ! {'cloudi_service_update_now', Dispatcher, Error},
            State
    end,
    process_queues(StateNew#state{update_plan = undefined}).

process_queues(#state{dispatcher = Dispatcher,
                      stop = StopReason,
                      update_plan = UpdatePlan,
                      suspended = #suspended{
                          processing = Processing} = Suspended,
                      service_state = ServiceState,
                      options = Options} = State)
    when Processing orelse
         UpdatePlan /= undefined orelse
         StopReason /= undefined ->
    {SuspendedNew,
     ServiceStateNew} = suspended_idle(Suspended, ServiceState, Options),
    case update_now(UpdatePlan, Dispatcher) of
        {true, UpdatePlanNew} ->
            process_update(State#state{update_plan = UpdatePlanNew,
                                       suspended = SuspendedNew,
                                       service_state = ServiceStateNew});
        {false, undefined} when StopReason /= undefined ->
            Dispatcher ! {'cloudi_service_stop', StopReason},
            State#state{update_plan = undefined,
                        suspended = SuspendedNew,
                        service_state = ServiceStateNew};
        {false, UpdatePlanNew} ->
            State#state{update_plan = UpdatePlanNew,
                        suspended = SuspendedNew,
                        service_state = ServiceStateNew}
    end;
process_queues(State) ->
    % info messages should be processed before service requests
    StateNew = process_queue_info(State),
    #state{queue_requests = QueueRequests} = StateNew,
    if
        QueueRequests =:= false ->
            process_queue(StateNew#state{queue_requests = true});
        true ->
            StateNew
    end.

-compile({inline,
          [{hibernate_check, 1},
           {pid_send, 2}]}).

hibernate_check({nohibernate, NoHibernate}) ->
    NoHibernate;

hibernate_check({reply, _,
                 #state{options = #config_service_options{
                            hibernate = false}}} = NoHibernate) ->
    NoHibernate;

hibernate_check({noreply,
                 #state{options = #config_service_options{
                            hibernate = false}}} = NoHibernate) ->
    NoHibernate;

hibernate_check({stop, _, _} = NoHibernate) ->
    NoHibernate;

hibernate_check({reply, Reply,
                 #state{options = #config_service_options{
                            hibernate = true}} = State}) ->
    {reply, Reply, State, hibernate};

hibernate_check({noreply,
                 #state{options = #config_service_options{
                            hibernate = true}} = State}) ->
    {noreply, State, hibernate};

hibernate_check({reply, Reply,
                 #state{options = #config_service_options{
                            hibernate = Hibernate}} = State} = NoHibernate)
    when is_tuple(Hibernate) ->
    case cloudi_core_i_rate_based_configuration:
         hibernate_check(Hibernate) of
        false ->
            NoHibernate;
        true ->
            {reply, Reply, State, hibernate}
    end;

hibernate_check({noreply,
                 #state{options = #config_service_options{
                            hibernate = Hibernate}} = State} = NoHibernate)
    when is_tuple(Hibernate) ->
    case cloudi_core_i_rate_based_configuration:
         hibernate_check(Hibernate) of
        false ->
            NoHibernate;
        true ->
            {noreply, State, hibernate}
    end.

pid_send(undefined, _) ->
    ok;
pid_send(Pid, Message)
    when is_pid(Pid) ->
    Pid ! Message,
    ok.

handle_module_request_loop_pid(RequestPidOld, ModuleRequest,
                               #config_service_options{
                                   request_pid_uses =
                                       RequestPidUses,
                                   request_pid_options =
                                       RequestPidOptions,
                                   hibernate =
                                       Hibernate}, ResultPid) ->
    if
        RequestPidOld =:= undefined ->
            case cloudi_core_i_rate_based_configuration:
                 hibernate_check(Hibernate) of
                false ->
                    spawn_opt_erlang(fun() ->
                        erlang:put(?PROCESS_DESCRIPTION_PDICT_KEY,
                                   process_description("request_pid "
                                                       "(without hibernate)")),
                        handle_module_request_loop_normal(RequestPidUses,
                                                          ModuleRequest,
                                                          ResultPid)
                    end, RequestPidOptions);
                true ->
                    spawn_opt_erlang(fun() ->
                        erlang:put(?PROCESS_DESCRIPTION_PDICT_KEY,
                                   process_description("request_pid "
                                                       "(with hibernate)")),
                        handle_module_request_loop_hibernate(RequestPidUses,
                                                             ModuleRequest,
                                                             ResultPid)
                    end, RequestPidOptions)
            end;
        is_pid(RequestPidOld) ->
            RequestPidOld ! ModuleRequest,
            RequestPidOld
    end.

handle_module_request_loop_normal(Uses, ResultPid) ->
    receive
        {'cloudi_service_request_loop_exit', Update} ->
            if
                Update =:= true ->
                    erlang:exit('cloudi_service_request_loop_exit');
                Update =:= false ->
                    ok
            end;
        {'cloudi_hibernate', false} ->
            handle_module_request_loop_normal(Uses, ResultPid);
        {'cloudi_hibernate', true} ->
            erlang:hibernate(?MODULE, handle_module_request_loop_hibernate,
                             [Uses, ResultPid]);
        {'cloudi_service_request_loop',
         _Type, _Name, _Pattern,
         _RequestInfo, _Request,
         _Timeout, _Priority, _TransId, _Source,
         _ServiceState, _Dispatcher,
         _Module, _ConfigOptions} = ModuleRequest ->
            handle_module_request_loop_normal(Uses,
                                              ModuleRequest,
                                              ResultPid)
    end.

handle_module_request_loop_hibernate(Uses, ResultPid) ->
    receive
        {'cloudi_service_request_loop_exit', Update} ->
            if
                Update =:= true ->
                    erlang:exit('cloudi_service_request_loop_exit');
                Update =:= false ->
                    ok
            end;
        {'cloudi_hibernate', false} ->
            handle_module_request_loop_normal(Uses, ResultPid);
        {'cloudi_hibernate', true} ->
            erlang:hibernate(?MODULE, handle_module_request_loop_hibernate,
                             [Uses, ResultPid]);
        {'cloudi_service_request_loop',
         _Type, _Name, _Pattern,
         _RequestInfo, _Request,
         _Timeout, _Priority, _TransId, _Source,
         _ServiceState, _Dispatcher,
         _Module, _ConfigOptions} = ModuleRequest ->
            handle_module_request_loop_hibernate(Uses,
                                                 ModuleRequest,
                                                 ResultPid)
    end.

handle_module_request_loop_normal(Uses,
                                  {'cloudi_service_request_loop',
                                   Type, Name, Pattern,
                                   RequestInfo, Request,
                                   Timeout, Priority, TransId, Source,
                                   ServiceState, Dispatcher,
                                   Module, ConfigOptions},
                                  ResultPid) ->
    FatalTimer = fatal_timer_start(Timeout, ResultPid, ConfigOptions),
    Result = handle_module_request(Type, Name, Pattern,
                                   RequestInfo, Request,
                                   Timeout, Priority, TransId, Source,
                                   ServiceState, Dispatcher,
                                   Module, ConfigOptions),
    ok = fatal_timer_end(FatalTimer),
    if
        Uses == 1 ->
            erlang:exit(Result);
        is_integer(Uses) ->
            ResultPid ! Result,
            handle_module_request_loop_normal(Uses - 1, ResultPid);
        Uses =:= infinity ->
            ResultPid ! Result,
            handle_module_request_loop_normal(Uses, ResultPid)
    end.

handle_module_request_loop_hibernate(Uses,
                                     {'cloudi_service_request_loop',
                                      Type, Name, Pattern,
                                      RequestInfo, Request,
                                      Timeout, Priority, TransId, Source,
                                      ServiceState, Dispatcher,
                                      Module, ConfigOptions},
                                     ResultPid) ->
    FatalTimer = fatal_timer_start(Timeout, ResultPid, ConfigOptions),
    Result = handle_module_request(Type, Name, Pattern,
                                   RequestInfo, Request,
                                   Timeout, Priority, TransId, Source,
                                   ServiceState, Dispatcher,
                                   Module, ConfigOptions),
    ok = fatal_timer_end(FatalTimer),
    if
        Uses == 1 ->
            erlang:exit(Result);
        is_integer(Uses) ->
            ResultPid ! Result,
            erlang:hibernate(?MODULE, handle_module_request_loop_hibernate,
                             [Uses - 1, ResultPid]);
        Uses =:= infinity ->
            ResultPid ! Result,
            erlang:hibernate(?MODULE, handle_module_request_loop_hibernate,
                             [Uses, ResultPid])
    end.

handle_module_info_loop_pid(InfoPidOld, ModuleInfo,
                            #config_service_options{
                                info_pid_uses =
                                    InfoPidUses,
                                info_pid_options =
                                    InfoPidOptions,
                                hibernate =
                                    Hibernate}, ResultPid) ->
    if
        InfoPidOld =:= undefined ->
            case cloudi_core_i_rate_based_configuration:
                 hibernate_check(Hibernate) of
                false ->
                    spawn_opt_erlang(fun() ->
                        erlang:put(?PROCESS_DESCRIPTION_PDICT_KEY,
                                   process_description("info_pid "
                                                       "(without hibernate)")),
                        handle_module_info_loop_normal(InfoPidUses,
                                                       ModuleInfo,
                                                       ResultPid)
                    end, InfoPidOptions);
                true ->
                    spawn_opt_erlang(fun() ->
                        erlang:put(?PROCESS_DESCRIPTION_PDICT_KEY,
                                   process_description("info_pid "
                                                       "(with hibernate)")),
                        handle_module_info_loop_hibernate(InfoPidUses,
                                                          ModuleInfo,
                                                          ResultPid)
                    end, InfoPidOptions)
            end;
        is_pid(InfoPidOld) ->
            InfoPidOld ! ModuleInfo,
            InfoPidOld
    end.

handle_module_info_loop_normal(Uses, ResultPid) ->
    receive
        {'cloudi_service_info_loop_exit', Update} ->
            if
                Update =:= true ->
                    erlang:exit('cloudi_service_info_loop_exit');
                Update =:= false ->
                    ok
            end;
        {'cloudi_hibernate', false} ->
            handle_module_info_loop_normal(Uses, ResultPid);
        {'cloudi_hibernate', true} ->
            erlang:hibernate(?MODULE, handle_module_info_loop_hibernate,
                             [Uses, ResultPid]);
        {'cloudi_service_info_loop',
         _Request, _ServiceState, _Dispatcher,
         _Module, _ConfigOptions} = ModuleInfo ->
            handle_module_info_loop_normal(Uses,
                                           ModuleInfo,
                                           ResultPid)
    end.

handle_module_info_loop_hibernate(Uses, ResultPid) ->
    receive
        {'cloudi_service_info_loop_exit', Update} ->
            if
                Update =:= true ->
                    erlang:exit('cloudi_service_info_loop_exit');
                Update =:= false ->
                    ok
            end;
        {'cloudi_hibernate', false} ->
            handle_module_info_loop_normal(Uses, ResultPid);
        {'cloudi_hibernate', true} ->
            erlang:hibernate(?MODULE, handle_module_info_loop_hibernate,
                             [Uses, ResultPid]);
        {'cloudi_service_info_loop',
         _Request, _ServiceState, _Dispatcher,
         _Module, _ConfigOptions} = ModuleInfo ->
            handle_module_info_loop_hibernate(Uses,
                                              ModuleInfo,
                                              ResultPid)
    end.

handle_module_info_loop_normal(Uses,
                               {'cloudi_service_info_loop',
                                Request, ServiceState, Dispatcher,
                                Module, ConfigOptions},
                               ResultPid) ->
    Result = handle_module_info(Request, ServiceState, Dispatcher,
                                Module, ConfigOptions),
    if
        Uses == 1 ->
            erlang:exit(Result);
        is_integer(Uses) ->
            ResultPid ! Result,
            handle_module_info_loop_normal(Uses - 1, ResultPid);
        Uses =:= infinity ->
            ResultPid ! Result,
            handle_module_info_loop_normal(Uses, ResultPid)
    end.

handle_module_info_loop_hibernate(Uses,
                                  {'cloudi_service_info_loop',
                                   Request, ServiceState, Dispatcher,
                                   Module, ConfigOptions},
                                  ResultPid) ->
    Result = handle_module_info(Request, ServiceState, Dispatcher,
                                Module, ConfigOptions),
    if
        Uses == 1 ->
            erlang:exit(Result);
        is_integer(Uses) ->
            ResultPid ! Result,
            erlang:hibernate(?MODULE, handle_module_info_loop_hibernate,
                             [Uses - 1, ResultPid]);
        Uses =:= infinity ->
            ResultPid ! Result,
            erlang:hibernate(?MODULE, handle_module_info_loop_hibernate,
                             [Uses, ResultPid])
    end.

% duo_mode specific logic

duo_mode_loop_init(#state_duo{duo_mode_pid = DuoModePid,
                              module = Module,
                              dispatcher = Dispatcher} = State) ->
    receive
        {'cloudi_service_init_execute', Args, Timeout,
         DispatcherProcessDictionary,
         #state{prefix = Prefix,
                options = #config_service_options{
                    aspects_init_after = Aspects,
                    init_pid_options = PidOptions}} = DispatcherState} ->
            ok = initialize_wait(Timeout),
            {ok, DispatcherProxy} = cloudi_core_i_services_internal_init:
                                    start_link(Timeout, PidOptions,
                                               DispatcherProcessDictionary,
                                               DispatcherState),
            Result = try Module:cloudi_service_init(Args, Prefix, Timeout,
                                                    DispatcherProxy) of
                    {ok, ServiceStateInit} ->
                        aspects_init_after(Aspects, Args, Prefix, Timeout,
                                           ServiceStateInit, DispatcherProxy);
                    {stop, _, _} = Stop ->
                        Stop;
                    {stop, _} = Stop ->
                        Stop
            catch
                ErrorType:Error:ErrorStackTrace ->
                    ?LOG_ERROR_SYNC("init ~tp ~tp~n~tp",
                                    [ErrorType, Error, ErrorStackTrace]),
                    {stop, {ErrorType, {Error, ErrorStackTrace}}}
            end,
            {DispatcherProcessDictionaryNew,
             #state{recv_timeouts = RecvTimeouts,
                    suspended = Suspended,
                    queue_requests = QueueRequests,
                    queued = Queued,
                    queued_info = QueuedInfo,
                    options = ConfigOptions} = DispatcherStateNext} =
                cloudi_core_i_services_internal_init:
                stop_link(DispatcherProxy),
            case Result of
                {ok, ServiceStateNew} ->
                    ConfigOptionsNew = check_init_receive(ConfigOptions),
                    #config_service_options{
                        hibernate = Hibernate} = ConfigOptionsNew,
                    % duo_mode_pid takes control of any state that may
                    % have been updated during initialization that is now
                    % only relevant to the duo_mode pid
                    StateNext = State#state_duo{
                        recv_timeouts = RecvTimeouts,
                        suspended = Suspended,
                        queue_requests = QueueRequests,
                        queued = Queued,
                        queued_info = QueuedInfo,
                        service_state = ServiceStateNew,
                        options = ConfigOptionsNew},
                    DispatcherConfigOptionsNew =
                        duo_mode_dispatcher_options(ConfigOptionsNew),
                    DispatcherStateNew = DispatcherStateNext#state{
                        recv_timeouts = undefined,
                        suspended = undefined,
                        queue_requests = undefined,
                        queued = undefined,
                        queued_info = undefined,
                        options = DispatcherConfigOptionsNew},
                    false = erlang:process_flag(trap_exit, true),
                    Dispatcher ! {'cloudi_service_init_state',
                                  DispatcherProcessDictionaryNew,
                                  DispatcherStateNew},
                    ok = cloudi_core_i_services_monitor:
                         process_init_end(DuoModePid),
                    StateNew = duo_process_queues(StateNext),
                    case cloudi_core_i_rate_based_configuration:
                         hibernate_check(Hibernate) of
                        false ->
                            duo_mode_loop(StateNew);
                        true ->
                            proc_lib:hibernate(?MODULE,
                                               duo_mode_loop,
                                               [StateNew])
                    end;
                {stop, Reason, ServiceState} ->
                    StateNew = State#state_duo{service_state = ServiceState},
                    duo_mode_loop_terminate(Reason, StateNew);
                {stop, Reason} ->
                    StateNew = State#state_duo{service_state = undefined},
                    duo_mode_loop_terminate(Reason, StateNew)
            end
    end.

duo_mode_loop(#state_duo{} = State) ->
    receive
        Request ->
            % mimic a gen_server:handle_info/2 for code reuse
            case duo_handle_info(Request, State) of
                {stop, Reason, StateNew} ->
                    duo_mode_loop_terminate(Reason, StateNew);
                {noreply, #state_duo{options = #config_service_options{
                                         hibernate = Hibernate}} = StateNew} ->
                    case cloudi_core_i_rate_based_configuration:
                         hibernate_check(Hibernate) of
                        false ->
                            duo_mode_loop(StateNew);
                        true ->
                            proc_lib:hibernate(?MODULE,
                                               duo_mode_loop,
                                               [StateNew])
                    end
            end
    end.

system_continue(_Dispatcher, _Debug, State) ->
    duo_mode_loop(State).

system_terminate(Reason, _Dispatcher, _Debug, State) ->
    duo_mode_loop_terminate(Reason, State).

system_code_change(State, _Module, _VsnOld, _Extra) ->
    {ok, State}.

sys_get_status(Timeout,
               #state{duo_mode_pid = DuoModePid} = State) ->
    % provide sys:get_status/2 data for all linked long-lived processes
    {sys_get_status_dispatcher(State),
     sys_get_status_duo_mode(DuoModePid, Timeout)}.

sys_get_status_dispatcher(#state{dispatcher = Dispatcher} = State) ->
    % only dispatcher process state is used to provide data similar to
    % the sys:get_status/2 output to allow calling
    % sys:get_status/2 on other linked processes
    PDict = erlang:get(),
    {status,
     Dispatcher,
     {module, gen_server},
     [PDict,
      running,
      undefined, % Parent
      undefined, % Debug
      format_status_state(State)]}.

sys_get_status_duo_mode(undefined, _) ->
    undefined;
sys_get_status_duo_mode(DuoModePid, Timeout)
    when is_pid(DuoModePid) ->
    try sys:get_status(DuoModePid, Timeout) of
        {status, DuoModePid,
         {module, cloudi_core_i_services_internal} = ModuleTuple,
         StatusItems} ->
            [#state_duo{} = State |
             StatusItemsReversed] = lists:reverse(StatusItems),
            StatusItemsNew = lists:reverse(StatusItemsReversed,
                                           [duo_mode_format_status(State)]),
            {status, DuoModePid, ModuleTuple, StatusItemsNew};
        _ ->
            timeout
    catch
        _:_ ->
            timeout
    end.

-ifdef(VERBOSE_STATE).
duo_mode_format_status(State) ->
    State.
-else.
duo_mode_format_status(#state_duo{recv_timeouts = RecvTimeouts,
                                  queued = Queue,
                                  queued_info = QueueInfo,
                                  options = ConfigOptions} = State) ->
    State#state_duo{recv_timeouts = maps:to_list(RecvTimeouts),
                    queued = pqueue4:to_plist(Queue),
                    queued_info = queue:to_list(QueueInfo),
                    options = cloudi_core_i_configuration:
                              services_format_options_internal(ConfigOptions)}.
-endif.

duo_mode_dispatcher_options(ConfigOptions) ->
    ConfigOptions#config_service_options{
        rate_request_max = undefined,
        count_process_dynamic = false,
        hibernate = false}.

duo_mode_loop_terminate(Reason,
                        #state_duo{duo_mode_pid = DuoModePid,
                                   module = Module,
                                   service_state = ServiceState,
                                   timeout_term = TimeoutTerm,
                                   options = #config_service_options{
                                       aspects_terminate_before = Aspects}
                                   } = State) ->
    ok = cloudi_core_i_services_monitor:
         process_terminate_begin(DuoModePid, Reason),
    ServiceStateNew = aspects_terminate_before(Aspects, Reason, TimeoutTerm,
                                               ServiceState),
    _ = Module:cloudi_service_terminate(Reason, TimeoutTerm, ServiceStateNew),
    ok = duo_terminate_pids(Reason, State),
    _ = erlang:process_flag(trap_exit, false),
    erlang:exit(DuoModePid, Reason).

duo_terminate_pids(normal,
                   #state_duo{dispatcher = Dispatcher,
                              request_pid = RequestPid,
                              options = #config_service_options{
                                  monkey_chaos = MonkeyChaos}}) ->
    Dispatcher ! {'cloudi_service_info_failure',
                  stop, normal, undefined, undefined},
    ok = pid_send(RequestPid, {'cloudi_service_request_loop_exit', false}),
    ok = cloudi_core_i_runtime_testing:monkey_chaos_destroy(MonkeyChaos);
duo_terminate_pids(_, _) ->
    ok.

duo_handle_info({'cloudi_service_return_async',
                 _, _, _, _, _, _, Source} = T,
                #state_duo{duo_mode_pid = DuoModePid,
                           dispatcher = Dispatcher} = State) ->
    true = Source =:= DuoModePid,
    Dispatcher ! T,
    {noreply, State};

duo_handle_info({'cloudi_service_return_sync',
                 _, _, _, _, _, _, Source} = T,
                #state_duo{duo_mode_pid = DuoModePid,
                           dispatcher = Dispatcher} = State) ->
    true = Source =:= DuoModePid,
    Dispatcher ! T,
    {noreply, State};

duo_handle_info({'cloudi_service_request_success', RequestResponse,
                 ServiceStateNew},
                #state_duo{dispatcher = Dispatcher} = State) ->
    ok = handle_module_request_success(RequestResponse, Dispatcher),
    StateNew = State#state_duo{service_state = ServiceStateNew},
    {noreply, duo_process_queues(StateNew)};

duo_handle_info({'cloudi_service_request_failure',
                 Type, Error, Stack, ServiceStateNew}, State) ->
    Reason = if
        Type =:= stop ->
            true = Stack =:= undefined,
            case Error of
                shutdown ->
                    ?LOG_WARN("duo_mode request stop shutdown", []);
                {shutdown, ShutdownReason} ->
                    ?LOG_WARN("duo_mode request stop shutdown (~tp)",
                              [ShutdownReason]);
                _ ->
                    ?LOG_ERROR("duo_mode request stop ~tp", [Error])
            end,
            Error;
        true ->
            ?LOG_ERROR("duo_mode request ~tp ~tp~n~tp", [Type, Error, Stack]),
            {Type, {Error, Stack}}
    end,
    {stop, Reason, State#state_duo{service_state = ServiceStateNew}};

duo_handle_info({'EXIT', RequestPid,
                 {'cloudi_service_request_success', _RequestResponse,
                  _ServiceStateNew} = Result},
                #state_duo{request_pid = RequestPid} = State) ->
    duo_handle_info(Result, State#state_duo{request_pid = undefined});

duo_handle_info({'EXIT', RequestPid,
                 {'cloudi_service_request_failure',
                  _Type, _Error, _Stack, _ServiceStateNew} = Result},
                #state_duo{request_pid = RequestPid} = State) ->
    duo_handle_info(Result, State#state_duo{request_pid = undefined});

duo_handle_info({'EXIT', RequestPid, 'cloudi_service_request_loop_exit'},
                #state_duo{request_pid = RequestPid} = State) ->
    {noreply, State#state_duo{request_pid = undefined}};

duo_handle_info({'EXIT', RequestPid, Reason},
                #state_duo{request_pid = RequestPid} = State) ->
    ?LOG_ERROR("~p duo_mode request exited: ~tp", [RequestPid, Reason]),
    {stop, Reason, State};

duo_handle_info({'EXIT', _, shutdown}, State) ->
    % CloudI Service shutdown
    {stop, shutdown, State};

duo_handle_info({'EXIT', _, {shutdown, _}}, State) ->
    % CloudI Service shutdown w/reason
    {stop, shutdown, State};

duo_handle_info({'EXIT', _, restart}, State) ->
    % CloudI Service API requested a restart
    {stop, restart, State};

duo_handle_info({'EXIT', Dispatcher, Reason},
                #state_duo{dispatcher = Dispatcher} = State) ->
    ?LOG_ERROR("~p duo_mode dispatcher exited: ~tp", [Dispatcher, Reason]),
    {stop, Reason, State};

duo_handle_info({'EXIT', Pid, Reason}, State) ->
    ?LOG_ERROR("~p forced exit: ~tp", [Pid, Reason]),
    {stop, Reason, State};

duo_handle_info({'cloudi_service_stop', Reason}, State) ->
    {stop, Reason, State};

duo_handle_info({SendType, Name, Pattern, RequestInfo, Request,
                 Timeout, Priority, TransId, Source},
                #state_duo{duo_mode_pid = DuoModePid,
                           queue_requests = false,
                           module = Module,
                           service_state = ServiceState,
                           dispatcher = Dispatcher,
                           request_pid = RequestPid,
                           options = #config_service_options{
                               rate_request_max = RateRequest,
                               response_timeout_immediate_max =
                                   ResponseTimeoutImmediateMax} = ConfigOptions
                           } = State)
    when SendType =:= 'cloudi_service_send_async';
         SendType =:= 'cloudi_service_send_sync' ->
    {RateRequestOk, RateRequestNew} = if
        RateRequest =/= undefined ->
            cloudi_core_i_rate_based_configuration:
            rate_request_max_request(RateRequest);
        true ->
            {true, RateRequest}
    end,
    if
        RateRequestOk =:= true ->
            Type = if
                SendType =:= 'cloudi_service_send_async' ->
                    'send_async';
                SendType =:= 'cloudi_service_send_sync' ->
                    'send_sync'
            end,
            ConfigOptionsNew =
                check_incoming(true, ConfigOptions#config_service_options{
                                         rate_request_max = RateRequestNew}),
            {noreply, State#state_duo{
                queue_requests = true,
                request_pid = handle_module_request_loop_pid(RequestPid,
                    {'cloudi_service_request_loop',
                     Type, Name, Pattern, RequestInfo, Request,
                     Timeout, Priority, TransId, Source,
                     ServiceState, Dispatcher,
                     Module, ConfigOptionsNew}, ConfigOptionsNew, DuoModePid),
                options = ConfigOptionsNew}};
        RateRequestOk =:= false ->
            ok = return_null_response(SendType, Name, Pattern,
                                      Timeout, TransId, Source,
                                      ResponseTimeoutImmediateMax),
            {noreply, State#state_duo{
                options = ConfigOptions#config_service_options{
                    rate_request_max = RateRequestNew}}}
    end;

duo_handle_info({SendType, Name, Pattern, _, _,
                 0, _, TransId, Source},
                #state_duo{queue_requests = true,
                           options = #config_service_options{
                               response_timeout_immediate_max =
                                   ResponseTimeoutImmediateMax}} = State)
    when SendType =:= 'cloudi_service_send_async';
         SendType =:= 'cloudi_service_send_sync' ->
    if
        0 =:= ResponseTimeoutImmediateMax ->
            ok = return_null_response(SendType, Name, Pattern,
                                      0, TransId, Source);
        true ->
            ok
    end,
    {noreply, State};

duo_handle_info({SendType, Name, Pattern, _, _,
                 Timeout, Priority, TransId, Source} = T,
                #state_duo{queue_requests = true,
                           queued = Queue,
                           queued_size = QueuedSize,
                           queued_word_size = WordSize,
                           options = #config_service_options{
                               queue_limit = QueueLimit,
                               queue_size = QueueSize,
                               rate_request_max = RateRequest,
                               response_timeout_immediate_max =
                                   ResponseTimeoutImmediateMax} = ConfigOptions
                           } = State)
    when SendType =:= 'cloudi_service_send_async';
         SendType =:= 'cloudi_service_send_sync' ->
    QueueLimitOk = if
        QueueLimit =/= undefined ->
            pqueue4:len(Queue) < QueueLimit;
        true ->
            true
    end,
    {QueueSizeOk, Size} = if
        QueueSize =/= undefined ->
            QueueElementSize = erlang_term:byte_size({0, T}, WordSize),
            {(QueuedSize + QueueElementSize) =< QueueSize, QueueElementSize};
        true ->
            {true, 0}
    end,
    {RateRequestOk, RateRequestNew} = if
        RateRequest =/= undefined ->
            cloudi_core_i_rate_based_configuration:
            rate_request_max_request(RateRequest);
        true ->
            {true, RateRequest}
    end,
    StateNew = State#state_duo{
        options = ConfigOptions#config_service_options{
            rate_request_max = RateRequestNew}},
    if
        QueueLimitOk, QueueSizeOk, RateRequestOk ->
            {noreply,
             duo_recv_timeout_start(Timeout, Priority, TransId,
                                    Size, T, StateNew)};
        true ->
            ok = return_null_response(SendType, Name, Pattern,
                                      Timeout, TransId, Source,
                                      ResponseTimeoutImmediateMax),
            {noreply, StateNew}
    end;

duo_handle_info({'cloudi_service_recv_timeout', Priority, TransId, Size},
                #state_duo{recv_timeouts = RecvTimeouts,
                           queue_requests = QueueRequests,
                           queued = Queue,
                           queued_size = QueuedSize} = State) ->
    {QueueNew, QueuedSizeNew} = if
        QueueRequests =:= true ->
            F = fun({_, {_, _, _, _, _, _, _, Id, _}}) -> Id == TransId end,
            {Removed,
             QueueNext} = pqueue4:remove_unique(F, Priority, Queue),
            QueuedSizeNext = if
                Removed =:= true ->
                    QueuedSize - Size;
                Removed =:= false ->
                    % false if a timer message was sent while cancelling
                    QueuedSize
            end,
            {QueueNext, QueuedSizeNext};
        true ->
            {Queue, QueuedSize}
    end,
    {noreply,
     State#state_duo{recv_timeouts = maps:remove(TransId, RecvTimeouts),
                     queued = QueueNew,
                     queued_size = QueuedSizeNew}};

duo_handle_info('cloudi_hibernate_rate',
                #state_duo{dispatcher = Dispatcher,
                           request_pid = RequestPid,
                           options = #config_service_options{
                               hibernate = Hibernate} = ConfigOptions
                           } = State) ->
    {Value, HibernateNew} = cloudi_core_i_rate_based_configuration:
                            hibernate_reinit(Hibernate),
    HibernateMessage = {'cloudi_hibernate', Value},
    Dispatcher ! HibernateMessage,
    ok = pid_send(RequestPid, HibernateMessage),
    {noreply,
     State#state_duo{options = ConfigOptions#config_service_options{
                         hibernate = HibernateNew}}};

duo_handle_info('cloudi_count_process_dynamic_rate',
                #state_duo{dispatcher = Dispatcher,
                           options = #config_service_options{
                               count_process_dynamic =
                                   CountProcessDynamic} = ConfigOptions
                           } = State) ->
    CountProcessDynamicNew = cloudi_core_i_rate_based_configuration:
                             count_process_dynamic_reinit(Dispatcher,
                                                          CountProcessDynamic),
    {noreply,
     State#state_duo{options = ConfigOptions#config_service_options{
                         count_process_dynamic = CountProcessDynamicNew}}};

duo_handle_info({'cloudi_count_process_dynamic_update', _} = Update,
                #state_duo{dispatcher = Dispatcher} = State) ->
    Dispatcher ! Update,
    {noreply, State};

duo_handle_info('cloudi_count_process_dynamic_terminate_check',
                #state_duo{update_plan = UpdatePlan,
                           suspended = Suspended,
                           queue_requests = QueueRequests} = State) ->
    % count_process_dynamic_terminate_set is not called inside the duo_mode_pid
    StopReason = {shutdown, cloudi_count_process_dynamic_terminate},
    StopDelayed = stop_delayed(UpdatePlan, Suspended, QueueRequests),
    if
        StopDelayed =:= false ->
            {stop, StopReason, State};
        StopDelayed =:= true ->
            {noreply, State#state_duo{stop = StopReason}}
    end;

duo_handle_info('cloudi_count_process_dynamic_terminate_now', State) ->
    {stop, {shutdown, cloudi_count_process_dynamic_terminate}, State};

duo_handle_info('cloudi_rate_request_max_rate',
                #state_duo{options = #config_service_options{
                               rate_request_max = RateRequest} = ConfigOptions
                           } = State) ->
    RateRequestNew = cloudi_core_i_rate_based_configuration:
                     rate_request_max_reinit(RateRequest),
    {noreply,
     State#state_duo{options = ConfigOptions#config_service_options{
                         rate_request_max = RateRequestNew}}};

duo_handle_info('cloudi_service_fatal_timeout',
                #state_duo{update_plan = UpdatePlan,
                           suspended = Suspended,
                           queue_requests = QueueRequests,
                           options = #config_service_options{
                               fatal_timeout_interrupt =
                                   FatalTimeoutInterrupt}} = State) ->
    StopReason = fatal_timeout,
    StopDelayed = stop_delayed(UpdatePlan, FatalTimeoutInterrupt,
                               Suspended, QueueRequests),
    if
        StopDelayed =:= false ->
            {stop, StopReason, State};
        StopDelayed =:= true ->
            {noreply, State#state_duo{stop = StopReason}}
    end;

duo_handle_info({'cloudi_service_suspended', SuspendPending, Suspend},
                #state_duo{duo_mode_pid = DuoModePid,
                           suspended = SuspendedOld,
                           queue_requests = QueueRequests,
                           service_state = ServiceState,
                           options = Options} = State) ->
    case suspended_change(SuspendedOld, Suspend,
                          SuspendPending, DuoModePid,
                          QueueRequests, ServiceState, Options) of
        undefined ->
            {noreply, State};
        {#suspended{processing = false} = SuspendedNew,
         false, ServiceStateNew} ->
            StateNew = State#state_duo{suspended = SuspendedNew,
                                       service_state = ServiceStateNew},
            {noreply,
             duo_process_queues(StateNew)};
        {SuspendedNew, QueueRequestsNew, ServiceStateNew} ->
            {noreply,
             State#state_duo{suspended = SuspendedNew,
                             queue_requests = QueueRequestsNew,
                             service_state = ServiceStateNew}}
    end;

duo_handle_info({'cloudi_service_update', UpdatePending, UpdatePlan},
                #state_duo{duo_mode_pid = DuoModePid,
                           update_plan = undefined,
                           suspended = Suspended,
                           queue_requests = QueueRequests} = State) ->
    #config_service_update{sync = Sync} = UpdatePlan,
    ProcessBusy = case Suspended of
        #suspended{processing = true,
                   busy = SuspendedWhileBusy} ->
            SuspendedWhileBusy;
        #suspended{processing = false} ->
            QueueRequests
    end,
    UpdatePlanNew = if
        Sync =:= true, ProcessBusy =:= true ->
            UpdatePlan#config_service_update{update_pending = UpdatePending,
                                             process_busy = ProcessBusy};
        true ->
            UpdatePending ! {'cloudi_service_update', DuoModePid},
            UpdatePlan#config_service_update{process_busy = ProcessBusy}
    end,
    {noreply, State#state_duo{update_plan = UpdatePlanNew,
                              queue_requests = true}};

duo_handle_info({'cloudi_service_update_now', UpdateNow, UpdateStart},
                #state_duo{update_plan = UpdatePlan} = State) ->
    #config_service_update{process_busy = ProcessBusy} = UpdatePlan,
    UpdatePlanNew = UpdatePlan#config_service_update{
                        update_now = UpdateNow,
                        update_start = UpdateStart},
    StateNew = State#state_duo{update_plan = UpdatePlanNew},
    if
        ProcessBusy =:= true ->
            {noreply, StateNew};
        ProcessBusy =:= false ->
            {noreply, duo_process_update(StateNew)}
    end;

duo_handle_info({system, From, Msg},
                #state_duo{dispatcher = Dispatcher} = State) ->
    case Msg of
        get_state ->
            sys:handle_system_msg(get_state, From, Dispatcher, ?MODULE, [],
                                  State);
        {replace_state, StateFun} ->
            StateNew = try StateFun(State) catch _:_ -> State end,
            sys:handle_system_msg(replace_state, From, Dispatcher, ?MODULE, [],
                                  StateNew);
        _ ->
            sys:handle_system_msg(Msg, From, Dispatcher, ?MODULE, [],
                                  State)
    end;

duo_handle_info({ReplyRef, _}, State) when is_reference(ReplyRef) ->
    % gen_server:call/3 had a timeout exception that was caught but the
    % reply arrived later and must be discarded
    {noreply, State};

duo_handle_info(Request,
                #state_duo{queue_requests = true,
                           queued_info = QueueInfo} = State) ->
    {noreply, State#state_duo{queued_info = queue:in(Request, QueueInfo)}};

duo_handle_info(Request,
                #state_duo{module = Module,
                           service_state = ServiceState,
                           dispatcher = Dispatcher,
                           options = ConfigOptions} = State) ->
    ConfigOptionsNew = check_incoming(false, ConfigOptions),
    case handle_module_info(Request, ServiceState, Dispatcher,
                            Module, ConfigOptionsNew) of
        {'cloudi_service_info_success', ServiceStateNew} ->
            {noreply,
             State#state_duo{service_state = ServiceStateNew,
                             options = ConfigOptionsNew}};
        {'cloudi_service_info_failure',
         stop, Reason, undefined, ServiceStateNew} ->
            ?LOG_ERROR("duo_mode info stop ~tp", [Reason]),
            {stop, Reason,
             State#state_duo{service_state = ServiceStateNew,
                             options = ConfigOptionsNew}};
        {'cloudi_service_info_failure',
         Type, Error, Stack, ServiceStateNew} ->
            ?LOG_ERROR("duo_mode info ~tp ~tp~n~tp", [Type, Error, Stack]),
            {stop, {Type, {Error, Stack}},
             State#state_duo{service_state = ServiceStateNew,
                             options = ConfigOptionsNew}}
    end.

duo_process_queue_info(#state_duo{queue_requests = true,
                                  queued_info = QueueInfo,
                                  module = Module,
                                  service_state = ServiceState,
                                  dispatcher = Dispatcher,
                                  options = ConfigOptions} = State) ->
    case queue:out(QueueInfo) of
        {empty, QueueInfoNew} ->
            State#state_duo{queue_requests = false,
                            queued_info = QueueInfoNew};
        {{value, Request}, QueueInfoNew} ->
            ConfigOptionsNew = check_incoming(false, ConfigOptions),
            case handle_module_info(Request, ServiceState, Dispatcher,
                                    Module, ConfigOptionsNew) of
                {'cloudi_service_info_success', ServiceStateNew} ->
                    duo_process_queue_info(
                        State#state_duo{queued_info = QueueInfoNew,
                                        service_state = ServiceStateNew,
                                        options = ConfigOptionsNew});
                {'cloudi_service_info_failure',
                 stop, Reason, undefined, ServiceStateNew} ->
                    ?LOG_ERROR("duo_mode info stop ~tp", [Reason]),
                    {stop, Reason,
                     State#state_duo{service_state = ServiceStateNew,
                                     queued_info = QueueInfoNew,
                                     options = ConfigOptionsNew}};
                {'cloudi_service_info_failure',
                 Type, Error, Stack, ServiceStateNew} ->
                    ?LOG_ERROR("duo_mode info ~tp ~tp~n~tp",
                               [Type, Error, Stack]),
                    {stop, {Type, {Error, Stack}},
                     State#state_duo{service_state = ServiceStateNew,
                                     queued_info = QueueInfoNew,
                                     options = ConfigOptionsNew}}
            end
    end.

duo_process_queue(#state_duo{duo_mode_pid = DuoModePid,
                             recv_timeouts = RecvTimeouts,
                             queue_requests = true,
                             queued = Queue,
                             queued_size = QueuedSize,
                             module = Module,
                             service_state = ServiceState,
                             dispatcher = Dispatcher,
                             request_pid = RequestPid,
                             options = ConfigOptions} = State) ->
    case pqueue4:out(Queue) of
        {empty, QueueNew} ->
            State#state_duo{queue_requests = false,
                            queued = QueueNew};
        {{value,
          {Size,
           {'cloudi_service_send_async', Name, Pattern,
            RequestInfo, Request,
            _, Priority, TransId, Source}}}, QueueNew} ->
            {RecvTimer,
             RecvTimeoutsNew} = maps:take(TransId, RecvTimeouts),
            Timeout = case erlang:cancel_timer(RecvTimer) of
                false ->
                    0;
                V ->
                    V
            end,
            ConfigOptionsNew = check_incoming(true, ConfigOptions),
            State#state_duo{
                recv_timeouts = RecvTimeoutsNew,
                queued = QueueNew,
                queued_size = QueuedSize - Size,
                request_pid = handle_module_request_loop_pid(RequestPid,
                    {'cloudi_service_request_loop',
                     'send_async', Name, Pattern,
                     RequestInfo, Request,
                     Timeout, Priority, TransId, Source,
                     ServiceState, Dispatcher,
                     Module, ConfigOptionsNew}, ConfigOptionsNew, DuoModePid),
                options = ConfigOptionsNew};
        {{value,
          {Size,
           {'cloudi_service_send_sync', Name, Pattern,
            RequestInfo, Request,
            _, Priority, TransId, Source}}}, QueueNew} ->
            {RecvTimer,
             RecvTimeoutsNew} = maps:take(TransId, RecvTimeouts),
            Timeout = case erlang:cancel_timer(RecvTimer) of
                false ->
                    0;
                V ->
                    V
            end,
            ConfigOptionsNew = check_incoming(true, ConfigOptions),
            State#state_duo{
                recv_timeouts = RecvTimeoutsNew,
                queued = QueueNew,
                queued_size = QueuedSize - Size,
                request_pid = handle_module_request_loop_pid(RequestPid,
                    {'cloudi_service_request_loop',
                     'send_sync', Name, Pattern,
                     RequestInfo, Request,
                     Timeout, Priority, TransId, Source,
                     ServiceState, Dispatcher,
                     Module, ConfigOptionsNew}, ConfigOptionsNew, DuoModePid),
                options = ConfigOptionsNew}
    end.

duo_process_update(#state_duo{duo_mode_pid = DuoModePid,
                              update_plan = UpdatePlan,
                              service_state = ServiceState} = State) ->
    #config_service_update{update_now = UpdateNow,
                           process_busy = false} = UpdatePlan,
    StateNew = case update(ServiceState, State, UpdatePlan) of
        {ok, ServiceStateNext, StateNext} ->
            UpdateNow ! {'cloudi_service_update_now', DuoModePid, ok},
            StateNext#state_duo{service_state = ServiceStateNext};
        {error, _} = Error ->
            UpdateNow ! {'cloudi_service_update_now', DuoModePid, Error},
            State
    end,
    duo_process_queues(StateNew#state_duo{update_plan = undefined}).

duo_process_queues(#state_duo{duo_mode_pid = DuoModePid,
                              stop = StopReason,
                              update_plan = UpdatePlan,
                              suspended = #suspended{
                                  processing = Processing} = Suspended,
                              service_state = ServiceState,
                              options = Options} = State)
    when Processing orelse
         UpdatePlan /= undefined orelse
         StopReason /= undefined ->
    {SuspendedNew,
     ServiceStateNew} = suspended_idle(Suspended, ServiceState, Options),
    case update_now(UpdatePlan, DuoModePid) of
        {true, UpdatePlanNew} ->
            duo_process_update(State#state_duo{
                                   update_plan = UpdatePlanNew,
                                   suspended = SuspendedNew,
                                   service_state = ServiceStateNew});
        {false, undefined} when StopReason /= undefined ->
            DuoModePid ! {'cloudi_service_stop', StopReason},
            State#state_duo{update_plan = undefined,
                            suspended = SuspendedNew,
                            service_state = ServiceStateNew};
        {false, UpdatePlanNew} ->
            State#state_duo{update_plan = UpdatePlanNew,
                            suspended = SuspendedNew,
                            service_state = ServiceStateNew}
    end;
duo_process_queues(State) ->
    % info messages should be processed before service requests
    StateNew = duo_process_queue_info(State),
    #state_duo{queue_requests = QueueRequests} = StateNew,
    if
        QueueRequests =:= false ->
            duo_process_queue(StateNew#state_duo{queue_requests = true});
        true ->
            StateNew
    end.

aspects_init_after([], _, _, _, ServiceState, _) ->
    {ok, ServiceState};
aspects_init_after([{M, F} = Aspect| L], Args, Prefix, Timeout,
                   ServiceState, Dispatcher) ->
    try M:F(Args, Prefix, Timeout, ServiceState, Dispatcher) of
        {ok, ServiceStateNew} ->
            aspects_init_after(L, Args, Prefix, Timeout,
                               ServiceStateNew, Dispatcher);
        {stop, _, _} = Stop ->
            Stop
    catch
        ErrorType:Error:ErrorStackTrace ->
            ?LOG_ERROR_SYNC("aspect ~tp ~tp ~tp~n~tp",
                            [Aspect, ErrorType, Error, ErrorStackTrace]),
            {stop, {ErrorType, {Error, ErrorStackTrace}}, ServiceState}
    end;
aspects_init_after([F | L], Args, Prefix, Timeout,
                   ServiceState, Dispatcher) ->
    try F(Args, Prefix, Timeout, ServiceState, Dispatcher) of
        {ok, ServiceStateNew} ->
            aspects_init_after(L, Args, Prefix, Timeout,
                               ServiceStateNew, Dispatcher);
        {stop, _, _} = Stop ->
            Stop
    catch
        ErrorType:Error:ErrorStackTrace ->
            ?LOG_ERROR_SYNC("aspect ~tp ~tp ~tp~n~tp",
                            [F, ErrorType, Error, ErrorStackTrace]),
            {stop, {ErrorType, {Error, ErrorStackTrace}}, ServiceState}
    end.

aspects_request_before([], _, _, _, _, _, _, _, _, _, ServiceState, _) ->
    {ok, ServiceState};
aspects_request_before([{M, F} = Aspect | L],
                       Type, Name, Pattern, RequestInfo, Request,
                       Timeout, Priority, TransId, Source,
                       ServiceState, Dispatcher) ->
    try M:F(Type, Name, Pattern, RequestInfo, Request,
            Timeout, Priority, TransId, Source, ServiceState, Dispatcher) of
        {ok, ServiceStateNew} ->
            aspects_request_before(L, Type, Name, Pattern, RequestInfo, Request,
                                   Timeout, Priority, TransId, Source,
                                   ServiceStateNew, Dispatcher);
        {stop, _, _} = Stop ->
            Stop
    catch
        ErrorType:Error:ErrorStackTrace ->
            ?LOG_ERROR("aspect ~tp ~tp ~tp~n~tp",
                       [Aspect, ErrorType, Error, ErrorStackTrace]),
            {stop, {ErrorType, {Error, ErrorStackTrace}}, ServiceState}
    end;
aspects_request_before([F | L],
                       Type, Name, Pattern, RequestInfo, Request,
                       Timeout, Priority, TransId, Source,
                       ServiceState, Dispatcher) ->
    try F(Type, Name, Pattern, RequestInfo, Request,
          Timeout, Priority, TransId, Source, ServiceState, Dispatcher) of
        {ok, ServiceStateNew} ->
            aspects_request_before(L, Type, Name, Pattern, RequestInfo, Request,
                                   Timeout, Priority, TransId, Source,
                                   ServiceStateNew, Dispatcher);
        {stop, _, _} = Stop ->
            Stop
    catch
        ErrorType:Error:ErrorStackTrace ->
            ?LOG_ERROR("aspect ~tp ~tp ~tp~n~tp",
                       [F, ErrorType, Error, ErrorStackTrace]),
            {stop, {ErrorType, {Error, ErrorStackTrace}}, ServiceState}
    end.

aspects_request_after([], _, _, _, _, _, _, _, _, _, _, ServiceState, _) ->
    {ok, ServiceState};
aspects_request_after([{M, F} = Aspect | L],
                      Type, Name, Pattern, RequestInfo, Request,
                      Timeout, Priority, TransId, Source,
                      Result, ServiceState, Dispatcher) ->
    try M:F(Type, Name, Pattern, RequestInfo, Request,
            Timeout, Priority, TransId, Source,
            Result, ServiceState, Dispatcher) of
        {ok, ServiceStateNew} ->
            aspects_request_after(L, Type, Name, Pattern, RequestInfo, Request,
                                  Timeout, Priority, TransId, Source,
                                  Result, ServiceStateNew, Dispatcher);
        {stop, _, _} = Stop ->
            Stop
    catch
        ErrorType:Error:ErrorStackTrace ->
            ?LOG_ERROR("aspect ~tp ~tp ~tp~n~tp",
                       [Aspect, ErrorType, Error, ErrorStackTrace]),
            {stop, {ErrorType, {Error, ErrorStackTrace}}, ServiceState}
    end;
aspects_request_after([F | L],
                      Type, Name, Pattern, RequestInfo, Request,
                      Timeout, Priority, TransId, Source,
                      Result, ServiceState, Dispatcher) ->
    try F(Type, Name, Pattern, RequestInfo, Request,
          Timeout, Priority, TransId, Source,
          Result, ServiceState, Dispatcher) of
        {ok, ServiceStateNew} ->
            aspects_request_after(L, Type, Name, Pattern, RequestInfo, Request,
                                  Timeout, Priority, TransId, Source,
                                  Result, ServiceStateNew, Dispatcher);
        {stop, _, _} = Stop ->
            Stop
    catch
        ErrorType:Error:ErrorStackTrace ->
            ?LOG_ERROR("aspect ~tp ~tp ~tp~n~tp",
                       [F, ErrorType, Error, ErrorStackTrace]),
            {stop, {ErrorType, {Error, ErrorStackTrace}}, ServiceState}
    end.

aspects_info_before([], _, ServiceState, _) ->
    {ok, ServiceState};
aspects_info_before([{M, F} = Aspect | L], Request,
                    ServiceState, Dispatcher) ->
    try M:F(Request, ServiceState, Dispatcher) of
        {ok, ServiceStateNew} ->
            aspects_info_before(L, Request,
                                ServiceStateNew, Dispatcher);
        {stop, _, _} = Stop ->
            Stop
    catch
        ErrorType:Error:ErrorStackTrace ->
            ?LOG_ERROR("aspect ~tp ~tp ~tp~n~tp",
                       [Aspect, ErrorType, Error, ErrorStackTrace]),
            {stop, {ErrorType, {Error, ErrorStackTrace}}, ServiceState}
    end;
aspects_info_before([F | L], Request,
                    ServiceState, Dispatcher) ->
    try F(Request, ServiceState, Dispatcher) of
        {ok, ServiceStateNew} ->
            aspects_info_before(L, Request,
                                ServiceStateNew, Dispatcher);
        {stop, _, _} = Stop ->
            Stop
    catch
        ErrorType:Error:ErrorStackTrace ->
            ?LOG_ERROR("aspect ~tp ~tp ~tp~n~tp",
                       [F, ErrorType, Error, ErrorStackTrace]),
            {stop, {ErrorType, {Error, ErrorStackTrace}}, ServiceState}
    end.

aspects_info_after([], _, ServiceState, _) ->
    {ok, ServiceState};
aspects_info_after([{M, F} = Aspect | L], Request,
                   ServiceState, Dispatcher) ->
    try M:F(Request, ServiceState, Dispatcher) of
        {ok, ServiceStateNew} ->
            aspects_info_after(L, Request,
                               ServiceStateNew, Dispatcher);
        {stop, _, _} = Stop ->
            Stop
    catch
        ErrorType:Error:ErrorStackTrace ->
            ?LOG_ERROR("aspect ~tp ~tp ~tp~n~tp",
                       [Aspect, ErrorType, Error, ErrorStackTrace]),
            {stop, {ErrorType, {Error, ErrorStackTrace}}, ServiceState}
    end;
aspects_info_after([F | L], Request,
                   ServiceState, Dispatcher) ->
    try F(Request, ServiceState, Dispatcher) of
        {ok, ServiceStateNew} ->
            aspects_info_after(L, Request,
                               ServiceStateNew, Dispatcher);
        {stop, _, _} = Stop ->
            Stop
    catch
        ErrorType:Error:ErrorStackTrace ->
            ?LOG_ERROR("aspect ~tp ~tp ~tp~n~tp",
                       [F, ErrorType, Error, ErrorStackTrace]),
            {stop, {ErrorType, {Error, ErrorStackTrace}}, ServiceState}
    end.

spawn_opt_proc_lib(F, Options0) ->
    spawn_opt_pid(proc_lib, F, Options0).

spawn_opt_erlang(F, Options0) ->
    spawn_opt_pid(erlang, F, Options0).

spawn_opt_pid(M, F, Options) ->
    M:spawn_opt(fun() ->
        spawn_opt_options_after(Options),
        F()
    end, spawn_opt_options_before(Options)).

process_description([_ | _] = ProcessName) ->
    "cloudi_core internal service " ++ ProcessName.

process_description([_ | _] = ProcessName, ProcessIndex) ->
    "cloudi_core internal service " ++ ProcessName ++ " process index " ++
    erlang:integer_to_list(ProcessIndex).

update(_, _, #config_service_update{type = Type})
    when Type =/= internal ->
    {error, type};
update(_, _, #config_service_update{update_start = false}) ->
    {error, update_start_failed};
update(ServiceState, State,
       #config_service_update{
           module_state = undefined} = UpdatePlan) ->
    {ok, ServiceState, update_state(State, UpdatePlan)};
update(ServiceState, State,
       #config_service_update{
           module = Module,
           module_state = ModuleState,
           module_version_old = ModuleVersionOld} = UpdatePlan) ->
    ModuleVersionNew = reltool_util:module_version(Module),
    try ModuleState(ModuleVersionOld,
                    ModuleVersionNew,
                    ServiceState) of
        {ok, ServiceStateNew} ->
            {ok, ServiceStateNew, update_state(State, UpdatePlan)};
        {error, _} = Error ->
            Error;
        Invalid ->
            {error, {result, Invalid}}
    catch
        Type:Error ->
            {error, {Type, Error}}
    end.

update_state(#state{dispatcher = Dispatcher,
                    timeout_async = TimeoutAsyncOld,
                    timeout_sync = TimeoutSyncOld,
                    request_pid = RequestPid,
                    info_pid = InfoPid,
                    dest_refresh = DestRefreshOld,
                    cpg_data = GroupsOld,
                    dest_deny = DestDenyOld,
                    dest_allow = DestAllowOld,
                    options = ConfigOptionsOld} = State,
             #config_service_update{
                 dest_refresh = DestRefreshNew,
                 timeout_async = TimeoutAsyncNew,
                 timeout_sync = TimeoutSyncNew,
                 dest_list_deny = DestListDenyNew,
                 dest_list_allow = DestListAllowNew,
                 options_keys = OptionsKeys,
                 options = ConfigOptionsNew}) ->
    DestRefresh = if
        DestRefreshNew =:= undefined ->
            DestRefreshOld;
        is_atom(DestRefreshNew) ->
            DestRefreshNew
    end,
    Groups = destination_refresh_groups(DestRefresh, GroupsOld),
    TimeoutAsync = if
        TimeoutAsyncNew =:= undefined ->
            TimeoutAsyncOld;
        is_integer(TimeoutAsyncNew) ->
            TimeoutAsyncNew
    end,
    TimeoutSync = if
        TimeoutSyncNew =:= undefined ->
            TimeoutSyncOld;
        is_integer(TimeoutSyncNew) ->
            TimeoutSyncNew
    end,
    DestDeny = if
        DestListDenyNew =:= invalid ->
            DestDenyOld;
        DestListDenyNew =:= undefined ->
            undefined;
        is_list(DestListDenyNew) ->
            trie:new(DestListDenyNew)
    end,
    DestAllow = if
        DestListAllowNew =:= invalid ->
            DestAllowOld;
        DestListAllowNew =:= undefined ->
            undefined;
        is_list(DestListAllowNew) ->
            trie:new(DestListAllowNew)
    end,
    case lists:member(dispatcher_pid_options, OptionsKeys) of
        true ->
            #config_service_options{
                dispatcher_pid_options = PidOptionsOld} = ConfigOptionsOld,
            #config_service_options{
                dispatcher_pid_options = PidOptionsNew} = ConfigOptionsNew,
            update_pid_options(PidOptionsOld, PidOptionsNew);
        false ->
            ok
    end,
    ConfigOptions = update_state_receiver(ConfigOptionsOld,
                                          ConfigOptionsNew,
                                          OptionsKeys,
                                          RequestPid, InfoPid),
    if
        (DestRefreshOld =:= immediate_closest orelse
         DestRefreshOld =:= immediate_furthest orelse
         DestRefreshOld =:= immediate_random orelse
         DestRefreshOld =:= immediate_local orelse
         DestRefreshOld =:= immediate_remote orelse
         DestRefreshOld =:= immediate_newest orelse
         DestRefreshOld =:= immediate_oldest) andalso
        (DestRefreshNew =:= lazy_closest orelse
         DestRefreshNew =:= lazy_furthest orelse
         DestRefreshNew =:= lazy_random orelse
         DestRefreshNew =:= lazy_local orelse
         DestRefreshNew =:= lazy_remote orelse
         DestRefreshNew =:= lazy_newest orelse
         DestRefreshNew =:= lazy_oldest) ->
            #config_service_options{
                dest_refresh_delay = Delay,
                scope = Scope} = ConfigOptions,
            ok = destination_refresh(DestRefresh, Dispatcher, Delay, Scope);
        true ->
            ok
    end,
    State#state{timeout_async = TimeoutAsync,
                timeout_sync = TimeoutSync,
                dest_refresh = DestRefresh,
                cpg_data = Groups,
                dest_deny = DestDeny,
                dest_allow = DestAllow,
                options = ConfigOptions};
update_state(#state_duo{dispatcher = Dispatcher,
                        request_pid = RequestPid,
                        options = ConfigOptionsOld} = State,
             #config_service_update{
                 options_keys = OptionsKeys,
                 options = ConfigOptionsNew} = UpdatePlan) ->
    case lists:member(info_pid_options, OptionsKeys) of
        true ->
            #config_service_options{
                info_pid_options = PidOptionsOld} = ConfigOptionsOld,
            #config_service_options{
                info_pid_options = PidOptionsNew} = ConfigOptionsNew,
            update_pid_options(PidOptionsOld, PidOptionsNew);
        false ->
            ok
    end,
    ConfigOptions = update_state_receiver(ConfigOptionsOld,
                                          ConfigOptionsNew,
                                          OptionsKeys,
                                          RequestPid, undefined),
    OptionsKeysDispatcher = lists:filter(fun(OptionKey) ->
        OptionKey =:= dispatcher_pid_options
    end, OptionsKeys),
    Dispatcher ! {'cloudi_service_update_state',
                  UpdatePlan#config_service_update{
                      options_keys = OptionsKeysDispatcher,
                      options = duo_mode_dispatcher_options(ConfigOptions)}},
    State#state_duo{options = ConfigOptions}.

update_state_receiver(ConfigOptionsOld, ConfigOptionsNew, OptionsKeys,
                      RequestPid, InfoPid) ->
    if
        is_pid(RequestPid) ->
            case cloudi_lists:member_any([request_pid_uses,
                                          request_pid_options],
                                         OptionsKeys) of
                true ->
                    RequestPid ! {'cloudi_service_request_loop_exit', true},
                    ok;
                false ->
                    ok
            end;
        RequestPid =:= undefined ->
            ok
    end,
    if
        is_pid(InfoPid) ->
            case cloudi_lists:member_any([info_pid_uses,
                                          info_pid_options],
                                         OptionsKeys) of
                true ->
                    InfoPid ! {'cloudi_service_info_loop_exit', true},
                    ok;
                false ->
                    ok
            end;
        InfoPid =:= undefined ->
            ok
    end,
    case lists:member(monkey_chaos, OptionsKeys) of
        true ->
            #config_service_options{
                monkey_chaos = MonkeyChaosOld} = ConfigOptionsOld,
            cloudi_core_i_runtime_testing:
            monkey_chaos_destroy(MonkeyChaosOld);
        false ->
            ok
    end,
    ConfigOptions0 = cloudi_core_i_configuration:
                     service_options_copy(OptionsKeys,
                                          ConfigOptionsOld,
                                          ConfigOptionsNew),
    ConfigOptions1 = case lists:member(rate_request_max, OptionsKeys) of
        true ->
            #config_service_options{
                rate_request_max = RateRequest} = ConfigOptions0,
            RateRequestNew = if
                RateRequest =/= undefined ->
                    cloudi_core_i_rate_based_configuration:
                    rate_request_max_init(RateRequest);
                true ->
                    RateRequest
            end,
            ConfigOptions0#config_service_options{
                rate_request_max = RateRequestNew};
        false ->
            ConfigOptions0
    end,
    ConfigOptionsN = case lists:member(hibernate, OptionsKeys) of
        true ->
            #config_service_options{
                hibernate = Hibernate} = ConfigOptions1,
            HibernateNew = if
                not is_boolean(Hibernate) ->
                    cloudi_core_i_rate_based_configuration:
                    hibernate_init(Hibernate);
                true ->
                    Hibernate
            end,
            ConfigOptions1#config_service_options{
                hibernate = HibernateNew};
        false ->
            ConfigOptions1
    end,
    ConfigOptionsN.

%-*-Mode:erlang;coding:utf-8;tab-width:4;c-basic-offset:4;indent-tabs-mode:()-*-
% ex: set ft=erlang fenc=utf-8 sts=4 ts=4 sw=4 et nomod:
%%%
%%%------------------------------------------------------------------------
%%% @doc
%%% ==CloudI External Service==
%%% Erlang process which provides the connection to a thread in an
%%% external service.
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

-module(cloudi_core_i_services_external).
-author('mjtruog at protonmail dot com').

-behaviour(gen_statem).

%% external interface
-export([start_link/20,
         port/2,
         stdout/2,
         stderr/2,
         get_status/1,
         get_status/2]).

%% gen_statem callbacks
-export([callback_mode/0,
         init/1, handle_event/4,
         terminate/3, code_change/4]).

%% FSM States
-export(['CONNECT'/3,
         'INIT_WAIT'/3,
         'HANDLE'/3]).

-include("cloudi_logger.hrl").
-include("cloudi_core_i_configuration.hrl").
-include("cloudi_core_i_constants.hrl").
-include("cloudi_core_i_services_common_types.hrl").

-ifdef(ERLANG_OTP_VERSION_27_FEATURES).
-export([format_status/1]).
-else.
-export([format_status/2]).
-endif.

% message type enumeration
-define(MESSAGE_INIT,                1).
-define(MESSAGE_SEND_ASYNC,          2).
-define(MESSAGE_SEND_SYNC,           3).
-define(MESSAGE_RECV_ASYNC,          4).
-define(MESSAGE_RETURN_ASYNC,        5).
-define(MESSAGE_RETURN_SYNC,         6).
-define(MESSAGE_RETURNS_ASYNC,       7).
-define(MESSAGE_KEEPALIVE,           8).
-define(MESSAGE_REINIT,              9).
-define(MESSAGE_SUBSCRIBE_COUNT,    10).
-define(MESSAGE_TERM,               11).

-record(state,
    {
        % state record fields common for cloudi_core_i_services_common.hrl:

        % ( 2) self() value cached
        dispatcher :: pid(),
        % ( 3) timeout enforcement for any outgoing service requests
        send_timeouts = #{}
            :: #{cloudi:trans_id() :=
                 {passive, pid() | undefined, reference()}} |
               list({cloudi:trans_id(),
                     {passive, pid() | undefined, reference()}}),
        % ( 4) if a sent service request timeout is greater than the
        % service configuration option request_timeout_immediate_max,
        % monitor the destination process with the sent service request
        % transaction id
        send_timeout_monitors = #{}
            :: #{pid() := {reference(), list(cloudi:trans_id())}} |
               list({pid(), {reference(), list(cloudi:trans_id())}}),
        % ( 5) timeout enforcement for any incoming service requests
        recv_timeouts = #{}
            :: #{cloudi:trans_id() := reference()} |
               list({cloudi:trans_id(), reference()}),
        % ( 6) timeout enforcement for any responses to
        % asynchronous outgoing service requests
        async_responses = #{}
            :: #{cloudi:trans_id() := {binary(), binary()}} |
               list({cloudi:trans_id(), {binary(), binary()}}),
        % ( 7) deferred stop reason to use when done processing
        stop = undefined
            :: atom() | {shutdown, atom()},
        % ( 8) pending update configuration
        update_plan = undefined
            :: undefined | #config_service_update{},
        % ( 9) is the external service OS process thread suspended?
        suspended = #suspended{}
            :: #suspended{},
        % (10) is the external service OS process thread busy?
        queue_requests = true :: boolean(),
        % (11) queued incoming service requests
        queued = pqueue4:new()
            :: pqueue4:pqueue4(
                   cloudi:message_service_request()) |
               list({cloudi:priority_value(), any()}),
        % (12) queued size in bytes
        queued_size = 0 :: non_neg_integer(),
        % (13) erlang:system_info(wordsize) cached
        queued_word_size :: pos_integer(),

        % state record fields unique to the external thread Erlang process:

        % (14) external thread connection protocol
        protocol = undefined :: undefined | tcp | udp | local,
        % (15) external thread connection port
        port = undefined :: undefined | non_neg_integer(),
        % (16) wait for cloudi_core_i_services_monitor:process_init_begin/2
        % to send cloudi_service_init_begin when all of the service instance
        % processes have been spawned
        initialize = false :: boolean(),
        % (17) udp incoming data port
        incoming_port = undefined :: undefined | inet:port_number(),
        % (18) tcp listener
        listener = undefined,
        % (19) tcp acceptor
        acceptor = undefined,
        % (20) local socket filesystem path
        socket_path = undefined :: undefined | string(),
        % (21) common socket options
        socket_options = undefined :: undefined | list(),
        % (22) data socket
        socket = undefined,
        % (23) service state for executing aspect functions
        % (as assigned from aspect function execution)
        service_state = undefined,
        % (24) request data currently being processed by the OS process
        request_data = undefined
            :: undefined |
               {cloudi:message_service_request(),
                fun((cloudi:timeout_value_milliseconds()) ->
                    cloudi:timeout_value_milliseconds())},
        % (25) 0-based index of the process in all service instance processes
        process_index :: non_neg_integer(),
        % (26) current count of all Erlang processes for the service instance
        process_count :: pos_integer(),
        % (27) command line of OS execve
        command_line :: list(string()),
        % (28) subscribe/unsubscribe name prefix set in service configuration
        prefix :: cloudi:service_name_pattern(),
        % (29) pre-poll() timeout in the external service thread
        timeout_init
            :: cloudi_service_api:timeout_initialize_value_milliseconds(),
        % (30) default timeout for send_async set in service configuration
        timeout_async
            :: cloudi_service_api:timeout_send_async_value_milliseconds(),
        % (31) default timeout for send_sync set in service configuration
        timeout_sync
            :: cloudi_service_api:timeout_send_sync_value_milliseconds(),
        % (32) post-poll() timeout in the external service thread
        timeout_term
            :: cloudi_service_api:timeout_terminate_value_milliseconds(),
        % (33) OS process pid for SIGKILL
        os_pid = undefined :: undefined | pos_integer(),
        % (34) udp keepalive succeeded
        keepalive = undefined :: undefined | received,
        % (35) init timeout handler
        init_timer :: undefined | reference(),
        % (36) timeout enforcement of fatal_timeout
        fatal_timer = undefined :: undefined | reference(),
        % (37) transaction id (UUIDv1) generator
        uuid_generator :: uuid:state(),
        % (38) how service destination lookups occur for a service request send
        dest_refresh :: cloudi_service_api:dest_refresh(),
        % (39) cached cpg data for lazy destination refresh methods
        cpg_data
            :: undefined | cpg_data:state() |
               list({cloudi:service_name_pattern(), any()}),
        % (40) old subscriptions to remove after an update's initialization
        subscribed = []
            :: list({cloudi:service_name_pattern(), pos_integer()}),
        % (41) ACL lookup for denied destinations
        dest_deny
            :: undefined | trie:trie() |
               list({cloudi:service_name_pattern(), any()}),
        % (42) ACL lookup for allowed destinations
        dest_allow
            :: undefined | trie:trie() |
               list({cloudi:service_name_pattern(), any()}),
        % (43) service configuration options
        options
            :: #config_service_options{} |
               cloudi_service_api:service_options_external()
    }).

-record(state_socket,
    {
        % write/read fields
        protocol
            :: tcp | udp | local,
        port
            :: non_neg_integer(),
        incoming_port
            :: undefined | inet:port_number(),
        listener,
        acceptor,
        socket_path
            :: undefined | string(),
        socket_options
            :: list(),
        socket,
        % read-only fields
        timeout_term
            :: undefined |
               cloudi_service_api:timeout_terminate_value_milliseconds(),
        os_pid
            :: undefined | pos_integer(),
        cgroup
            :: cloudi_service_api:cgroup_external()
    }).

-dialyzer({no_improper_lists,
           ['init_out'/12,
            'send_async_out'/8,
            'send_sync_out'/8,
            'return_async_out'/1,
            'return_sync_out'/2,
            'return_sync_out'/3,
            'returns_async_out'/1,
            'recv_async_out'/2,
            'recv_async_out'/3]}).

-include("cloudi_core_i_services_common.hrl").

%%%------------------------------------------------------------------------
%%% External interface functions
%%%------------------------------------------------------------------------

start_link(Protocol, SocketPath, ThreadIndex, ProcessIndex, ProcessCount,
           TimeStart, TimeRestart, Restarts,
           CommandLine, BufferSize, Timeout, [PrefixC | _] = Prefix,
           TimeoutAsync, TimeoutSync, TimeoutTerm,
           DestRefresh, DestDeny, DestAllow,
           #config_service_options{
               scope = Scope,
               dispatcher_pid_options = PidOptions} = ConfigOptions, ID)
    when is_atom(Protocol), is_list(SocketPath), is_integer(ThreadIndex),
         is_integer(ProcessIndex), is_integer(ProcessCount),
         is_integer(TimeStart), is_integer(Restarts),
         is_list(CommandLine),
         is_integer(BufferSize), is_integer(Timeout), is_integer(PrefixC),
         is_integer(TimeoutAsync), is_integer(TimeoutSync),
         is_integer(TimeoutTerm) ->
    true = (Protocol =:= tcp) orelse
           (Protocol =:= udp) orelse
           (Protocol =:= local),
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
            gen_statem:start_link(?MODULE,
                                  [Protocol, SocketPath,
                                   ThreadIndex, ProcessIndex, ProcessCount,
                                   TimeStart, TimeRestart, Restarts,
                                   CommandLine, BufferSize, Timeout, Prefix,
                                   TimeoutAsync, TimeoutSync, TimeoutTerm,
                                   DestRefresh, DestDeny, DestAllow,
                                   ConfigOptions, ID],
                                  [{timeout, Timeout + ?TIMEOUT_DELTA},
                                   {spawn_opt,
                                    spawn_opt_options_before(PidOptions)}]);
        {error, Reason} ->
            {error, {service_options_scope_invalid, Reason}}
    end.

port(Dispatcher, Timeout)
    when is_pid(Dispatcher), is_integer(Timeout) ->
    gen_statem:call(Dispatcher, port,
                    {dirty_timeout, Timeout + ?TIMEOUT_DELTA}).

stdout(OSPid, Output) ->
    % uses a fake file name and a fake line number
    cloudi_core_i_logger_interface:info("STDOUT", OSPid,
                                        undefined, undefined,
                                        Output, undefined).

stderr(OSPid, Output) ->
    % uses a fake file name and a fake line number
    cloudi_core_i_logger_interface:error("STDERR", OSPid,
                                         undefined, undefined,
                                         Output, undefined).

get_status(Dispatcher) ->
    get_status(Dispatcher, 5000).

get_status(Dispatcher, Timeout) ->
    sys:get_status(Dispatcher, Timeout).

%%%------------------------------------------------------------------------
%%% Callback functions from gen_statem
%%%------------------------------------------------------------------------

callback_mode() -> state_functions.

init([Protocol, SocketPath, ThreadIndex, ProcessIndex, ProcessCount,
      TimeStart, TimeRestart, Restarts,
      CommandLine, BufferSize, Timeout, Prefix,
      TimeoutAsync, TimeoutSync, TimeoutTerm,
      DestRefresh, DestDeny, DestAllow,
      #config_service_options{
          dispatcher_pid_options = PidOptions,
          bind = Bind} = ConfigOptions, ID])
    when Protocol =:= tcp;
         Protocol =:= udp;
         Protocol =:= local ->
    ok = spawn_opt_options_after(PidOptions),
    Uptime = uptime(TimeStart, TimeRestart, Restarts),
    erlang:put(?SERVICE_ID_PDICT_KEY, ID),
    erlang:put(?SERVICE_UPTIME_PDICT_KEY, Uptime),
    erlang:put(?SERVICE_FILE_PDICT_KEY, hd(CommandLine)),
    erlang:put(?PROCESS_DESCRIPTION_PDICT_KEY,
               process_description("dispatcher (sender/receiver)",
                                   ProcessIndex)),
    Dispatcher = self(),
    InitTimer = erlang:send_after(Timeout, Dispatcher,
                                  'cloudi_service_init_timeout'),
    case socket_open(Protocol, SocketPath, ThreadIndex, BufferSize) of
        {ok, StateSocket} ->
            ok = quickrand:seed([quickrand]),
            WordSize = erlang:system_info(wordsize),
            ok = cloudi_core_i_concurrency:bind_init(Bind),
            ConfigOptionsNew = check_init_send(ConfigOptions),
            Variant = application:get_env(cloudi_core, uuid_v1_variant,
                                          ?UUID_V1_VARIANT_DEFAULT),
            {ok, MacAddress} = application:get_env(cloudi_core, mac_address),
            {ok, TimestampType} = application:get_env(cloudi_core,
                                                      timestamp_type),
            UUID = uuid:new(Dispatcher,
                                     [{timestamp_type, TimestampType},
                                      {mac_address, MacAddress},
                                      {variant, Variant}]),
            Groups = destination_refresh_groups(DestRefresh, undefined),
            #config_service_options{
                dest_refresh_start = Delay,
                scope = Scope} = ConfigOptionsNew,
            false = erlang:process_flag(trap_exit, true),
            ok = destination_refresh(DestRefresh, Dispatcher, Delay, Scope),
            State = #state{dispatcher = Dispatcher,
                           queued_word_size = WordSize,
                           process_index = ProcessIndex,
                           process_count = ProcessCount,
                           command_line = CommandLine,
                           prefix = Prefix,
                           timeout_init = Timeout,
                           timeout_async = TimeoutAsync,
                           timeout_sync = TimeoutSync,
                           timeout_term = TimeoutTerm,
                           init_timer = InitTimer,
                           uuid_generator = UUID,
                           dest_refresh = DestRefresh,
                           cpg_data = Groups,
                           dest_deny = DestDeny,
                           dest_allow = DestAllow,
                           options = ConfigOptionsNew},
            {ok, 'CONNECT',
             socket_data_to_state(StateSocket, State)};
        {error, Reason} ->
            {stop, Reason}
    end.

handle_event(EventType, EventContent, StateName, State) ->
    Event = {EventType, EventContent},
    ?LOG_WARN("Unknown event \"~w\"", [Event]),
    {stop, {StateName, undefined_event, Event}, State}.

% incoming messages (from the port socket)

'CONNECT'({call, From}, port, #state{port = Port}) ->
    {keep_state_and_data, {reply, From, Port}};

'CONNECT'(connection, {'pid', OSPid}, State) ->
    {keep_state, os_pid_set(OSPid, State)};

'CONNECT'(connection, 'init', #state{initialize = Ready} = State) ->
    if
        Ready =:= true ->
            connection_init(State);
        Ready =:= false ->
            {next_state, 'INIT_WAIT', State}
    end;

'CONNECT'(info, {inet_async, _, _, {ok, _}} = Accept, State) ->
    StateSocket = socket_data_from_state(State),
    StateSocketNew = socket_accept(Accept, StateSocket),
    {keep_state,
     socket_data_to_state(StateSocketNew, State)};

'CONNECT'(info, {inet_async, Listener, Acceptor, Error},
          #state{protocol = Protocol,
                 listener = Listener,
                 acceptor = Acceptor})
    when Protocol =:= tcp; Protocol =:= local ->
    {stop, {?FUNCTION_NAME, inet_async, Error}};

'CONNECT'(info, cloudi_service_init_begin, State) ->
    {keep_state, State#state{initialize = true}};

'CONNECT'(info, EventContent, State) ->
    handle_info(EventContent, ?FUNCTION_NAME, State);

'CONNECT'(EventType, EventContent, _) ->
    Event = {EventType, EventContent},
    {stop, {?FUNCTION_NAME, undefined_message, Event}}.

'INIT_WAIT'({call, From}, port, #state{port = Port}) ->
    {keep_state_and_data, {reply, From, Port}};

'INIT_WAIT'(info, cloudi_service_init_begin, State) ->
    connection_init(State#state{initialize = true});

'INIT_WAIT'(info, EventContent, State) ->
    handle_info(EventContent, ?FUNCTION_NAME, State);

'INIT_WAIT'(EventType, EventContent, _) ->
    Event = {EventType, EventContent},
    {stop, {?FUNCTION_NAME, undefined_message, Event}}.

'HANDLE'(connection,
         'polling',
         #state{dispatcher = Dispatcher,
                service_state = ServiceState,
                command_line = CommandLine,
                prefix = Prefix,
                timeout_init = Timeout,
                os_pid = OSPid,
                init_timer = InitTimer,
                subscribed = Subscriptions,
                options = #config_service_options{
                    scope = Scope,
                    aspects_init_after = Aspects} = ConfigOptions} = State) ->
    case aspects_init_after(Aspects, CommandLine, Prefix, Timeout,
                            ServiceState) of
        {ok, ServiceStateNew} ->
            % initialization is now complete because the
            % CloudI API poll function has been called for the
            % first time (i.e., by the service code)
            % and all the aspects_init_after functions have been called.
            ok = cancel_timer_async(InitTimer),
            ConfigOptionsNew = check_init_receive(ConfigOptions),
            ok = cloudi_core_i_services_monitor:
                 process_init_end(Dispatcher, OSPid),
            if
                Subscriptions == [] ->
                    ok;
                true ->
                    % if this is a new OS process after an update,
                    % the old subscriptions are removed so that only the
                    % subscriptions from the new initialization remain
                    ok = cpg:leave_counts(Scope, Subscriptions,
                                                   Dispatcher, infinity)
            end,
            {keep_state,
             process_queues(State#state{service_state = ServiceStateNew,
                                        init_timer = undefined,
                                        subscribed = [],
                                        options = ConfigOptionsNew})};
        {stop, Reason, ServiceStateNew} ->
            {stop, Reason,
             State#state{service_state = ServiceStateNew,
                         init_timer = undefined}}
    end;

'HANDLE'(connection, Request,
         #state{init_timer = InitTimer} = State)
    when is_reference(InitTimer), is_tuple(Request),
         (element(1, Request) =:= 'send_sync' orelse
          element(1, Request) =:= 'recv_async') ->
    % service request responses are always handled after initialization
    % is successful though it is possible for the
    % service request response to be received before initialization
    % is complete (the response remains queued)
    {stop, {error, invalid_state}, State};

'HANDLE'(connection,
         {'subscribe', Suffix},
         #state{dispatcher = Dispatcher,
                prefix = Prefix,
                options = #config_service_options{
                    count_process_dynamic = CountProcessDynamic,
                    scope = Scope}}) ->
    true = is_list(Suffix),
    case cloudi_core_i_rate_based_configuration:
         count_process_dynamic_terminated(CountProcessDynamic) of
        false ->
            Pattern = Prefix ++ Suffix,
            _ = trie:is_pattern2_bytes(Pattern),
            ok = cpg:join(Scope, Pattern,
                                   Dispatcher, infinity);
        true ->
            ok
    end,
    keep_state_and_data;

'HANDLE'(connection,
         {'subscribe_count', Suffix},
         #state{dispatcher = Dispatcher,
                prefix = Prefix,
                options = #config_service_options{
                    scope = Scope}} = State) ->
    true = is_list(Suffix),
    Pattern = Prefix ++ Suffix,
    _ = trie:is_pattern2_bytes(Pattern),
    Count = cpg:join_count(Scope, Pattern,
                                    Dispatcher, infinity),
    ok = send('subscribe_count_out'(Count), State),
    keep_state_and_data;

'HANDLE'(connection,
         {'unsubscribe', Suffix},
         #state{dispatcher = Dispatcher,
                prefix = Prefix,
                options = #config_service_options{
                    count_process_dynamic = CountProcessDynamic,
                    scope = Scope}}) ->
    true = is_list(Suffix),
    case cloudi_core_i_rate_based_configuration:
         count_process_dynamic_terminated(CountProcessDynamic) of
        false ->
            Pattern = Prefix ++ Suffix,
            _ = trie:is_pattern2_bytes(Pattern),
            case cpg:leave(Scope, Pattern,
                                    Dispatcher, infinity) of
                ok ->
                    keep_state_and_data;
                error ->
                    {stop, {error, {unsubscribe_invalid, Pattern}}}
            end;
        true ->
            keep_state_and_data
    end;

'HANDLE'(connection,
         {'send_async', Name, RequestInfo, Request, Timeout, Priority},
         #state{dest_deny = DestDeny,
                dest_allow = DestAllow} = State) ->
    true = trie:is_bytestring(Name),
    true = is_integer(Timeout),
    true = (Timeout >= 0) andalso
           (Timeout =< ?TIMEOUT_MAX_ERLANG),
    true = is_integer(Priority),
    true = (Priority >= ?PRIORITY_HIGH) andalso
           (Priority =< ?PRIORITY_LOW),
    case destination_allowed(Name, DestDeny, DestAllow) of
        true ->
            handle_send_async(Name, RequestInfo, Request,
                              Timeout, Priority, State);
        false ->
            ok = send('return_async_out'(), State),
            keep_state_and_data
    end;

'HANDLE'(connection,
         {'send_sync', Name, RequestInfo, Request, Timeout, Priority},
         #state{dest_deny = DestDeny,
                dest_allow = DestAllow} = State) ->
    true = trie:is_bytestring(Name),
    true = is_integer(Timeout),
    true = (Timeout >= 0) andalso
           (Timeout =< ?TIMEOUT_MAX_ERLANG),
    true = is_integer(Priority),
    true = (Priority >= ?PRIORITY_HIGH) andalso
           (Priority =< ?PRIORITY_LOW),
    case destination_allowed(Name, DestDeny, DestAllow) of
        true ->
            handle_send_sync(Name, RequestInfo, Request,
                             Timeout, Priority, State);
        false ->
            ok = send('return_sync_out'(), State),
            keep_state_and_data
    end;

'HANDLE'(connection,
         {'mcast_async', Name, RequestInfo, Request, Timeout, Priority},
         #state{dest_deny = DestDeny,
                dest_allow = DestAllow} = State) ->
    true = trie:is_bytestring(Name),
    true = is_integer(Timeout),
    true = (Timeout >= 0) andalso
           (Timeout =< ?TIMEOUT_MAX_ERLANG),
    true = is_integer(Priority),
    true = (Priority >= ?PRIORITY_HIGH) andalso
           (Priority =< ?PRIORITY_LOW),
    case destination_allowed(Name, DestDeny, DestAllow) of
        true ->
            handle_mcast_async(Name, RequestInfo, Request,
                               Timeout, Priority, State);
        false ->
            ok = send('returns_async_out'(), State),
            keep_state_and_data
    end;

'HANDLE'(connection,
         {ForwardType, NameNext, RequestInfoNext, RequestNext,
          TimeoutNext, PriorityNext, TransId, Source},
         #state{dispatcher = Dispatcher,
                service_state = ServiceState,
                request_data = {{SendType, Name, Pattern, RequestInfo, Request,
                                 Timeout, Priority, TransId, Source},
                                RequestTimeoutF},
                fatal_timer = FatalTimer,
                dest_refresh = DestRefresh,
                cpg_data = Groups,
                dest_deny = DestDeny,
                dest_allow = DestAllow,
                options = #config_service_options{
                    request_name_lookup = RequestNameLookup,
                    response_timeout_immediate_max =
                        ResponseTimeoutImmediateMax,
                    scope = Scope,
                    aspects_request_after = AspectsAfter}} = State)
    when ForwardType =:= 'forward_async';
         ForwardType =:= 'forward_sync' ->
    true = trie:is_bytestring(NameNext),
    true = is_integer(TimeoutNext),
    true = (TimeoutNext >= 0) andalso
           (TimeoutNext =< ?TIMEOUT_MAX_ERLANG),
    true = is_integer(PriorityNext),
    true = (PriorityNext >= ?PRIORITY_HIGH) andalso
           (PriorityNext =< ?PRIORITY_LOW),
    Type = if
        ForwardType =:= 'forward_async' ->
            SendType = 'cloudi_service_send_async',
            send_async;
        ForwardType =:= 'forward_sync' ->
            SendType = 'cloudi_service_send_sync',
            send_sync
    end,
    Result = {forward, NameNext,
              RequestInfoNext, RequestNext,
              TimeoutNext, PriorityNext},
    case aspects_request_after(AspectsAfter, Type,
                               Name, Pattern, RequestInfo, Request,
                               Timeout, Priority, TransId, Source,
                               Result, ServiceState) of
        {ok, ServiceStateNew} ->
            TimeoutNew = if
                TimeoutNext == Timeout ->
                    RequestTimeoutF(Timeout);
                true ->
                    TimeoutNext
            end,
            ok = fatal_timer_end(FatalTimer),
            ok = case destination_allowed(NameNext, DestDeny, DestAllow) of
                true ->
                    {ForwardRetryType,
                     ForwardRetryInterval} = if
                        ForwardType =:= 'forward_async' ->
                            {'cloudi_service_forward_async_retry',
                             ?FORWARD_ASYNC_INTERVAL};
                        ForwardType =:= 'forward_sync' ->
                            {'cloudi_service_forward_sync_retry',
                             ?FORWARD_SYNC_INTERVAL}
                    end,
                    case destination_get(DestRefresh, Scope, NameNext, Source,
                                         Groups, TimeoutNew) of
                        {error, timeout} ->
                            ok;
                        {error, _}
                            when RequestNameLookup =:= async ->
                            return_null_response(SendType, Name, Pattern,
                                                 TimeoutNew, TransId, Source,
                                                 ResponseTimeoutImmediateMax);
                        {error, _}
                            when TimeoutNew >= ForwardRetryInterval ->
                            Retry = {ForwardRetryType,
                                     NameNext, RequestInfoNext, RequestNext,
                                     TimeoutNew - ForwardRetryInterval,
                                     PriorityNext, TransId, Source},
                            erlang:send_after(ForwardRetryInterval,
                                              Dispatcher, Retry),
                            ok;
                        {error, _} ->
                            ok;
                        {ok, PatternNext, PidNext}
                            when TimeoutNew >= ?FORWARD_DELTA ->
                            PidNext ! {SendType, NameNext, PatternNext,
                                       RequestInfoNext, RequestNext,
                                       TimeoutNew - ?FORWARD_DELTA,
                                       PriorityNext, TransId, Source},
                            ok;
                        _ ->
                            ok
                    end;
                false ->
                    ok
            end,
            StateNew = State#state{service_state = ServiceStateNew,
                                   request_data = undefined,
                                   fatal_timer = undefined},
            {keep_state, process_queues(StateNew)};
        {stop, Reason, ServiceStateNew} ->
            ok = fatal_timer_end(FatalTimer),
            {stop, Reason,
             State#state{service_state = ServiceStateNew,
                         request_data = undefined,
                         fatal_timer = undefined}}
    end;

'HANDLE'(connection,
         {ReturnType, Name, Pattern, ResponseInfo, Response,
          TimeoutNext, TransId, Source},
         #state{service_state = ServiceState,
                request_data = {{_, Name, Pattern, RequestInfo, Request,
                                 Timeout, Priority, TransId, Source},
                                RequestTimeoutF},
                fatal_timer = FatalTimer,
                options = #config_service_options{
                    response_timeout_immediate_max =
                        ResponseTimeoutImmediateMax,
                    aspects_request_after =
                        AspectsAfter}} = State)
    when ReturnType =:= 'return_async';
         ReturnType =:= 'return_sync' ->
    true = is_integer(TimeoutNext),
    true = (TimeoutNext >= 0) andalso
           (TimeoutNext =< ?TIMEOUT_MAX_ERLANG),
    Type = if
        ReturnType =:= 'return_async' ->
            send_async;
        ReturnType =:= 'return_sync' ->
            send_sync
    end,
    Result = if
        ResponseInfo == <<>>, Response == <<>>,
        TimeoutNext < ResponseTimeoutImmediateMax ->
            noreply;
        true ->
            {reply, ResponseInfo, Response}
    end,
    case aspects_request_after(AspectsAfter, Type,
                               Name, Pattern, RequestInfo, Request,
                               Timeout, Priority, TransId, Source,
                               Result, ServiceState) of
        {ok, ServiceStateNew} ->
            TimeoutNew = if
                TimeoutNext == Timeout ->
                    RequestTimeoutF(Timeout);
                true ->
                    TimeoutNext
            end,
            ok = fatal_timer_end(FatalTimer),
            if
                Result =:= noreply ->
                    ok;
                ReturnType =:= 'return_async' ->
                    Source ! {'cloudi_service_return_async',
                              Name, Pattern, ResponseInfo, Response,
                              TimeoutNew, TransId, Source},
                    ok;
                ReturnType =:= 'return_sync' ->
                    Source ! {'cloudi_service_return_sync',
                              Name, Pattern, ResponseInfo, Response,
                              TimeoutNew, TransId, Source},
                    ok
            end,
            StateNew = State#state{service_state = ServiceStateNew,
                                   request_data = undefined,
                                   fatal_timer = undefined},
            {keep_state, process_queues(StateNew)};
        {stop, Reason, ServiceStateNew} ->
            ok = fatal_timer_end(FatalTimer),
            {stop, Reason,
             State#state{service_state = ServiceStateNew,
                         request_data = undefined,
                         fatal_timer = undefined}}
    end;

'HANDLE'(connection, {'recv_async', Timeout, TransId, Consume}, State) ->
    true = is_integer(Timeout),
    true = (Timeout >= 0) andalso
           (Timeout =< ?TIMEOUT_MAX_ERLANG),
    true = is_boolean(Consume),
    handle_recv_async(Timeout, TransId, Consume, State);

'HANDLE'(connection, 'keepalive', State) ->
    {keep_state, State#state{keepalive = received}};

'HANDLE'(connection, {'shutdown', Reason},
         #state{dispatcher = Dispatcher,
                os_pid = OSPid,
                init_timer = InitTimer} = State) ->
    StopReason = if
        Reason == "" ->
            shutdown;
        is_list(Reason) ->
            {shutdown, Reason};
        true ->
            {shutdown, cloudi_string:term_to_list_compact(Reason)}
    end,
    if
        is_reference(InitTimer) ->
            % initialization was interrupted by the shutdown request
            ok = cancel_timer_async(InitTimer),
            % initialization is considered successful
            ok = cloudi_core_i_services_monitor:
                 process_init_end(Dispatcher, OSPid),
            {stop, StopReason, State#state{init_timer = undefined}};
        InitTimer =:= undefined ->
            {stop, StopReason}
    end;

'HANDLE'(info,
         {'cloudi_service_send_async_retry', Name, RequestInfo, Request,
          Timeout, Priority}, State) ->
    handle_send_async(Name, RequestInfo, Request,
                      Timeout, Priority, State);

'HANDLE'(info,
         {'cloudi_service_send_sync_retry', Name, RequestInfo, Request,
          Timeout, Priority}, State) ->
    handle_send_sync(Name, RequestInfo, Request,
                     Timeout, Priority, State);

'HANDLE'(info,
         {'cloudi_service_mcast_async_retry', Name, RequestInfo, Request,
          Timeout, Priority}, State) ->
    handle_mcast_async(Name, RequestInfo, Request,
                       Timeout, Priority, State);

'HANDLE'(info,
         {ForwardRetryType, Name, RequestInfo, Request,
          Timeout, Priority, TransId, Source},
         #state{dispatcher = Dispatcher,
                dest_refresh = DestRefresh,
                cpg_data = Groups,
                options = #config_service_options{
                    request_name_lookup = RequestNameLookup,
                    scope = Scope}})
    when ForwardRetryType =:= 'cloudi_service_forward_async_retry';
         ForwardRetryType =:= 'cloudi_service_forward_sync_retry' ->
    {SendType,
     ForwardRetryInterval} = if
        ForwardRetryType =:= 'cloudi_service_forward_async_retry' ->
            {'cloudi_service_send_async',
             ?FORWARD_ASYNC_INTERVAL};
        ForwardRetryType =:= 'cloudi_service_forward_sync_retry' ->
            {'cloudi_service_send_sync',
             ?FORWARD_SYNC_INTERVAL}
    end,
    case destination_get(DestRefresh, Scope, Name, Source, Groups, Timeout) of
        {error, timeout} ->
            ok;
        {error, _} when RequestNameLookup =:= async ->
            ok;
        {error, _} when Timeout >= ForwardRetryInterval ->
            erlang:send_after(ForwardRetryInterval, Dispatcher,
                              {ForwardRetryType,
                               Name, RequestInfo, Request,
                               Timeout - ForwardRetryInterval,
                               Priority, TransId, Source}),
            ok;
        {error, _} ->
            ok;
        {ok, Pattern, PidNext} when Timeout >= ?FORWARD_DELTA ->
            PidNext ! {SendType, Name, Pattern,
                       RequestInfo, Request,
                       Timeout - ?FORWARD_DELTA,
                       Priority, TransId, Source},
            ok;
        _ ->
            ok
    end,
    keep_state_and_data;

'HANDLE'(info,
         {'cloudi_service_recv_async_retry', Timeout, TransId, Consume},
         State) ->
    handle_recv_async(Timeout, TransId, Consume, State);

'HANDLE'(info,
         {SendType, Name, Pattern, RequestInfo, Request,
          Timeout, _, TransId, Source},
         #state{options = #config_service_options{
                    response_timeout_immediate_max =
                        ResponseTimeoutImmediateMax}})
    when SendType =:= 'cloudi_service_send_async' orelse
         SendType =:= 'cloudi_service_send_sync',
         is_binary(Request) =:= false orelse
         is_binary(RequestInfo) =:= false orelse
         Timeout =:= 0 ->
    ok = return_null_response(SendType, Name, Pattern,
                              Timeout, TransId, Source,
                              ResponseTimeoutImmediateMax),
    keep_state_and_data;

'HANDLE'(info,
         {SendType, Name, Pattern, RequestInfo, Request,
          Timeout, Priority, TransId, Source} = T,
         #state{dispatcher = Dispatcher,
                queue_requests = false,
                service_state = ServiceState,
                options = #config_service_options{
                    rate_request_max = RateRequest,
                    response_timeout_immediate_max =
                        ResponseTimeoutImmediateMax} = ConfigOptions} = State)
    when SendType =:= 'cloudi_service_send_async' orelse
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
            #config_service_options{
                request_timeout_adjustment = RequestTimeoutAdjustment,
                aspects_request_before = AspectsBefore} = ConfigOptionsNew,
            FatalTimer = fatal_timer_start(Timeout, Dispatcher,
                                           ConfigOptionsNew),
            RequestTimeoutF =
                request_timeout_adjustment_f(RequestTimeoutAdjustment),
            case aspects_request_before(AspectsBefore, Type,
                                        Name, Pattern, RequestInfo, Request,
                                        Timeout, Priority, TransId, Source,
                                        ServiceState) of
                {ok, ServiceStateNew} ->
                    if
                        SendType =:= 'cloudi_service_send_async' ->
                            ok = send('send_async_out'(Name, Pattern,
                                                       RequestInfo, Request,
                                                       Timeout, Priority,
                                                       TransId, Source),
                                      State);
                        SendType =:= 'cloudi_service_send_sync' ->
                            ok = send('send_sync_out'(Name, Pattern,
                                                      RequestInfo, Request,
                                                      Timeout, Priority,
                                                      TransId, Source),
                                      State)
                    end,
                    {keep_state,
                     State#state{queue_requests = true,
                                 service_state = ServiceStateNew,
                                 request_data = {T, RequestTimeoutF},
                                 fatal_timer = FatalTimer,
                                 options = ConfigOptionsNew}};
                {stop, Reason, ServiceStateNew} ->
                    {stop, Reason,
                     State#state{service_state = ServiceStateNew,
                                 fatal_timer = FatalTimer,
                                 options = ConfigOptionsNew}}
            end;
        RateRequestOk =:= false ->
            ok = return_null_response(SendType, Name, Pattern,
                                      Timeout, TransId, Source,
                                      ResponseTimeoutImmediateMax),
            {keep_state,
             State#state{options = ConfigOptions#config_service_options{
                             rate_request_max = RateRequestNew}}}
    end;

'HANDLE'(info,
         {SendType, Name, Pattern, _, _,
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
                        ResponseTimeoutImmediateMax} = ConfigOptions} = State)
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
    if
        QueueLimitOk, QueueSizeOk, RateRequestOk ->
            {keep_state,
             recv_timeout_start(Timeout, Priority, TransId,
                                Size, T, StateNew)};
        true ->
            ok = return_null_response(SendType, Name, Pattern,
                                      Timeout, TransId, Source,
                                      ResponseTimeoutImmediateMax),
            {keep_state, StateNew}
    end;

'HANDLE'(info,
         {'cloudi_service_recv_timeout', Priority, TransId, Size},
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
    {keep_state,
     State#state{recv_timeouts = maps:remove(TransId, RecvTimeouts),
                 queued = QueueNew,
                 queued_size = QueuedSizeNew}};

'HANDLE'(info,
         {'cloudi_service_return_async', _Name, _Pattern,
          ResponseInfo, Response, TimeoutOld, TransId, Source},
         #state{dispatcher = Dispatcher,
                send_timeouts = SendTimeouts,
                options = #config_service_options{
                    request_timeout_immediate_max =
                        RequestTimeoutImmediateMax,
                    response_timeout_adjustment =
                        ResponseTimeoutAdjustment}} = State) ->
    true = Source =:= Dispatcher,
    case maps:find(TransId, SendTimeouts) of
        error ->
            % send_async timeout already occurred
            keep_state_and_data;
        {ok, {passive, Pid, Tref}}
            when ResponseInfo == <<>>, Response == <<>> ->
            if
                ResponseTimeoutAdjustment;
                TimeoutOld >= RequestTimeoutImmediateMax ->
                    ok = cancel_timer_async(Tref);
                true ->
                    % avoid cancel_timer/1 latency
                    ok
            end,
            {keep_state,
             send_timeout_end(TransId, Pid, State)};
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
                    % avoid cancel_timer/1 latency
                    TimeoutOld
            end,
            StateNew = if
                is_binary(ResponseInfo) =:= false;
                is_binary(Response) =:= false ->
                    State;
                true ->
                    async_response_timeout_start(ResponseInfo, Response,
                                                 Timeout, TransId, State)
            end,
            {keep_state,
             send_timeout_end(TransId, Pid, StateNew)}
    end;

'HANDLE'(info,
         {'cloudi_service_return_sync', _Name, _Pattern,
          ResponseInfo, Response, TimeoutOld, TransId, Source},
         #state{dispatcher = Dispatcher,
                send_timeouts = SendTimeouts,
                options = #config_service_options{
                    request_timeout_immediate_max =
                        RequestTimeoutImmediateMax,
                    response_timeout_adjustment =
                        ResponseTimeoutAdjustment}} = State) ->
    true = Source =:= Dispatcher,
    case maps:find(TransId, SendTimeouts) of
        error ->
            % send_sync timeout already occurred
            keep_state_and_data;
        {ok, {_, Pid, Tref}} ->
            if
                ResponseTimeoutAdjustment;
                TimeoutOld >= RequestTimeoutImmediateMax ->
                    ok = cancel_timer_async(Tref);
                true ->
                    % avoid cancel_timer/1 latency
                    ok
            end,
            if
                is_binary(ResponseInfo) =:= false;
                is_binary(Response) =:= false ->
                    ok = send('return_sync_out'(timeout, TransId),
                              State);
                true ->
                    ok = send('return_sync_out'(ResponseInfo, Response,
                                                TransId),
                              State)
            end,
            {keep_state,
             send_timeout_end(TransId, Pid, State)}
    end;

'HANDLE'(info, {'cloudi_service_send_async_timeout', TransId},
         #state{send_timeouts = SendTimeouts} = State) ->
    case maps:find(TransId, SendTimeouts) of
        error ->
            keep_state_and_data;
        {ok, {_, Pid, _}} ->
            {keep_state,
             send_timeout_end(TransId, Pid, State)}
    end;

'HANDLE'(info, {'cloudi_service_send_sync_timeout', TransId},
         #state{send_timeouts = SendTimeouts} = State) ->
    case maps:find(TransId, SendTimeouts) of
        error ->
            keep_state_and_data;
        {ok, {_, Pid, _}} ->
            ok = send('return_sync_out'(timeout, TransId), State),
            {keep_state,
             send_timeout_end(TransId, Pid, State)}
    end;

'HANDLE'(info, {'cloudi_service_recv_async_timeout', TransId},
         #state{async_responses = AsyncResponses} = State) ->
    {keep_state,
     State#state{async_responses = maps:remove(TransId, AsyncResponses)}};

'HANDLE'(info, keepalive_udp,
         #state{dispatcher = Dispatcher,
                keepalive = undefined,
                socket = Socket}) ->
    Dispatcher ! {udp_closed, Socket},
    keep_state_and_data;

'HANDLE'(info, keepalive_udp,
         #state{dispatcher = Dispatcher,
                keepalive = received} = State) ->
    ok = send('keepalive_out'(), State),
    erlang:send_after(?KEEPALIVE_UDP, Dispatcher, keepalive_udp),
    {keep_state, State#state{keepalive = undefined}};

'HANDLE'(info, 'cloudi_count_process_dynamic_rate',
         #state{dispatcher = Dispatcher,
                options = #config_service_options{
                    count_process_dynamic =
                        CountProcessDynamic} = ConfigOptions} = State) ->
    CountProcessDynamicNew = cloudi_core_i_rate_based_configuration:
                             count_process_dynamic_reinit(Dispatcher,
                                                          CountProcessDynamic),
    {keep_state,
     State#state{options = ConfigOptions#config_service_options{
                     count_process_dynamic = CountProcessDynamicNew}}};

'HANDLE'(info, {'cloudi_count_process_dynamic_update', ProcessCount},
         #state{timeout_async = TimeoutAsync,
                timeout_sync = TimeoutSync,
                options = #config_service_options{
                    priority_default = PriorityDefault,
                    fatal_exceptions = FatalExceptions}
                } = State) ->
    ok = send('reinit_out'(ProcessCount, TimeoutAsync, TimeoutSync,
                           PriorityDefault, FatalExceptions),
              State),
    {keep_state,
     State#state{process_count = ProcessCount}};

'HANDLE'(info, 'cloudi_count_process_dynamic_terminate',
         #state{dispatcher = Dispatcher,
                options = #config_service_options{
                    count_process_dynamic = CountProcessDynamic,
                    scope = Scope} = ConfigOptions} = State) ->
    cpg:leave(Scope, Dispatcher, infinity),
    CountProcessDynamicNew =
        cloudi_core_i_rate_based_configuration:
        count_process_dynamic_terminate_set(Dispatcher, CountProcessDynamic),
    {keep_state,
     State#state{options = ConfigOptions#config_service_options{
                     count_process_dynamic = CountProcessDynamicNew}}};

'HANDLE'(info, 'cloudi_count_process_dynamic_terminate_check',
         #state{update_plan = UpdatePlan,
                suspended = Suspended,
                queue_requests = QueueRequests} = State) ->
    StopReason = {shutdown, cloudi_count_process_dynamic_terminate},
    StopDelayed = stop_delayed(UpdatePlan, Suspended, QueueRequests),
    if
        StopDelayed =:= false ->
            {stop, StopReason};
        StopDelayed =:= true ->
            {keep_state, State#state{stop = StopReason}}
    end;

'HANDLE'(info, 'cloudi_count_process_dynamic_terminate_now', _) ->
    {stop, {shutdown, cloudi_count_process_dynamic_terminate}};

'HANDLE'(info, 'cloudi_rate_request_max_rate',
         #state{options = #config_service_options{
                    rate_request_max = RateRequest} = ConfigOptions} = State) ->
    RateRequestNew = cloudi_core_i_rate_based_configuration:
                     rate_request_max_reinit(RateRequest),
    {keep_state,
     State#state{options = ConfigOptions#config_service_options{
                     rate_request_max = RateRequestNew}}};

'HANDLE'(info, 'cloudi_service_fatal_timeout',
         #state{update_plan = UpdatePlan,
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
            {stop, StopReason};
        StopDelayed =:= true ->
            {keep_state, State#state{stop = StopReason}}
    end;

'HANDLE'(info, {'cloudi_service_suspended', SuspendPending, Suspend},
         #state{dispatcher = Dispatcher,
                suspended = SuspendedOld,
                queue_requests = QueueRequests,
                service_state = ServiceState,
                options = Options} = State) ->
    case suspended_change(SuspendedOld, Suspend,
                          SuspendPending, Dispatcher,
                          QueueRequests, ServiceState, Options) of
        undefined ->
            {keep_state, State};
        {#suspended{processing = false} = SuspendedNew,
         false, ServiceStateNew} ->
            StateNew = State#state{suspended = SuspendedNew,
                                   service_state = ServiceStateNew},
            {keep_state,
             process_queues(StateNew)};
        {SuspendedNew, QueueRequestsNew, ServiceStateNew} ->
            {keep_state,
             State#state{suspended = SuspendedNew,
                         queue_requests = QueueRequestsNew,
                         service_state = ServiceStateNew}}
    end;

'HANDLE'(info, {'cloudi_service_update', UpdatePending, UpdatePlan},
         #state{dispatcher = Dispatcher,
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
            UpdatePending ! {'cloudi_service_update', Dispatcher},
            UpdatePlan#config_service_update{process_busy = ProcessBusy}
    end,
    {keep_state,
     State#state{update_plan = UpdatePlanNew,
                 queue_requests = true}};

'HANDLE'(info, {'cloudi_service_update_now', UpdateNow, UpdateStart},
         #state{update_plan = UpdatePlan} = State) ->
    #config_service_update{process_busy = ProcessBusy} = UpdatePlan,
    UpdatePlanNew = UpdatePlan#config_service_update{
                        update_now = UpdateNow,
                        update_start = UpdateStart},
    StateNew = State#state{update_plan = UpdatePlanNew},
    if
        ProcessBusy =:= true ->
            {keep_state, StateNew};
        ProcessBusy =:= false ->
            {keep_state, process_update(StateNew)}
    end;

'HANDLE'(info, {'cloudi_service_update_state', CommandLine}, State) ->
    % state updates when #config_service_update{spawn_os_process = true}
    erlang:put(?SERVICE_FILE_PDICT_KEY, hd(CommandLine)),
    {keep_state, State#state{command_line = CommandLine}};

'HANDLE'(info, {'DOWN', _MonitorRef, process, Pid, _Info}, State) ->
    {_, StateNew} = send_timeout_dead(Pid, State),
    {keep_state, StateNew};

'HANDLE'(info, {ReplyRef, _}, _) when is_reference(ReplyRef) ->
    % gen_server:call/3 had a timeout exception that was caught but the
    % reply arrived later and must be discarded
    keep_state_and_data;

'HANDLE'(info, EventContent, State) ->
    handle_info(EventContent, ?FUNCTION_NAME, State);

'HANDLE'(EventType, EventContent, State) ->
    Event = {EventType, EventContent},
    {stop, {?FUNCTION_NAME, undefined_message, Event}, State}.

terminate(Reason, _,
          #state{dispatcher = Dispatcher,
                 service_state = ServiceState,
                 timeout_term = TimeoutTerm,
                 os_pid = OSPid,
                 options = #config_service_options{
                     aspects_terminate_before = Aspects}} = State) ->
    ok = cloudi_core_i_services_monitor:
         process_terminate_begin(Dispatcher, OSPid, Reason),
    _ = aspects_terminate_before(Aspects, Reason, TimeoutTerm, ServiceState),
    ok = socket_close(Reason, socket_data_from_state(State)),
    ok = terminate_pids(Reason, State),
    ok.

terminate_pids(normal,
               #state{options = #config_service_options{
                          monkey_chaos = MonkeyChaos}}) ->
    ok = cloudi_core_i_runtime_testing:monkey_chaos_destroy(MonkeyChaos);
terminate_pids(_, _) ->
    ok.

code_change(_, StateName, State, _) ->
    {ok, StateName, State}.

-ifdef(ERLANG_OTP_VERSION_27_FEATURES).
format_status(Status) ->
    maps:update_with(data, fun format_status_state/1, Status).
-else.
format_status(_Opt, [_PDict, _StateName, State]) ->
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
                           cpg_data = Groups,
                           dest_deny = DestDeny,
                           dest_allow = DestAllow,
                           options = ConfigOptions} = State) ->
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
                       services_format_options_external(ConfigOptions),
    State#state{send_timeouts = maps:to_list(SendTimeouts),
                send_timeout_monitors = maps:to_list(SendTimeoutMonitors),
                recv_timeouts = maps:to_list(RecvTimeouts),
                async_responses = maps:to_list(AsyncResponses),
                queued = pqueue4:to_plist(Queue),
                cpg_data = GroupsNew,
                dest_deny = DestDenyNew,
                dest_allow = DestAllowNew,
                options = ConfigOptionsNew}.
-endif.

%%%------------------------------------------------------------------------
%%% Private functions
%%%------------------------------------------------------------------------

os_pid_set(OSPid, State) ->
    % forked process has connected before CloudI API initialization
    % (only the thread_index == 0 Erlang process gets this message,
    %  since the OS process only needs to be killed once, if at all)
    ?LOG_INFO("OS pid ~w connected", [OSPid]),
    State#state{os_pid = OSPid}.

os_pid_unset(#state_socket{os_pid = undefined}) ->
    ok;
os_pid_unset(#state_socket{os_pid = OSPid,
                           cgroup = CGroup}) ->
    _ = cloudi_core_i_os_process:cgroup_unset(OSPid, CGroup),
    ok.

os_init(#state{initialize = true,
               process_index = ProcessIndex,
               process_count = ProcessCount,
               prefix = Prefix,
               timeout_init = TimeoutInit,
               timeout_async = TimeoutAsync,
               timeout_sync = TimeoutSync,
               timeout_term = TimeoutTerm,
               options = #config_service_options{
                   priority_default = PriorityDefault,
                   count_process_dynamic = CountProcessDynamic,
                   fatal_exceptions = FatalExceptions,
                   bind = Bind}} = State) ->
    {ProcessCountMin,
     ProcessCountMax
     } = case cloudi_core_i_rate_based_configuration:
              count_process_dynamic_limits(CountProcessDynamic) of
        undefined ->
            {ProcessCount, ProcessCount};
        {_, _} = MinMax ->
            MinMax
    end,
    % first message within the CloudI API received during
    % the object construction or init API function
    ok = send('init_out'(ProcessIndex, ProcessCount,
                         ProcessCountMax, ProcessCountMin, Prefix,
                         TimeoutInit, TimeoutAsync, TimeoutSync, TimeoutTerm,
                         PriorityDefault, FatalExceptions, Bind),
              State),
    ok.

connection_init(#state{dispatcher = Dispatcher,
                       protocol = Protocol} = State) ->
    ok = os_init(State),
    if
        Protocol =:= udp ->
            ok = send('keepalive_out'(), State),
            _ = erlang:send_after(?KEEPALIVE_UDP, Dispatcher, keepalive_udp),
            ok;
        true ->
            ok
    end,
    {next_state, 'HANDLE', State}.

handle_info({udp, Socket, _, IncomingPort, _} = UDP, StateName,
            #state{protocol = udp,
                   incoming_port = undefined,
                   socket = Socket} = State) ->
    handle_info(UDP, StateName,
                State#state{incoming_port = IncomingPort});

handle_info({udp, Socket, _, IncomingPort, Data}, StateName,
            #state{protocol = udp,
                   incoming_port = IncomingPort,
                   socket = Socket} = State) ->
    ok = inet:setopts(Socket, [{active, once}]),
    try erlang:binary_to_term(Data, [safe]) of
        Request ->
            ?MODULE:StateName(connection, Request, State)
    catch
        error:badarg ->
            ?LOG_ERROR("Protocol Error ~w", [Data]),
            {stop, {error, protocol}, State}
    end;

handle_info({tcp, Socket, Data}, StateName,
            #state{protocol = Protocol,
                   socket = Socket} = State)
    when Protocol =:= tcp; Protocol =:= local ->
    ok = inet:setopts(Socket, [{active, once}]),
    try erlang:binary_to_term(Data, [safe]) of
        Request ->
            ?MODULE:StateName(connection, Request, State)
    catch
        error:badarg ->
            ?LOG_ERROR("Protocol Error ~w", [Data]),
            {stop, {error, protocol}, State}
    end;

handle_info({udp_closed, Socket}, _,
            #state{protocol = udp,
                   socket = Socket} = State) ->
    {stop, socket_closed, State};

handle_info({tcp_closed, Socket}, _,
                  #state{protocol = Protocol,
                         socket = Socket} = State)
    when Protocol =:= tcp; Protocol =:= local ->
    {stop, socket_closed, State};

handle_info({tcp_error, Socket, Reason}, _,
                  #state{protocol = Protocol,
                         socket = Socket} = State)
    when Protocol =:= tcp; Protocol =:= local ->
    {stop, Reason, State};

handle_info({cloudi_cpg_data, Groups}, _,
            #state{dispatcher = Dispatcher,
                   dest_refresh = DestRefresh,
                   options = #config_service_options{
                       dest_refresh_delay = Delay,
                       scope = Scope}} = State) ->
    ok = destination_refresh(DestRefresh, Dispatcher, Delay, Scope),
    {keep_state, State#state{cpg_data = Groups}};

handle_info({'EXIT', _, Reason}, _, _) ->
    {stop, Reason};

handle_info({'cloudi_service_stop', Reason}, _, _) ->
    {stop, Reason};

handle_info('cloudi_service_init_timeout', _, _) ->
    {stop, timeout};

handle_info({'cloudi_service_update', UpdatePending, _}, _,
            #state{dispatcher = Dispatcher,
                   update_plan = undefined}) ->
    UpdatePending ! {'cloudi_service_update', Dispatcher,
                     {error, invalid_state}},
    keep_state_and_data;

handle_info(EventContent, StateName, State) ->
    Event = {info, EventContent},
    {stop, {StateName, undefined_message, Event}, State}.


handle_send_async(Name, RequestInfo, Request, Timeout, Priority,
                  #state{dispatcher = Dispatcher,
                         uuid_generator = UUID,
                         dest_refresh = DestRefresh,
                         cpg_data = Groups,
                         options = #config_service_options{
                             request_name_lookup = RequestNameLookup,
                             scope = Scope}} = State) ->
    case destination_get(DestRefresh, Scope, Name, Dispatcher,
                         Groups, Timeout) of
        {error, timeout} ->
            ok = send('return_async_out'(), State),
            keep_state_and_data;
        {error, _} when RequestNameLookup =:= async ->
            ok = send('return_async_out'(), State),
            keep_state_and_data;
        {error, _} when Timeout >= ?SEND_ASYNC_INTERVAL ->
            erlang:send_after(?SEND_ASYNC_INTERVAL, Dispatcher,
                              {'cloudi_service_send_async_retry',
                               Name, RequestInfo, Request,
                               Timeout - ?SEND_ASYNC_INTERVAL, Priority}),
            keep_state_and_data;
        {error, _} ->
            ok = send('return_async_out'(), State),
            keep_state_and_data;
        {ok, Pattern, Pid} ->
            {TransId, UUIDNew} = uuid:get_v1(UUID),
            Pid ! {'cloudi_service_send_async',
                   Name, Pattern, RequestInfo, Request,
                   Timeout, Priority, TransId, Dispatcher},
            ok = send('return_async_out'(TransId), State),
            {keep_state,
             send_async_timeout_start(Timeout, TransId, Pid,
                                      State#state{uuid_generator = UUIDNew})}
    end.

handle_send_sync(Name, RequestInfo, Request, Timeout, Priority,
                 #state{dispatcher = Dispatcher,
                        uuid_generator = UUID,
                        dest_refresh = DestRefresh,
                        cpg_data = Groups,
                        options = #config_service_options{
                            request_name_lookup = RequestNameLookup,
                            scope = Scope}} = State) ->
    case destination_get(DestRefresh, Scope, Name, Dispatcher,
                         Groups, Timeout) of
        {error, timeout} ->
            ok = send('return_sync_out'(), State),
            keep_state_and_data;
        {error, _} when RequestNameLookup =:= async ->
            ok = send('return_sync_out'(), State),
            keep_state_and_data;
        {error, _} when Timeout >= ?SEND_SYNC_INTERVAL ->
            erlang:send_after(?SEND_SYNC_INTERVAL, Dispatcher,
                              {'cloudi_service_send_sync_retry',
                               Name, RequestInfo, Request,
                               Timeout - ?SEND_SYNC_INTERVAL, Priority}),
            keep_state_and_data;
        {error, _} ->
            ok = send('return_sync_out'(), State),
            keep_state_and_data;
        {ok, Pattern, Pid} ->
            {TransId, UUIDNew} = uuid:get_v1(UUID),
            Pid ! {'cloudi_service_send_sync',
                   Name, Pattern, RequestInfo, Request,
                   Timeout, Priority, TransId, Dispatcher},
            {keep_state,
             send_sync_timeout_start(Timeout, TransId, Pid, undefined,
                                     State#state{uuid_generator = UUIDNew})}
    end.

handle_mcast_async_pids(_Name, _Pattern, _RequestInfo, _Request,
                        _Timeout, _Priority,
                        TransIdList, [],
                        State) ->
    ok = send('returns_async_out'(lists:reverse(TransIdList)), State),
    State;
handle_mcast_async_pids(Name, Pattern, RequestInfo, Request,
                        Timeout, Priority,
                        TransIdList, [Pid | PidList],
                        #state{dispatcher = Dispatcher,
                               uuid_generator = UUID} = State) ->
    {TransId, UUIDNew} = uuid:get_v1(UUID),
    Pid ! {'cloudi_service_send_async',
           Name, Pattern, RequestInfo, Request,
           Timeout, Priority, TransId, Dispatcher},
    StateNew = State#state{uuid_generator = UUIDNew},
    handle_mcast_async_pids(Name, Pattern, RequestInfo, Request,
                            Timeout, Priority,
                            [TransId | TransIdList], PidList,
                            send_async_timeout_start(Timeout,
                                                     TransId,
                                                     Pid,
                                                     StateNew)).

handle_mcast_async(Name, RequestInfo, Request, Timeout, Priority,
                   #state{dispatcher = Dispatcher,
                          dest_refresh = DestRefresh,
                          cpg_data = Groups,
                          options = #config_service_options{
                              request_name_lookup = RequestNameLookup,
                              scope = Scope}} = State) ->
    case destination_all(DestRefresh, Scope, Name, Dispatcher,
                         Groups, Timeout) of
        {error, timeout} ->
            ok = send('returns_async_out'(), State),
            keep_state_and_data;
        {error, _} when RequestNameLookup =:= async ->
            ok = send('returns_async_out'(), State),
            keep_state_and_data;
        {error, _} when Timeout >= ?MCAST_ASYNC_INTERVAL ->
            erlang:send_after(?MCAST_ASYNC_INTERVAL, Dispatcher,
                              {'cloudi_service_mcast_async_retry',
                               Name, RequestInfo, Request,
                               Timeout - ?MCAST_ASYNC_INTERVAL, Priority}),
            keep_state_and_data;
        {error, _} ->
            ok = send('returns_async_out'(), State),
            keep_state_and_data;
        {ok, Pattern, PidList} ->
            {keep_state,
             handle_mcast_async_pids(Name, Pattern, RequestInfo, Request,
                                     Timeout, Priority,
                                     [], PidList, State)}
    end.

handle_recv_async(Timeout, <<0:128>> = TransId, Consume,
                  #state{dispatcher = Dispatcher,
                         async_responses = AsyncResponses} = State) ->
    case maps:to_list(AsyncResponses) of
        [] when Timeout >= ?RECV_ASYNC_INTERVAL ->
            erlang:send_after(?RECV_ASYNC_INTERVAL, Dispatcher,
                              {'cloudi_service_recv_async_retry',
                               Timeout - ?RECV_ASYNC_INTERVAL,
                               TransId, Consume}),
            keep_state_and_data;
        [] ->
            ok = send('recv_async_out'(timeout, TransId), State),
            keep_state_and_data;
        L when Consume =:= true ->
            TransIdPick = ?RECV_ASYNC_STRATEGY(L),
            {{ResponseInfo, Response},
             AsyncResponsesNew} = maps:take(TransIdPick, AsyncResponses),
            ok = send('recv_async_out'(ResponseInfo, Response,
                                       TransIdPick),
                      State),
            {keep_state, State#state{async_responses = AsyncResponsesNew}};
        L when Consume =:= false ->
            TransIdPick = ?RECV_ASYNC_STRATEGY(L),
            {ResponseInfo, Response} = maps:get(TransIdPick,
                                                AsyncResponses),
            ok = send('recv_async_out'(ResponseInfo, Response,
                                       TransIdPick),
                      State),
            keep_state_and_data
    end;
handle_recv_async(Timeout, TransId, Consume,
                  #state{dispatcher = Dispatcher,
                         async_responses = AsyncResponses} = State) ->
    case maps:find(TransId, AsyncResponses) of
        error when Timeout >= ?RECV_ASYNC_INTERVAL ->
            erlang:send_after(?RECV_ASYNC_INTERVAL, Dispatcher,
                              {'cloudi_service_recv_async_retry',
                               Timeout - ?RECV_ASYNC_INTERVAL,
                               TransId, Consume}),
            keep_state_and_data;
        error ->
            ok = send('recv_async_out'(timeout, TransId), State),
            keep_state_and_data;
        {ok, {ResponseInfo, Response}} when Consume =:= true ->
            ok = send('recv_async_out'(ResponseInfo, Response, TransId),
                      State),
            {keep_state, State#state{
                async_responses = maps:remove(TransId,
                                              AsyncResponses)}};
        {ok, {ResponseInfo, Response}} when Consume =:= false ->
            ok = send('recv_async_out'(ResponseInfo, Response, TransId),
                      State),
            keep_state_and_data
    end.

'init_out'(ProcessIndex, ProcessCount,
           ProcessCountMax, ProcessCountMin, Prefix,
           TimeoutInit, TimeoutAsync, TimeoutSync, TimeoutTerm,
           PriorityDefault, FatalExceptions, Bind) ->
    true = ProcessCount < 4294967296,
    true = ProcessCountMax < 4294967296,
    true = ProcessCountMin < 4294967296,
    PrefixSize = length(Prefix) + 1,
    true = PrefixSize < 4294967296,
    TimeoutTermExternal = ?TIMEOUT_TERMINATE_EXTERNAL(TimeoutTerm),
    FatalExceptionsValue = if
        FatalExceptions =:= true ->
            1;
        FatalExceptions =:= false ->
            0
    end,
    BindValue = cloudi_core_i_concurrency:bind_logical_processor(Bind),
    [<<?MESSAGE_INIT:32/unsigned-integer-native,
       ProcessIndex:32/unsigned-integer-native,
       ProcessCount:32/unsigned-integer-native,
       ProcessCountMax:32/unsigned-integer-native,
       ProcessCountMin:32/unsigned-integer-native,
       PrefixSize:32/unsigned-integer-native>>,
     Prefix |
     <<0:8,
       TimeoutInit:32/unsigned-integer-native,
       TimeoutAsync:32/unsigned-integer-native,
       TimeoutSync:32/unsigned-integer-native,
       TimeoutTermExternal:32/unsigned-integer-native,
       PriorityDefault:8/signed-integer-native,
       FatalExceptionsValue:8/unsigned-integer-native,
       BindValue:32/signed-integer-native>>].

'reinit_out'(ProcessCount, TimeoutAsync, TimeoutSync,
             PriorityDefault, FatalExceptions) ->
    true = ProcessCount < 4294967296,
    FatalExceptionsValue = if
        FatalExceptions =:= true ->
            1;
        FatalExceptions =:= false ->
            0
    end,
    <<?MESSAGE_REINIT:32/unsigned-integer-native,
      ProcessCount:32/unsigned-integer-native,
      TimeoutAsync:32/unsigned-integer-native,
      TimeoutSync:32/unsigned-integer-native,
      PriorityDefault:8/signed-integer-native,
      FatalExceptionsValue:8/unsigned-integer-native>>.

'terminate_out'() ->
    <<?MESSAGE_TERM:32/unsigned-integer-native>>.

'keepalive_out'() ->
    <<?MESSAGE_KEEPALIVE:32/unsigned-integer-native>>.

'send_async_out'(Name, Pattern,
                 RequestInfo, Request, Timeout, Priority, TransId, Source)
    when is_binary(RequestInfo), is_binary(Request), is_pid(Source) ->
    NameSize = length(Name) + 1,
    true = NameSize < 4294967296,
    PatternSize = length(Pattern) + 1,
    true = PatternSize < 4294967296,
    RequestInfoSize = byte_size(RequestInfo),
    true = RequestInfoSize < 4294967296,
    RequestSize = byte_size(Request),
    true = RequestSize < 4294967296,
    SourceBin = erlang:term_to_binary(Source),
    SourceSize = byte_size(SourceBin),
    true = SourceSize < 4294967296,
    [<<?MESSAGE_SEND_ASYNC:32/unsigned-integer-native,
       NameSize:32/unsigned-integer-native>>,
     Name,
     0,
     <<PatternSize:32/unsigned-integer-native>>,
     Pattern,
     0,
     <<RequestInfoSize:32/unsigned-integer-native>>,
     RequestInfo,
     0,
     <<RequestSize:32/unsigned-integer-native>>,
     Request,
     0,
     <<Timeout:32/unsigned-integer-native,
       Priority:8/signed-integer-native>>,
     TransId,
     <<SourceSize:32/unsigned-integer-native>> |
     SourceBin].

'send_sync_out'(Name, Pattern,
                RequestInfo, Request, Timeout, Priority, TransId, Source)
    when is_binary(RequestInfo), is_binary(Request), is_pid(Source) ->
    NameSize = length(Name) + 1,
    true = NameSize < 4294967296,
    PatternSize = length(Pattern) + 1,
    true = PatternSize < 4294967296,
    RequestInfoSize = byte_size(RequestInfo),
    true = RequestInfoSize < 4294967296,
    RequestSize = byte_size(Request),
    true = RequestSize < 4294967296,
    SourceBin = erlang:term_to_binary(Source),
    SourceSize = byte_size(SourceBin),
    true = SourceSize < 4294967296,
    [<<?MESSAGE_SEND_SYNC:32/unsigned-integer-native,
       NameSize:32/unsigned-integer-native>>,
     Name,
     0,
     <<PatternSize:32/unsigned-integer-native>>,
     Pattern,
     0,
     <<RequestInfoSize:32/unsigned-integer-native>>,
     RequestInfo,
     0,
     <<RequestSize:32/unsigned-integer-native>>,
     Request,
     0,
     <<Timeout:32/unsigned-integer-native,
       Priority:8/signed-integer-native>>,
     TransId,
     <<SourceSize:32/unsigned-integer-native>> |
     SourceBin].

'return_async_out'() ->
    <<?MESSAGE_RETURN_ASYNC:32/unsigned-integer-native,
      0:128>>.

'return_async_out'(TransId) ->
    [<<?MESSAGE_RETURN_ASYNC:32/unsigned-integer-native>> |
     TransId].

'return_sync_out'() ->
    <<?MESSAGE_RETURN_SYNC:32/unsigned-integer-native,
      0:32,
      0:8,
      0:32,
      0:8,
      0:128>>.

'return_sync_out'(timeout, TransId) ->
    [<<?MESSAGE_RETURN_SYNC:32/unsigned-integer-native,
       0:32,
       0:8,
       0:32,
       0:8>> |
     TransId].

'return_sync_out'(ResponseInfo, Response, TransId) ->
    ResponseInfoSize = byte_size(ResponseInfo),
    true = ResponseInfoSize < 4294967296,
    ResponseSize = byte_size(Response),
    true = ResponseSize < 4294967296,
    [<<?MESSAGE_RETURN_SYNC:32/unsigned-integer-native,
       ResponseInfoSize:32/unsigned-integer-native>>,
     ResponseInfo,
     0,
     <<ResponseSize:32/unsigned-integer-native>>,
     Response,
     0 |
     TransId].

'returns_async_out'() ->
    <<?MESSAGE_RETURNS_ASYNC:32/unsigned-integer-native,
      0:32>>.

'returns_async_out'(TransIdList) ->
    TransIdListCount = length(TransIdList),
    true = TransIdListCount < 4294967296,
    [<<?MESSAGE_RETURNS_ASYNC:32/unsigned-integer-native,
       TransIdListCount:32/unsigned-integer-native>> |
     TransIdList].

'recv_async_out'(timeout, TransId) ->
    [<<?MESSAGE_RECV_ASYNC:32/unsigned-integer-native,
       0:32,
       0:8,
       0:32,
       0:8>> |
     TransId].

'recv_async_out'(ResponseInfo, Response, TransId) ->
    ResponseInfoSize = byte_size(ResponseInfo),
    true = ResponseInfoSize < 4294967296,
    ResponseSize = byte_size(Response),
    true = ResponseSize < 4294967296,
    [<<?MESSAGE_RECV_ASYNC:32/unsigned-integer-native,
       ResponseInfoSize:32/unsigned-integer-native>>,
     ResponseInfo,
     0,
     <<ResponseSize:32/unsigned-integer-native>>,
     Response,
     0 |
     TransId].

'subscribe_count_out'(Count)
    when is_integer(Count), Count >= 0, Count < 4294967296 ->
    <<?MESSAGE_SUBSCRIBE_COUNT:32/unsigned-integer-native,
      Count:32/unsigned-integer-native>>.

recv_timeout_start(Timeout, Priority, TransId, Size, T,
                   #state{dispatcher = Dispatcher,
                          recv_timeouts = RecvTimeouts,
                          queued = Queue,
                          queued_size = QueuedSize} = State)
    when is_integer(Timeout), is_integer(Priority), is_binary(TransId) ->
    State#state{
        recv_timeouts = maps:put(TransId,
            erlang:send_after(Timeout, Dispatcher,
                {'cloudi_service_recv_timeout', Priority, TransId, Size}),
            RecvTimeouts),
        queued = pqueue4:in({Size, T}, Priority, Queue),
        queued_size = QueuedSize + Size}.

process_queue(#state{dispatcher = Dispatcher,
                     recv_timeouts = RecvTimeouts,
                     queue_requests = true,
                     queued = Queue,
                     queued_size = QueuedSize,
                     service_state = ServiceState,
                     options = ConfigOptions} = State) ->
    case pqueue4:out(Queue) of
        {empty, QueueNew} ->
            State#state{queue_requests = false,
                        queued = QueueNew};
        {{value,
          {Size,
           {'cloudi_service_send_async',
            Name, Pattern, RequestInfo, Request,
            _, Priority, TransId, Source}}}, QueueNew} ->
            Type = 'send_async',
            ConfigOptionsNew = check_incoming(true, ConfigOptions),
            #config_service_options{
                request_timeout_adjustment =
                    RequestTimeoutAdjustment,
                aspects_request_before =
                    AspectsBefore} = ConfigOptionsNew,
            {RecvTimer,
             RecvTimeoutsNew} = maps:take(TransId, RecvTimeouts),
            Timeout = case erlang:cancel_timer(RecvTimer) of
                false ->
                    0;
                V ->
                    V
            end,
            FatalTimer = fatal_timer_start(Timeout, Dispatcher,
                                           ConfigOptionsNew),
            RequestTimeoutF =
                request_timeout_adjustment_f(RequestTimeoutAdjustment),
            case aspects_request_before(AspectsBefore, Type,
                                        Name, Pattern, RequestInfo, Request,
                                        Timeout, Priority, TransId, Source,
                                        ServiceState) of
                {ok, ServiceStateNew} ->
                    T = {'cloudi_service_send_async',
                         Name, Pattern, RequestInfo, Request,
                         Timeout, Priority, TransId, Source},
                    ok = send('send_async_out'(Name, Pattern,
                                               RequestInfo, Request,
                                               Timeout, Priority, TransId,
                                               Source),
                              State),
                    State#state{recv_timeouts = RecvTimeoutsNew,
                                queued = QueueNew,
                                queued_size = QueuedSize - Size,
                                service_state = ServiceStateNew,
                                request_data = {T, RequestTimeoutF},
                                fatal_timer = FatalTimer,
                                options = ConfigOptionsNew};
                {stop, Reason, ServiceStateNew} ->
                    Dispatcher ! {'cloudi_service_stop', Reason},
                    State#state{recv_timeouts = RecvTimeoutsNew,
                                service_state = ServiceStateNew,
                                fatal_timer = FatalTimer,
                                options = ConfigOptionsNew}
            end;
        {{value,
          {Size,
           {'cloudi_service_send_sync',
            Name, Pattern, RequestInfo, Request,
            _, Priority, TransId, Source}}}, QueueNew} ->
            Type = 'send_sync',
            ConfigOptionsNew = check_incoming(true, ConfigOptions),
            #config_service_options{
                request_timeout_adjustment =
                    RequestTimeoutAdjustment,
                aspects_request_before =
                    AspectsBefore} = ConfigOptionsNew,
            {RecvTimer,
             RecvTimeoutsNew} = maps:take(TransId, RecvTimeouts),
            Timeout = case erlang:cancel_timer(RecvTimer) of
                false ->
                    0;
                V ->
                    V
            end,
            FatalTimer = fatal_timer_start(Timeout, Dispatcher,
                                           ConfigOptionsNew),
            RequestTimeoutF =
                request_timeout_adjustment_f(RequestTimeoutAdjustment),
            case aspects_request_before(AspectsBefore, Type,
                                        Name, Pattern, RequestInfo, Request,
                                        Timeout, Priority, TransId, Source,
                                        ServiceState) of
                {ok, ServiceStateNew} ->
                    T = {'cloudi_service_send_sync',
                         Name, Pattern, RequestInfo, Request,
                         Timeout, Priority, TransId, Source},
                    ok = send('send_sync_out'(Name, Pattern,
                                              RequestInfo, Request,
                                              Timeout, Priority, TransId,
                                              Source),
                              State),
                    State#state{recv_timeouts = RecvTimeoutsNew,
                                queued = QueueNew,
                                queued_size = QueuedSize - Size,
                                service_state = ServiceStateNew,
                                request_data = {T, RequestTimeoutF},
                                fatal_timer = FatalTimer,
                                options = ConfigOptionsNew};
                {stop, Reason, ServiceStateNew} ->
                    Dispatcher ! {'cloudi_service_stop', Reason},
                    State#state{recv_timeouts = RecvTimeoutsNew,
                                service_state = ServiceStateNew,
                                fatal_timer = FatalTimer,
                                options = ConfigOptionsNew}
            end
    end.

process_update(#state{dispatcher = Dispatcher,
                      update_plan = UpdatePlan} = State) ->
    #config_service_update{update_now = UpdateNow,
                           spawn_os_process = SpawnOsProcess,
                           process_busy = false} = UpdatePlan,
    {OsProcessNew, StateNew} = case update(State, UpdatePlan) of
        {ok, undefined, StateNext} ->
            false = SpawnOsProcess,
            % re-initialize the old OS process after the update success
            % when a new OS process is not created during the update
            #state{process_count = ProcessCount,
                   timeout_async = TimeoutAsync,
                   timeout_sync = TimeoutSync,
                   options = #config_service_options{
                       priority_default = PriorityDefault,
                       fatal_exceptions = FatalExceptions}
                   } = StateNext,
            ok = send('reinit_out'(ProcessCount,
                                   TimeoutAsync, TimeoutSync,
                                   PriorityDefault, FatalExceptions),
                      StateNext),
            UpdateNow ! {'cloudi_service_update_now', Dispatcher, ok},
            {false, StateNext};
        {ok, {error, _} = Error} ->
            UpdateNow ! {'cloudi_service_update_now', Dispatcher, Error},
            {false, State};
        {ok, #state_socket{port = Port} = StateSocket, StateNext} ->
            true = SpawnOsProcess,
            UpdateNow ! {'cloudi_service_update_now', Dispatcher, {ok, Port}},
            receive
                {'cloudi_service_update_after', ok} ->
                    {true, update_after(StateSocket, StateNext)};
                {'cloudi_service_update_after', error} ->
                    ok = socket_close(StateSocket),
                    erlang:exit(update_failed)
            end;
        {error, _} = Error ->
            true = SpawnOsProcess,
            UpdateNow ! {'cloudi_service_update_now', Dispatcher, Error},
            erlang:exit(update_failed)
    end,
    StateFinal = StateNew#state{update_plan = undefined},
    if
        OsProcessNew =:= true ->
            % wait to receive 'polling' to make sure initialization is complete
            % with the newly created OS process
            StateFinal;
        OsProcessNew =:= false ->
            process_queues(StateFinal)
    end.

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
    process_queue(State).

send(Data, #state{protocol = Protocol,
                  incoming_port = IncomingPort,
                  socket = Socket}) ->
    socket_send(Socket, IncomingPort, Data, Protocol);
send(Data, #state_socket{protocol = Protocol,
                         incoming_port = IncomingPort,
                         socket = Socket}) ->
    socket_send(Socket, IncomingPort, Data, Protocol).

socket_send(Socket, _, Data, Protocol)
    when Protocol =:= tcp; Protocol =:= local ->
    gen_tcp:send(Socket, Data);
socket_send(Socket, IncomingPort, Data, Protocol)
    when Protocol =:= udp ->
    gen_udp:send(Socket, {127,0,0,1}, IncomingPort, Data).

socket_recv(#state_socket{protocol = udp,
                          socket = Socket,
                          incoming_port = IncomingPort} = StateSocket) ->
    receive
        {udp, Socket, _, IncomingPort, Data} when IncomingPort =:= undefined ->
            ok = inet:setopts(Socket, [{active, once}]),
            {ok, Data, StateSocket#state_socket{incoming_port = IncomingPort}};
        {udp, Socket, _, IncomingPort, Data} ->
            ok = inet:setopts(Socket, [{active, once}]),
            {ok, Data, StateSocket};
        {udp_closed, Socket} ->
            {error, socket_closed};
        'cloudi_service_init_timeout' ->
            {error, timeout}
    end;
socket_recv(#state_socket{protocol = Protocol,
                          listener = Listener,
                          acceptor = Acceptor,
                          socket = Socket} = StateSocket)
    when Protocol =:= tcp; Protocol =:= local ->
    receive
        {tcp, Socket, Data} ->
            ok = inet:setopts(Socket, [{active, once}]),
            {ok, Data, StateSocket};
        {tcp_closed, Socket} ->
            {error, socket_closed};
        {tcp_error, Socket, Reason} ->
            {error, Reason};
        {inet_async, _, _, {ok, _}} = Accept ->
            socket_recv(socket_accept(Accept, StateSocket));
        {inet_async, Listener, Acceptor, _} ->
            {error, inet_async};
        'cloudi_service_init_timeout' ->
            {error, timeout}
    end.

socket_recv_term(StateSocket) ->
    case socket_recv(StateSocket) of
        {ok, Data, StateSocketNew} ->
            try erlang:binary_to_term(Data, [safe]) of
                Term ->
                    {ok, Term, StateSocketNew}
            catch
                error:badarg ->
                    {error, protocol}
            end;
        {error, _} = Error ->
            Error
    end.

socket_new(#state{protocol = Protocol,
                  port = Port,
                  socket_path = SocketPath,
                  socket_options = SocketOptions}) ->
    if
        Protocol =:= tcp ->
            socket_open_tcp(SocketOptions);
        Protocol =:= udp ->
            socket_open_udp(SocketOptions);
        Protocol =:= local ->
            socket_open_local(SocketOptions, Port, SocketPath)
    end.

socket_open(tcp, _, _, BufferSize) ->
    SocketOptions = [{recbuf, BufferSize}, {sndbuf, BufferSize},
                     {nodelay, true}, {delay_send, false}, {keepalive, false},
                     {send_timeout, 5000}, {send_timeout_close, true}],
    socket_open_tcp(SocketOptions);
socket_open(udp, _, _, BufferSize) ->
    SocketOptions = [{recbuf, BufferSize}, {sndbuf, BufferSize}],
    socket_open_udp(SocketOptions);
socket_open(local, SocketPath, ThreadIndex, BufferSize) ->
    SocketOptions = [{recbuf, BufferSize}, {sndbuf, BufferSize},
                     {delay_send, false}, {keepalive, false},
                     {send_timeout, 5000}, {send_timeout_close, true}],
    ThreadSocketPath = SocketPath ++ erlang:integer_to_list(ThreadIndex),
    socket_open_local(SocketOptions, ThreadIndex, ThreadSocketPath).

socket_open_tcp(SocketOptions) ->
    try
        case gen_tcp:listen(0, [binary, inet, {ip, {127,0,0,1}},
                                {packet, 4}, {backlog, 1},
                                {active, false} | SocketOptions]) of
            {ok, Listener} ->
                {ok, Port} = inet:port(Listener),
                {ok, Acceptor} = socket_open_acceptor(Listener),
                {ok, #state_socket{protocol = tcp,
                                   port = Port,
                                   listener = Listener,
                                   acceptor = Acceptor,
                                   socket_options = SocketOptions}};
            {error, _} = Error ->
                Error
        end
    catch
        ErrorType:ErrorReason ->
            {error, {ErrorType, ErrorReason}}
    end.

socket_open_udp(SocketOptions) ->
    try
        case gen_udp:open(0, [binary, inet, {ip, {127,0,0,1}},
                              {active, once} | SocketOptions]) of
            {ok, Socket} ->
                {ok, Port} = inet:port(Socket),
                {ok, #state_socket{protocol = udp,
                                   port = Port,
                                   socket_options = SocketOptions,
                                   socket = Socket}};
            {error, _} = Error ->
                Error
        end
    catch
        ErrorType:ErrorReason ->
            {error, {ErrorType, ErrorReason}}
    end.

socket_open_local(SocketOptions, Port, SocketPath) ->
    try
        case gen_tcp:listen(0, [binary, {ifaddr, {local, SocketPath}},
                                {packet, 4}, {backlog, 1},
                                {active, false} | SocketOptions]) of
            {ok, Listener} ->
                {ok, Acceptor} = socket_open_acceptor(Listener),
                {ok, #state_socket{protocol = local,
                                   port = Port,
                                   listener = Listener,
                                   acceptor = Acceptor,
                                   socket_path = SocketPath,
                                   socket_options = SocketOptions}};
            {error, _} = Error ->
                Error
        end
    catch
        ErrorType:ErrorReason ->
            {error, {ErrorType, ErrorReason}}
    end.

socket_accept({inet_async, Listener, Acceptor, {ok, Socket}},
              #state_socket{protocol = Protocol,
                            listener = Listener,
                            acceptor = Acceptor,
                            socket_options = SocketOptions} = StateSocket)
    when Protocol =:= tcp; Protocol =:= local ->
    ok = socket_accept_connection(Protocol, Socket),
    ok = inet:setopts(Socket, [{active, once} | SocketOptions]),
    ?CATCH(gen_tcp:close(Listener)),
    StateSocket#state_socket{listener = undefined,
                             acceptor = undefined,
                             socket = Socket}.

socket_close(socket_closed = Reason,
             #state_socket{socket = Socket} = StateSocket)
    when Socket =/= undefined ->
    socket_close(Reason, StateSocket#state_socket{socket = undefined});
socket_close(_Reason,
             #state_socket{protocol = Protocol,
                           socket = Socket,
                           timeout_term = TimeoutTerm,
                           socket_options = SocketOptions} = StateSocket)
    when Protocol =:= tcp; Protocol =:= local ->
    if
        Socket =:= undefined ->
            ok;
        true ->
            case send('terminate_out'(), StateSocket) of
                ok ->
                    case inet:setopts(Socket,
                                      [{active, true} | SocketOptions]) of
                        ok ->
                            Timeout = ?TIMEOUT_TERMINATE_EXTERNAL(TimeoutTerm),
                            receive
                                {tcp_closed, Socket} ->
                                    ok;
                                {tcp_error, Socket, _} ->
                                    ok
                            after
                                Timeout ->
                                    ok
                            end;
                        {error, _} ->
                            ok
                    end;
                {error, _} ->
                    ok
            end
    end,
    ok = socket_close(StateSocket),
    ok;
socket_close(_Reason,
             #state_socket{protocol = udp,
                           socket = Socket,
                           timeout_term = TimeoutTerm} = StateSocket) ->
    if
        Socket =:= undefined ->
            ok;
        true ->
            case send('terminate_out'(), StateSocket) of
                ok ->
                    Timeout = ?TIMEOUT_TERMINATE_EXTERNAL(TimeoutTerm),
                    TerminateSleep = erlang:min(?KEEPALIVE_UDP, Timeout),
                    receive after TerminateSleep -> ok end;
                {error, _} ->
                    ok
            end
    end,
    ok = socket_close(StateSocket),
    ok.

socket_close(#state_socket{protocol = Protocol,
                           listener = Listener,
                           socket_path = SocketPath,
                           socket = Socket} = StateSocket)
    when Protocol =:= tcp; Protocol =:= local ->
    if
        Socket =:= undefined ->
            ok;
        true ->
            ?CATCH(gen_tcp:close(Socket))
    end,
    ?CATCH(gen_tcp:close(Listener)),
    if
        Protocol =:= local ->
            ?CATCH(file_delete(SocketPath));
        true ->
            ok
    end,
    ok = os_pid_unset(StateSocket),
    ok;
socket_close(#state_socket{protocol = udp,
                           socket = Socket} = StateSocket) ->
    if
        Socket =:= undefined ->
            ok;
        true ->
            ?CATCH(gen_udp:close(Socket))
    end,
    ok = os_pid_unset(StateSocket),
    ok.

-ifdef(ERLANG_OTP_VERSION_24_FEATURES).
socket_open_acceptor(Listener) ->
    Dispatcher = self(),
    Acceptor = erlang:spawn_link(fun() ->
        Acceptor = self(),
        Result = case gen_tcp:accept(Listener) of
            {ok, Socket} = Success ->
                case gen_tcp:controlling_process(Socket, Dispatcher) of
                    ok ->
                        Success;
                    {error, _} = Error ->
                        Error
                end;
            {error, _} = Error ->
                Error
        end,
        Dispatcher ! {inet_async, Listener, Acceptor, Result},
        true = erlang:unlink(Dispatcher)
    end),
    {ok, Acceptor}.

socket_accept_connection(_, _) ->
    ok.

file_delete(FilePath) ->
    file:delete(FilePath, [raw]).
-else.
socket_open_acceptor(Listener) ->
    prim_inet:async_accept(Listener, -1).

socket_accept_connection(tcp, Socket) ->
    true = inet_db:register_socket(Socket, inet_tcp),
    ok;
socket_accept_connection(local, Socket) ->
    true = inet_db:register_socket(Socket, local_tcp),
    ok.

file_delete(FilePath) ->
    file:delete(FilePath).
-endif.

socket_data_to_state(#state_socket{protocol = Protocol,
                                   port = Port,
                                   incoming_port = IncomingPort,
                                   listener = Listener,
                                   acceptor = Acceptor,
                                   socket_path = SocketPath,
                                   socket_options = SocketOptions,
                                   socket = Socket}, State) ->
    State#state{protocol = Protocol,
                port = Port,
                incoming_port = IncomingPort,
                listener = Listener,
                acceptor = Acceptor,
                socket_path = SocketPath,
                socket_options = SocketOptions,
                socket = Socket}.

socket_data_from_state(#state{protocol = Protocol,
                              port = Port,
                              incoming_port = IncomingPort,
                              listener = Listener,
                              acceptor = Acceptor,
                              socket_path = SocketPath,
                              socket_options = SocketOptions,
                              socket = Socket,
                              timeout_term = TimeoutTerm,
                              os_pid = OSPid,
                              options = #config_service_options{
                                  cgroup = CGroup}}) ->
    #state_socket{protocol = Protocol,
                  port = Port,
                  incoming_port = IncomingPort,
                  listener = Listener,
                  acceptor = Acceptor,
                  socket_path = SocketPath,
                  socket_options = SocketOptions,
                  socket = Socket,
                  timeout_term = TimeoutTerm,
                  os_pid = OSPid,
                  cgroup = CGroup}.

aspects_init_after([], _, _, _, ServiceState) ->
    {ok, ServiceState};
aspects_init_after([{M, F} = Aspect | L], CommandLine, Prefix, Timeout,
                   ServiceState) ->
    try M:F(CommandLine, Prefix, Timeout, ServiceState) of
        {ok, ServiceStateNew} ->
            aspects_init_after(L, CommandLine, Prefix, Timeout,
                               ServiceStateNew);
        {stop, _, _} = Stop ->
            Stop
    catch
        ErrorType:Error:ErrorStackTrace ->
            ?LOG_ERROR_SYNC("aspect ~tp ~tp ~tp~n~tp",
                            [Aspect, ErrorType, Error, ErrorStackTrace]),
            {stop, {ErrorType, {Error, ErrorStackTrace}}, ServiceState}
    end;
aspects_init_after([F | L], CommandLine, Prefix, Timeout,
                   ServiceState) ->
    try F(CommandLine, Prefix, Timeout, ServiceState) of
        {ok, ServiceStateNew} ->
            aspects_init_after(L, CommandLine, Prefix, Timeout,
                               ServiceStateNew);
        {stop, _, _} = Stop ->
            Stop
    catch
        ErrorType:Error:ErrorStackTrace ->
            ?LOG_ERROR_SYNC("aspect ~tp ~tp ~tp~n~tp",
                            [F, ErrorType, Error, ErrorStackTrace]),
            {stop, {ErrorType, {Error, ErrorStackTrace}}, ServiceState}
    end.

aspects_request_before([], _, _, _, _, _, _, _, _, _, ServiceState) ->
    {ok, ServiceState};
aspects_request_before([{M, F} = Aspect | L],
                       Type, Name, Pattern, RequestInfo, Request,
                       Timeout, Priority, TransId, Source,
                       ServiceState) ->
    try M:F(Type, Name, Pattern, RequestInfo, Request,
            Timeout, Priority, TransId, Source,
            ServiceState) of
        {ok, ServiceStateNew} ->
            aspects_request_before(L, Type, Name, Pattern, RequestInfo, Request,
                                   Timeout, Priority, TransId, Source,
                                   ServiceStateNew);
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
                       ServiceState) ->
    try F(Type, Name, Pattern, RequestInfo, Request,
          Timeout, Priority, TransId, Source,
          ServiceState) of
        {ok, ServiceStateNew} ->
            aspects_request_before(L, Type, Name, Pattern, RequestInfo, Request,
                                   Timeout, Priority, TransId, Source,
                                   ServiceStateNew);
        {stop, _, _} = Stop ->
            Stop
    catch
        ErrorType:Error:ErrorStackTrace ->
            ?LOG_ERROR("aspect ~tp ~tp ~tp~n~tp",
                       [F, ErrorType, Error, ErrorStackTrace]),
            {stop, {ErrorType, {Error, ErrorStackTrace}}, ServiceState}
    end.

aspects_request_after([], _, _, _, _, _, _, _, _, _, _, ServiceState) ->
    {ok, ServiceState};
aspects_request_after([{M, F} = Aspect | L],
                      Type, Name, Pattern, RequestInfo, Request,
                      Timeout, Priority, TransId, Source,
                      Result, ServiceState) ->
    try M:F(Type, Name, Pattern, RequestInfo, Request,
            Timeout, Priority, TransId, Source,
            Result, ServiceState) of
        {ok, ServiceStateNew} ->
            aspects_request_after(L, Type, Name, Pattern, RequestInfo, Request,
                                  Timeout, Priority, TransId, Source,
                                  Result, ServiceStateNew);
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
                      Result, ServiceState) ->
    try F(Type, Name, Pattern, RequestInfo, Request,
          Timeout, Priority, TransId, Source,
          Result, ServiceState) of
        {ok, ServiceStateNew} ->
            aspects_request_after(L, Type, Name, Pattern, RequestInfo, Request,
                                  Timeout, Priority, TransId, Source,
                                  Result, ServiceStateNew);
        {stop, _, _} = Stop ->
            Stop
    catch
        ErrorType:Error:ErrorStackTrace ->
            ?LOG_ERROR("aspect ~tp ~tp ~tp~n~tp",
                       [F, ErrorType, Error, ErrorStackTrace]),
            {stop, {ErrorType, {Error, ErrorStackTrace}}, ServiceState}
    end.

process_description([_ | _] = ProcessName, ProcessIndex) ->
    "cloudi_core external service " ++ ProcessName ++ " process index " ++
    erlang:integer_to_list(ProcessIndex).

update(_, #config_service_update{type = Type})
    when Type =/= external ->
    {ok, {error, type}};
update(_, #config_service_update{update_start = false}) ->
    {ok, {error, update_start_failed}};
update(State, #config_service_update{spawn_os_process = false} = UpdatePlan) ->
    {ok, undefined, update_state(State, UpdatePlan)};
update(State, #config_service_update{spawn_os_process = true} = UpdatePlan) ->
    ok = socket_close(update, socket_data_from_state(State)),
    StateNew = update_state(State, UpdatePlan),
    case socket_new(StateNew) of
        {ok, StateSocket} ->
            #state{dispatcher = Dispatcher,
                   timeout_init = Timeout,
                   options = #config_service_options{
                       scope = Scope}} = StateNew,
            InitTimer = erlang:send_after(Timeout, Dispatcher,
                                          'cloudi_service_init_timeout'),
            % all old subscriptions are stored but not removed until after
            % the new OS process is initialized
            % (if old service requests are queued for service name patterns
            %  that are no longer valid for the new OS process, the CloudI API
            %  implementation will make sure a null response is returned)
            Subscriptions = cpg:which_groups_counts(Scope, Dispatcher,
                                                             Timeout),
            {ok, StateSocket,
             socket_data_to_state(StateSocket,
                                  StateNew#state{os_pid = undefined,
                                                 init_timer = InitTimer,
                                                 subscribed = Subscriptions})};
        {error, _} = Error ->
            Error
    end.

update_state(#state{dispatcher = Dispatcher,
                    timeout_init = TimeoutInitOld,
                    timeout_async = TimeoutAsyncOld,
                    timeout_sync = TimeoutSyncOld,
                    dest_refresh = DestRefreshOld,
                    cpg_data = GroupsOld,
                    dest_deny = DestDenyOld,
                    dest_allow = DestAllowOld,
                    options = ConfigOptionsOld} = State,
             #config_service_update{
                 dest_refresh = DestRefreshNew,
                 timeout_init = TimeoutInitNew,
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
    TimeoutInit = if
        TimeoutInitNew =:= undefined ->
            TimeoutInitOld;
        is_integer(TimeoutInitNew) ->
            TimeoutInitNew
    end,
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
    ConfigOptionsN = case lists:member(rate_request_max, OptionsKeys) of
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
                scope = Scope} = ConfigOptionsN,
            ok = destination_refresh(DestRefresh, Dispatcher, Delay, Scope);
        true ->
            ok
    end,
    State#state{timeout_init = TimeoutInit,
                timeout_async = TimeoutAsync,
                timeout_sync = TimeoutSync,
                dest_refresh = DestRefresh,
                cpg_data = Groups,
                dest_deny = DestDeny,
                dest_allow = DestAllow,
                options = ConfigOptionsN}.

update_after(StateSocket, State) ->
    case socket_recv_term(StateSocket) of
        {ok, {'pid', OSPid}, StateSocketNew} ->
            StateNew = socket_data_to_state(StateSocketNew, State),
            update_after(StateSocketNew#state_socket{os_pid = OSPid},
                         os_pid_set(OSPid, StateNew));
        {ok, 'init', StateSocketNew} ->
            StateNew = socket_data_to_state(StateSocketNew, State),
            ok = os_init(StateNew),
            StateNew;
        {error, Reason} ->
            ?LOG_ERROR("update_failed: ~tp", [Reason]),
            erlang:exit(update_failed)
    end.


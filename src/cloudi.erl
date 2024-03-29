%-*-Mode:erlang;coding:utf-8;tab-width:4;c-basic-offset:4;indent-tabs-mode:()-*-
% ex: set ft=erlang fenc=utf-8 sts=4 ts=4 sw=4 et nomod:
%%%
%%%------------------------------------------------------------------------
%%% @doc
%%% ==CloudI Erlang Interface==
%%% Used for sending CloudI service requests from any Erlang process.
%%% To create an Erlang CloudI service, use the cloudi_service behavior
%%% module instead of this module.
%%% @end
%%%
%%% MIT License
%%%
%%% Copyright (c) 2013-2022 Michael Truog <mjtruog at protonmail dot com>
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
%%% @copyright 2013-2022 Michael Truog
%%% @version 2.0.5 {@date} {@time}
%%%------------------------------------------------------------------------

-module(cloudi).
-author('mjtruog at protonmail dot com').

%% external interface
-export([new/0,
         new/1,
         destinations_refresh/2,
         get_pid/2,
         get_pid/3,
         get_pids/2,
         get_pids/3,
         send_async/3,
         send_async/4,
         send_async/5,
         send_async/6,
         send_async/7,
         send_async_passive/3,
         send_async_passive/4,
         send_async_passive/5,
         send_async_passive/6,
         send_async_passive/7,
         send_sync/3,
         send_sync/4,
         send_sync/5,
         send_sync/6,
         send_sync/7,
         mcast_async/3,
         mcast_async/4,
         mcast_async/6,
         mcast_async_passive/3,
         mcast_async_passive/4,
         mcast_async_passive/6,
         recv_async/1,
         recv_async/2,
         recv_async/3,
         recv_asyncs/2,
         recv_asyncs/3,
         timeout_async/1,
         timeout_sync/1,
         timeout_max/1,
         priority_default/1,
         destination_refresh_immediate/1,
         destination_refresh_lazy/1,
         trans_id/1,
         trans_id_age/1]).

-include("cloudi_logger.hrl").
-include("cloudi_core_i_constants.hrl").
-include("cloudi_core_i_configuration_defaults.hrl").

-type nonempty_bytestring() :: nonempty_list(byte()).
-type bytestring() :: list(byte()).
-export_type([nonempty_bytestring/0,
              bytestring/0]).

-type service_name() :: nonempty_bytestring().
-type service_name_pattern() :: nonempty_bytestring().
-type service_name_pattern_suffix() :: bytestring().
-type request_info() :: any().
-type request() :: any().
-type response_info() :: any().
-type response() :: any().
-type timeout_value_milliseconds() :: 0..?TIMEOUT_MAX_ERLANG.
-type timeout_milliseconds() :: timeout_value_milliseconds() |
                                undefined | limit_min | limit_max.
-type timeout_period() :: {pos_integer(),
                           second | seconds | minute | minutes |
                           hour | hours | day | days} |
                          timeout_milliseconds().
-type priority_value() :: cloudi_service_api:priority().
-type priority() :: priority_value() | undefined.
-type trans_id() :: <<_:128>>. % version 1 UUID
-type pattern_pid() :: {service_name_pattern(), pid()}.
-export_type([service_name/0,
              service_name_pattern/0,
              service_name_pattern_suffix/0,
              request_info/0, request/0,
              response_info/0, response/0,
              timeout_value_milliseconds/0,
              timeout_milliseconds/0,
              timeout_period/0,
              priority_value/0,
              priority/0,
              trans_id/0,
              pattern_pid/0]).

-type error_reason() :: timeout.
-export_type([error_reason/0]).

-type message_service_request() ::
    {Type :: 'cloudi_service_send_async' |
             'cloudi_service_send_sync',
     Name :: service_name(),
     Pattern :: service_name_pattern(),
     RequestInfo :: request_info(),
     Request :: request(),
     Timeout :: timeout_value_milliseconds(),
     Priority :: priority_value(),
     TransId :: trans_id(),
     Source :: pid()}.
-type message_service_response() ::
    {Type :: 'cloudi_service_return_async' |
             'cloudi_service_return_sync',
     Name :: service_name(),
     Pattern :: service_name_pattern(),
     ResponseInfo :: response_info(),
     Response :: response(),
     Timeout :: timeout_value_milliseconds(),
     TransId :: trans_id(),
     Source :: pid()}.
-export_type([message_service_request/0,
              message_service_response/0]).

-record(cloudi_context,
        {
            dest_refresh :: cloudi_service_api:dest_refresh(),
            dest_refresh_delay
                :: cloudi_service_api:dest_refresh_delay_value_milliseconds(),
            request_name_lookup :: sync | async,
            timeout_async
                :: cloudi_service_api:timeout_send_async_value_milliseconds(),
            timeout_sync
                :: cloudi_service_api:timeout_send_sync_value_milliseconds(),
            priority_default :: cloudi_service_api:priority(),
            scope :: atom(),
            receiver :: pid(),
            uuid_generator :: uuid:state(),
            cpg_data :: cpg_data:state(),
            cpg_data_stale = false :: boolean()
        }).

-type options() ::
    list({dest_refresh, cloudi_service_api:dest_refresh()} |
         {dest_refresh_start, cloudi_service_api:dest_refresh_delay_period()} |
         {dest_refresh_delay, cloudi_service_api:dest_refresh_delay_period()} |
         {request_name_lookup, sync | async} |
         {timeout_async, cloudi_service_api:timeout_send_async_period()} |
         {timeout_sync, cloudi_service_api:timeout_send_sync_period()} |
         {priority_default, priority()} |
         {scope, atom()} |
         % advanced:
         % options for internal coordination with cloudi_service
         {uuid, uuid:state()} |
         {groups, cpg_data:state()} |
         {groups_scope, atom()} |
         {groups_static, boolean()}).
-type context() :: #cloudi_context{}.
-type agent() :: context() | cloudi_service:dispatcher().
-export_type([options/0,
              context/0,
              agent/0]).

% only relevant to service modules, but some people just want the shorter names
-type request_type() :: cloudi_service:request_type().
-type dispatcher() :: cloudi_service:dispatcher().
-export_type([request_type/0,
              dispatcher/0]).

-include("cloudi_core_i_common.hrl").
-include("cloudi_core_i_common_interface.hrl").

%%%------------------------------------------------------------------------
%%% External interface functions
%%%------------------------------------------------------------------------

%%-------------------------------------------------------------------------
%% @doc
%% ===Create a CloudI context.===
%% @end
%%-------------------------------------------------------------------------
-spec new() ->
    context().

new() ->
    new([]).

%%-------------------------------------------------------------------------
%% @doc
%% ===Create a CloudI context.===
%% If a lazy destination refresh method is used, make sure to receive the
%% {cloudi_cpg_data, Groups} message and pass it to the
%% destinations_refresh/2 function.
%% @end
%%-------------------------------------------------------------------------
-spec new(Options :: options()) ->
    context().

new(Options)
    when is_list(Options) ->
    Defaults = [
        {dest_refresh,                     ?DEFAULT_DEST_REFRESH},
        {dest_refresh_start,         ?DEFAULT_DEST_REFRESH_START},
        {dest_refresh_delay,         ?DEFAULT_DEST_REFRESH_DELAY},
        {request_name_lookup,       ?DEFAULT_REQUEST_NAME_LOOKUP},
        {timeout_async,                   ?DEFAULT_TIMEOUT_ASYNC},
        {timeout_sync,                     ?DEFAULT_TIMEOUT_SYNC},
        {priority_default,                     ?DEFAULT_PRIORITY},
        {scope,                                   ?DEFAULT_SCOPE},
        {uuid,                                         undefined},
        {groups,                                       undefined},
        {groups_scope,                                 undefined},
        {groups_static,                                    false}
        ],
    [DestRefresh, DestRefreshStart0, DestRefreshDelay0, RequestNameLookup,
     TimeoutAsyncDefault0, TimeoutSyncDefault0, PriorityDefault, Scope,
     UUIDOld, GroupsOld, GroupsScope, GroupsStatic] =
        cloudi_proplists:take_values(Defaults, Options),
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
           (DestRefresh =:= lazy_oldest),
    true = ?DEST_REFRESH_START_GUARD(DestRefreshStart0),
    true = ?DEST_REFRESH_DELAY_GUARD(DestRefreshDelay0),
    true = (RequestNameLookup =:= sync) orelse
           (RequestNameLookup =:= async),
    true = ?TIMEOUT_SEND_ASYNC_GUARD(TimeoutAsyncDefault0),
    true = ?TIMEOUT_SEND_SYNC_GUARD(TimeoutSyncDefault0),
    true = (PriorityDefault >= ?PRIORITY_HIGH) andalso
           (PriorityDefault =< ?PRIORITY_LOW),
    true = is_atom(Scope),
    true = (UUIDOld =:= undefined) orelse
           (element(1, UUIDOld) =:= uuid_state),
    true = is_atom(GroupsScope),
    true = is_boolean(GroupsStatic),
    DestRefreshStartN = ?DEST_REFRESH_START_ASSIGN(DestRefreshStart0),
    DestRefreshDelayN = ?DEST_REFRESH_DELAY_ASSIGN(DestRefreshDelay0),
    TimeoutAsyncDefaultN = ?TIMEOUT_SEND_ASYNC_ASSIGN(TimeoutAsyncDefault0),
    TimeoutSyncDefaultN = ?TIMEOUT_SEND_SYNC_ASSIGN(TimeoutSyncDefault0),
    ConfiguredScope = if
        GroupsScope =:= undefined ->
            CpgScope = ?SCOPE_ASSIGN(Scope),
            ok = cpg:scope_exists(CpgScope),
            CpgScope;
        true ->
            GroupsScope
    end,
    Receiver = self(),
    UUID = if
        UUIDOld =:= undefined ->
            Variant = application:get_env(cloudi_core, uuid_v1_variant,
                                          ?UUID_V1_VARIANT_DEFAULT),
            {ok, MacAddress} = application:get_env(cloudi_core, mac_address),
            {ok, TimestampType} = application:get_env(cloudi_core,
                                                      timestamp_type),
            uuid:new(Receiver,
                              [{timestamp_type, TimestampType},
                               {mac_address, MacAddress},
                               {variant, Variant}]);
        true ->
            UUIDOld
    end,
    Groups = if
        GroupsStatic =:= true ->
            destination_refresh_groups(DestRefresh,
                                       GroupsOld);
        GroupsStatic =:= false ->
            ok = destination_refresh(DestRefresh,
                                     Receiver,
                                     DestRefreshStartN,
                                     ConfiguredScope),
            if
                ((DestRefresh =:= lazy_closest) orelse
                 (DestRefresh =:= lazy_furthest) orelse
                 (DestRefresh =:= lazy_random) orelse
                 (DestRefresh =:= lazy_local) orelse
                 (DestRefresh =:= lazy_remote) orelse
                 (DestRefresh =:= lazy_newest) orelse
                 (DestRefresh =:= lazy_oldest)),
                DestRefreshStartN < ?DEFAULT_DEST_REFRESH_START ->
                    receive
                        {cloudi_cpg_data, G} ->
                            % DestRefreshStart was small enough to
                            % immediately cache the groups
                            ok = destination_refresh(DestRefresh,
                                                     Receiver,
                                                     DestRefreshDelayN,
                                                     ConfiguredScope),
                            G
                    after
                        ?DEFAULT_DEST_REFRESH_START ->
                            destination_refresh_groups(DestRefresh,
                                                       GroupsOld)
                    end;
                true ->
                    destination_refresh_groups(DestRefresh,
                                               GroupsOld)
            end
    end,
    #cloudi_context{
        dest_refresh = DestRefresh,
        dest_refresh_delay = DestRefreshDelayN,
        request_name_lookup = RequestNameLookup,
        timeout_async = TimeoutAsyncDefaultN,
        timeout_sync = TimeoutSyncDefaultN,
        priority_default = PriorityDefault,
        scope = ConfiguredScope,
        receiver = Receiver,
        uuid_generator = UUID,
        cpg_data = Groups
    }.

%%-------------------------------------------------------------------------
%% @doc
%% ===Refresh destination lookup data.===
%% Called when using a lazy destination refresh method.
%% The {cloudi_cpg_data, Groups} message is stored and processed
%% by this function.  However, if it isn't processed, the other function
%% calls will update the Context based on any pending destination refresh
%% messages.
%% @end
%%-------------------------------------------------------------------------

-spec destinations_refresh(Context :: context(),
                           Message :: {cloudi_cpg_data,
                                       cpg_data:state()}) ->
    context().

destinations_refresh(#cloudi_context{
                         dest_refresh = DestRefresh,
                         dest_refresh_delay = DestRefreshDelay,
                         scope = Scope,
                         receiver = Receiver} = Context,
                     {cloudi_cpg_data, Groups}) ->
    ok = destination_refresh(DestRefresh, Receiver, DestRefreshDelay, Scope),
    Context#cloudi_context{cpg_data = Groups}.

%%-------------------------------------------------------------------------
%% @doc
%% ===Get a service destination based on a service name.===
%% @end
%%-------------------------------------------------------------------------

-spec get_pid(Context :: agent(),
              Name :: service_name()) ->
    {{ok, PatternPid :: pattern_pid()} |
     {error, Reason :: error_reason()}, agent()}.

get_pid(Dispatcher, Name)
    when is_pid(Dispatcher) ->
    {cloudi_service:get_pid(Dispatcher, Name), Dispatcher};

get_pid(#cloudi_context{timeout_sync = TimeoutSyncDefault} = Context, Name) ->
    get_pid(Context, Name, TimeoutSyncDefault).

%%-------------------------------------------------------------------------
%% @doc
%% ===Get a service destination based on a service name.===
%% @end
%%-------------------------------------------------------------------------

-spec get_pid(Context :: agent(),
              Name :: service_name(),
              Timeout :: timeout_period()) ->
    {{ok, PatternPid :: pattern_pid()} |
     {error, Reason :: error_reason()}, agent()}.

get_pid(Dispatcher, Name, Timeout)
    when is_pid(Dispatcher) ->
    {cloudi_service:get_pid(Dispatcher, Name, Timeout), Dispatcher};

get_pid(#cloudi_context{} = Context, [NameC | _] = Name, Timeout)
    when is_integer(NameC) ->
    ContextNew = destinations_refresh_check(Context),
    #cloudi_context{
        dest_refresh = DestRefresh,
        request_name_lookup = RequestNameLookup,
        timeout_sync = TimeoutSyncDefault,
        scope = Scope,
        cpg_data = Groups} = ContextNew,
    TimeoutNew = timeout_period_to_milliseconds(Timeout,
                                                ?TIMEOUT_GET_PID_MIN,
                                                ?TIMEOUT_GET_PID_MAX,
                                                TimeoutSyncDefault),
    case destination_get(DestRefresh, Scope, Name, Groups, TimeoutNew) of
        {error, {Reason, Name}}
        when (Reason =:= no_process orelse Reason =:= no_such_group),
             TimeoutNew >= ?SEND_SYNC_INTERVAL ->
            if
                RequestNameLookup =:= sync ->
                    get_pid(sleep(ContextNew, ?SEND_SYNC_INTERVAL), Name,
                            TimeoutNew - ?SEND_SYNC_INTERVAL);
                RequestNameLookup =:= async ->
                    result(ContextNew, {error, timeout})
            end;
        {error, _} ->
            result(ContextNew, {error, timeout});
        {ok, Pattern, Pid} ->
            result(ContextNew, {ok, {Pattern, Pid}})
    end.

%%-------------------------------------------------------------------------
%% @doc
%% ===Get all service destinations based on a service name.===
%% @end
%%-------------------------------------------------------------------------

-spec get_pids(Context :: agent(),
               Name :: service_name()) ->
    {{ok, PatternPids :: list(pattern_pid())} |
     {error, Reason :: error_reason()}, agent()}.

get_pids(Dispatcher, Name)
    when is_pid(Dispatcher) ->
    {cloudi_service:get_pids(Dispatcher, Name), Dispatcher};

get_pids(#cloudi_context{timeout_sync = TimeoutSyncDefault} = Context, Name) ->
    get_pids(Context, Name, TimeoutSyncDefault).

%%-------------------------------------------------------------------------
%% @doc
%% ===Get all service destinations based on a service name.===
%% @end
%%-------------------------------------------------------------------------

-spec get_pids(Context :: agent(),
               Name :: service_name(),
               Timeout :: timeout_period()) ->
    {{ok, PatternPids :: list(pattern_pid())} |
     {error, Reason :: error_reason()}, agent()}.

get_pids(Dispatcher, Name, Timeout)
    when is_pid(Dispatcher) ->
    {cloudi_service:get_pids(Dispatcher, Name, Timeout), Dispatcher};

get_pids(#cloudi_context{} = Context, [NameC | _] = Name, Timeout)
    when is_integer(NameC) ->
    ContextNew = destinations_refresh_check(Context),
    #cloudi_context{
        dest_refresh = DestRefresh,
        request_name_lookup = RequestNameLookup,
        timeout_sync = TimeoutSyncDefault,
        scope = Scope,
        cpg_data = Groups} = ContextNew,
    TimeoutNew = timeout_period_to_milliseconds(Timeout,
                                                ?TIMEOUT_GET_PIDS_MIN,
                                                ?TIMEOUT_GET_PIDS_MAX,
                                                TimeoutSyncDefault),
    case destination_all(DestRefresh, Scope, Name, Groups, TimeoutNew) of
        {error, {no_such_group, Name}}
        when TimeoutNew >= ?SEND_SYNC_INTERVAL ->
            if
                RequestNameLookup =:= sync ->
                    get_pids(sleep(ContextNew, ?SEND_SYNC_INTERVAL), Name,
                             TimeoutNew - ?SEND_SYNC_INTERVAL);
                RequestNameLookup =:= async ->
                    result(ContextNew, {error, timeout})
            end;
        {error, _} ->
            result(ContextNew, {error, timeout});
        {ok, Pattern, Pids} ->
            result(ContextNew, {ok, [{Pattern, Pid} || Pid <- Pids]})
    end.

%%-------------------------------------------------------------------------
%% @doc
%% ===Send an asynchronous service request.===
%% @end
%%-------------------------------------------------------------------------

-spec send_async(Context :: agent(),
                 Name :: service_name(),
                 Request :: request()) ->
    {{ok, TransId :: trans_id()} |
     {error, Reason :: error_reason()}, agent()}.

send_async(Dispatcher, Name, Request)
    when is_pid(Dispatcher) ->
    {cloudi_service:send_async(Dispatcher, Name, Request), Dispatcher};

send_async(Context, Name, Request) ->
    send_async(Context, Name, <<>>, Request,
               undefined, undefined, undefined).

%%-------------------------------------------------------------------------
%% @doc
%% ===Send an asynchronous service request.===
%% @end
%%-------------------------------------------------------------------------

-spec send_async(Context :: agent(),
                 Name :: service_name(),
                 Request :: request(),
                 Timeout :: timeout_period()) ->
    {{ok, TransId :: trans_id()} |
     {error, Reason :: error_reason()}, agent()}.

send_async(Dispatcher, Name, Request, Timeout)
    when is_pid(Dispatcher) ->
    {cloudi_service:send_async(Dispatcher, Name, Request,
                               Timeout), Dispatcher};

send_async(Context, Name, Request, Timeout) ->
    send_async(Context, Name, <<>>, Request,
               Timeout, undefined, undefined).

%%-------------------------------------------------------------------------
%% @doc
%% ===Send an asynchronous service request.===
%% @end
%%-------------------------------------------------------------------------

-spec send_async(Context :: agent(),
                 Name :: service_name(),
                 Request :: request(),
                 Timeout :: timeout_period(),
                 PatternPid :: pattern_pid() | undefined) ->
    {{ok, TransId :: trans_id()} |
     {error, Reason :: error_reason()}, agent()}.

send_async(Dispatcher, Name, Request, Timeout, PatternPid)
    when is_pid(Dispatcher) ->
    {cloudi_service:send_async(Dispatcher, Name, Request,
                               Timeout, PatternPid), Dispatcher};

send_async(Context, Name, Request, Timeout, PatternPid) ->
    send_async(Context, Name, <<>>, Request,
               Timeout, undefined, PatternPid).

%%-------------------------------------------------------------------------
%% @doc
%% ===Send an asynchronous service request.===
%% @end
%%-------------------------------------------------------------------------

-spec send_async(Context :: agent(),
                 Name :: service_name(),
                 RequestInfo :: request_info(),
                 Request :: request(),
                 Timeout :: timeout_period(),
                 Priority :: priority()) ->
    {{ok, TransId :: trans_id()} |
     {error, Reason :: error_reason()}, agent()}.

send_async(Dispatcher, Name, RequestInfo, Request,
           Timeout, Priority)
    when is_pid(Dispatcher) ->
    {cloudi_service:send_async(Dispatcher, Name, RequestInfo, Request,
                               Timeout, Priority), Dispatcher};

send_async(Context, Name, RequestInfo, Request,
           Timeout, Priority) ->
    send_async(Context, Name, RequestInfo, Request,
               Timeout, Priority, undefined).

%%-------------------------------------------------------------------------
%% @doc
%% ===Send an asynchronous service request.===
%% @end
%%-------------------------------------------------------------------------

-spec send_async(Context :: agent(),
                 Name :: service_name(),
                 RequestInfo :: request_info(),
                 Request :: request(),
                 Timeout :: timeout_period(),
                 Priority :: priority(),
                 PatternPid :: pattern_pid() | undefined) ->
    {{ok, TransId :: trans_id()} |
     {error, Reason :: error_reason()}, agent()}.

send_async(Dispatcher, Name, RequestInfo, Request,
           Timeout, Priority, PatternPid)
    when is_pid(Dispatcher) ->
    {cloudi_service:send_async(Dispatcher, Name, RequestInfo, Request,
                               Timeout, Priority, PatternPid), Dispatcher};

send_async(#cloudi_context{priority_default = PriorityDefault} = Context,
           Name, RequestInfo, Request,
           Timeout, undefined, PatternPid) ->
    send_async(Context, Name, RequestInfo, Request,
               Timeout, PriorityDefault, PatternPid);

send_async(#cloudi_context{} = Context,
           [NameC | _] = Name, RequestInfo, Request,
           Timeout, Priority, undefined)
    when is_integer(NameC) ->
    ContextNew = destinations_refresh_check(Context),
    #cloudi_context{
        dest_refresh = DestRefresh,
        request_name_lookup = RequestNameLookup,
        timeout_async = TimeoutAsyncDefault,
        scope = Scope,
        cpg_data = Groups} = ContextNew,
    TimeoutNew = timeout_period_to_milliseconds(Timeout,
                                                ?TIMEOUT_SEND_ASYNC_MIN,
                                                ?TIMEOUT_SEND_ASYNC_MAX,
                                                TimeoutAsyncDefault),
    case destination_get(DestRefresh, Scope, Name, Groups, TimeoutNew) of
        {error, {Reason, Name}}
        when (Reason =:= no_process orelse Reason =:= no_such_group),
             TimeoutNew >= ?SEND_ASYNC_INTERVAL ->
            if
                RequestNameLookup =:= sync ->
                    send_async(sleep(ContextNew, ?SEND_ASYNC_INTERVAL), Name,
                               RequestInfo, Request,
                               TimeoutNew - ?SEND_ASYNC_INTERVAL,
                               Priority, undefined);
                RequestNameLookup =:= async ->
                    result(ContextNew, {error, timeout})
            end;
        {error, _} ->
            result(ContextNew, {error, timeout});
        {ok, Pattern, Pid} ->
            send_async(ContextNew, Name, RequestInfo, Request,
                       TimeoutNew, Priority, {Pattern, Pid})
    end;

send_async(#cloudi_context{timeout_async = TimeoutAsyncDefault,
                           receiver = Receiver,
                           uuid_generator = UUID} = Context,
           [NameC | _] = Name, RequestInfo, Request,
           Timeout, Priority, {Pattern, Pid})
    when is_integer(NameC), is_integer(Priority),
         Priority >= ?PRIORITY_HIGH, Priority =< ?PRIORITY_LOW ->
    TimeoutNew = timeout_period_to_milliseconds(Timeout,
                                                ?TIMEOUT_SEND_ASYNC_MIN,
                                                ?TIMEOUT_SEND_ASYNC_MAX,
                                                TimeoutAsyncDefault),
    {TransId, UUIDNew} = uuid:get_v1(UUID),
    Pid ! {'cloudi_service_send_async',
           Name, Pattern, RequestInfo, Request,
           TimeoutNew, Priority, TransId, Receiver},
    result(Context#cloudi_context{uuid_generator = UUIDNew}, {ok, TransId}).

%%-------------------------------------------------------------------------
%% @doc
%% ===Send an asynchronous service request.===
%% An alias for send_async.  The asynchronous service request is returned
%% and handled the same way as within external services.
%% @end
%%-------------------------------------------------------------------------

-spec send_async_passive(Context :: agent(),
                         Name :: service_name(),
                         Request :: request()) ->
    {{ok, TransId :: trans_id()} |
     {error, Reason :: error_reason()}, agent()}.

send_async_passive(Context, Name, Request) ->
    send_async(Context, Name, Request).

%%-------------------------------------------------------------------------
%% @doc
%% ===Send an asynchronous service request.===
%% An alias for send_async.  The asynchronous service request is returned
%% and handled the same way as within external services.
%% @end
%%-------------------------------------------------------------------------

-spec send_async_passive(Context :: agent(),
                         Name :: service_name(),
                         Request :: request(),
                         Timeout :: timeout_period()) ->
    {{ok, TransId :: trans_id()} |
     {error, Reason :: error_reason()}, agent()}.

send_async_passive(Context, Name, Request, Timeout) ->
    send_async(Context, Name, Request, Timeout).

%%-------------------------------------------------------------------------
%% @doc
%% ===Send an asynchronous service request.===
%% An alias for send_async.  The asynchronous service request is returned
%% and handled the same way as within external services.
%% @end
%%-------------------------------------------------------------------------

-spec send_async_passive(Context :: agent(),
                         Name :: service_name(),
                         Request :: request(),
                         Timeout :: timeout_period(),
                         PatternPid :: pattern_pid() | undefined) ->
    {{ok, TransId :: trans_id()} |
     {error, Reason :: error_reason()}, agent()}.

send_async_passive(Context, Name, Request, Timeout, PatternPid) ->
    send_async(Context, Name, Request, Timeout, PatternPid).

%%-------------------------------------------------------------------------
%% @doc
%% ===Send an asynchronous service request.===
%% An alias for send_async.  The asynchronous service request is returned
%% and handled the same way as within external services.
%% @end
%%-------------------------------------------------------------------------

-spec send_async_passive(Context :: agent(),
                         Name :: service_name(),
                         RequestInfo :: request_info(),
                         Request :: request(),
                         Timeout :: timeout_period(),
                         Priority :: priority()) ->
    {{ok, TransId :: trans_id()} |
     {error, Reason :: error_reason()}, agent()}.

send_async_passive(Context, Name, RequestInfo, Request,
                   Timeout, Priority) ->
    send_async(Context, Name, RequestInfo, Request,
               Timeout, Priority).

%%-------------------------------------------------------------------------
%% @doc
%% ===Send an asynchronous service request.===
%% An alias for send_async.  The asynchronous service request is returned
%% and handled the same way as within external services.
%% @end
%%-------------------------------------------------------------------------

-spec send_async_passive(Context :: agent(),
                         Name :: service_name(),
                         RequestInfo :: request_info(),
                         Request :: request(),
                         Timeout :: timeout_period(),
                         Priority :: priority(),
                         PatternPid :: pattern_pid() | undefined) ->
    {{ok, TransId :: trans_id()} |
     {error, Reason :: error_reason()}, agent()}.

send_async_passive(Context, Name, RequestInfo, Request,
                   Timeout, Priority, PatternPid) ->
    send_async(Context, Name, RequestInfo, Request,
               Timeout, Priority, PatternPid).

%%-------------------------------------------------------------------------
%% @doc
%% ===Send a synchronous service request.===
%% @end
%%-------------------------------------------------------------------------

-spec send_sync(Context :: agent(),
                Name :: service_name(),
                Request :: request()) ->
    {{ok, ResponseInfo :: response_info(), Response :: response()} |
     {ok, Response :: response()} |
     {error, Reason :: error_reason()}, agent()}.

send_sync(Dispatcher, Name, Request)
    when is_pid(Dispatcher) ->
    {cloudi_service:send_sync(Dispatcher, Name, Request), Dispatcher};

send_sync(Context, Name, Request) ->
    send_sync(Context, Name, <<>>, Request,
              undefined, undefined, undefined).

%%-------------------------------------------------------------------------
%% @doc
%% ===Send a synchronous service request.===
%% @end
%%-------------------------------------------------------------------------

-spec send_sync(Context :: agent(),
                Name :: service_name(),
                Request :: request(),
                Timeout :: timeout_period()) ->
    {{ok, ResponseInfo :: response_info(), Response :: response()} |
     {ok, Response :: response()} |
     {error, Reason :: error_reason()}, agent()}.

send_sync(Dispatcher, Name, Request, Timeout)
    when is_pid(Dispatcher) ->
    {cloudi_service:send_sync(Dispatcher, Name, Request,
                              Timeout), Dispatcher};

send_sync(Context, Name, Request, Timeout) ->
    send_sync(Context, Name, <<>>, Request,
              Timeout, undefined, undefined).

%%-------------------------------------------------------------------------
%% @doc
%% ===Send a synchronous service request.===
%% @end
%%-------------------------------------------------------------------------

-spec send_sync(Context :: agent(),
                Name :: service_name(),
                Request :: request(),
                Timeout :: timeout_period(),
                PatternPid :: pattern_pid() | undefined) ->
    {{ok, ResponseInfo :: response_info(), Response :: response()} |
     {ok, Response :: response()} |
     {error, Reason :: error_reason()}, agent()}.

send_sync(Dispatcher, Name, Request, Timeout, PatternPid)
    when is_pid(Dispatcher) ->
    {cloudi_service:send_sync(Dispatcher, Name, Request,
                              Timeout, PatternPid), Dispatcher};

send_sync(Context, Name, Request, Timeout, PatternPid) ->
    send_sync(Context, Name, <<>>, Request,
              Timeout, undefined, PatternPid).

%%-------------------------------------------------------------------------
%% @doc
%% ===Send a synchronous service request.===
%% @end
%%-------------------------------------------------------------------------

-spec send_sync(Context :: agent(),
                Name :: service_name(),
                RequestInfo :: request_info(),
                Request :: request(),
                Timeout :: timeout_period(),
                Priority :: priority()) ->
    {{ok, ResponseInfo :: response_info(), Response :: response()} |
     {ok, Response :: response()} |
     {error, Reason :: error_reason()}, agent()}.

send_sync(Dispatcher, Name, RequestInfo, Request,
          Timeout, Priority)
    when is_pid(Dispatcher) ->
    {cloudi_service:send_sync(Dispatcher, Name, RequestInfo, Request,
                              Timeout, Priority), Dispatcher};

send_sync(Context, Name, RequestInfo, Request,
          Timeout, Priority) ->
    send_sync(Context, Name, RequestInfo, Request,
              Timeout, Priority, undefined).

%%-------------------------------------------------------------------------
%% @doc
%% ===Send a synchronous service request.===
%% @end
%%-------------------------------------------------------------------------

-spec send_sync(Context :: agent(),
                Name :: service_name(),
                RequestInfo :: request_info(),
                Request :: request(),
                Timeout :: timeout_period(),
                Priority :: priority(),
                PatternPid :: pattern_pid() | undefined) ->
    {{ok, ResponseInfo :: response_info(), Response :: response()} |
     {ok, Response :: response()} |
     {error, Reason :: error_reason()}, agent()}.

send_sync(Dispatcher, Name, RequestInfo, Request,
          Timeout, Priority, PatternPid)
    when is_pid(Dispatcher) ->
    {cloudi_service:send_sync(Dispatcher, Name, RequestInfo, Request,
                              Timeout, Priority, PatternPid), Dispatcher};

send_sync(#cloudi_context{priority_default = PriorityDefault} = Context,
          Name, RequestInfo, Request,
          Timeout, undefined, PatternPid) ->
    send_sync(Context, Name, RequestInfo, Request,
              Timeout, PriorityDefault, PatternPid);

send_sync(#cloudi_context{} = Context,
          [NameC | _] = Name, RequestInfo, Request,
          Timeout, Priority, undefined)
    when is_integer(NameC) ->
    ContextNew = destinations_refresh_check(Context),
    #cloudi_context{
        dest_refresh = DestRefresh,
        request_name_lookup = RequestNameLookup,
        timeout_sync = TimeoutSyncDefault,
        scope = Scope,
        cpg_data = Groups} = ContextNew,
    TimeoutNew = timeout_period_to_milliseconds(Timeout,
                                                ?TIMEOUT_SEND_SYNC_MIN,
                                                ?TIMEOUT_SEND_SYNC_MAX,
                                                TimeoutSyncDefault),
    case destination_get(DestRefresh, Scope, Name, Groups, TimeoutNew) of
        {error, {Reason, Name}}
        when (Reason =:= no_process orelse Reason =:= no_such_group),
             TimeoutNew >= ?SEND_SYNC_INTERVAL ->
            if
                RequestNameLookup =:= sync ->
                    send_sync(sleep(ContextNew, ?SEND_SYNC_INTERVAL), Name,
                              RequestInfo, Request,
                              TimeoutNew - ?SEND_SYNC_INTERVAL,
                              Priority, undefined);
                RequestNameLookup =:= async ->
                    result(ContextNew, {error, timeout})
            end;
        {error, _} ->
            result(ContextNew, {error, timeout});
        {ok, Pattern, Pid} ->
            send_sync(ContextNew, Name, RequestInfo, Request,
                      TimeoutNew, Priority, {Pattern, Pid})
    end;

send_sync(#cloudi_context{timeout_sync = TimeoutSyncDefault,
                          receiver = Receiver,
                          uuid_generator = UUID} = Context,
          [NameC | _] = Name, RequestInfo, Request,
          Timeout, Priority, {Pattern, Pid})
    when is_integer(NameC), is_integer(Priority),
         Priority >= ?PRIORITY_HIGH, Priority =< ?PRIORITY_LOW ->
    TimeoutNew = timeout_period_to_milliseconds(Timeout,
                                                ?TIMEOUT_SEND_SYNC_MIN,
                                                ?TIMEOUT_SEND_SYNC_MAX,
                                                TimeoutSyncDefault),
    {TransId, UUIDNew} = uuid:get_v1(UUID),
    Pid ! {'cloudi_service_send_sync',
           Name, Pattern, RequestInfo, Request,
           TimeoutNew, Priority, TransId, Receiver},
    send_sync_receive(Context#cloudi_context{uuid_generator = UUIDNew},
                      TimeoutNew, TransId).

%%-------------------------------------------------------------------------
%% @doc
%% ===Send a multicast asynchronous service request.===
%% Asynchronous service requests are sent to all services that have
%% subscribed to the service name pattern that matches the destination.
%% @end
%%-------------------------------------------------------------------------

-spec mcast_async(Context :: agent(),
                  Name :: service_name(),
                  Request :: request()) ->
    {{ok, TransIdList :: list(trans_id())} |
     {error, Reason :: error_reason()}, agent()}.

mcast_async(Dispatcher, Name, Request)
    when is_pid(Dispatcher) ->
    {cloudi_service:mcast_async(Dispatcher, Name, Request), Dispatcher};

mcast_async(Context, Name, Request) ->
    mcast_async(Context, Name, <<>>, Request,
                undefined, undefined).

%%-------------------------------------------------------------------------
%% @doc
%% ===Send a multicast asynchronous service request.===
%% Asynchronous service requests are sent to all services that have
%% subscribed to the service name pattern that matches the destination.
%% @end
%%-------------------------------------------------------------------------

-spec mcast_async(Context :: agent(),
                  Name :: service_name(),
                  Request :: request(),
                  Timeout :: timeout_period()) ->
    {{ok, TransIdList :: list(trans_id())} |
     {error, Reason :: error_reason()}, agent()}.

mcast_async(Dispatcher, Name, Request, Timeout)
    when is_pid(Dispatcher) ->
    {cloudi_service:mcast_async(Dispatcher, Name, Request,
                                Timeout), Dispatcher};

mcast_async(Context, Name, Request, Timeout) ->
    mcast_async(Context, Name, <<>>, Request,
                Timeout, undefined).

%%-------------------------------------------------------------------------
%% @doc
%% ===Send a multicast asynchronous service request.===
%% Asynchronous service requests are sent to all services that have
%% subscribed to the service name pattern that matches the destination.
%% @end
%%-------------------------------------------------------------------------

-spec mcast_async(Context :: agent(),
                  Name :: service_name(),
                  RequestInfo :: request_info(),
                  Request :: request(),
                  Timeout :: timeout_period(),
                  Priority :: priority()) ->
    {{ok, TransIdList :: list(trans_id())} |
     {error, Reason :: error_reason()}, agent()}.

mcast_async(Dispatcher, Name, RequestInfo, Request,
            Timeout, Priority)
    when is_pid(Dispatcher) ->
    {cloudi_service:mcast_async(Dispatcher, Name, RequestInfo, Request,
                                Timeout, Priority), Dispatcher};

mcast_async(#cloudi_context{priority_default = PriorityDefault} = Context,
            Name, RequestInfo, Request, Timeout, undefined) ->
    mcast_async(Context, Name, RequestInfo, Request,
                Timeout, PriorityDefault);

mcast_async(#cloudi_context{} = Context,
            [NameC | _] = Name, RequestInfo, Request, Timeout, Priority)
    when is_integer(NameC), is_integer(Priority),
         Priority >= ?PRIORITY_HIGH, Priority =< ?PRIORITY_LOW ->
    ContextNew = destinations_refresh_check(Context),
    #cloudi_context{
        dest_refresh = DestRefresh,
        request_name_lookup = RequestNameLookup,
        timeout_async = TimeoutAsyncDefault,
        scope = Scope,
        cpg_data = Groups} = ContextNew,
    TimeoutNew = timeout_period_to_milliseconds(Timeout,
                                                ?TIMEOUT_MCAST_ASYNC_MIN,
                                                ?TIMEOUT_MCAST_ASYNC_MAX,
                                                TimeoutAsyncDefault),
    case destination_all(DestRefresh, Scope, Name, Groups, TimeoutNew) of
        {error, {no_such_group, Name}}
        when TimeoutNew >= ?MCAST_ASYNC_INTERVAL ->
            if
                RequestNameLookup =:= sync ->
                    mcast_async(sleep(ContextNew, ?MCAST_ASYNC_INTERVAL), Name,
                                RequestInfo, Request,
                                TimeoutNew - ?MCAST_ASYNC_INTERVAL, Priority);
                RequestNameLookup =:= async ->
                    result(ContextNew, {error, timeout})
            end;
        {error, _} ->
            result(ContextNew, {error, timeout});
        {ok, Pattern, PidList} ->
            mcast_async_pids(ContextNew, [], PidList,
                             Name, Pattern, RequestInfo, Request,
                             TimeoutNew, Priority)
    end.

%%-------------------------------------------------------------------------
%% @doc
%% ===Send a multicast asynchronous service request.===
%% An alias for mcast_async.  The asynchronous service requests are returned
%% and handled the same way as within external services.
%% @end
%%-------------------------------------------------------------------------

-spec mcast_async_passive(Context :: agent(),
                          Name :: service_name(),
                          Request :: request()) ->
    {{ok, TransIdList :: list(trans_id())} |
     {error, Reason :: error_reason()}, agent()}.

mcast_async_passive(Context, Name, Request) ->
    mcast_async(Context, Name, Request).

%%-------------------------------------------------------------------------
%% @doc
%% ===Send a multicast asynchronous service request.===
%% An alias for mcast_async.  The asynchronous service requests are returned
%% and handled the same way as within external services.
%% @end
%%-------------------------------------------------------------------------

-spec mcast_async_passive(Context :: agent(),
                          Name :: service_name(),
                          Request :: request(),
                          Timeout :: timeout_period()) ->
    {{ok, TransIdList :: list(trans_id())} |
     {error, Reason :: error_reason()}, agent()}.

mcast_async_passive(Context, Name, Request, Timeout) ->
    mcast_async(Context, Name, Request, Timeout).

%%-------------------------------------------------------------------------
%% @doc
%% ===Send a multicast asynchronous service request.===
%% An alias for mcast_async.  The asynchronous service requests are returned
%% and handled the same way as within external services.
%% @end
%%-------------------------------------------------------------------------

-spec mcast_async_passive(Context :: agent(),
                          Name :: service_name(),
                          RequestInfo :: request_info(),
                          Request :: request(),
                          Timeout :: timeout_period(),
                          Priority :: priority()) ->
    {{ok, TransIdList :: list(trans_id())} |
     {error, Reason :: error_reason()}, agent()}.

mcast_async_passive(Context, Name, RequestInfo, Request,
                    Timeout, Priority) ->
    mcast_async(Context, Name, RequestInfo, Request,
                Timeout, Priority).

%%-------------------------------------------------------------------------
%% @doc
%% ===Receive an asynchronous service request.===
%% Use a null TransId to receive the oldest service request.  Consume is
%% implicitly true.
%% @end
%%-------------------------------------------------------------------------

-spec recv_async(Context :: agent()) ->
    {{ok, ResponseInfo :: response_info(), Response :: response(),
      TransId :: trans_id()} |
     {error, Reason :: error_reason()}, agent()}.

recv_async(Dispatcher)
    when is_pid(Dispatcher) ->
    {cloudi_service:recv_async(Dispatcher), Dispatcher};

recv_async(Context) ->
    recv_async(Context, undefined, <<0:128>>).

%%-------------------------------------------------------------------------
%% @doc
%% ===Receive an asynchronous service request.===
%% Either use the supplied TransId to receive the specific service request
%% or use a null TransId to receive the oldest service request.  Consume is
%% implicitly true.
%% @end
%%-------------------------------------------------------------------------

-spec recv_async(Context :: agent(),
                 trans_id() | timeout_period()) ->
    {{ok, ResponseInfo :: response_info(), Response :: response(),
      TransId :: trans_id()} |
     {error, Reason :: error_reason()}, agent()}.

recv_async(Dispatcher, TransId_Timeout)
    when is_pid(Dispatcher) ->
    {cloudi_service:recv_async(Dispatcher, TransId_Timeout), Dispatcher};

recv_async(Context, TransId)
    when is_binary(TransId) ->
    recv_async(Context, undefined, TransId);

recv_async(#cloudi_context{timeout_sync = TimeoutSyncDefault} = Context,
           Timeout) ->
    TimeoutNew = timeout_period_to_milliseconds(Timeout,
                                                ?TIMEOUT_RECV_ASYNC_MIN,
                                                ?TIMEOUT_RECV_ASYNC_MAX,
                                                TimeoutSyncDefault),
    recv_async(Context, TimeoutNew, <<0:128>>).

%%-------------------------------------------------------------------------
%% @doc
%% ===Receive an asynchronous service request.===
%% Either use the supplied TransId to receive the specific service request
%% or use a null TransId to receive the oldest service request.  Consume is
%% implicitly true.
%% @end
%%-------------------------------------------------------------------------

-spec recv_async(Context :: agent(),
                 Timeout :: timeout_period(),
                 TransId :: trans_id()) ->
    {{ok, ResponseInfo :: response_info(), Response :: response(),
      TransId :: trans_id()} |
     {error, Reason :: error_reason()}, agent()}.

recv_async(Dispatcher, Timeout, TransId)
    when is_pid(Dispatcher) ->
    {cloudi_service:recv_async(Dispatcher, Timeout, TransId), Dispatcher};

recv_async(#cloudi_context{timeout_sync = TimeoutSyncDefault,
                           receiver = Receiver} = Context,
           Timeout, <<0:128>>) ->
    TimeoutNew = timeout_period_to_milliseconds(Timeout,
                                                ?TIMEOUT_RECV_ASYNC_MIN,
                                                ?TIMEOUT_RECV_ASYNC_MAX,
                                                TimeoutSyncDefault),
    if
        self() /= Receiver ->
            ?LOG_ERROR("recv_async called outside of context", []),
            erlang:exit(badarg);
        true ->
            ok
    end,
    recv_async_receive_any(Context, TimeoutNew);

recv_async(#cloudi_context{timeout_sync = TimeoutSyncDefault,
                           receiver = Receiver} = Context,
           Timeout, TransId)
    when is_binary(TransId) ->
    TimeoutNew = timeout_period_to_milliseconds(Timeout,
                                                ?TIMEOUT_RECV_ASYNC_MIN,
                                                ?TIMEOUT_RECV_ASYNC_MAX,
                                                TimeoutSyncDefault),
    if
        self() /= Receiver ->
            ?LOG_ERROR("recv_async called outside of context", []),
            erlang:exit(badarg);
        true ->
            ok
    end,
    recv_async_receive_id(Context, TimeoutNew, TransId).

%%-------------------------------------------------------------------------
%% @doc
%% ===Receive asynchronous service requests.===
%% @end
%%-------------------------------------------------------------------------

-spec recv_asyncs(Context :: agent(),
                  TransIdList :: list(trans_id())) ->
    {{ok, list({ResponseInfo :: response_info(), Response :: response(),
                TransId :: trans_id()})} |
     {error, Reason :: error_reason()}, agent()}.

recv_asyncs(Dispatcher, TransIdList)
    when is_pid(Dispatcher) ->
    {cloudi_service:recv_asyncs(Dispatcher, TransIdList), Dispatcher};

recv_asyncs(Context, TransIdList) ->
    recv_asyncs(Context, undefined, TransIdList).

%%-------------------------------------------------------------------------
%% @doc
%% ===Receive asynchronous service requests.===
%% @end
%%-------------------------------------------------------------------------

-spec recv_asyncs(Context :: agent(),
                  Timeout :: timeout_period(),
                  TransIdList :: list(trans_id())) ->
    {{ok, list({ResponseInfo :: response_info(), Response :: response(),
                TransId :: trans_id()})} |
     {error, Reason :: error_reason()}, agent()}.

recv_asyncs(Dispatcher, Timeout, TransIdList)
    when is_pid(Dispatcher) ->
    {cloudi_service:recv_asyncs(Dispatcher, Timeout, TransIdList), Dispatcher};

recv_asyncs(#cloudi_context{timeout_sync = TimeoutSyncDefault,
                            receiver = Receiver} = Context,
            Timeout, TransIdList)
    when is_list(TransIdList) ->
    TimeoutNew = timeout_period_to_milliseconds(Timeout,
                                                ?TIMEOUT_RECV_ASYNCS_MIN,
                                                ?TIMEOUT_RECV_ASYNCS_MAX,
                                                TimeoutSyncDefault),
    if
        self() /= Receiver ->
            ?LOG_ERROR("recv_asyncs called outside of context", []),
            erlang:exit(badarg);
        true ->
            ok
    end,
    recv_asyncs_receive_ids([{<<>>, <<>>, TransId} || TransId <- TransIdList],
                            TimeoutNew, Context).

%%-------------------------------------------------------------------------
%% @doc
%% ===Configured service default asynchronous timeout (in milliseconds).===
%% @end
%%-------------------------------------------------------------------------

-spec timeout_async(Context :: agent()) ->
    TimeoutAsync :: cloudi_service_api:timeout_send_async_value_milliseconds().

timeout_async(Dispatcher)
    when is_pid(Dispatcher) ->
    cloudi_service:timeout_async(Dispatcher);

timeout_async(#cloudi_context{timeout_async = TimeoutAsyncDefault}) ->
    TimeoutAsyncDefault.

%%-------------------------------------------------------------------------
%% @doc
%% ===Configured service default synchronous timeout (in milliseconds).===
%% @end
%%-------------------------------------------------------------------------

-spec timeout_sync(Context :: agent()) ->
    TimeoutSync :: cloudi_service_api:timeout_send_sync_value_milliseconds().

timeout_sync(Dispatcher)
    when is_pid(Dispatcher) ->
    cloudi_service:timeout_sync(Dispatcher);

timeout_sync(#cloudi_context{timeout_sync = TimeoutSyncDefault}) ->
    TimeoutSyncDefault.

%%-------------------------------------------------------------------------
%% @doc
%% === Maximum possible service request timeout (in milliseconds).===
%% @end
%%-------------------------------------------------------------------------

-spec timeout_max(Context :: agent()) ->
    ?TIMEOUT_MAX_ERLANG.

timeout_max(Dispatcher)
    when is_pid(Dispatcher) ->
    cloudi_service:timeout_max(Dispatcher);

timeout_max(#cloudi_context{}) ->
    ?TIMEOUT_MAX_ERLANG.

%%-------------------------------------------------------------------------
%% @doc
%% ===Configured service default priority.===
%% @end
%%-------------------------------------------------------------------------

-spec priority_default(Context :: agent()) ->
    PriorityDefault :: cloudi_service_api:priority().

priority_default(Dispatcher)
    when is_pid(Dispatcher) ->
    cloudi_service:priority_default(Dispatcher);

priority_default(#cloudi_context{priority_default = PriorityDefault}) ->
    PriorityDefault.

%%-------------------------------------------------------------------------
%% @doc
%% ===Configured service destination refresh is immediate.===
%% @end
%%-------------------------------------------------------------------------

-spec destination_refresh_immediate(Context :: agent()) ->
    boolean().

destination_refresh_immediate(Dispatcher)
    when is_pid(Dispatcher) ->
    cloudi_service:destination_refresh_immediate(Dispatcher);

destination_refresh_immediate(#cloudi_context{
                                  dest_refresh = DestRefresh}) ->
    (DestRefresh =:= immediate_closest orelse
     DestRefresh =:= immediate_furthest orelse
     DestRefresh =:= immediate_random orelse
     DestRefresh =:= immediate_local orelse
     DestRefresh =:= immediate_remote orelse
     DestRefresh =:= immediate_newest orelse
     DestRefresh =:= immediate_oldest).

%%-------------------------------------------------------------------------
%% @doc
%% ===Configured service destination refresh is lazy.===
%% @end
%%-------------------------------------------------------------------------

-spec destination_refresh_lazy(Context :: agent()) ->
    boolean().

destination_refresh_lazy(Dispatcher)
    when is_pid(Dispatcher) ->
    cloudi_service:destination_refresh_lazy(Dispatcher);

destination_refresh_lazy(#cloudi_context{
                             dest_refresh = DestRefresh}) ->
    (DestRefresh =:= lazy_closest orelse
     DestRefresh =:= lazy_furthest orelse
     DestRefresh =:= lazy_random orelse
     DestRefresh =:= lazy_local orelse
     DestRefresh =:= lazy_remote orelse
     DestRefresh =:= lazy_newest orelse
     DestRefresh =:= lazy_oldest).

%%-------------------------------------------------------------------------
%% @doc
%% ===Return a new transaction id.===
%% The same data as used when sending service requests is used.
%% @end
%%-------------------------------------------------------------------------

-spec trans_id(Context :: agent()) ->
    {trans_id(), agent()}.

trans_id(Dispatcher)
    when is_pid(Dispatcher) ->
    {cloudi_service:trans_id(Dispatcher), Dispatcher};

trans_id(#cloudi_context{uuid_generator = UUID} = Context) ->
    {TransId, UUIDNew} = uuid:get_v1(UUID),
    {TransId, Context#cloudi_context{uuid_generator = UUIDNew}}.

%%-------------------------------------------------------------------------
%% @doc
%% ===Return the age of the transaction id.===
%% The result is microseconds since the Unix epoch 1970-01-01 00:00:00.
%% @end
%%-------------------------------------------------------------------------

-spec trans_id_age(TransId :: trans_id()) ->
    non_neg_integer().

trans_id_age(TransId)
    when is_binary(TransId) ->
    uuid:get_v1_time(TransId).

%%%------------------------------------------------------------------------
%%% Private functions
%%%------------------------------------------------------------------------

destinations_refresh_check(#cloudi_context{
                               dest_refresh = DestRefresh,
                               receiver = Receiver} = Context)
    when (DestRefresh =:= lazy_closest orelse
          DestRefresh =:= lazy_furthest orelse
          DestRefresh =:= lazy_random orelse
          DestRefresh =:= lazy_local orelse
          DestRefresh =:= lazy_remote orelse
          DestRefresh =:= lazy_newest orelse
          DestRefresh =:= lazy_oldest) ->
    if
        self() /= Receiver ->
            ?LOG_ERROR("called outside of context", []),
            erlang:exit(badarg);
        true ->
            ok
    end,
    receive
        {cloudi_cpg_data, Groups} ->
            % clear queue of all destination_refreshes that are pending
            destinations_refresh_check(Context#cloudi_context{
                                           cpg_data = Groups,
                                           cpg_data_stale = true})
    after
        0 ->
            Context
    end;

destinations_refresh_check(#cloudi_context{
                               receiver = Receiver} = Context) ->
    if
        self() /= Receiver ->
            ?LOG_ERROR("called outside of context", []),
            erlang:exit(badarg);
        true ->
            ok
    end,
    Context.

sleep(#cloudi_context{} = Context, Delay) ->
    receive
        {cloudi_cpg_data, Groups} ->
            sleep(Context#cloudi_context{
                      cpg_data = Groups,
                      cpg_data_stale = true}, Delay)
    after
        Delay ->
            Context
    end.

send_sync_receive(#cloudi_context{
                      receiver = Receiver} = Context,
                  Timeout, TransId) ->
    receive
        {'cloudi_service_return_sync',
         _, _, <<>>, <<>>, _, TransId, Receiver} ->
            result(Context, {error, timeout});
        {'cloudi_service_return_sync',
         _, _, <<>>, Response, _, TransId, Receiver} ->
            result(Context, {ok, Response});
        {'cloudi_service_return_sync',
         _, _, ResponseInfo, Response, _, TransId, Receiver} ->
            result(Context, {ok, ResponseInfo, Response});
        {cloudi_cpg_data, Groups} ->
            send_sync_receive(Context#cloudi_context{
                                  cpg_data = Groups,
                                  cpg_data_stale = true},
                              Timeout, TransId)
    after
        Timeout ->
            result(Context, {error, timeout})
    end.

mcast_async_pids(Context, TransIdList, [],
                 _Name, _Pattern, _RequestInfo, _Request,
                 _Timeout, _Priority) ->
    result(Context, {ok, lists:reverse(TransIdList)});
mcast_async_pids(#cloudi_context{
                     receiver = Receiver,
                     uuid_generator = UUID} = Context,
                 TransIdList, [Pid | PidList],
                 Name, Pattern, RequestInfo, Request,
                 Timeout, Priority) ->
    {TransId, UUIDNew} = uuid:get_v1(UUID),
    Pid ! {'cloudi_service_send_async',
           Name, Pattern, RequestInfo, Request,
           Timeout, Priority, TransId, Receiver},
    mcast_async_pids(Context#cloudi_context{uuid_generator = UUIDNew},
                     [TransId | TransIdList], PidList,
                     Name, Pattern, RequestInfo, Request,
                     Timeout, Priority).

recv_async_receive_any(#cloudi_context{
                           receiver = Receiver} = Context,
                       Timeout) ->
    receive
        {'cloudi_service_return_async',
         _, _, <<>>, <<>>, _, _, Receiver} ->
            result(Context, {error, timeout});
        {'cloudi_service_return_async',
         _, _, ResponseInfo, Response, _, TransId, Receiver} ->
            result(Context, {ok, ResponseInfo, Response, TransId});
        {cloudi_cpg_data, Groups} ->
            recv_async_receive_any(Context#cloudi_context{
                                       cpg_data = Groups,
                                       cpg_data_stale = true},
                                   Timeout)
    after
        Timeout ->
            result(Context, {error, timeout})
    end.

recv_async_receive_id(#cloudi_context{
                          receiver = Receiver} = Context,
                      Timeout, TransId) ->
    receive
        {'cloudi_service_return_async',
         _, _, <<>>, <<>>, _, TransId, Receiver} ->
            result(Context, {error, timeout});
        {'cloudi_service_return_async',
         _, _, ResponseInfo, Response, _, TransId, Receiver} ->
            result(Context, {ok, ResponseInfo, Response, TransId});
        {cloudi_cpg_data, Groups} ->
            recv_async_receive_id(Context#cloudi_context{
                                      cpg_data = Groups,
                                      cpg_data_stale = true},
                                  Timeout, TransId)
    after
        Timeout ->
            result(Context, {error, timeout})
    end.

recv_asyncs_receive_ids(Results, Timeout, Context) ->
    case recv_asyncs_receive_ids(Results, [], true, false, Context) of
        {true, _, ResultsNew, ContextNew} ->
            result(ContextNew, {ok, ResultsNew});
        {false, _, ResultsNew, ContextNew}
            when Timeout >= ?RECV_ASYNC_INTERVAL ->
            recv_asyncs_receive_ids(ResultsNew,
                                    Timeout - ?RECV_ASYNC_INTERVAL,
                                    sleep(ContextNew, ?RECV_ASYNC_INTERVAL));
        {false, false, ResultsNew, ContextNew} ->
            result(ContextNew, {ok, ResultsNew});
        {false, true, _, ContextNew} ->
            result(ContextNew, {error, timeout})
    end.

recv_asyncs_receive_ids([], L, Done, FoundOne, Context) ->
    {Done, not FoundOne, lists:reverse(L), Context};

recv_asyncs_receive_ids([{<<>>, <<>>, TransId} = Entry | Results] = ResultsOld,
                        L, Done, FoundOne,
                        #cloudi_context{
                            receiver = Receiver} = Context) ->
    receive
        {'cloudi_service_return_async',
         _, _, <<>>, <<>>, _, TransId, Receiver} ->
            recv_asyncs_receive_ids(Results,
                                    [Entry | L],
                                    Done, FoundOne, Context);
        {'cloudi_service_return_async',
         _, _, ResponseInfo, Response, _, TransId, Receiver} ->
            recv_asyncs_receive_ids(Results,
                                    [{ResponseInfo, Response, TransId} | L],
                                    Done, true, Context);
        {cloudi_cpg_data, Groups} ->
            recv_asyncs_receive_ids(ResultsOld, L, Done, FoundOne,
                                    Context#cloudi_context{
                                        cpg_data = Groups,
                                        cpg_data_stale = true})
    after
        0 ->
            recv_asyncs_receive_ids(Results,
                                    [Entry | L],
                                    false, FoundOne, Context)
    end;

recv_asyncs_receive_ids([{_, _, _} = Entry | Results],
                        L, Done, _FoundOne, Context) ->
    recv_asyncs_receive_ids(Results,
                            [Entry | L],
                            Done, true, Context).

result(#cloudi_context{
           dest_refresh = DestRefresh,
           dest_refresh_delay = DestRefreshDelay,
           scope = Scope,
           receiver = Receiver,
           cpg_data_stale = SendGroups} = Context, Result) ->
    if
        SendGroups =:= true ->
            ok = destination_refresh(DestRefresh, Receiver,
                                     DestRefreshDelay, Scope),
            {Result, Context#cloudi_context{cpg_data_stale = false}};
        SendGroups =:= false ->
            {Result, Context}
    end.

destination_get(lazy_closest, _, Name, Groups, _) ->
    cpg_data:get_closest_pid(Name, Groups);

destination_get(lazy_furthest, _, Name, Groups, _) ->
    cpg_data:get_furthest_pid(Name, Groups);

destination_get(lazy_random, _, Name, Groups, _) ->
    cpg_data:get_random_pid(Name, Groups);

destination_get(lazy_local, _, Name, Groups, _) ->
    cpg_data:get_local_pid(Name, Groups);

destination_get(lazy_remote, _, Name, Groups, _) ->
    cpg_data:get_remote_pid(Name, Groups);

destination_get(lazy_newest, _, Name, Groups, _) ->
    cpg_data:get_newest_pid(Name, Groups);

destination_get(lazy_oldest, _, Name, Groups, _) ->
    cpg_data:get_oldest_pid(Name, Groups);

destination_get(immediate_closest, Scope, Name, _, Timeout) ->
    ?CATCH_EXIT(cpg:get_closest_pid(Scope, Name, Timeout));

destination_get(immediate_furthest, Scope, Name, _, Timeout) ->
    ?CATCH_EXIT(cpg:get_furthest_pid(Scope, Name, Timeout));

destination_get(immediate_random, Scope, Name, _, Timeout) ->
    ?CATCH_EXIT(cpg:get_random_pid(Scope, Name, Timeout));

destination_get(immediate_local, Scope, Name, _, Timeout) ->
    ?CATCH_EXIT(cpg:get_local_pid(Scope, Name, Timeout));

destination_get(immediate_remote, Scope, Name, _, Timeout) ->
    ?CATCH_EXIT(cpg:get_remote_pid(Scope, Name, Timeout));

destination_get(immediate_newest, Scope, Name, _, Timeout) ->
    ?CATCH_EXIT(cpg:get_newest_pid(Scope, Name, Timeout));

destination_get(immediate_oldest, Scope, Name, _, Timeout) ->
    ?CATCH_EXIT(cpg:get_oldest_pid(Scope, Name, Timeout));

destination_get(DestRefresh, _, _, _, _) ->
    ?LOG_ERROR("unable to send with invalid destination refresh: ~p",
               [DestRefresh]),
    erlang:exit(badarg).

destination_all(DestRefresh, _, Name, Groups, _)
    when (DestRefresh =:= lazy_closest orelse
          DestRefresh =:= lazy_furthest orelse
          DestRefresh =:= lazy_random orelse
          DestRefresh =:= lazy_newest orelse
          DestRefresh =:= lazy_oldest) ->
    cpg_data:get_members(Name, Groups);

destination_all(lazy_local, _, Name, Groups, _) ->
    cpg_data:get_local_members(Name, Groups);

destination_all(lazy_remote, _, Name, Groups, _) ->
    cpg_data:get_remote_members(Name, Groups);

destination_all(DestRefresh, Scope, Name, _, Timeout)
    when (DestRefresh =:= immediate_closest orelse
          DestRefresh =:= immediate_furthest orelse
          DestRefresh =:= immediate_random orelse
          DestRefresh =:= immediate_newest orelse
          DestRefresh =:= immediate_oldest) ->
    ?CATCH_EXIT(cpg:get_members(Scope, Name, Timeout));

destination_all(immediate_local, Scope, Name, _, Timeout) ->
    ?CATCH_EXIT(cpg:get_local_members(Scope, Name, Timeout));

destination_all(immediate_remote, Scope, Name, _, Timeout) ->
    ?CATCH_EXIT(cpg:get_remote_members(Scope, Name, Timeout));

destination_all(DestRefresh, _, _, _, _) ->
    ?LOG_ERROR("unable to send with invalid destination refresh: ~p",
               [DestRefresh]),
    erlang:exit(badarg).

timeout_period_to_milliseconds(undefined, _, _, Default) ->
    Default;
timeout_period_to_milliseconds(Timeout, Min, Max, _) ->
    timeout_period_to_milliseconds(Timeout, Min, Max).

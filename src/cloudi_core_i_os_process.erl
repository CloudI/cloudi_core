%-*-Mode:erlang;coding:utf-8;tab-width:4;c-basic-offset:4;indent-tabs-mode:()-*-
% ex: set ft=erlang fenc=utf-8 sts=4 ts=4 sw=4 et nomod:
%%%
%%%------------------------------------------------------------------------
%%% @doc
%%% ==CloudI OS Process Configuration==
%%% Maximum resource limits can be set after
%%% "setcap 'CAP_SYS_RESOURCE=+ep' executable" (on Linux).
%%% @end
%%%
%%% MIT License
%%%
%%% Copyright (c) 2015-2020 Michael Truog <mjtruog at protonmail dot com>
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
%%% @copyright 2015-2020 Michael Truog
%%% @version 2.0.1 {@date} {@time}
%%%------------------------------------------------------------------------

-module(cloudi_core_i_os_process).
-author('mjtruog at protonmail dot com').

%% external interface
-export([limit_validate/1,
         limit_format/1,
         owner_validate/1,
         owner_format/2,
         cgroup_validate/1,
         cgroup_format/2,
         cgroup_set/2,
         cgroup_unset/2,
         chroot_format/2,
         directory_format/2]).

-include("cloudi_core_i_constants.hrl").
-ifdef(CLOUDI_CORE_STANDALONE).
-define(OS_RLIMIT_DEFAULTS, [{invalid, undefined}]).
-else.
-include("cloudi_core_i_os_rlimit.hrl").
-endif.
-define(CGROUP_UPDATE_OR_CREATE_DEFAULT, true).

-spec limit_validate(cloudi_service_api:limit_external()) ->
    {ok, list({cloudi_service_api:limit_external_key(),
               cloudi_service_api:limit_external_value()})} |
    {error, {service_options_limit_invalid, any()}}.

limit_validate(system) ->
    L = application:get_env(cloudi_core, limit, []),
    if
        is_list(L) ->
            limit_validate(limit_validate_defaults(), L, []);
        true ->
            {error, {service_options_limit_invalid, system}}
    end;
limit_validate(L)
    when is_list(L) ->
    limit_validate(limit_validate_defaults(), L, []);
limit_validate(Invalid) ->
    {error, {service_options_limit_invalid, Invalid}}.

limit_validate([], [], Output) ->
    {ok, lists:reverse(Output)};
limit_validate([], [_ | _] = L, _) ->
    {error, {service_options_limit_invalid, L}};
limit_validate([{Key, Default} | Defaults], L, Output) ->
    case lists:keytake(Key, 1, L) of
        {value, {Key, Value}, NewL} ->
            case limit_validate_value(Key, Value, Output) of
                {ok, NewOutput} ->
                    limit_validate(Defaults, NewL, NewOutput);
                {error, _} = Error ->
                    Error
            end;
        false ->
            case limit_validate_value(Key, Default, Output) of
                {ok, NewOutput} ->
                    limit_validate(Defaults, L, NewOutput);
                {error, _} = Error ->
                    Error
            end
    end.

limit_validate_defaults() ->
    ?OS_RLIMIT_DEFAULTS.

limit_validate_value(_, undefined, Output) ->
    {ok, Output};
limit_validate_value(Key, Current, Output)
    when (is_integer(Current) andalso (Current >= 0)) orelse
         (Current =:= infinity) ->
    {ok, [{Key, [{current, Current}]} | Output]};
limit_validate_value(Key, [_ | _] = Values, Output) ->
    Defaults = [
        {current, undefined},
        {maximum, undefined}],
    case cloudi_proplists:take_values(Defaults, Values) of
        [Current, _]
        when not ((Current =:= undefined) orelse
                  (Current =:= infinity) orelse
                  (is_integer(Current) andalso (Current >= 0))) ->
            {error, {service_options_limit_invalid, Key}};
        [_, Maximum]
        when not ((Maximum =:= undefined) orelse
                  (Maximum =:= infinity) orelse
                  (is_integer(Maximum) andalso (Maximum >= 0))) ->
            {error, {service_options_limit_invalid, Key}};
        [undefined, undefined] ->
            {ok, Output};
        [Current, undefined] ->
            {ok, [{Key, [{current, Current}]} | Output]};
        [undefined, Maximum] ->
            {ok, [{Key, [{maximum, Maximum}]} | Output]};
        [Current, Maximum]
        when is_integer(Current) andalso is_integer(Maximum) andalso
             (Current =< Maximum) ->
            {ok, [{Key, [{current, Current}, {maximum, Maximum}]} | Output]};
        [Current, Maximum]
        when (is_integer(Current) orelse (Current =:= infinity)) andalso
             (Maximum =:= infinity) ->
            {ok, [{Key, [{current, Current}, {maximum, Maximum}]} | Output]};
        [_, _ | _] ->
            {error, {service_options_limit_invalid, Key}}
    end;
limit_validate_value(Key, _, _) ->
    {error, {service_options_limit_invalid, Key}}.

% same defines used in the C++ source code

% limit type
-define(CLOUDI_RLIMIT_AS,               1).
-define(CLOUDI_RLIMIT_CORE,             2).
-define(CLOUDI_RLIMIT_CPU,              3).
-define(CLOUDI_RLIMIT_DATA,             4).
-define(CLOUDI_RLIMIT_FSIZE,            5).
-define(CLOUDI_RLIMIT_MEMLOCK,          6).
-define(CLOUDI_RLIMIT_MSGQUEUE,         7).
-define(CLOUDI_RLIMIT_NICE,             8).
-define(CLOUDI_RLIMIT_NOFILE,           9).
-define(CLOUDI_RLIMIT_NPROC,           10).
-define(CLOUDI_RLIMIT_RSS,             11).
-define(CLOUDI_RLIMIT_RTPRIO,          12).
-define(CLOUDI_RLIMIT_RTTIME,          13).
-define(CLOUDI_RLIMIT_SIGPENDING,      14).
-define(CLOUDI_RLIMIT_STACK,           15).
-define(CLOUDI_RLIMIT_VMEM,            16).

% limit combination
-define(CLOUDI_RLIMITS_CURRENT_ONLY,    1).
-define(CLOUDI_RLIMITS_MAXIMUM_ONLY,    2).
-define(CLOUDI_RLIMITS_CURRENT_MAXIMUM, 3).

% limit special values
-define(CLOUDI_RLIMITS_VALUE_INFINITY,  16#ffffffffffffffff).

-spec limit_format(L :: list({cloudi_service_api:limit_external_key(),
                              cloudi_service_api:limit_external_value()})) ->
    binary().

limit_format(L) ->
    erlang:iolist_to_binary(limit_format_list(L)).

limit_format_list([]) ->
    [];
limit_format_list([H | L]) ->
    [limit_format_list_type(H) | limit_format_list(L)].

limit_format_list_type({Type, Values}) ->
    TypeI = if
        Type =:= as ->
            ?CLOUDI_RLIMIT_AS;
        Type =:= core ->
            ?CLOUDI_RLIMIT_CORE;
        Type =:= cpu ->
            ?CLOUDI_RLIMIT_CPU;
        Type =:= data ->
            ?CLOUDI_RLIMIT_DATA;
        Type =:= fsize ->
            ?CLOUDI_RLIMIT_FSIZE;
        Type =:= memlock ->
            ?CLOUDI_RLIMIT_MEMLOCK;
        Type =:= msgqueue ->
            ?CLOUDI_RLIMIT_MSGQUEUE;
        Type =:= nice ->
            ?CLOUDI_RLIMIT_NICE;
        Type =:= nofile ->
            ?CLOUDI_RLIMIT_NOFILE;
        Type =:= nproc ->
            ?CLOUDI_RLIMIT_NPROC;
        Type =:= rss ->
            ?CLOUDI_RLIMIT_RSS;
        Type =:= rtprio ->
            ?CLOUDI_RLIMIT_RTPRIO;
        Type =:= rttime ->
            ?CLOUDI_RLIMIT_RTTIME;
        Type =:= sigpending ->
            ?CLOUDI_RLIMIT_SIGPENDING;
        Type =:= stack ->
            ?CLOUDI_RLIMIT_STACK;
        Type =:= vmem ->
            ?CLOUDI_RLIMIT_VMEM
    end,
    Defaults = [
        {current, undefined},
        {maximum, undefined}],
    case cloudi_proplists:take_values(Defaults, Values) of
        [Current, undefined] ->
            CurrentI = limit_format_list_value(Current),
            <<TypeI, ?CLOUDI_RLIMITS_CURRENT_ONLY,
              CurrentI:64/unsigned-integer-native>>;
        [undefined, Maximum] ->
            MaximumI = limit_format_list_value(Maximum),
            <<TypeI, ?CLOUDI_RLIMITS_MAXIMUM_ONLY,
              MaximumI:64/unsigned-integer-native>>;
        [Current, Maximum] ->
            CurrentI = limit_format_list_value(Current),
            MaximumI = limit_format_list_value(Maximum),
            <<TypeI, ?CLOUDI_RLIMITS_CURRENT_MAXIMUM,
              CurrentI:64/unsigned-integer-native,
              MaximumI:64/unsigned-integer-native>>
    end.

limit_format_list_value(infinity) ->
    ?CLOUDI_RLIMITS_VALUE_INFINITY;
limit_format_list_value(Value)
    when is_integer(Value), Value >= 0 ->
    Value.

-spec owner_validate(cloudi_service_api:owner_external()) ->
    {ok, cloudi_service_api:owner_external()} |
    {error, {service_options_owner_invalid, any()}}.

owner_validate(Values)
    when is_list(Values) ->
    Defaults = [
        {user, "user"},
        {group, "group"}],
    case cloudi_proplists:take_values(Defaults, Values) of
        [User, _]
            when not ((is_list(User) andalso is_integer(hd(User))) orelse
                      (is_integer(User) andalso
                       (User > 0) andalso (User =< 16#ffffffffffffffff))) ->
            {error, {service_options_owner_invalid, [{user, User}]}};
        [_, Group]
            when not ((is_list(Group) andalso is_integer(hd(Group))) orelse
                      (is_integer(Group) andalso
                       (Group > 0) andalso (Group =< 16#ffffffffffffffff))) ->
            {error, {service_options_owner_invalid, [{group, Group}]}};
        [_, _] ->
            {ok, Values};
        [_, _ | Extra] ->
            {error, {service_options_owner_invalid, Extra}}
    end;
owner_validate(Invalid) ->
    {error, {service_options_owner_invalid, Invalid}}.

-spec owner_format(Values :: cloudi_service_api:owner_external(),
                   EnvironmentLookup :: cloudi_environment:lookup()) ->
    {UserI :: non_neg_integer(), UserStr :: string(),
     GroupI :: non_neg_integer(), GroupStr :: string()}.

owner_format(Values, EnvironmentLookup) ->
    {UserI, UserStr} = case lists:keyfind(user, 1, Values) of
        {user, User}
            when is_integer(User) ->
            {User, ""};
        {user, [_ | _] = User} ->
            case cloudi_environment:transform(User, EnvironmentLookup) of
                [] ->
                    % make user lookup fail
                    {0, User};
                [_ | _] = UserFinal ->
                    {0, UserFinal}
            end;
        false ->
            {0, ""}
    end,
    {GroupI, GroupStr} = case lists:keyfind(group, 1, Values) of
        {group, Group}
            when is_integer(Group) ->
            {Group, ""};
        {group, [_ | _] = Group} ->
            case cloudi_environment:transform(Group, EnvironmentLookup) of
                [] ->
                    % make group lookup fail
                    {0, Group};
                [_ | _] = GroupFinal ->
                    {0, GroupFinal}
            end;
        false ->
            {0, ""}
    end,
    {UserI, UserStr, GroupI, GroupStr}.

-spec cgroup_validate(cloudi_service_api:cgroup_external()) ->
    {ok, cloudi_service_api:cgroup_external()} |
    {error, {service_options_cgroup_invalid, any()}}.

cgroup_validate(undefined) ->
    {ok, undefined};
cgroup_validate(Values)
    when is_list(Values) ->
    Defaults = [
        {name, undefined},
        {parameters, []},
        {update_or_create, ?CGROUP_UPDATE_OR_CREATE_DEFAULT}],
    case cloudi_proplists:take_values(Defaults, Values) of
        [Name, _, _]
            when not (is_list(Name) andalso is_integer(hd(Name))) ->
            {error, {service_options_cgroup_invalid,
                     [{name, Name}]}};
        [_, Parameters, _]
            when not is_list(Parameters) ->
            {error, {service_options_cgroup_invalid,
                     [{parameters, Parameters}]}};
        [_, _, UpdateOrCreate]
            when not is_boolean(UpdateOrCreate) ->
            {error, {service_options_cgroup_invalid,
                     [{update_or_create, UpdateOrCreate}]}};
        [_, _, _] ->
            case cgroups:new() of
                {ok, _} ->
                    {ok, Values};
                {error, _} ->
                    {error, {service_options_cgroup_invalid, does_not_exist}}
            end;
        [_, _, _ | Extra] ->
            {error, {service_options_cgroup_invalid, Extra}}
    end;
cgroup_validate(Invalid) ->
    {error, {service_options_cgroup_invalid, Invalid}}.

-spec cgroup_format(Values0 :: cloudi_service_api:cgroup_external(),
                    EnvironmentLookup :: cloudi_environment:lookup()) ->
    cloudi_service_api:cgroup_external().

cgroup_format(undefined, _) ->
    undefined;
cgroup_format(Values0, EnvironmentLookup)
    when is_list(Values0) ->
    {value, {name, NameValue}, Values1} = lists:keytake(name, 1, Values0),
    Name = cloudi_environment:transform(NameValue, EnvironmentLookup),
    {Parameters, Values3} = case lists:keytake(parameters, 1, Values1) of
        {value, {parameters, ParametersL}, Values2} ->
            {[{cloudi_environment:transform(ParameterKey, EnvironmentLookup),
               cloudi_environment:transform(ParameterValue, EnvironmentLookup)}
              || {ParameterKey, ParameterValue} <- ParametersL], Values2};
        false ->
            {[], Values1}
    end,
    {UpdateOrCreate, []} = case lists:keytake(update_or_create, 1, Values3) of
        {value, {update_or_create, UpdateOrCreateValue}, Values4} ->
            {UpdateOrCreateValue, Values4};
        false ->
            {?CGROUP_UPDATE_OR_CREATE_DEFAULT, Values3}
    end,
    [{name, Name},
     {parameters, Parameters},
     {update_or_create, UpdateOrCreate}].

-spec cgroup_set(OSPid :: pos_integer() | undefined,
                 Values :: cloudi_service_api:cgroup_external()) ->
    ok |
    {error, any()}.

cgroup_set(undefined, _) ->
    ok;
cgroup_set(_, undefined) ->
    ok;
cgroup_set(OSPid, Values)
    when is_integer(OSPid), is_list(Values) ->
    {_, Name} = lists:keyfind(name, 1, Values),
    {_, Parameters} = lists:keyfind(parameters, 1, Values),
    {_, UpdateOrCreate} = lists:keyfind(update_or_create, 1, Values),
    {ok, CGroups} = cgroups:new(),
    F = if
        UpdateOrCreate =:= true ->
            update_or_create;
        UpdateOrCreate =:= false ->
            update
    end,
    Result = cgroups:F(Name, [OSPid], Parameters, CGroups),
    ok = cgroups:destroy(CGroups),
    Result.

-spec cgroup_unset(OSPid :: pos_integer(),
                   Values :: cloudi_service_api:cgroup_external()) ->
    ok |
    {error, any()}.

cgroup_unset(_, undefined) ->
    ok;
cgroup_unset(OSPid, Values)
    when is_integer(OSPid), is_list(Values) ->
    {_, Name} = lists:keyfind(name, 1, Values),
    {_, UpdateOrCreate} = lists:keyfind(update_or_create, 1, Values),
    {ok, CGroups} = cgroups:new(),
    if
        UpdateOrCreate =:= true ->
            % move the OSPid back to the root cgroup
            _ = cgroups:update("", [OSPid], [], CGroups),
            % delete the cgroup path if no OSPids remain in the cgroup path
            _ = cgroups:delete_recursive(Name, CGroups),
            ok;
        UpdateOrCreate =:= false ->
            ok
    end,
    ok = cgroups:destroy(CGroups),
    ok.

-spec chroot_format(Chroot :: cloudi_service_api:chroot_external(),
                    EnvironmentLookup :: cloudi_environment:lookup()) ->
    {ok, NewChroot :: string()} |
    {error, any()}.

chroot_format(undefined, _) ->
    {ok, ""};
chroot_format(Chroot, EnvironmentLookup) ->
    NewChroot = cloudi_environment:transform(Chroot, EnvironmentLookup),
    Valid = absolute_path(NewChroot) andalso
            filelib:is_dir(NewChroot),
    if
        Valid =:= true ->
            {ok, NewChroot};
        Valid =:= false ->
            {error, {service_options_chroot_invalid, NewChroot}}
    end.

-spec directory_format(Directory :: cloudi_service_api:directory_external(),
                       EnvironmentLookup :: cloudi_environment:lookup()) ->
    {ok, NewDirectory :: string()} |
    {error, any()}.

directory_format(undefined, _) ->
    {ok, ""};
directory_format(Directory, EnvironmentLookup) ->
    NewDirectory = cloudi_environment:transform(Directory, EnvironmentLookup),
    Valid = absolute_path(NewDirectory),
    if
        Valid =:= true ->
            {ok, NewDirectory};
        Valid =:= false ->
            {error, {service_options_directory_invalid, NewDirectory}}
    end.

%%%------------------------------------------------------------------------
%%% Private functions
%%%------------------------------------------------------------------------

absolute_path([]) ->
    false;
absolute_path([_ | _] = Path) ->
    [H | _] = AbsolutePath = filename:absname(Path),
    (AbsolutePath == Path) orelse
    (AbsolutePath ++ [H] == Path).


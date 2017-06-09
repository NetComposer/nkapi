%% -------------------------------------------------------------------
%%
%% Copyright (c) 2017 Carlos Gonzalez Florido.  All Rights Reserved.
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%
%% -------------------------------------------------------------------

-module(nkapi_api_cmd).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([cmd/3]).

-include_lib("nkevent/include/nkevent.hrl").
-include_lib("nkservice/include/nkservice.hrl").


-define(DEBUG(Txt, Args, Req),
    case erlang:get(nkapi_server_debug) of
        true -> ?LLOG(debug, Txt, Args, Req);
        _ -> ok
    end).

-define(LLOG(Type, Txt, Args, Req),
    lager:Type(
        [
            {session_id, Req#nkreq.session_id},
            {user_id, Req#nkreq.user_id},
            {cmd, Req#nkreq.cmd}
        ],
        "NkAPI Server Req (~s, ~s, ~s) "++Txt,
        [
            Req#nkreq.user_id,
            Req#nkreq.session_id,
            Req#nkreq.cmd
            | Args
        ])).


%% ===================================================================
%% Types
%% ===================================================================

-type state() :: nkapi_server:state().
-type req() :: #nkreq{}.

%% ===================================================================
%% Commands
%% ===================================================================


%% @doc
-spec cmd(binary(), req(), state()) ->
    {ok, Reply::map(), state()} |
    {ack, state()} |
    {login, Reply::map(), User::nkservice:user_id(), Meta::nkservice:user_meta(), state()} |
    {error, nkservice:error(), state()}.

cmd(<<"event/subscribe">>, #nkreq{data=Data}, State) ->
    case nkapi_server:subscribe(self(), Data) of
        ok ->
            {ok, #{}, State};
        {error, Error} ->
            {error, Error, State}
    end;

cmd(<<"event/unsubscribe">>, #nkreq{data=Data}, State) ->
    case nkapi_server:unsubscribe(self(), Data) of
        ok ->
            {ok, #{}, State};
        {error, Error} ->
            {error, Error, State}
    end;

%% Gets [#{class=>...}]
cmd(<<"event/get_subscriptions">>, #nkreq{tid=TId}, State) ->
    Self = self(),
    spawn_link(
        fun() ->
            Reply = nkapi_server:get_subscriptions(Self),
            nkapi_server:reply(Self, TId, {ok, Reply})
        end),
    {ack, State};

cmd(<<"event/send">>, #nkreq{data=Data}, State) ->
    case nkapi_server:event(self(), Data) of
        ok ->
            {ok, #{}, State};
        {error, Error} ->
            {error, Error, State}
    end;

cmd(<<"event/send_to_user">>, #nkreq{srv_id=SrvId, data=Data}, State) ->
    #{user_id:=UserId} = Data,
    Event = #nkevent{
        class = <<"api">>,
        subclass = <<"user">>,
        type = maps:get(type, Data, <<>>),
        srv_id = SrvId,
        obj_id = UserId,
        body = maps:get(body, Data, #{})
    },
    case nkevent:send(Event) of
        ok ->
            {ok, #{}, State};
        {error, Error} ->
            {error, Error, State}
    end;

cmd(<<"session/ping">>, _Req, State) ->
    {ok, #{now=>nklib_util:m_timestamp()}, State};

cmd(<<"session/stop">>, #nkreq{data=Data}, State) ->
    case Data of
        #{session_id:=SessId} ->
            %% TODO: check if authorized
            case nkapi_server:find_session(SessId) of
                {ok, _User, Pid} ->
                    nkapi_server:stop(Pid),
                    {ok, #{}, State};
                not_found ->
                    {error, session_not_found, State}
            end;
        _ ->
            nkapi_server:stop(self()),
            {ok, #{}, State}
    end;

cmd(<<"session/cmd">>, #nkreq{data=Data}=Req, State) ->
    #{session_id:=SessId} = Data,
    case nkapi_server:find_session(SessId) of
        {ok, _User, Pid} ->
            Self = self(),
            _ = spawn_link(fun() -> launch_cmd(Req, Pid, Self) end),
            {ack, State};
        not_found ->
            {error, session_not_found, State}
    end;

cmd(<<"session/log">>, #nkreq{data=Data}, State) ->
    Txt = "API Session Log: ~p",
    case maps:get(level, Data) of
        7 -> lager:debug(Txt, [Data]);
        6 -> lager:info(Txt, [Data]);
        5 -> lager:notice(Txt, [Data]);
        4 -> lager:warning(Txt, [Data]);
        _ -> lager:error(Txt, [Data])
    end,
    {ok, #{}, State};

cmd(<<"session/api_test">>, #nkreq{data=#{data:=Data}}, State) ->
    {ok, #{reply=>Data}, State};

cmd(<<"session/api_test.async">>, #nkreq{data=#{data:=Data}}=Req, State) ->
    spawn_link(
        fun() ->
            timer:sleep(2000),
            nkapi_server:reply(Req, {ok, #{reply=>Data}})
        end),
    {ack, State};

cmd(Cmd, Req, State) ->
    ?LLOG(notice, "command not implemented: ~s", [Cmd], Req),
    {error, not_implemented, State}.


%% ===================================================================
%% Internal
%% ===================================================================


%% @private
launch_cmd(#nkreq{data=#{cmd:=Cmd}=Data, tid=TId}=Req, Pid, Self) ->
    CmdData = maps:get(data, Data, #{}),
    case nkapi_server:cmd(Pid, Cmd, CmdData) of
        {ok, <<"ok">>, ResData} ->
            nkapi_server:reply(Self, TId, {ok, ResData});
        {ok, <<"error">>, #{<<"code">>:=Code, <<"error">>:=Error}} ->
            nkapi_server:reply(Self, TId, {error, {Code, Error}});
        {ok, Res, _ResData} ->
            Ref = nklib_util:uid(),
            ?LLOG(notice, "invalid reply: ~p (~p)", [Res, Ref], Req),
            nkapi_server:reply(Self, TId, {error, {internal_error, Ref}});
        {error, Error} ->
            nkapi_server:reply(Self, TId, {error, Error})
    end.


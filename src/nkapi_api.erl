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

-module(nkapi_api).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').
-export([cmd/4]).

-include("nkapi.hrl").
-include_lib("nkservice/include/nkservice.hrl").

-define(DEBUG(Txt, Args, Req),
    case erlang:get(nkapi_server_debug) of
        true -> ?LLOG(debug, Txt, Args, Req);
        _ -> ok
    end).

-define(LLOG(Type, Txt, Args, Req),
    lager:Type(
        [
            {session_id, Req#nkapi_req.session_id},
            {user_id, Req#nkapi_req.user_id},
            {class, Req#nkapi_req.class},
            {subclass, Req#nkapi_req.subclass},
            {cmd, Req#nkapi_req.cmd}
        ],
        "NkAPI Server Req (~s, ~s, ~s/~s/~s) "++Txt,
        [
            Req#nkapi_req.user_id,
            Req#nkapi_req.session_id,
            Req#nkapi_req.class,
            Req#nkapi_req.subclass,
            Req#nkapi_req.cmd
            | Args
        ])).


%% ===================================================================
%% Types
%% ===================================================================

-type state() :: nkapi_server:state().


%% ===================================================================
%% Commands
%% ===================================================================


%% @doc
-spec cmd(binary(), binary(), #nkapi_req{}, state()) ->
    {ok, map(), state()} | {error, nkservice:error(), state()}.

cmd(event, subscribe, #nkapi_req{data=Data}, State) ->
    case nkapi_server:subscribe(self(), Data) of
        ok ->
            {ok, #{}, State};
        {error, Error} ->
            {error, Error, State}
    end;

cmd(event, unsubscribe, #nkapi_req{data=Data}, State) ->
    case nkapi_server:unsubscribe(self(), Data) of
        ok ->
            {ok, #{}, State};
        {error, Error} ->
            {error, Error, State}
    end;

%% Gets [#{class=>...}]
cmd(event, get_subscriptions, #nkapi_req{tid=TId},
        State) ->
    Self = self(),
    spawn_link(
        fun() ->
            Reply = nkapi_server:get_subscriptions(Self),
            nkapi_server:reply_ok(Self, TId, Reply)
        end),
    {ack, State};

cmd(event, send, #nkapi_req{data=Data}, State) ->
    case nkapi_server:event(self(), Data) of
        ok ->
            {ok, #{}, State};
        {error, Error} ->
            {error, Error, State}
    end;

cmd(event, send_to_user, #nkapi_req{srv_id=SrvId, data=Data}, State) ->
    #{user_id:=UserId} = Data,
    Event = #event{
        class = <<"api">>,
        subclass = <<"user">>,
        type = maps:get(type, Data, <<>>),
        srv_id = SrvId,
        obj_id = UserId,
        body = maps:get(body, Data, #{})
    },
    case nkservice_events:send(Event) of
        ok ->
            {ok, #{}, State};
        {error, Error} ->
            {error, Error, State}
    end;

cmd(session, ping, _Req, State) ->
    {ok, #{now=>nklib_util:m_timestamp()}, State};

cmd(session, stop, #nkapi_req{data=Data}, State) ->
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

cmd(session, cmd, #nkapi_req{data=Data}=Req, State) ->
    #{session_id:=SessId} = Data,
    case nkapi_server:find_session(SessId) of
        {ok, _User, Pid} ->
            Self = self(),
            _ = spawn_link(fun() -> launch_cmd(Req, Pid, Self) end),
            {ack, State};
        not_found ->
            {error, session_not_found, State}
    end;

%% Default implementation, plugins like GELF implement his
cmd(session, log, #nkapi_req{data=Data}, State) ->
    Txt = "API Session Log: ~p",
    case maps:get(level, Data) of
        7 -> lager:debug(Txt, [Data]);
        6 -> lager:info(Txt, [Data]);
        5 -> lager:notice(Txt, [Data]);
        4 -> lager:warning(Txt, [Data]);
        _ -> lager:error(Txt, [Data])
    end,
    {ok, #{}, State};

cmd(session, api_test, #nkapi_req{data=#{data:=Data}}, State) ->
    {reply, Data, State};

cmd(session, api_test_async, #nkapi_req{tid=TId, data=#{data:=Data}}, State) ->
    Self = self(),
    spawn_link(
        fun() ->
            timer:sleep(2000),
            nkapi_server:reply_ok(Self, TId, #{reply=>Data})
        end),
    {ack, State};

cmd(Sub, Cmd, Req, State) ->
    ?LLOG(notice, "not implemented command: ~s:~s", [Sub, Cmd], Req),
    {error, not_implemented, State}.


%% ===================================================================
%% Internal
%% ===================================================================


%% @private
launch_cmd(#nkapi_req{data=Data, tid=TId}=Req, Pid, Self) ->
    #{class:=Class, cmd:=Cmd} = Data,
    Sub = maps:get(subclass, Data, <<>>),
    CmdData = maps:get(data, Data, #{}),
    case nkapi_server:cmd(Pid, Class, Sub, Cmd, CmdData) of
        {ok, <<"ok">>, ResData} ->
            nkapi_server:reply_ok(Self, TId, ResData);
        {ok, <<"error">>, #{<<"code">>:=Code, <<"error">>:=Error}} ->
            nkapi_server:reply_error(Self, TId, {Code, Error});
        {ok, Res, _ResData} ->
            Ref = nklib_util:uid(),
            ?LLOG(notice, "invalid reply: ~p (~p)", [Res, Ref], Req),
            nkapi_server:reply_error(Self, TId, {internal_error, Ref});
        {error, Error} ->
            nkapi_server:reply_error(Self, TId, Error)
    end.


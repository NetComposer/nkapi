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

%% @doc
%% When an http listener is configured for api_server, and a request arrives,
%% init/2 is called
%% - callback api_server_http_auth is called to check authentication
%% - callback api_server_http is called to process the message

-module(nkapi_server_http).
-behavior(nkservice_session).

-export([cmd/3, cmd_async/3, send_event/2, start_ping/2, stop_ping/1, stop_session/2]).
-export([register/2, unregister/2, subscribe/2, unsubscribe/2, get_subscriptions/1]).
-export([reply/2, get_qs/1, get_headers/1, get_basic_auth/1, get_peer/1]).
-export([init/2, terminate/3]).

-define(MAX_BODY, 100000).
-define(MAX_ACK_TIME, 180).

-include("nkapi.hrl").
-include_lib("nkservice/include/nkservice.hrl").


-define(DEBUG(Txt, Args, Req),
    case Req#nkreq.debug of
        true -> ?LLOG(debug, Txt, Args, Req);
        _ -> ok
    end).

-define(LLOG(Type, Txt, Args, Req),
    lager:Type("NkAPI API Server HTTP (~s) "++Txt, [Req#nkreq.session_id|Args])).


%% ===================================================================
%% Types
%% ===================================================================

-type http_req() :: term().

%% @doc
-spec get_qs(http_req()) ->
    list().

get_qs(HttpReq) ->
    cowboy_req:parse_qs(HttpReq).


%% @doc
-spec get_headers(http_req()) ->
    list().

get_headers(HttpReq) ->
    cowboy_req:headers(HttpReq).


%% @doc
-spec get_basic_auth(http_req()) ->
    {user, binary(), binary()} | undefined.

get_basic_auth(HttpReq) ->
    case cowboy_req:parse_header(<<"authorization">>, HttpReq) of
        {basic, User, Pass} ->
            {basic, User, Pass};
        _ ->
            undefined
    end.


%% @doc
-spec get_peer(http_req()) ->
    {inet:ip_address(), inet:port_number()}.

get_peer(HttpReq) ->
    {Ip, Port} = cowboy_req:peer(HttpReq),
    {Ip, Port}.



%% ===================================================================
%% NKAPI
%% ===================================================================

%% @doc
cmd(_Pid, _Cmd, _Data) ->
    {error, invalid_session}.


%% @doc
cmd_async(_Pid, _Cmd, _Data) ->
    {error, invalid_session}.

%% @doc
send_event(_Pid, _Data) ->
    {error, invalid_session}.


%% @doc
start_ping(_Pid, _Secs) ->
    {error, invalid_session}.


%% @doc
stop_ping(_Pid) ->
    {error, invalid_session}.


%% @doc
stop_session(_Pid, _Reason) ->
    {error, invalid_session}.


%% @doc
register(_Pid, _Link) ->
    {error, invalid_session}.


%% @doc
unregister(_Pid, _Link) ->
    {error, invalid_session}.


%% @doc
subscribe(_Pid, _Data) ->
    {error, invalid_session}.


%% @doc
unsubscribe(_Pid, _Data) ->
    {error, invalid_session}.


%% @doc
get_subscriptions(_Pid) ->
    {error, invalid_session}.


%% @doc Sends a reply to a command (when you reply 'ack' in callbacks)
reply(Pid, {ok, Reply, #nkreq{session_module=?MODULE, tid=TId}}) ->
    Pid ! {nkapi_reply_ok, TId, Reply},
    ok;

reply(Pid, {error, Error, #nkreq{session_module=?MODULE, tid=TId}}) ->
    Pid ! {nkapi_reply_error, TId, Error},
    ok;

reply(Pid, {ack, Req}) ->
    reply(Pid, {ack, undefined, Req});

reply(Pid, {ack, AckPid, #nkreq{session_module=?MODULE, tid=TId}}) ->
    Pid ! {nkapi_reply_ack, TId, AckPid},
    ok.


%% ===================================================================
%% Callbacks
%% ===================================================================


%% @private
init(HttpReq, [{srv_id, SrvId}, {id, Id}]) ->
    {Ip, Port} = cowboy_req:peer(HttpReq),
    Remote = <<
        (nklib_util:to_host(Ip))/binary, ":",
        (to_bin(Port))/binary
    >>,
    Debug = case nkservice_util:get_debug_info(SrvId, nkapi_server) of
        {true, _} -> true;
        _ -> false
    end,
    try
        case cowboy_req:path_info(HttpReq) of
            [] -> ok;
            _ -> throw({404, [], <<"API path not found">>})
        end,
        case cowboy_req:method(HttpReq) of
            <<"POST">> -> ok;
            _ -> throw({400, [], <<"Only POST is supported">>})
        end,
        {ok, Cmd, Data} = get_body(HttpReq),
        SessionId = nklib_util:luid(),
        Req = #nkreq{
            srv_id = SrvId,
            api_id = Id,
            session_module = ?MODULE,
            session_id = SessionId,
            session_pid = self(),
            session_meta = #{remote => Remote},
            tid = erlang:phash2(SessionId),
            debug = Debug,
            cmd = Cmd,
            data = Data,
            timeout_pending = false
        },
        case process_auth(HttpReq, Req) of
            {ok, Req2} ->
                process_req(HttpReq, Req2);
            {error, Error} ->
                send_msg_error(Error, Req, HttpReq)
        end
    catch throw:{Code, Hds, Reply} ->
        send_http_reply(Code, Hds, Reply, HttpReq)
    end.


%% @private
terminate(_Reason, _Req, _Opts) ->
    ok.


%% ===================================================================
%% Internal
%% ===================================================================

%% @private
process_auth(HttpReq, #nkreq{srv_id=SrvId, api_id=Id}=Req) ->
    case ?CALL_SRV(SrvId, api_server_http_auth, [Id, HttpReq, Req]) of
        {true, UserId} ->
            {ok, Req#nkreq{user_id=UserId}};
        {true, UserId, UserState} ->
            {ok, Req#nkreq{user_id=UserId, user_state=UserState}};
        {true, UserId, UserState, #nkreq{}=Req2} ->
            {ok, Req2#nkreq{user_id=UserId, user_state=UserState}};
        false ->
            throw({403, [], <<"User forbidden">>});
        {error, Error} ->
            {error, Error}
    end.


%% @private
process_req(HttpReq, Req) ->
    case nkservice_api:api(Req) of
        {ok, Reply, #nkreq{unknown_fields=Unknown}} ->
            send_msg_ok(Reply, Unknown, HttpReq);
        {ack, Pid, #nkreq{}} ->
            Mon = case is_pid(Pid) of
                true ->
                    monitor(process, Pid);
                false ->
                    undefined
            end,
            wait_ack(Mon, Req, HttpReq);
        {error, Error, _UserState2} ->
            send_msg_error(Error, Req, HttpReq)
    end.


%% @private
get_body(Req) ->
    case cowboy_req:body_length(Req) of
        BL when is_integer(BL), BL =< ?MAX_BODY ->
            {ok, Body, _} = cowboy_req:body(Req, [{length, infinity}]),
            case cowboy_req:header(<<"content-type">>, Req) of
                <<"application/json">> ->
                    case nklib_json:decode(Body) of
                        error ->
                            throw({400, [], <<"Invalid json">>});
                        #{<<"cmd">>:=Cmd}=Json ->
                            Data = maps:get(<<"data">>, Json, #{}),
                            {ok, Cmd, Data};
                        _ ->
                            throw({400, <<"Invalid API body">>})
                    end;
                _ ->
                    throw({400, [], <<"Invalid Content-Type">>})
            end;
        _ ->
            throw({[], <<"Body too large">>})
    end.


%% @private
wait_ack(Mon, #nkreq{tid=TId, unknown_fields=Unknown}=Req, HttpReq) ->
    receive
        {nkapi_reply_ok, TId, Reply} ->
            nklib_util:demonitor(Mon),
            send_msg_ok(Reply, Unknown, HttpReq);
        {nkapi_reply_error, TId, Error} ->
            nklib_util:demonitor(Mon),
            send_msg_error(Error, Req, HttpReq);
        {nkapi_reply_login, TId, Reply, _UserId, _UserMeta} ->
            nklib_util:demonitor(Mon),
            send_msg_ok(Reply, Unknown, HttpReq);
        {nkapi_reply_ack, TId, Pid} when is_pid(Pid) ->
            nklib_util:demonitor(Mon),
            Mon2 = monitor(process, Pid),
            wait_ack(Mon2, Req, HttpReq);
        {nkapi_reply_ack, TId, _} ->
            wait_ack(Mon, Req, HttpReq);
        {'DOWN', Mon, process, _Pid, _Reason} ->
            send_msg_error(process_down, Req, HttpReq);
        Other ->
            ?LLOG(warning, "unexpected msg in wait_ack: ~p", [Other], Req),
            wait_ack(Mon, Req, HttpReq)
    after
        1000*?MAX_ACK_TIME ->
            nklib_util:demonitor(Mon),
            send_msg_error(timeout, Req, HttpReq)
    end.


%% @private
send_msg_ok(Reply, Unknown, HttpReq) ->
    Msg1 = #{result=>ok},
    Msg2 = case Reply of
        #{} when map_size(Reply)==0 -> Msg1;
        #{} -> Msg1#{data=>Reply};
        List when is_list(List) -> Msg1#{data=>Reply}
    end,
    Msg3 = case Unknown of
        [] -> Msg2;
        _ -> Msg2#{unknown_fields=>Unknown}
    end,
    send_http_reply(200, [], Msg3, HttpReq).


%% @private
send_msg_error(Error, #nkreq{srv_id=SrvId}, HttpReq) ->
    {Code, Text} = nkservice_util:error(SrvId, Error),
    Msg = #{
        result => error,
        data => #{ 
            code => Code,
            error => Text
        }
    },
    send_http_reply(200, [], Msg, HttpReq).


%% @private
send_http_reply(Code, Hds, Body, HttpReq) ->
    {Hds2, Body2} = case is_map(Body) orelse is_list(Body) of
        true -> 
            {
                [{<<"content-type">>, <<"application/json">>}|Hds],
                nklib_json:encode(Body)
            };
        false -> 
            {
                Hds,
                to_bin(Body)
            }
    end,
    {ok, cowboy_req:reply(Code, Hds2, Body2, HttpReq), []}.


%% @private
to_bin(Term) -> nklib_util:to_binary(Term).

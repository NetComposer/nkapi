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
-export([reply/2, get_qs/1, get_headers/1, get_basic_auth/1, get_peer/1]).
-export([init/2, terminate/3]).

-define(MAX_BODY, 10000000).
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


%% ===================================================================
%% Public
%% ===================================================================

%% @doc Sends a reply to a command (when you reply 'ack' in callbacks)
-spec reply(pid(), {ok, map()} | {error, term()}) ->
    ok.

reply(Pid, {ok, Reply}) ->
    Pid ! {nkapi_reply_ok, Reply},
    ok;

reply(Pid, {error, Error}) ->
    Pid ! {nkapi_reply_error, Error},
    ok;

reply(Pid, {login, Reply, User, UserMeta}) ->
    Pid ! {nkapi_reply_login, Reply, User, UserMeta},
    ok;

reply(Pid, ack) ->
    Pid ! nkapi_reply_ack,
    ok.


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
%% Callbacks
%% ===================================================================


%% @private
init(HttpReq, [{srv_id, SrvId}]) ->
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
        Req = #nkreq{
            srv_id = SrvId,
            session_module = ?MODULE,
            session_id = nklib_util:luid(),
            session_meta = #{remote => Remote},
            debug = Debug,
            cmd = Cmd,
            data = Data
        },
        case process_auth(Req, HttpReq) of
            {ok, Req2, UserState} ->
                case Cmd of
                    <<"event">> ->
                        process_event(Req2, HttpReq, UserState);
                    _ ->
                        process_req(Req2, HttpReq, UserState)
                end;
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
process_auth(#nkreq{srv_id=SrvId}=Req, HttpReq) ->
    case SrvId:api_server_http_auth(Req, HttpReq) of
        {true, UserId, Meta, State} ->
            {ok, Req#nkreq{user_id=UserId, user_meta=Meta}, State};
        false ->
            throw({403, [], <<"User forbidden">>});
        {error, Error} ->
            {error, Error}
    end.


%% @private
process_req(Req, HttpReq, UserState) ->
    case nkservice_api:api(Req, UserState) of
        {ok, Reply, Unknown, _UserState2} ->
            send_msg_ok(Reply, Unknown, HttpReq);
        {ack, Unknown, _UserState2} ->
            wait_ack(Unknown, Req, HttpReq);
        {login, Reply, _UserId, _Meta, Unknown, _UserState2} ->
            send_msg_ok(Reply, Unknown, HttpReq);
        {error, Error, _UserState2} ->
            send_msg_error(Error, Req, HttpReq)
    end.

%% @private
process_event(Req, HttpReq, UserState) ->
    case nkservice_api:event(Req, UserState) of
        {ok, _UserState2} ->
            send_msg_ok(#{}, [], HttpReq);
        {error, Error, _UserState2} ->
            send_msg_error(Error, Req, HttpReq)
    end.


%% @private
get_body(Req) ->
    case cowboy_req:body_length(Req) of
        BL when is_integer(BL), BL =< ?MAX_BODY ->
            {ok, Body, _} = cowboy_req:body(Req),
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


%%%% @private
%%auth(#state{user_state=#{remote:=Remote}=UserState} = State) ->
%%    case handle(api_server_http_auth, [], State) of
%%        {true, User, Meta, State2} when is_map(Meta) ->
%%            User2 = to_bin(User),
%%            #state{user_state=UserState} = State,
%%            UserState2 = UserState#{user=>User2, user_meta=>Meta},
%%            State3 = State2#state{user=User2, user_state=UserState2},
%%            ?LLOG(info, "user authenticated (~s)", [Remote], State3),
%%            State3;
%%        {token, User, Meta, Token, State2} ->
%%            User2 = to_bin(User),
%%            #state{user_state=UserState} = State,
%%            UserState2 = UserState#{user=>User2, user_meta=>Meta},
%%            State3 = State2#state{user=User2, user_token=Token, user_state=UserState2},
%%            ?LLOG(info, "user authenticated (~s)", [Remote], State3),
%%            State3;
%%        {false, _State2} ->
%%            ?LLOG(info, "user forbidden (~s)", [Remote], State),
%%            throw({403, [], <<"Forbidden">>})
%%    end.


%% @private
wait_ack(Unknown, Req, HttpReq) ->
    receive
        {nkapi_reply_ok, Reply} ->
            send_msg_ok(Reply, Unknown, HttpReq);
        {nkapi_reply_error, Error} ->
            send_msg_error(Error, Req, HttpReq);
        {nkapi_reply_login, Reply, _UserId, _UserMeta} ->
            send_msg_ok(Reply, Unknown, HttpReq);
        nkapi_ack ->
            wait_ack(Unknown, Req, HttpReq)
    after
        1000*?MAX_ACK_TIME -> 
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

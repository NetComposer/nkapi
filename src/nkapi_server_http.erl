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
-export([filename_encode/3, filename_decode/1]).
-export([get_body/2, get_qs/1, get_ct/1, get_basic_auth/1]).
-export([init/2, terminate/3]).
-export_type([reply/0, method/0, code/0, path/0, http_qs/0]).

-define(MAX_BODY, 10000000).
-define(MAX_ACK_TIME, 180).

-include("nkapi.hrl").
-include_lib("nkservice/include/nkservice.hrl").


-define(DEBUG(Txt, Args, State),
    case erlang:get(nkapi_server_debug) of
        true -> ?LLOG(debug, Txt, Args, State);
        _ -> ok
    end).

-define(LLOG(Type, Txt, Args, State),
    lager:Type("NkAPI API Server HTTP (~s, ~s) "++Txt, 
               [State#state.user, State#state.session_id|Args])).



%% ===================================================================
%% Types
%% ===================================================================


-record(state, {
    srv_id :: nkapi:id(),
    user = <<>> :: binary(),
    user_token = <<>> :: binary(),
    session_id :: binary(),
    req :: term(),
    method :: binary(),
    path :: [binary()],
    ct :: binary(),
    user_state :: nkapi:user_state()
}).


-type method() :: get | post | head | delete | put.

-type code() :: 100 .. 599.

-type header() :: [{binary(), binary()}].

-type body() ::  Body::binary()|map().

-type state() :: nkapi_server:user_state().

-type reply() ::
    {ok, Reply::map(), state()} |
    {error, nkapi:error(), state()} |
    {http, code(), [header()], body(), state()} |
    {rpc, state()}.

-type http_qs() ::
    [{binary(), binary()|true}].

-type req() :: #state{}.

-type path() :: [binary()].


%% ===================================================================
%% Public
%% ===================================================================

%% @doc
-spec filename_encode(Module::atom(), ObjId::binary(), Name::binary()) ->
    binary().

filename_encode(Module, ObjId, Name) when is_atom(Module) ->
    ObjId2 = to_bin(ObjId),
    Name2 = to_bin(Name),
    Term = term_to_binary({Module, ObjId2, Name2}),
    nklib_util:base64url_encode(Term).


%% @doc
-spec filename_decode(binary()|string()) ->
    {Module::atom(), Id::term(), Name::term()} | error.

filename_decode(Term) ->
    try
        Bin = nklib_util:base64url_decode(Term),
        {_Module, _ObjId, _Name} = binary_to_term(Bin)
    catch
        error:_ -> error
    end.


%% @doc
-spec get_body(req(), #{max_size=>integer(), parse=>boolean()}) ->
    binary() | map().

get_body(#state{ct=CT, req=Req}, Opts) ->
    MaxBody = maps:get(max_size, Opts, 100000),
    case cowboy_req:body_length(Req) of
        BL when is_integer(BL), BL =< MaxBody ->
            {ok, Body, _} = cowboy_req:body(Req),
            case maps:get(parse, Opts, false) of
                true ->
                    case CT of
                        <<"application/json">> ->
                            case nklib_json:decode(Body) of
                                error ->
                                    throw({400, [], <<"Invalid json">>});
                                Json ->
                                    Json
                            end;
                        _ ->
                            Body
                    end;
                _ ->
                    Body
            end;
        _ ->
            throw({400, [], <<"Body too large">>})
    end.


%% @doc
-spec get_qs(req()) ->
    http_qs().

get_qs(#state{req=Req}) ->
    cowboy_req:parse_qs(Req).


%% @doc
-spec get_ct(req()) ->
    binary().

get_ct(#state{ct=CT}) ->
    CT.


%% @doc
-spec get_basic_auth(req()) ->
    {user, binary(), binary()} | undefined.

get_basic_auth(#state{req=Req}) ->
    case cowboy_req:parse_header(<<"authorization">>, Req) of
        {basic, User, Pass} ->
            {basic, User, Pass};
        _ ->
            undefined
    end.


%% ===================================================================
%% Callbacks
%% ===================================================================


%% @private
init(Req, [{srv_id, SrvId}]) ->
    {Ip, Port} = cowboy_req:peer(Req),
    Remote = <<
        (nklib_util:to_host(Ip))/binary, ":",
        (to_bin(Port))/binary
    >>,
    SessId = nklib_util:luid(),
    Method = case cowboy_req:method(Req) of
        <<"POST">> -> post;
        <<"GET">> -> get;
        <<"HEAD">> -> head;
        <<"DELETE">> -> delete;
        <<"PUT">> -> put;
        _ -> throw({400, [], <<"Invalid Method">>})
    end,
    Path = case cowboy_req:path_info(Req) of
        [<<>>|Rest] -> Rest;
        Rest -> Rest
    end,
    UserState = #{
        srv_id => SrvId,
        session_type => ?MODULE,
        session_id => SessId,
        remote => Remote
    },
    State1 = #state{
        srv_id = SrvId,
        session_id = SessId,
        user = <<>>,
        req = Req,
        method = Method,
        path = Path,
        ct = cowboy_req:header(<<"content-type">>, Req),
        user_state = UserState
    },
    set_log(State1),
    ?DEBUG("received ~p (~p) from ~s", [Method, Path, Remote], State1),
    try
        State2 = auth(State1),
        Reply = handle(api_server_http, [Method, Path], State2),
        process(Reply)
    catch
        throw:{Code, Hds, Body} ->
            send_http_reply(Code, Hds, Body, State1)
    end.


%% @private
terminate(_Reason, _Req, _Opts) ->
    ok.


%% ===================================================================
%% Internal
%% ===================================================================


%% @private
set_log(#state{srv_id=SrvId}=State) ->
    Debug = case nkservice_util:get_debug_info(SrvId, nkapi_server) of
        {true, _} -> true;
        _ -> false
    end,
    % lager:error("DEBUG: ~p", [Debug]),
    put(nkapi_server_debug, Debug),
    State.


%% @private
auth(#state{user_state=#{remote:=Remote}=UserState} = State) ->
    case handle(api_server_http_auth, [], State) of
        {true, User, Meta, State2} when is_map(Meta) ->
            User2 = to_bin(User),
            #state{user_state=UserState} = State,
            UserState2 = UserState#{user=>User2, user_meta=>Meta},
            State3 = State2#state{user=User2, user_state=UserState2},
            ?LLOG(info, "user authenticated (~s)", [Remote], State3),
            State3;
        {token, User, Meta, Token, State2} ->
            User2 = to_bin(User),
            #state{user_state=UserState} = State,
            UserState2 = UserState#{user=>User2, user_meta=>Meta},
            State3 = State2#state{user=User2, user_token=Token, user_state=UserState2},
            ?LLOG(info, "user authenticated (~s)", [Remote], State3),
            State3;
        {false, _State2} ->
            ?LLOG(info, "user forbidden (~s)", [Remote], State),
            throw({403, [], <<"Forbidden">>})
    end.


%% @private
process({ok, Reply, State}) ->
    send_msg_ok(Reply, State);

process({error, Error, State}) ->
    send_msg_error(Error, State);

process({http, Code, Hds, Body, State}) ->
    send_http_reply(Code, Hds, Body, State);

process({rpc, State}) ->
    #state{srv_id=SrvId, user=User, session_id=SessId, user_state=_UserState} = State,
    case get_body(State, #{max_size=>100000, parse=>true}) of
        #{<<"cmd">>:=Cmd} = Body ->
            TId = erlang:phash2(make_ref()),
            ApiReq = #nkreq{
                srv_id = SrvId,
                cmd = Cmd,
                data = maps:get(<<"data">>, Body, #{}),
                user_id = User,
                session_id = SessId,
                session_module = ?MODULE,
                session_meta = #{tid => TId}
                %req_state = _UserState
            },
            case nkservice_api:api(ApiReq, State) of
                {ok, Reply, State2} ->
                    send_msg_ok(Reply, State2);
                {ack, State2} ->
                    nkapi_server:do_register_http(SessId),
                    ack_wait(TId, State2);
                {error, Error, State2} ->
                    send_msg_error(Error, State2)
            end;
        _ ->
            send_http_reply(400, [], <<>>, State)
    end.


%% @private
ack_wait(TId, State) ->
    receive
        {'$gen_cast', {nkapi_reply_ok, TId, Reply}} ->
            send_msg_ok(Reply, State);
        {'$gen_cast', {nkapi_reply_error, TId, Error}} ->
            send_msg_error(Error, State)
    after 
        1000*?MAX_ACK_TIME -> 
            send_msg_error(timeout, State)
    end.


%% @private
send_msg_ok(Reply, State) ->
    Msg1 = #{result=>ok},
    Msg2 = case Reply of
        #{} when map_size(Reply)==0 -> Msg1;
        #{} -> Msg1#{data=>Reply};
        List when is_list(List) -> Msg1#{data=>Reply}
    end,
    send_http_reply(200, [], Msg2, State).


%% @private
send_msg_error(Error, #state{srv_id=SrvId}=State) ->
    {Code, Text} = nkservice_util:error(SrvId, Error),
    Msg = #{
        result => error,
        data => #{ 
            code => Code,
            error => Text
        }
    },
    send_http_reply(200, [], Msg, State).


%% @private
send_http_reply(Code, Hds, Body, #state{req=Req}) ->
    {Hds2, Body2} = case is_map(Body) of
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
    {ok, cowboy_req:reply(Code, Hds2, Body2, Req), []}.


%% @private
handle(Fun, Args, State) ->
    nklib_gen_server:handle_any(Fun, Args++[State], State, #state.srv_id, #state.user_state).

%% @private
to_bin(Term) -> nklib_util:to_binary(Term).

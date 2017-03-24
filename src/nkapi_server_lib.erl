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

%% @doc Implementation of the NkService External Interface (server)
-module(nkapi_server_lib).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([process_req/2, process_event/2]).

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
        "NkAPI API Server (~s, ~s, ~s/~s/~s) "++Txt, 
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

-type state() :: map().



%% ===================================================================
%% Public
%% ===================================================================


%% ===================================================================
%% Private
%% ===================================================================

%% @doc Starts the processing of an external API request
%% It parses the request, getting the syntax calling SrvId:api_server_syntax()
%% If it is valid, calls SrvId:api_server_allow() to authorized the request
%% If is is authorized, calls SrvId:api_server_cmd() to process the request.
%% It received some state (usually from api_server_cmd/5) that can be updated
-spec process_req(#nkapi_req{}, state()) ->
    {ok, Reply::term(), state()} | {ack, state()} |
    {login, Reply::term(), User::binary(), Meta::map(), state()} |
    {error, nkapi:error(), state()}.

process_req(Req, State) ->
    case make_req(Req) of
        #nkapi_req{srv_id=SrvId, user_id=_User, data=Data} = Req2 ->
            {Syntax, Req3, State2} = SrvId:api_server_syntax(#{}, Req2, State),
            ?DEBUG("parsing syntax ~p (~p)", [Data, Syntax], Req),
            case nklib_syntax:parse(Data, Syntax) of
                {ok, Parsed, _Ext, Unrecognized} ->
                    case Unrecognized of
                        [] -> ok;
                        _ -> send_unrecognized_fields(Req, Unrecognized)
                    end,
                    Req4 = Req3#nkapi_req{data=Parsed},
                    case SrvId:api_server_allow(Req4, State2) of
                        {true, State3} ->
                            ?DEBUG("request allowed", [], Req),
                            SrvId:api_server_cmd(Req4, State3);
                        {false, State3} ->
                            ?DEBUG("request NOT allowed", [], Req),
                            {error, unauthorized, State3}
                    end;
                {error, {syntax_error, Error}} ->
                    {error, {syntax_error, Error}, State2};
                {error, {missing_mandatory_field, Field}} ->
                    {error, {missing_field, Field}, State2};
                {error, Error} ->
                    {error, Error, State2}
            end;
        error ->
            ?LLOG(error, "set atoms error", [], Req),
            {error, not_implemented, State}
    end.


%% @doc Process event sent from client
-spec process_event(#nkapi_req{}, state()) ->
    {ok, state()}.

process_event(Req, State) ->
    #nkapi_req{class=event, srv_id=SrvId, data=Data} = Req,
    ?DEBUG("parsing event ~p", [Data], Req),
    case nkservice_events:parse(SrvId, Data) of
        {ok, Event, Unrecognized} ->
            case Unrecognized of
                [] -> ok;
                _ -> send_unrecognized_fields(Req, Unrecognized)
            end,
            Req2 = Req#nkapi_req{data=Event},
            case SrvId:api_server_allow(Req2, State) of
                {true, State2} ->
                    ?DEBUG("event allowed", [], Req),
                    {ok, State3} = SrvId:api_server_client_event(Event, State2),
                    {ok, State3};
                {false, State2} ->
                    ?DEBUG("sending of event NOT authorized", [], State),
                    {ok, State2}
            end;
        {error, Error} ->
            {Code, Txt} = nkapi_util:api_error(SrvId, Error),
            Body = #{code=>Code, error=>Txt},
            send_reply_event(Req, <<"invalid_event_format">>, Body),
            {ok, State}
    end.


%% @private
make_req(#nkapi_req{class=Class, subclass=Sub, cmd=Cmd}=Req) ->
    try
        Req#nkapi_req{
            class = nklib_util:to_existing_atom(Class),
            subclass = nklib_util:to_existing_atom(Sub),
            cmd = nklib_util:to_existing_atom(Cmd)
        }
    catch
        _:_ -> error
    end.


%% @private
send_unrecognized_fields(Req, Fields) ->
    #nkapi_req{class=Class, subclass=Sub, cmd=Cmd} = Req,
    Body = #{class=>Class, subclass=>Sub, cmd=>Cmd, fields=>Fields},
    send_reply_event(Req, <<"unrecognized_fields">>, Body).


%% @private
%% TODO: if it is not a WS session, don't do this
send_reply_event(Req, Type, Body) ->
    #nkapi_req{
        srv_id = SrvId,
        session_id = SessId
    } = Req,
    Event = #event{
        class = <<"api">>,
        subclass = <<"session">>,
        type = Type,
        srv_id = SrvId,
        obj_id = SessId,
        body = Body
    },
    nkapi_server:event(self(), Event).


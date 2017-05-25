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
        "NkAPI API Server (~s, ~s, ~s) "++Txt,
        [
            Req#nkreq.user_id,
            Req#nkreq.session_id,
            Req#nkreq.cmd
            | Args
        ])).


%% ===================================================================
%% Types
%% ===================================================================

-type req() :: #nkreq{}.



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
-spec process_req(req()) ->
    {ok, Reply::term(), session()} | {ack, session()} |
    {login, Reply::term(), session()} | {error, nkapi:error(), session()}.

process_req(Req) ->
    #nkreq{srv_id=SrvId, data=Data} = Req,
    {Syntax, Req2} = SrvId:service_api_syntax(Req, #{}),
    ?DEBUG("parsing syntax ~p (~p)", [Data, Syntax], Req),
    case nklib_syntax:parse(Data, Syntax) of
        {ok, Parsed, Unknown} ->
            Req3 = Req2#nkreq{data=Parsed, unknown_fields=Unknown},
            case SrvId:service_api_allow(Req3) of
                {true, Req4} ->
                    do_process_req(Req4);
                {false, Req4} ->
                    ?DEBUG("request NOT allowed", [], Req4),
                    {error, unauthorized, Req4}
            end;
        {error, {syntax_error, Error}} ->
            {error, {syntax_error, Error}, Req2};
        {error, {missing_mandatory_field, Field}} ->
            {error, {missing_field, Field}, Req2};
        {error, Error} ->
            {error, Error, Req2}
    end.


%% @private
do_process_req(Req) ->
    #nkreq{srv_id=SrvId, cmd=Cmd} = Req,
    ?DEBUG("request allowed", [], Req, Session),
    case SrvId:api_server_cmd(Req) of
        {ok, Reply, Req2} ->
            {ok, send_unknown(Reply, Req2), Req2};
        {login, Reply, UserId, Meta, Req2} when UserId /= <<>> ->
            Req3 = Req2#nkreq{user_id=UserId, user_meta=Meta},
            {login, send_unknown(Reply, Req3), Req3};
        {ack, Req2} ->
            send_unknown(none, Req2),
            {ack, Req2};
        {error, Error, Req2} ->
            {error, Error, Req2}
    end.


%% @doc Process event sent from client
-spec process_event(req(), session()) ->
    {ok, session()}.

process_event(Req, Session) ->
    #nkreq{data=Data} = Req,
    #nkapi_session{srv_id=SrvId} = Session,
    ?DEBUG("parsing event ~p", [Data], Req, Session),
    case nkevent_util:parse(Data#{srv_id=>SrvId}) of
        {ok, Event} ->
            Req2 = Req#nkreq{data=Event},
            case SrvId:api_server_allow(Req2, Session) of
                true ->
                    ?DEBUG("event allowed", [], Req, Session),
                    SrvId:api_server_client_event(Event, Session);
                {true, Session2} ->
                    ?DEBUG("event allowed", [], Req, Session),
                    SrvId:api_server_client_event(Event, Session2);
                false ->
                    ?DEBUG("sending of event NOT authorized", [], Req, Session),
                    {ok, Session};
                {false, Session2} ->
                    ?DEBUG("sending of event NOT authorized", [], Req, Session),
                    {ok, Session2}
            end;
        {error, Error} ->
            {Code, Txt} = nkapi_util:api_error(SrvId, Error),
            Body = #{code=>Code, error=>Txt},
            send_reply_event(Req, <<"invalid_event_format">>, Body),
            {ok, Session}
    end.



%% @private
send_unknown(Reply, #nkapi_req{unknown_fields=[]}) ->
    Reply;

send_unknown(Reply, #nkapi_req{unknown_fields=Unknown}) when is_map(Reply) ->
    BaseUnknowns = maps:get(unknown_fields, Reply, []),
    Reply#{unknown_fields => lists:usort(BaseUnknowns++Unknown)};

send_unknown(_Reply, Req) ->
    #nkapi_req{class=Class, subclass=Sub, cmd=Cmd, unknown_fields=Unknown} = Req,
    Body = #{class=>Class, subclass=>Sub, cmd=>Cmd, fields=>Unknown},
    send_reply_event(Req, <<"unrecognized_fields">>, Body).




%% @private
%% TODO: if it is not a WS session, don't do this
send_reply_event(Req, Type, Body) ->
    #nkapi_req{
        srv_id = SrvId,
        session_id = SessId
    } = Req,
    Event = #nkevent{
        class = <<"api">>,
        subclass = <<"session">>,
        type = Type,
        srv_id = SrvId,
        obj_id = SessId,
        body = Body
    },
    nkapi_server:event(self(), Event).


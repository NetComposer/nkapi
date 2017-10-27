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

%% @doc Default callbacks
-module(nkapi_callbacks).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').
-export([api_server_init/3, api_server_terminate/3,
		 api_server_reg_down/4,
		 api_server_handle_call/4, api_server_handle_cast/3,
		 api_server_handle_info/3, api_server_code_change/4]).
-export([api_server_http_auth/3]).
-export([service_api_syntax/3,  service_api_cmd/2]).
-export_type([continue/0]).

-type continue() :: continue | {continue, list()}.
-type config() :: nkapi:config().
%%-type error_code() :: nkservice:error().

-include_lib("nkpacket/include/nkpacket.hrl").
-include("nkapi.hrl").
-include_lib("nkservice/include/nkservice.hrl").




%% ===================================================================
%% Error Codes
%% ===================================================================

%% ===================================================================
%% API Server Callbacks
%% ===================================================================

-type state() :: nkapi_server:user_state().


%% @doc Called when a new connection starts
-spec api_server_init(nkapi:id(), nkpacket:nkport(), state()) ->
	{ok, state()} | {stop, term()}.

api_server_init(_Id, _NkPort, State) ->
	{ok, State}.


%% @doc Called when the service process receives a registered process down
-spec api_server_reg_down(nkapi:id(), nklib:link(), Reason::term(), state()) ->
	{ok, state()} | {stop, Reason::term(), state()} | continue().

api_server_reg_down(_Id, _Link, _Reason, State) ->
    {ok, State}.


%% @doc Called when the process receives a handle_call/3.
-spec api_server_handle_call(nkapi:id(), term(), {pid(), reference()}, state()) ->
	{ok, state()} | continue().

api_server_handle_call(_Id, Msg, _From, State) ->
    lager:error("Module nkapi_server received unexpected call ~p", [Msg]),
    {ok, State}.


%% @doc Called when the process receives a handle_cast/3.
-spec api_server_handle_cast(nkapi:id(), term(), state()) ->
	{ok, state()} | continue().

api_server_handle_cast(_Id, Msg, State) ->
    lager:error("Module nkapi_server received unexpected cast ~p", [Msg]),
	{ok, State}.


%% @doc Called when the process receives a handle_info/3.
-spec api_server_handle_info(nkapi:id(), term(), state()) ->
	{ok, state()} | continue().

api_server_handle_info(_Id, Msg, State) ->
    lager:notice("Module nkapi_server received unexpected info ~p", [Msg]),
	{ok, State}.


%% @doc
-spec api_server_code_change(nkapi:id(), term()|{down, term()}, state(), term()) ->
    ok | {ok, state()} | {error, term()} | continue().

api_server_code_change(_Id, OldVsn, State, Extra) ->
	{continue, [OldVsn, State, Extra]}.


%% @doc Called when a service is stopped
-spec api_server_terminate(nkapi:id(), term(), state()) ->
	{ok, state()}.

api_server_terminate(_Id, _Reason, State) ->
	{ok, State}.


%% @doc called when a new http request has been received to select te authenticated user
-spec api_server_http_auth(nkapi:id(), nkapi_server_http:http_req(), #nkreq{}) ->
    {true, User::binary()} |
    {true, User::binary, #nkreq{}} |
    {true, User::binary, #nkreq{}, State::map()} |
    false |
    {error, nkservice:error()}.

api_server_http_auth(_Id, _HttpReq, _Req) ->
    false.





%% ===================================================================
%% Service Callbacks
%% ===================================================================


%% @doc
service_api_syntax(_Id, SyntaxAcc, #nkreq{cmd=Cmd}=Req) ->
    {nkapi_api_syntax:syntax(Cmd, SyntaxAcc), Req};

service_api_syntax(_Id, _SyntaxAcc, _Req) ->
    continue.


%% @doc
service_api_cmd(_Id, #nkreq{cmd=Cmd}=Req) ->
    nkapi_api_cmd:cmd(Cmd, Req);

service_api_cmd(_Id, _Req) ->
    continue.

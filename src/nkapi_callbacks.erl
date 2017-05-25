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
-export([plugin_deps/0, plugin_syntax/0, plugin_listen/2]).
-export([api_error/2, api_error/1]).
-export([api_server_init/2, api_server_terminate/2, 
         api_server_http_auth/2, api_server_http/4,
		 api_server_reg_down/3,
		 api_server_handle_call/3, api_server_handle_cast/2, 
		 api_server_handle_info/2, api_server_code_change/3]).
-export([service_api_syntax/2,service_api_cmd/1]).
-export_type([continue/0]).

-type continue() :: continue | {continue, list()}.
-type config() :: nkapi:config().
%%-type error_code() :: nkapi:error().

-include_lib("nkpacket/include/nkpacket.hrl").
-include("nkapi.hrl").
-include_lib("nkservice/include/nkservice.hrl").



%% ===================================================================
%% Plugin Callbacks
%% ===================================================================

plugin_deps() ->
	[].



%% @doc This function, if implemented, can offer a nklib_config:syntax()
%% that will be checked against service configuration. Entries passing will be
%% updated on the configuration with their parsed values
-spec plugin_syntax() ->
	nklib_config:syntax().

plugin_syntax() ->
    nkpacket_util:get_plugin_net_syntax(#{
        api_server => fun nkapi_util:parse_api_server/3,
        api_server_timeout => {integer, 5, none},
        web_server => fun nkapi_util:parse_web_server/3,
        web_server_path => binary
    }).


%% @doc This function, if implemented, allows to add listening transports.
%% By default start the web_server and api_server transports.
-spec plugin_listen(config(), nkservice:service()) ->
	[{nkpacket:user_connection(), nkpacket:listener_opts()}].

plugin_listen(Config, #{id:=SrvId}) ->
    {multi, WebSrv} = maps:get(web_server, Config, {multi, []}),
    WebSrvs = nkapi_util:get_web_servers(SrvId, WebSrv, Config),
    {multi, ApiSrv} = maps:get(api_server, Config, {multi, []}),
    ApiSrvs1 = nkapi_util:get_api_webs(SrvId, ApiSrv, Config),
    ApiSrvs2 = nkapi_util:get_api_sockets(SrvId, ApiSrv, Config),
    WebSrvs ++ ApiSrvs1 ++ ApiSrvs2.




%% ===================================================================
%% Error Codes
%% ===================================================================

%% @doc
-spec api_error(nkservice:lang(), nkservice:error()) ->
    atom() |
    tuple() |
    list() |
    {atom(), string()} |
    {Fmt::string(), Vals::string()} |
    {atom(), Fmt::string(), Vals::string()}.

api_error(SrvId, Error) ->
    SrvId:api_error(Error).


%% @doc
-spec api_error(nkservice:error()) ->
    atom() |
    tuple() |
    list() |
    {atom(), string()} |
    {Fmt::string(), Vals::string()} |
    {atom(), Fmt::string(), Vals::string()}.

api_error(already_authenticated)	-> "Already authenticated";
api_error(already_started)	        -> "Already started";
api_error(already_uploaded)   		-> "Already uploaded";
api_error(api_delete) 				-> "API delete received";
api_error(api_stop) 				-> "API stop received";
api_error(data_not_available)   	-> "Data is not available";
api_error(destionation_not_found)   -> "Destination not found";
api_error(duplicated_session_id)	-> "Duplicated session";
api_error(file_read_error)   		-> "File read error";
api_error(internal_error)			-> "Internal error";
api_error({internal_error, Ref})	-> {"Internal error: ~s", [Ref]};
api_error({invalid_action, Txt})    -> {"Invalid action '~s'", [Txt]};
api_error({invalid_state, St}) 	    -> {"Invalid state: ~s", [St]};
api_error({invalid_value, V}) 		-> {"Invalid value: '~s'", [V]};
api_error(invalid_json) 			-> "Invalid JSON";
api_error(invalid_operation) 		-> "Invalid operation";
api_error(invalid_parameters) 		-> "Invalid parameters";
api_error(invalid_password) 		-> "Invalid password";
api_error(invalid_reply) 			-> "Invalid reply";
api_error(invalid_role)			    -> "Invalid role";
api_error(invalid_session_id)		-> "Invalid session";
api_error(invalid_state) 			-> "Invalid state";
api_error(invalid_uri) 			    -> "Invalid Uri";
api_error(invalid_object_id) 		-> "Invalid ObjectId";
api_error({missing_field, Txt})	    -> {"Missing field: '~s'", [Txt]};
api_error(missing_id)				-> "Missing Id";
api_error(no_usages)           		-> "No remaining usages";
api_error(normal)           		-> "Normal termination";
api_error(normal_termination) 		-> "Normal termination";
api_error(not_authenticated)		-> "Not authenticated";
api_error(not_found) 				-> "Not found";
api_error(not_started) 				-> "Not yet started";
api_error(not_implemented) 		    -> "Not implemented";
api_error(process_down)  			-> "Process failed";
api_error(process_not_found) 		-> "Process not found";
api_error(registered_down) 	        -> "Registered process stopped";
api_error(service_not_found) 		-> "Service not found";
api_error(session_not_found) 		-> "Session not found";
api_error(session_stop) 			-> "Session stop";
api_error(session_timeout) 		    -> "Session timeout";
api_error({syntax_error, Txt})		-> {"Syntax error: '~s'", [Txt]};
api_error(timeout) 				    -> "Timeout";
api_error(unauthorized) 			-> "Unauthorized";
api_error({unknown_command, Txt})	-> {"Unknown command '~s'", [Txt]};
api_error(unknown_peer) 			-> "Unknown peer";
api_error(unknown_op)   			-> "Unknown operation";
api_error(user_not_found)			-> "User not found";
api_error({user_not_found, User})	-> {"User not found: '~s'", [User]};
api_error(user_stop) 				-> "User stop";
api_error(_)   		                -> continue.


%% ===================================================================
%% API Server Callbacks
%% ===================================================================

-type state() :: nkapi_server:user_state().
-type http_method() :: nkapi_server_http:method().
-type http_path() :: nkapi_server_http:path().
-type http_req() :: nkapi_server_http:req().
-type http_reply() :: nkapi_server_http:reply().



%% @doc Called when a new connection starts
-spec api_server_init(nkpacket:nkport(), state()) ->
	{ok, state()} | {stop, term()}.

api_server_init(_NkPort, State) ->
	{ok, State}.


%%%% @doc Used when the standard login apply
%%%% Called from nkapi_api or nkapi_server_http
%%-spec api_server_login(map(), state()) ->
%%	{true, User::binary(), Meta::map(), state()} |
%%	{false, error_code(), state()} | continue.
%%
%%api_server_login(_Data, State) ->
%%	{false, unauthorized, State}.


%% @doc called when a new http request has been received
-spec api_server_http_auth(http_req(), state()) ->
    {true, User::binary(), Meta::map(), state()} | {false, state()}.

api_server_http_auth(Req, State) ->
    case nkapi_server_http:get_basic_auth(Req) of
        {basic, _User, _Pass} ->
            {false, State};
        undefined ->
            {false, State}
    end.


%% @doc called when a new http request has been received
-spec api_server_http(http_method(), http_path(), http_req(), state()) ->
    http_reply().

api_server_http(post, [<<"api">>], _Req, State) ->
    {rpc, State};

api_server_http(_Method, _Path, _Req, State) ->
    lager:info("NkAPI HTTP path not found: ~p", [_Path]),
    {http, 404, [], <<"Not Found">>, State}.



%%%% @doc Called when the API server receives an event notification from
%%%% nkevent (because we are subscribed to it).
%%%% We can send it to the remote side or ignore it.
%%-spec api_server_forward_event(nkevent:event(), state()) ->
%%	{ok, nkevent:event(), continue()} |
%%	{ignore, state()}.
%%
%%api_server_forward_event(Event, State) ->
%%	{ok, Event, State}.


%% @doc Called when the service process receives a registered process down
-spec api_server_reg_down(nklib:link(), Reason::term(), state()) ->
	{ok, state()} | {stop, Reason::term(), state()} | continue().

api_server_reg_down(_Link, _Reason, State) ->
    {ok, State}.


%% @doc Called when the process receives a handle_call/3.
-spec api_server_handle_call(term(), {pid(), reference()}, state()) ->
	{ok, state()} | continue().

api_server_handle_call(Msg, _From, State) ->
    lager:error("Module nkapi_server received unexpected call ~p", [Msg]),
    {ok, State}.


%% @doc Called when the process receives a handle_cast/3.
-spec api_server_handle_cast(term(), state()) ->
	{ok, state()} | continue().

api_server_handle_cast(Msg, State) ->
    lager:error("Module nkapi_server received unexpected cast ~p", [Msg]),
	{ok, State}.


%% @doc Called when the process receives a handle_info/3.
-spec api_server_handle_info(term(), state()) ->
	{ok, state()} | continue().

api_server_handle_info(Msg, State) ->
    lager:notice("Module nkapi_server received unexpected info ~p", [Msg]),
	{ok, State}.


%% @doc
-spec api_server_code_change(term()|{down, term()}, state(), term()) ->
    ok | {ok, state()} | {error, term()} | continue().

api_server_code_change(OldVsn, State, Extra) ->
	{continue, [OldVsn, State, Extra]}.


%% @doc Called when a service is stopped
-spec api_server_terminate(term(), state()) ->
	{ok, state()}.

api_server_terminate(_Reason, State) ->
	{ok, State}.


%% ===================================================================
%% Service Callbacks
%% ===================================================================


%% @doc
service_api_syntax(#nkreq{session_module=nkapi_server, cmd=Cmd}=Req, SyntaxAcc) ->
    {nkapi_api_syntax:syntax(Cmd, SyntaxAcc), Req};

service_api_syntax(_Req, _SyntaxAcc) ->
    continue.


%% @doc
service_api_cmd(#nkreq{session_module=nkapi_server, cmd=Cmd}=Req) ->
    nkapi_api_cmd:cmd(Cmd, Req);

service_api_cmd(_Req) ->
    continue.

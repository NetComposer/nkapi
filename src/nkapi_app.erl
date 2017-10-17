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

%% @doc NkAPI Domain Application Module
-module(nkapi_app).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').
-behaviour(application).

-export([start/0, start/1, start/2, stop/1]).
-export([get/1, put/2, del/1]).

-include("nkapi.hrl").

-define(APP, nkapi).
-compile({no_auto_import, [get/1, put/2]}).

%% ===================================================================
%% Private
%% ===================================================================

%% @doc Starts NkAPI stand alone.
-spec start() -> 
    ok | {error, Reason::term()}.

start() ->
    start(temporary).


%% @doc Starts NkAPI stand alone.
-spec start(permanent|transient|temporary) -> 
    ok | {error, Reason::term()}.

start(Type) ->
    % nkdist_util:ensure_dir(),
    case nklib_util:ensure_all_started(?APP, Type) of
        {ok, _Started} ->
            ok;
        Error ->
            Error
    end.


%% @private OTP standard start callback
start(_Type, _Args) ->
    nkpacket:register_protocol(nkapi, nkapi_server),
    %nkpacket:register_protocol(nkapi_c, nkapi_client),
    Syntax = #{
        api_ping_timeout => {integer, 5, none},
        api_cmd_timeout => {integer, 5, none},
        '__defaults' => #{
            api_ping_timeout => 60,
            api_cmd_timeout => 10
        }
    },
    case nklib_config:load_env(?APP, Syntax) of
        {ok, _} ->
            {ok, Pid} = nkapi_sup:start_link(),
            {ok, Vsn} = application:get_key(nkapi, vsn),
            lager:info("NkAPI v~s has started.", [Vsn]),
            {ok, Pid};
        {error, Error} ->
            lager:error("Error parsing config: ~p", [Error]),
            error(Error)
    end.


%% @private OTP standard stop callback
stop(_) ->
    ok.


%% @doc gets a configuration value
get(Key) ->
    get(Key, undefined).


%% @doc gets a configuration value
get(Key, Default) ->
    nklib_config:get(?APP, Key, Default).


%% @doc updates a configuration value
put(Key, Value) ->
    nklib_config:put(?APP, Key, Value).


%% @doc updates a configuration value
del(Key) ->
    nklib_config:del(?APP, Key).


